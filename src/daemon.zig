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
const exec = @import("exec.zig");
const pty = @import("pty.zig");
const sessions_mod = @import("sessions.zig");
const watch_hooks = @import("watch_hooks.zig");
const watch_paths = @import("watch_paths.zig");
const watch_session = @import("watch_session.zig");
const wire = @import("wire.zig");

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

/// The write end of the self-pipe, for the SIGCHLD handler.
///
/// The one global in this codebase, and it exists because a signal handler has
/// no other channel: it may touch nothing but an atomic and an async-signal-safe
/// call. Without it a child's death could not wake the loop at all —
/// `std.posix.poll` swallows EINTR and restarts with the *full* timeout, so a
/// signal alone is invisible to it.
var wake_write_fd: std.atomic.Value(i32) = .init(-1);

fn onChild(_: std.c.SIG) callconv(.c) void {
    const fd = wake_write_fd.load(.monotonic);
    if (fd < 0) return;
    const byte = [_]u8{0};
    // A full pipe means a wake is already queued, so the result is discarded.
    _ = std.c.write(fd, &byte, 1);
}

const Client = struct {
    stream: Io.net.Stream,
    fd: std.posix.fd_t,
    role: wire.Role = .control,
    said_hello: bool = false,
    dec_buf: []u8,
    dec: wire.Decoder,
    /// Bounded by one frame: bytes are taken from the session's ring only when
    /// this is empty, so a slow client costs one frame of memory, not a queue.
    out: std.ArrayList(u8) = .empty,
    /// The session this connection is attached to, by id rather than index —
    /// indices move when a session is removed.
    attached: ?[]const u8 = null,
    cursor: u64 = 0,
    size: pty.Size = .{ .rows = 24, .cols = 80 },
    /// A connection that says nothing must not hold an fd forever.
    handshake_deadline: i64,
    dead: bool = false,

    fn wantsWrite(self: Client) bool {
        return self.out.items.len > 0;
    }
};

fn readFd(fd: std.posix.fd_t, buf: []u8) pty.Read {
    while (true) {
        const rc = std.c.read(fd, buf.ptr, buf.len);
        if (rc > 0) return .{ .n = @intCast(rc) };
        if (rc == 0) return .closed;
        switch (std.posix.errno(rc)) {
            // Io.Threaded's SIGPIPE handler carries no SA_RESTART, so an
            // interrupted read is ours to retry.
            .INTR => continue,
            .AGAIN => return .again,
            else => return .closed,
        }
    }
}

fn writeFd(fd: std.posix.fd_t, bytes: []const u8) pty.Write {
    while (true) {
        const rc = std.c.write(fd, bytes.ptr, bytes.len);
        if (rc >= 0) return .{ .n = @intCast(rc) };
        switch (std.posix.errno(rc)) {
            .INTR => continue,
            .AGAIN => return .again,
            else => return .closed,
        }
    }
}

fn setNonblocking(fd: std.posix.fd_t) void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    var o: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
    o.NONBLOCK = true;
    _ = std.c.fcntl(fd, std.posix.F.SETFL, @as(c_int, @bitCast(o)));
}

/// Detach from the terminal that started us.
///
/// Two forks. The first makes us a non-leader so `setsid` can succeed — it
/// fails with EPERM for a process-group leader, which is what `lcc daemon`
/// typed into a job-control shell always is. The second makes us a non-leader
/// again, so no later `open` of a terminal can hand *us* a controlling
/// terminal: `forkpty` opens each slave in the parent, and a session-leading
/// daemon could acquire one and start receiving that session's SIGHUP.
fn daemonize(app: app_mod.App) void {
    // Anything still buffered would be printed again by the child.
    app.ui.flush();

    if (std.c.fork() != 0) std.c._exit(0);
    _ = std.c.setsid();
    if (std.c.fork() != 0) std.c._exit(0);

    const log_path = watch_paths.logFile(app.gpa, app.environ) catch return;
    if (std.fs.path.dirname(log_path)) |parent| {
        Io.Dir.cwd().createDirPath(app.io, parent) catch {};
    }
    const log = Io.Dir.cwd().createFile(app.io, log_path, .{ .truncate = false }) catch return;
    _ = std.c.dup2(log.handle, 1);
    _ = std.c.dup2(log.handle, 2);
}

const Loop = struct {
    app: app_mod.App,
    opts: Options,
    bound: *Bound,
    list: std.ArrayList(watch_session.Session) = .empty,
    clients: std.ArrayList(Client) = .empty,
    wake_r: std.posix.fd_t,
    started_at: i64 = 0,
    next_id: u32 = 1,
    running: bool = true,
    dirty: bool = true,
    deadlines: Deadlines = .{},

    fn now(self: *Loop) i64 {
        return app_mod.nowSeconds(self.app.io);
    }

    fn find(self: *Loop, id: []const u8) ?*watch_session.Session {
        for (self.list.items) |*s| {
            if (std.mem.eql(u8, s.id, id)) return s;
        }
        return null;
    }

    /// Sessions filed by worktree, which is the key hook payloads carry.
    fn findByWorktree(self: *Loop, cwd: []const u8) ?*watch_session.Session {
        for (self.list.items) |*s| {
            if (std.mem.eql(u8, s.worktree, cwd)) return s;
        }
        return null;
    }

    fn send(self: *Loop, client: *Client, t: wire.Type, payload: []const u8) void {
        const header = wire.encodeHeader(t, @intCast(payload.len));
        client.out.appendSlice(self.app.gpa, &header) catch {
            client.dead = true;
            return;
        };
        client.out.appendSlice(self.app.gpa, payload) catch {
            client.dead = true;
        };
    }

    fn sendControl(self: *Loop, client: *Client, t: wire.Type, value: anytype) void {
        const body = std.json.Stringify.valueAlloc(self.app.gpa, value, .{}) catch return;
        defer self.app.gpa.free(body);
        self.send(client, t, body);
    }

    fn fail(self: *Loop, client: *Client, code: []const u8, message: []const u8) void {
        self.sendControl(client, .err, wire.ErrorBody{ .code = code, .message = message });
    }
};

/// Runs until the last session is gone or a client asks it to stop.
///
/// Returns immediately when another daemon already holds the lock, which is the
/// whole two-daemon guard — a concurrent `lcc start --watch` may spawn several,
/// and all but one evaporate in milliseconds.
pub fn run(app: app_mod.App, opts: Options) !void {
    // Before the fork, because after it there is nowhere left to complain: the
    // terminal is gone and the log lives under the very directory that a path
    // problem is usually about. A daemon that fails here should say so to the
    // person who ran it, not vanish.
    _ = try watch_paths.socket(app.gpa, app.environ);

    if (!opts.foreground) daemonize(app);

    // Stay detached: a hangup on the terminal that started us must not take the
    // sessions with it. Never SIGIO or SIGPIPE — `Io.Threaded` owns those, and
    // its SIGPIPE handler is what turns a write to a dead client into EPIPE
    // instead of a dead daemon.
    const ignore: std.posix.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]std.c.SIG{ .HUP, .INT, .QUIT, .TSTP, .TTIN, .TTOU }) |sig| {
        std.posix.sigaction(sig, &ignore, null);
    }

    var wake: [2]std.posix.fd_t = .{ -1, -1 };
    if (std.c.pipe(&wake) != 0) return error.SpawnFailed;
    setNonblocking(wake[0]);
    setNonblocking(wake[1]);
    _ = std.c.fcntl(wake[0], std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC));
    _ = std.c.fcntl(wake[1], std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC));
    wake_write_fd.store(wake[1], .monotonic);

    const on_child: std.posix.Sigaction = .{
        .handler = .{ .handler = onChild },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.CHLD, &on_child, null);

    // macOS defaults the soft limit to 256, which a handful of sessions plus
    // their clients can reach.
    if (std.posix.getrlimit(.NOFILE)) |limit| {
        var raised = limit;
        raised.cur = @min(limit.max, 4096);
        std.posix.setrlimit(.NOFILE, raised) catch {};
    } else |_| {}

    var bound = (try bind(app, opts)) orelse return;
    defer bound.deinit(app.io);

    try writeHookSettings(app);

    var loop: Loop = .{
        .app = app,
        .opts = opts,
        .bound = &bound,
        .wake_r = wake[0],
        .started_at = app_mod.nowSeconds(app.io),
    };
    try serve(&loop);
}

/// The `--settings` file every session is launched with. Written once at
/// startup rather than per session, because its contents do not vary.
fn writeHookSettings(app: app_mod.App) !void {
    const exe = try exec.selfPath(app.gpa, app.io);
    const socket_path = try watch_paths.socket(app.gpa, app.environ);
    const body = try watch_hooks.settingsJson(app.gpa, exe, socket_path);
    const path = try watch_paths.hooks(app.gpa, app.environ);
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = body });
}

fn serve(loop: *Loop) !void {
    const gpa = loop.app.gpa;
    var fds: std.ArrayList(std.posix.pollfd) = .empty;
    defer fds.deinit(gpa);

    var idle_since: ?i64 = loop.now();

    while (loop.running) {
        // Before the poll, not after. The deadlines are what the poll timeout is
        // computed from, so a tick that ran afterwards would leave the first
        // iteration with nothing pending — and `nextTimeout` correctly answers
        // "block forever" to that, so the daemon would sleep before ever writing
        // the registry that tells anyone it exists.
        tick(loop, loop.now(), &idle_since);

        fds.clearRetainingCapacity();
        try fds.append(gpa, .{ .fd = loop.wake_r, .events = std.posix.POLL.IN, .revents = 0 });

        const listener_at = fds.items.len;
        const accepting = loop.list.items.len < loop.opts.max_sessions and
            loop.deadlines.listener_resume_at == null;
        if (accepting) {
            try fds.append(gpa, .{
                .fd = loop.bound.server.socket.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            });
        }

        const sessions_at = fds.items.len;
        // Counted here, not re-read after the poll: handling one event can add
        // a session or a client, and `fds` describes the world as it was when
        // it was built. Indexing it by the live length walks off the end.
        const session_count = loop.list.items.len;
        for (loop.list.items) |*s| {
            var events: i16 = if (s.master_open) std.posix.POLL.IN else 0;
            if (s.wantsWrite()) events |= std.posix.POLL.OUT;
            try fds.append(gpa, .{ .fd = if (s.master_open) s.master else -1, .events = events, .revents = 0 });
        }

        const clients_at = fds.items.len;
        const client_count = loop.clients.items.len;
        for (loop.clients.items) |*c| {
            var events: i16 = std.posix.POLL.IN;
            // Armed only when there is something to send, so a caught-up client
            // contributes zero wakeups — which is what keeps an idle daemon at
            // zero even with clients attached.
            if (c.wantsWrite()) events |= std.posix.POLL.OUT;
            try fds.append(gpa, .{ .fd = c.fd, .events = events, .revents = 0 });
        }

        const now_ms = loop.now() * std.time.ms_per_s;
        _ = std.posix.poll(fds.items, nextTimeout(now_ms, loop.deadlines)) catch {};

        const at = loop.now();

        if (fds.items[0].revents != 0) drainWake(loop);
        if (accepting and fds.items[listener_at].revents != 0) acceptClient(loop, at);

        for (0..session_count) |i| {
            const revents = fds.items[sessions_at + i].revents;
            if (revents == 0) continue;
            const s = &loop.list.items[i];
            if (revents & std.posix.POLL.OUT != 0) s.onWritable();
            if (revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
                if (s.onReadable(at)) _ = s.reap(at);
            }
        }

        for (0..client_count) |i| {
            const revents = fds.items[clients_at + i].revents;
            if (revents == 0) continue;
            // Re-indexed rather than held across the loop: registering a
            // session or accepting a peer can reallocate these lists.
            if (revents & std.posix.POLL.OUT != 0) flushClient(loop, &loop.clients.items[i]);
            if (revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
                readClient(loop, &loop.clients.items[i], at);
            }
        }

        pump(loop);
        reapDead(loop);
    }

    flushRegistry(loop, loop.now());
}

fn drainWake(loop: *Loop) void {
    var buf: [256]u8 = undefined;
    while (readFd(loop.wake_r, &buf) == .n) {}
    // A child died. Which one is not in the signal, so every known pid is
    // offered a non-blocking reap — never `waitpid(-1)`, which would steal a
    // status `std.process.Child.wait` is blocked on elsewhere and hang it.
    const at = loop.now();
    for (loop.list.items) |*s| {
        if (s.exit == null and s.reap(at)) loop.dirty = true;
    }
}

fn acceptClient(loop: *Loop, at: i64) void {
    const stream = loop.bound.server.accept(loop.app.io) catch |err| switch (err) {
        // A full fd table leaves the listener permanently readable, so letting
        // accept keep failing would spin at 100% CPU — the exact inversion of
        // this daemon's reason for existing. Drop it from the set for a second.
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => {
            loop.deadlines.listener_resume_at = (loop.now() + 1) * std.time.ms_per_s;
            return;
        },
        // The peer aborted between poll and accept. Ordinary.
        else => return,
    };

    const buf = loop.app.gpa.alloc(u8, wire.bufferLen()) catch {
        stream.close(loop.app.io);
        return;
    };
    const dec = wire.Decoder.init(buf, .control) catch {
        stream.close(loop.app.io);
        return;
    };
    const fd = stream.socket.handle;
    setNonblocking(fd);

    loop.clients.append(loop.app.gpa, .{
        .stream = stream,
        .fd = fd,
        .dec_buf = buf,
        .dec = dec,
        // Otherwise `nc daemon.sock` pins an fd and a slot forever.
        .handshake_deadline = at + 5,
    }) catch stream.close(loop.app.io);
}

fn readClient(loop: *Loop, client: *Client, at: i64) void {
    while (true) {
        const room = client.dec.writable();
        if (room.len == 0) break;
        switch (readFd(client.fd, room)) {
            .n => |n| client.dec.commit(n),
            .again => break,
            .closed => {
                client.dead = true;
                return;
            },
        }
        while (client.dec.next() catch {
            client.dead = true;
            return;
        }) |frame| handleFrame(loop, client, frame, at);
        if (client.dead) return;
    }
}

fn handleFrame(loop: *Loop, client: *Client, frame: wire.Frame, at: i64) void {
    const gpa = loop.app.gpa;

    if (!client.said_hello) {
        if (frame.type != .hello) {
            loop.fail(client, "expected_hello", "The first frame must be a hello.");
            client.dead = true;
            return;
        }
        const hello = wire.parse(wire.Hello, gpa, frame) catch {
            client.dead = true;
            return;
        };
        if (hello.protocol != wire.protocol) {
            // Named, not guessed at. `lcc` on PATH is a symlink into
            // zig-out/bin, so a rebuild swaps the client under a running daemon
            // routinely — and a garbled byte stream into a live session is a far
            // worse outcome than a sentence.
            loop.fail(client, "protocol_mismatch", "This daemon speaks a different protocol version.");
            client.dead = true;
            return;
        }
        client.role = if (std.mem.eql(u8, hello.role, "attach")) .attach else .control;
        client.dec.role = client.role;
        client.said_hello = true;
        client.handshake_deadline = 0;
        loop.sendControl(client, .hello, wire.Hello{
            .role = @tagName(client.role),
            .pid = @intCast(std.c.getpid()),
        });
        return;
    }

    if (!wire.allowedOn(frame.type, client.role)) {
        loop.fail(client, "wrong_role", "That frame does not belong on this connection.");
        client.dead = true;
        return;
    }

    switch (frame.type) {
        .register => registerSession(loop, client, frame, at),
        .list => sendSnapshot(loop, client),
        .kill => {
            const body = wire.parse(wire.Kill, gpa, frame) catch return;
            if (loop.find(body.session_id)) |s| {
                s.stop(std.mem.eql(u8, body.signal, "KILL"));
            } else loop.fail(client, "unknown_session", "No such session.");
        },
        .stop => {
            const body = wire.parse(wire.Stop, gpa, frame) catch return;
            for (loop.list.items) |*s| s.stop(body.force);
            loop.running = false;
        },
        .hook => {
            const body = wire.parse(wire.Hook, gpa, frame) catch return;
            const event = watch_hooks.Event.parse(body.event) orelse return;
            // Keyed by worktree. A cwd the daemon does not know is a Claude Code
            // session it did not start — ignored rather than an error, so a
            // stale hook config cannot make anything fail.
            const session = loop.findByWorktree(body.cwd) orelse return;
            if (session.note(event, at)) loop.dirty = true;
        },
        .attach => attachClient(loop, client, frame),
        .detach => detachClient(loop, client),
        .resize => {
            const body = wire.parse(wire.Resize, gpa, frame) catch return;
            client.size = .{ .rows = body.rows, .cols = body.cols };
            renegotiate(loop);
        },
        .input => {
            const id = client.attached orelse return;
            if (loop.find(id)) |s| s.queueInput(frame.payload);
        },
        else => {},
    }
}

fn registerSession(loop: *Loop, client: *Client, frame: wire.Frame, at: i64) void {
    const gpa = loop.app.gpa;
    const body = wire.parse(wire.Register, gpa, frame) catch {
        loop.fail(client, "bad_register", "Malformed register payload.");
        return;
    };
    if (loop.list.items.len >= loop.opts.max_sessions) {
        loop.fail(client, "session_limit", "Too many sessions.");
        return;
    }

    const id = std.fmt.allocPrint(gpa, "s-{x:0>8}", .{loop.next_id}) catch return;
    loop.next_id += 1;

    const session = watch_session.Session.start(gpa, .{
        .id = id,
        .worktree = body.worktree,
        .branch = body.branch,
        .issue = body.issue,
        .repo_root = body.repo_root,
    }, .{
        .program = body.program,
        .argv = body.argv,
        .env = body.env,
        .cwd = body.worktree,
        .size = .{ .rows = body.rows, .cols = body.cols },
    }, loop.opts.scrollback_bytes, at) catch {
        loop.fail(client, "spawn_failed", "Could not start a session.");
        return;
    };

    loop.list.append(gpa, session) catch return;
    loop.dirty = true;
    loop.sendControl(client, .registered, wire.Registered{
        .session_id = id,
        .pid = @intCast(session.pid),
        .status = @tagName(session.status),
        .started_at = session.started_at,
    });
}

fn sendSnapshot(loop: *Loop, client: *Client) void {
    const gpa = loop.app.gpa;
    var rows = gpa.alloc(sessions_mod.Session, loop.list.items.len) catch return;
    for (loop.list.items, 0..) |*s, i| rows[i] = s.entry();

    // Cut rather than fail: a caller that sees `truncated` knows its view is
    // partial, which beats a snapshot that never arrives.
    var truncated = false;
    while (rows.len > 0) {
        const body = std.json.Stringify.valueAlloc(gpa, wire.Snapshot{
            .daemon_pid = @intCast(std.c.getpid()),
            .protocol = wire.protocol,
            .sessions = rows,
            .truncated = truncated,
        }, .{}) catch return;
        if (body.len <= wire.max_payload) {
            loop.send(client, .snapshot, body);
            gpa.free(body);
            return;
        }
        gpa.free(body);
        rows = rows[0 .. rows.len / 2];
        truncated = true;
    }
}

fn attachClient(loop: *Loop, client: *Client, frame: wire.Frame) void {
    const gpa = loop.app.gpa;
    const body = wire.parse(wire.Attach, gpa, frame) catch return;
    const session = loop.find(body.session_id) orelse {
        loop.fail(client, "unknown_session", "No such session.");
        return;
    };

    client.attached = session.id;
    client.size = .{ .rows = body.rows, .cols = body.cols };
    // Replay from the oldest byte still held, so an attaching client can
    // repaint rather than staring at a blank screen until the agent next prints.
    client.cursor = if (body.replay) session.scrollback.oldest() else session.scrollback.written;

    var attached: u32 = 0;
    for (loop.clients.items) |*c| {
        if (c.attached) |id| {
            if (std.mem.eql(u8, id, session.id)) attached += 1;
        }
    }
    loop.sendControl(client, .attached, wire.Attached{
        .session_id = session.id,
        .cols = session.size.cols,
        .rows = session.size.rows,
        .input = true,
        .attached_clients = attached,
    });
    renegotiate(loop);
}

fn detachClient(loop: *Loop, client: *Client) void {
    client.attached = null;
    renegotiate(loop);
}

/// The pty takes the smallest attached terminal. Nobody attached leaves the
/// last size in place, because a 0x0 winsize makes Ink render nothing.
fn renegotiate(loop: *Loop) void {
    const gpa = loop.app.gpa;
    for (loop.list.items) |*s| {
        var sizes: std.ArrayList(pty.Size) = .empty;
        defer sizes.deinit(gpa);
        for (loop.clients.items) |*c| {
            const id = c.attached orelse continue;
            if (!std.mem.eql(u8, id, s.id)) continue;
            sizes.append(gpa, c.size) catch continue;
        }
        const size = watch_session.negotiateSize(sizes.items) orelse continue;
        if (size.rows == s.size.rows and size.cols == s.size.cols) continue;
        s.size = size;
        if (s.master_open) pty.resize(s.master, size);
    }
}

/// Move each attached client forward through its session's ring.
fn pump(loop: *Loop) void {
    for (loop.clients.items) |*c| {
        if (c.dead or c.out.items.len > 0) continue;
        const id = c.attached orelse continue;
        const session = loop.find(id) orelse continue;

        const clamped = session.scrollback.clamp(c.cursor);
        c.cursor = clamped.cursor;
        const parts = session.scrollback.since(c.cursor);
        const available = parts[0].len + parts[1].len;
        if (available == 0) continue;

        const take = @min(available, wire.max_payload);
        const first = @min(parts[0].len, take);
        const header = wire.encodeHeader(.output, @intCast(take));
        c.out.appendSlice(loop.app.gpa, &header) catch continue;
        c.out.appendSlice(loop.app.gpa, parts[0][0..first]) catch continue;
        if (take > first) c.out.appendSlice(loop.app.gpa, parts[1][0 .. take - first]) catch continue;
        c.cursor += take;
    }
}

fn flushClient(loop: *Loop, client: *Client) void {
    while (client.out.items.len > 0) {
        switch (writeFd(client.fd, client.out.items)) {
            .n => |n| {
                if (n == 0) return;
                std.mem.copyForwards(u8, client.out.items[0 .. client.out.items.len - n], client.out.items[n..]);
                client.out.shrinkRetainingCapacity(client.out.items.len - n);
            },
            .again => return,
            // EPIPE. `Io.Threaded` installs a SIGPIPE handler, so this is an
            // error return rather than a dead daemon.
            .closed => {
                client.dead = true;
                return;
            },
        }
    }
    _ = loop;
}

fn tick(loop: *Loop, at: i64, idle_since: *?i64) void {
    for (loop.list.items) |*s| {
        if (s.tick(at)) loop.dirty = true;
        // A session whose pty closed but whose child has not been reaped yet.
        if (!s.master_open and s.exit == null and s.reap(at)) loop.dirty = true;
    }

    if (loop.dirty and loop.deadlines.registry_flush_at == null) {
        // Debounced, so a burst of events costs one write rather than one each.
        loop.deadlines.registry_flush_at = (at + 1) * std.time.ms_per_s;
    }
    if (loop.deadlines.registry_flush_at) |due| {
        if (at * std.time.ms_per_s >= due) {
            flushRegistry(loop, at);
            loop.deadlines.registry_flush_at = null;
        }
    }
    if (loop.deadlines.listener_resume_at) |due| {
        if (at * std.time.ms_per_s >= due) loop.deadlines.listener_resume_at = null;
    }

    var live: usize = 0;
    for (loop.list.items) |*s| {
        if (s.exit == null) live += 1;
    }
    if (live == 0 and loop.clients.items.len == 0) {
        if (idle_since.* == null) idle_since.* = at;
        if (at - idle_since.*.? >= loop.opts.idle_exit_seconds) loop.running = false;
        loop.deadlines.idle_exit_at = (idle_since.*.? + loop.opts.idle_exit_seconds) * std.time.ms_per_s;
    } else {
        idle_since.* = null;
        loop.deadlines.idle_exit_at = null;
    }
}

fn flushRegistry(loop: *Loop, at: i64) void {
    const gpa = loop.app.gpa;
    const rows = gpa.alloc(sessions_mod.Session, loop.list.items.len) catch return;
    defer gpa.free(rows);
    for (loop.list.items, 0..) |*s, i| rows[i] = s.entry();

    sessions_mod.save(gpa, loop.app.io, loop.app.environ, .{
        .daemon = .{
            .pid = @intCast(std.c.getpid()),
            .started_at = loop.started_at,
            .socket = loop.bound.socket_path,
            .protocol = wire.protocol,
            .wrote_at = at,
        },
        .sessions = rows,
    }) catch {};
    loop.dirty = false;
}

/// Drop dead clients, and sessions whose linger has expired.
fn reapDead(loop: *Loop) void {
    var i: usize = 0;
    while (i < loop.clients.items.len) {
        const c = &loop.clients.items[i];
        const timed_out = c.handshake_deadline != 0 and loop.now() > c.handshake_deadline;
        if (c.dead or timed_out) {
            c.stream.close(loop.app.io);
            c.out.deinit(loop.app.gpa);
            loop.app.gpa.free(c.dec_buf);
            _ = loop.clients.orderedRemove(i);
            continue;
        }
        i += 1;
    }
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

/// A blocking framed exchange over a raw socket fd, for the end-to-end test
/// below. Deliberately not `watch_client`: a test that used the client would
/// pass just as happily if both sides shared the same misunderstanding.
const TestConn = struct {
    fd: std.posix.fd_t,
    buf: []u8,
    dec: wire.Decoder,

    fn open(gpa: std.mem.Allocator, io: Io, socket_path: []const u8) !TestConn {
        const address = try Io.net.UnixAddress.init(socket_path);
        const stream = try address.connect(io);
        const buf = try gpa.alloc(u8, wire.bufferLen());
        return .{
            .fd = stream.socket.handle,
            .buf = buf,
            .dec = try wire.Decoder.init(buf, .control),
        };
    }

    fn send(self: *TestConn, gpa: std.mem.Allocator, t: wire.Type, value: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(gpa, value, .{});
        defer gpa.free(body);
        try self.raw(t, body);
    }

    fn raw(self: *TestConn, t: wire.Type, payload: []const u8) !void {
        const header = wire.encodeHeader(t, @intCast(payload.len));
        _ = std.c.write(self.fd, &header, header.len);
        if (payload.len > 0) _ = std.c.write(self.fd, payload.ptr, payload.len);
    }

    /// Deadlined, because the failure mode without one is a CI job that hangs
    /// instead of a test that fails.
    fn recv(self: *TestConn, want: wire.Type, budget_ms: *i32) !wire.Frame {
        while (budget_ms.* > 0) {
            if (try self.dec.next()) |frame| {
                if (frame.type == want) return frame;
                continue;
            }
            var fds = [_]std.posix.pollfd{
                .{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&fds, 100) catch 0;
            budget_ms.* -= 100;
            if (ready == 0) continue;
            const room = self.dec.writable();
            const n = std.c.read(self.fd, room.ptr, room.len);
            if (n <= 0) return error.TestUnexpectedResult;
            self.dec.commit(@intCast(n));
        }
        return error.TestExpectedEqual;
    }

    fn hello(self: *TestConn, gpa: std.mem.Allocator, budget_ms: *i32) !void {
        try self.send(gpa, .hello, wire.Hello{ .role = "control", .pid = 0 });
        _ = try self.recv(.hello, budget_ms);
    }

    fn close(self: *TestConn) void {
        _ = std.c.close(self.fd);
    }
};

fn runForTest(app: app_mod.App, opts: Options) void {
    run(app, opts) catch {};
}

test "a registered session runs, echoes, and its output survives a reconnect" {
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

    // The daemon gets its own arena: an `ArenaAllocator` is not threadsafe, and
    // this test is the one place two threads allocate at once.
    var daemon_arena: std.heap.ArenaAllocator = .init(gpa);
    defer daemon_arena.deinit();
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out_w: Io.Writer = .fixed(&out_buf);
    var err_w: Io.Writer = .fixed(&err_buf);
    const daemon_app: app_mod.App = .{
        .gpa = daemon_arena.allocator(),
        .io = io,
        .environ = &environ,
        .ui = .{ .io = io, .out = &out_w, .err = &err_w },
    };

    // `foreground` exists for this: the loop has to run somewhere a test can
    // reach it, and a double fork would take it out of this process entirely.
    //
    // Running it on a thread also means every `pty.spawn` below forks from a
    // multithreaded process — precisely the hazard this module's header is
    // about — so this doubles as proof that the code between the fork and the
    // execve stays inside what is safe there.
    const thread = try std.Thread.spawn(.{}, runForTest, .{ daemon_app, Options{
        .foreground = true,
        .idle_exit_seconds = 3600,
    } });
    defer thread.join();

    var budget: i32 = 15_000;
    while (budget > 0) : (budget -= 50) {
        if (Io.Dir.cwd().statFile(io, socket_path, .{})) |_| break else |_| {}
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }

    {
        var conn = try TestConn.open(arena, io, socket_path);
        defer conn.close();
        var b: i32 = 15_000;
        try conn.hello(arena, &b);

        // `/bin/cat` stands in for `claude`: it is a real program on a real pty
        // whose behaviour is entirely predictable, which is what makes the
        // assertions below about the daemon rather than about Claude Code.
        try conn.send(arena, .register, wire.Register{
            .worktree = base,
            .branch = "feature/pe-1-test",
            .issue = "PE-1",
            .repo_root = base,
            .program = "/bin/cat",
            .argv = &.{},
            .env = &.{"TERM=dumb"},
            .cols = 80,
            .rows = 24,
        });
        const registered = try conn.recv(.registered, &b);
        const body = try wire.parse(wire.Registered, arena, registered);
        try testing.expect(body.session_id.len > 0);
        try testing.expect(body.pid > 0);

        // Attach, type, and read it back through the pty's echo.
        try conn.send(arena, .hello, wire.Hello{ .role = "attach", .pid = 0 });
        var attach_conn = try TestConn.open(arena, io, socket_path);
        defer attach_conn.close();
        var ab: i32 = 15_000;
        try attach_conn.send(arena, .hello, wire.Hello{ .role = "attach", .pid = 0 });
        _ = try attach_conn.recv(.hello, &ab);
        attach_conn.dec.role = .attach;
        try attach_conn.send(arena, .attach, wire.Attach{
            .session_id = body.session_id,
            .cols = 80,
            .rows = 24,
            .replay = true,
        });
        _ = try attach_conn.recv(.attached, &ab);

        try attach_conn.raw(.input, "hello-from-lcc\n");
        var seen: std.ArrayList(u8) = .empty;
        defer seen.deinit(gpa);
        while (ab > 0) {
            const frame = try attach_conn.recv(.output, &ab);
            try seen.appendSlice(gpa, frame.payload);
            if (std.mem.indexOf(u8, seen.items, "hello-from-lcc") != null) break;
        }
        try testing.expect(std.mem.indexOf(u8, seen.items, "hello-from-lcc") != null);
    }

    // Everything above is gone — both connections closed, as if the terminal
    // had been shut. The session must still be there, and its scrollback with
    // it. This is the whole feature in one assertion.
    {
        var conn = try TestConn.open(arena, io, socket_path);
        defer conn.close();
        var b: i32 = 15_000;
        try conn.hello(arena, &b);
        try conn.send(arena, .list, .{});
        const snap = try conn.recv(.snapshot, &b);
        const body = try wire.parse(wire.Snapshot, arena, snap);
        try testing.expectEqual(@as(usize, 1), body.sessions.len);
        try testing.expectEqualStrings("PE-1", body.sessions[0].issue.?);

        var attach_conn = try TestConn.open(arena, io, socket_path);
        defer attach_conn.close();
        var ab: i32 = 15_000;
        try attach_conn.send(arena, .hello, wire.Hello{ .role = "attach", .pid = 0 });
        _ = try attach_conn.recv(.hello, &ab);
        attach_conn.dec.role = .attach;
        try attach_conn.send(arena, .attach, wire.Attach{
            .session_id = body.sessions[0].id,
            .cols = 80,
            .rows = 24,
            .replay = true,
        });
        _ = try attach_conn.recv(.attached, &ab);

        // Replayed from the ring, not produced again: nothing has typed into
        // this session since the first connection closed.
        var replay: std.ArrayList(u8) = .empty;
        defer replay.deinit(gpa);
        while (ab > 0) {
            const frame = try attach_conn.recv(.output, &ab);
            try replay.appendSlice(gpa, frame.payload);
            if (std.mem.indexOf(u8, replay.items, "hello-from-lcc") != null) break;
        }
        try testing.expect(std.mem.indexOf(u8, replay.items, "hello-from-lcc") != null);

        try conn.send(arena, .stop, wire.Stop{ .force = true });
    }
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
