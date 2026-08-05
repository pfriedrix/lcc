//! The session daemon: one process, one lock, one poll loop, and no timer at
//! all when nothing is pending.
//!
//! **Single-threaded by construction, and that is a hard requirement rather
//! than a simplification.** `pty.spawn` forks, and a fork from a process with a
//! thread pool leaves the child holding locks no surviving thread will ever
//! release — libc's allocator lock among them — so it can deadlock before it
//! reaches `execve`. `Io.Group` and `Io.async` spawn detached pooled threads
//! that live for the rest of the process (`Io/Threaded.zig`), so **neither may
//! be used anywhere the daemon can reach**. `src/commands/list.zig` uses
//! `Io.Group` quite correctly for its own purposes; copying that shape into
//! here would be a heisenbug that only appears under load.
//!
//! The loop is `std.posix.poll` over the listener, every client socket, every
//! pty master and a self-pipe. That is also why a task-per-session design was
//! rejected: it would need a mutex over the ring, the client list and the
//! registry, which is synchronisation for a workload whose entire point is
//! being idle.

const std = @import("std");
const Io = std.Io;
const app_mod = @import("app.zig");
const watch_paths = @import("watch_paths.zig");

extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;

pub const Options = struct {
    /// Skips the double fork and the stdio redirect, so the loop can run on a
    /// thread inside a test. Also what `lcc daemon --foreground` sets.
    foreground: bool = false,
    /// Exit once nothing has been running for this long, so a laptop does not
    /// accumulate daemons from months of finished work.
    idle_exit_seconds: i64 = 30 * 60,
    max_sessions: u32 = 64,
    max_clients_per_session: u32 = 8,
    scrollback_bytes: usize = 256 * 1024,
};

pub const BindError = error{
    SocketPathOccupied,
} || watch_paths.Error || Io.File.OpenError || Io.net.UnixAddress.ListenError;

pub const Bound = struct {
    /// Held for the daemon's whole life. Both the single-instance guard and the
    /// liveness probe: a client that could take this lock would know the socket
    /// beside it is stale.
    ///
    /// Opened through `Io.Dir`, which sets `O_CLOEXEC`, and that is load-bearing
    /// rather than incidental: `flock` is per open-file-description and
    /// inherited across fork, released only when every copy closes. A lock fd
    /// that leaked into a Claude Code child would answer "still held" for as
    /// long as that agent ran, wedging every future daemon restart.
    lock_file: Io.File,
    server: Io.net.Server,
    socket_path: []const u8,

    pub fn deinit(self: *Bound, io: Io) void {
        self.server.deinit(io);
        // Unlink before unlocking: the reverse order leaves a window in which
        // the next daemon takes the lock and then has its fresh socket deleted
        // by this one.
        Io.Dir.cwd().deleteFile(io, self.socket_path) catch {};
        self.lock_file.unlock(io);
        self.lock_file.close(io);
    }
};

/// Take the lock, remove a stale socket, then listen — in that order, always.
///
/// Null when another daemon holds the lock, which is the whole two-daemon
/// guard: the loser exits in milliseconds and its client connects to the
/// winner. Unlinking before locking would let a starting daemon delete a *live*
/// daemon's socket, which is the one ordering mistake here that loses sessions.
pub fn bind(app: app_mod.App, opts: Options) BindError!?Bound {
    _ = opts;
    const dir = try watch_paths.dir(app.gpa, app.environ);
    const socket_path = try watch_paths.socket(app.gpa, app.environ);
    const lock_path = try watch_paths.lock(app.gpa, app.environ);

    const cwd = Io.Dir.cwd();
    cwd.createDirPath(app.io, dir) catch {};

    // macOS enforces the socket file's permissions on `connect`, and the
    // default umask leaves it world-readable. Without this another local
    // account could attach to a session and get a shell in the worktree.
    if (app.gpa.dupeZ(u8, dir)) |dir_z| {
        _ = chmod(dir_z.ptr, 0o700);
    } else |_| {}

    const lock_file = try cwd.createFile(app.io, lock_path, .{ .truncate = false });
    errdefer lock_file.close(app.io);
    if (!try lock_file.tryLock(app.io, .exclusive)) {
        lock_file.close(app.io);
        return null;
    }

    // The lock is ours, so whoever left this socket behind is gone. std does
    // not do this: `UnixAddress.listen` goes straight to bind and fails with
    // AddressInUse on a leftover path.
    cwd.deleteFile(app.io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        // A directory (or anything undeletable) sitting on the socket path is
        // worth naming, rather than falling through into a confusing
        // AddressInUse from the listen below.
        else => return BindError.SocketPathOccupied,
    };

    const address = Io.net.UnixAddress.init(socket_path) catch return BindError.SocketPathTooLong;
    const server = try address.listen(app.io, .{});
    return .{ .lock_file = lock_file, .server = server, .socket_path = socket_path };
}

/// Everything the loop might have to wake up for. All optional: absent means
/// "nothing pending of this kind".
pub const Deadlines = struct {
    /// The debounced registry write.
    registry_flush_at: ?i64 = null,
    /// A child that has closed its pty but not yet been reaped.
    reap_retry_at: ?i64 = null,
    /// The listener was dropped from the poll set after EMFILE.
    listener_resume_at: ?i64 = null,
    /// Nothing is running; exit when this passes.
    idle_exit_at: ?i64 = null,
    /// Re-evaluate time-based status decay.
    decay_at: ?i64 = null,
};

/// Milliseconds for `std.posix.poll`: the nearest pending deadline, `0` when one
/// is already due, and `-1` when there is none.
///
/// The `-1` is the point. With no sessions and no attached clients the daemon
/// blocks indefinitely and costs *zero* wakeups — not "almost no CPU", none —
/// which is the difference between a daemon worth leaving running on a laptop
/// and one that is not. A fixed tick would burn four wakeups a second forever
/// to notice nothing.
pub fn nextTimeout(now_ms: i64, d: Deadlines) i32 {
    var soonest: ?i64 = null;
    inline for (@typeInfo(Deadlines).@"struct".fields) |field| {
        if (@field(d, field.name)) |at| {
            if (soonest == null or at < soonest.?) soonest = at;
        }
    }
    const at = soonest orelse return -1;
    // Never negative: `poll` reads a negative timeout as "block forever", so an
    // off-by-one here turns an overdue registry flush into a hang.
    if (at <= now_ms) return 0;
    const delta = at - now_ms;
    return @intCast(@min(delta, std.math.maxInt(i32)));
}

const testing = std.testing;

test "with nothing pending the daemon blocks rather than ticking" {
    // The zero-wakeup requirement, expressed as a pure function so it can be
    // pinned. If this ever returns a number, an idle daemon starts costing
    // wakeups forever to discover that nothing happened.
    try testing.expectEqual(@as(i32, -1), nextTimeout(1_000, .{}));
}

test "the nearest deadline wins, and one already past is zero, never negative" {
    const now: i64 = 10_000;

    try testing.expectEqual(@as(i32, 500), nextTimeout(now, .{ .registry_flush_at = now + 500 }));

    // Whichever comes first, regardless of which field it is in.
    try testing.expectEqual(@as(i32, 250), nextTimeout(now, .{
        .registry_flush_at = now + 500,
        .reap_retry_at = now + 250,
        .idle_exit_at = now + 900_000,
    }));

    // Exactly due, and overdue, are both "run now". A negative return would
    // mean *block forever* to poll, so an overdue flush would never happen.
    try testing.expectEqual(@as(i32, 0), nextTimeout(now, .{ .registry_flush_at = now }));
    try testing.expectEqual(@as(i32, 0), nextTimeout(now, .{ .registry_flush_at = now - 5_000 }));
}

test "a deadline beyond i32 milliseconds is clamped, not wrapped" {
    // idle_exit_at can sit half an hour out, and a clock jump could put a
    // deadline much further. Wrapping into a negative would block the daemon
    // forever; clamping just wakes it early to find nothing to do.
    const huge = nextTimeout(0, .{ .idle_exit_at = std.math.maxInt(i64) });
    try testing.expectEqual(std.math.maxInt(i32), huge);
    try testing.expect(huge > 0);
}

test "bind takes the lock, and a second bind on the same directory declines" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_WATCH_DIR", base);

    const socket_path = watch_paths.socket(arena, &environ) catch |err| switch (err) {
        // A deep tmpDir can exceed Darwin's 104-byte sun_path. Skipping beats
        // failing on something that says nothing about the code under test.
        error.SocketPathTooLong => return error.SkipZigTest,
        else => return err,
    };
    _ = socket_path;

    var out_buf: [1024]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out_w: Io.Writer = .fixed(&out_buf);
    var err_w: Io.Writer = .fixed(&err_buf);
    const app: app_mod.App = .{
        .gpa = arena,
        .io = io,
        .environ = &environ,
        .ui = .{ .io = io, .out = &out_w, .err = &err_w },
    };

    var first = (try bind(app, .{})) orelse return error.TestExpectedEqual;
    defer first.deinit(io);

    // The two-daemon guard. A second daemon must decline in milliseconds and
    // leave the live one's socket alone, rather than unlinking it and listening
    // on top — which would strand every session the first one owns.
    const before = try Io.Dir.cwd().statFile(io, first.socket_path, .{});
    try testing.expect((try bind(app, .{})) == null);
    const after = try Io.Dir.cwd().statFile(io, first.socket_path, .{});
    try testing.expectEqual(before.inode, after.inode);
}

test "a stale socket left by a killed daemon is replaced, not tripped over" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_WATCH_DIR", base);

    const socket_path = watch_paths.socket(arena, &environ) catch |err| switch (err) {
        error.SocketPathTooLong => return error.SkipZigTest,
        else => return err,
    };

    // What SIGKILL leaves behind: the kernel drops the flock but the socket
    // file stays. std's `listen` does not unlink, so without the step in `bind`
    // every restart after a crash would fail with AddressInUse forever.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = socket_path, .data = "stale" });

    var out_buf: [1024]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out_w: Io.Writer = .fixed(&out_buf);
    var err_w: Io.Writer = .fixed(&err_buf);
    const app: app_mod.App = .{
        .gpa = arena,
        .io = io,
        .environ = &environ,
        .ui = .{ .io = io, .out = &out_w, .err = &err_w },
    };

    var bound = (try bind(app, .{})) orelse return error.TestExpectedEqual;
    defer bound.deinit(io);
}

test "a directory sitting on the socket path is a named error, not a panic" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_WATCH_DIR", base);

    const socket_path = watch_paths.socket(arena, &environ) catch |err| switch (err) {
        error.SocketPathTooLong => return error.SkipZigTest,
        else => return err,
    };
    try Io.Dir.cwd().createDirPath(io, socket_path);

    var out_buf: [1024]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out_w: Io.Writer = .fixed(&out_buf);
    var err_w: Io.Writer = .fixed(&err_buf);
    const app: app_mod.App = .{
        .gpa = arena,
        .io = io,
        .environ = &environ,
        .ui = .{ .io = io, .out = &out_w, .err = &err_w },
    };

    // Naming it beats falling through to an AddressInUse that sends the reader
    // looking for another daemon that does not exist.
    try testing.expectError(BindError.SocketPathOccupied, bind(app, .{}));
}
