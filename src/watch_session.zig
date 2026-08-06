//! One watched session: its pty, its child, its scrollback and its status.
//!
//! Clients are not here. The daemon owns those, because a client on a control
//! connection belongs to no session and one that switches sessions belongs to
//! two for an instant; keeping them in one list leaves a single place where a
//! socket is closed and forgotten.

const std = @import("std");
const Io = std.Io;
const pty = @import("pty.zig");
const ring = @import("ring.zig");
const sessions = @import("sessions.zig");
const watch_hooks = @import("watch_hooks.zig");
const watch_status = @import("watch_status.zig");

/// Keystrokes the pty could not take yet.
///
/// Bounded, and overflow is counted rather than queued. Darwin's tty input
/// queue is about a kilobyte, so a paste into a busy agent reaches this in
/// ordinary use — and a queue that grew instead would let one child that
/// stopped reading consume the daemon's memory.
const input_capacity = 8 * 1024;

pub const Session = struct {
    id: []const u8,
    worktree: []const u8,
    branch: []const u8,
    issue: ?[]const u8,
    repo_root: []const u8,

    pid: std.posix.pid_t,
    master: std.posix.fd_t,
    /// Closed once the child is gone, so the fd is not held for the five
    /// minutes the row lingers in the registry.
    master_open: bool = true,

    scrollback: ring.Ring,
    size: pty.Size,

    status: sessions.Status = .starting,
    status_at: i64,
    started_at: i64,
    /// When the last hook event arrived — what the time-based decay measures.
    last_event_at: i64,
    exit: ?pty.Exit = null,

    input: [input_capacity]u8 = undefined,
    input_len: usize = 0,
    input_dropped: u32 = 0,

    /// A registry-visible field changed since the last write. Only this, never
    /// output, schedules a flush — otherwise every chunk of pty output would
    /// rewrite the file.
    dirty: bool = true,

    pub const Meta = struct {
        id: []const u8,
        worktree: []const u8,
        branch: []const u8,
        issue: ?[]const u8,
        repo_root: []const u8,
    };

    pub fn start(
        gpa: std.mem.Allocator,
        meta: Meta,
        spec: pty.Spec,
        scrollback_bytes: usize,
        now: i64,
    ) !Session {
        var scrollback = try ring.Ring.init(gpa, scrollback_bytes);
        errdefer scrollback.deinit(gpa);
        const spawned = try pty.spawn(gpa, spec);
        return .{
            .id = meta.id,
            .worktree = meta.worktree,
            .branch = meta.branch,
            .issue = meta.issue,
            .repo_root = meta.repo_root,
            .pid = spawned.pid,
            .master = spawned.master,
            .scrollback = scrollback,
            .size = spec.size,
            .status_at = now,
            .started_at = now,
            .last_event_at = now,
        };
    }

    pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        self.closeMaster();
        self.scrollback.deinit(gpa);
    }

    fn closeMaster(self: *Session) void {
        if (!self.master_open) return;
        pty.close(self.master);
        self.master_open = false;
    }

    fn setStatus(self: *Session, status: sessions.Status, now: i64) void {
        if (self.status == status) return;
        self.status = status;
        self.status_at = now;
        self.dirty = true;
    }

    /// Drain whatever the pty has. Returns true when the session is over.
    ///
    /// A read of 0 or EIO is the primary death signal: Darwin reports a hung-up
    /// master as EIO rather than EOF, and both mean the slave is gone.
    pub fn onReadable(self: *Session, now: i64) bool {
        if (!self.master_open) return true;
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            switch (pty.read(self.master, &buf)) {
                .n => |n| {
                    self.scrollback.append(buf[0..n]);
                    // First byte out of a child means the exec worked. Status
                    // beyond that is the hooks' business, not the screen's.
                    if (self.status == .starting) self.setStatus(.idle, now);
                },
                .again => return false,
                .closed => {
                    self.closeMaster();
                    return true;
                },
            }
        }
    }

    /// Push queued keystrokes at the pty. Called only while `input_len > 0`,
    /// because `POLLOUT` on the master is armed only then.
    pub fn onWritable(self: *Session) void {
        while (self.input_len > 0) {
            switch (pty.write(self.master, self.input[0..self.input_len])) {
                .n => |n| {
                    if (n == 0) return;
                    std.mem.copyForwards(u8, self.input[0 .. self.input_len - n], self.input[n..self.input_len]);
                    self.input_len -= n;
                },
                .again => return,
                .closed => {
                    self.input_len = 0;
                    return;
                },
            }
        }
    }

    /// Counted, never queued past the cap. A dropped keystroke is visible in
    /// the registry; unbounded growth would not be until it mattered.
    pub fn queueInput(self: *Session, bytes: []const u8) void {
        const room = input_capacity - self.input_len;
        const take = @min(room, bytes.len);
        @memcpy(self.input[self.input_len..][0..take], bytes[0..take]);
        self.input_len += take;
        if (take < bytes.len) {
            self.input_dropped += @intCast(bytes.len - take);
            self.dirty = true;
        }
    }

    pub fn wantsWrite(self: Session) bool {
        return self.master_open and self.input_len > 0;
    }

    /// A hook event. Returns true when the registry needs rewriting.
    pub fn note(self: *Session, event: watch_hooks.Event, now: i64) bool {
        const before = self.status;
        self.last_event_at = now;
        self.setStatus(watch_status.apply(self.status, event), now);
        return before != self.status;
    }

    /// Time-based decay, run on the coarse tick. Separate from `note` so a
    /// status only ages when nothing has been reported.
    pub fn tick(self: *Session, now: i64) bool {
        const before = self.status;
        self.setStatus(watch_status.resolve(self.status, self.last_event_at, now), now);
        return before != self.status;
    }

    /// `waitpid(WNOHANG)`. Returns true once the child has been reaped.
    pub fn reap(self: *Session, now: i64) bool {
        if (self.exit != null) return true;
        const status = pty.reap(self.pid) orelse return false;
        self.exit = status;
        self.closeMaster();
        self.setStatus(.exited, now);
        return true;
    }

    /// `SIGTERM` to the child's whole process group, or `SIGKILL` when forced.
    ///
    /// The group, not the pid: `login_tty` made the child a group leader, so
    /// this reaches the shells and builds Claude Code started rather than
    /// orphaning them still holding the pty open.
    pub fn stop(self: *Session, force: bool) void {
        pty.signalGroup(self.pid, if (force) .KILL else .TERM);
    }

    pub fn exitCode(self: Session) ?i32 {
        const e = self.exit orelse return null;
        return switch (e) {
            .code => |c| @intCast(c),
            // Negated, so a caller can tell "exited 9" from "killed by 9"
            // without a second field.
            .signal => |s| -@as(i32, @intCast(s)),
        };
    }

    /// The projection written to `sessions.json`.
    pub fn entry(self: Session) sessions.Session {
        return .{
            .id = self.id,
            .worktree = self.worktree,
            .branch = self.branch,
            .issue = self.issue,
            .repo_root = self.repo_root,
            .pid = @intCast(self.pid),
            .status = @tagName(self.status),
            .status_at = self.status_at,
            .started_at = self.started_at,
            .last_activity_at = self.last_event_at,
            .exit_code = self.exitCode(),
        };
    }
};

/// The size a pty should take, given every attached client's terminal.
///
/// The componentwise minimum, which is tmux's rule: anything larger would let
/// one client's rows fall off the bottom of another's window. `null` when
/// nobody is attached — the caller keeps the last size rather than applying
/// one, because a 0x0 winsize makes Ink render nothing at all and a session
/// left that way looks hung.
pub fn negotiateSize(client_sizes: []const pty.Size) ?pty.Size {
    if (client_sizes.len == 0) return null;
    var out = client_sizes[0];
    for (client_sizes[1..]) |size| {
        out.rows = @min(out.rows, size.rows);
        out.cols = @min(out.cols, size.cols);
    }
    if (out.rows == 0 or out.cols == 0) return null;
    return out;
}

/// The two sizes that make a full-screen program repaint: one row short, then
/// the real one.
///
/// Rows rather than columns. A column change makes a terminal rewrap every line
/// it is holding, so poking with one would reflow the whole scrollback to
/// produce a redraw that a row change gets for free.
pub fn pokeSizes(current: pty.Size) [2]pty.Size {
    const shrunk: pty.Size = .{ .rows = if (current.rows > 1) current.rows - 1 else 1, .cols = current.cols };
    return .{ shrunk, current };
}

const testing = std.testing;

test "two attachers get the smaller terminal, componentwise" {
    // tmux's rule. Taking the larger would push rows off the bottom of the
    // smaller client's window with no way for it to scroll back to them.
    const got = negotiateSize(&.{
        .{ .rows = 40, .cols = 200 },
        .{ .rows = 60, .cols = 120 },
    }).?;
    try testing.expectEqual(@as(u16, 40), got.rows);
    try testing.expectEqual(@as(u16, 120), got.cols);
}

test "the last size survives the last detach" {
    // A 0x0 winsize makes Ink render nothing, and a session left that way is
    // indistinguishable from a hung one. So detaching resizes nothing.
    try testing.expect(negotiateSize(&.{}) == null);
    // A client reporting a degenerate size is refused for the same reason,
    // rather than propagated to the pty.
    try testing.expect(negotiateSize(&.{.{ .rows = 0, .cols = 80 }}) == null);
    try testing.expect(negotiateSize(&.{.{ .rows = 24, .cols = 0 }}) == null);
}

test "the repaint poke moves rows, never columns" {
    const poke = pokeSizes(.{ .rows = 40, .cols = 120 });
    try testing.expectEqual(@as(u16, 39), poke[0].rows);
    try testing.expectEqual(@as(u16, 40), poke[1].rows);
    // Columns held constant on both: changing them rewraps every line the
    // terminal is holding, to get a redraw a row change produces for free.
    try testing.expectEqual(@as(u16, 120), poke[0].cols);
    try testing.expectEqual(@as(u16, 120), poke[1].cols);

    // A one-row terminal cannot shrink below one, or the poke itself becomes
    // the 0-row winsize it exists to avoid.
    const tiny = pokeSizes(.{ .rows = 1, .cols = 80 });
    try testing.expectEqual(@as(u16, 1), tiny[0].rows);
}

/// A session with no child behind it, for the pure-state tests below.
fn stubSession(scratch: *ring.Ring) Session {
    return .{
        .id = "s-test",
        .worktree = "/w",
        .branch = "feature/x",
        .issue = "PE-1",
        .repo_root = "/r",
        .pid = 0,
        .master = -1,
        .master_open = false,
        .scrollback = scratch.*,
        .size = .{ .rows = 24, .cols = 80 },
        .status_at = 1000,
        .started_at = 1000,
        .last_event_at = 1000,
    };
}

test "input past the cap is counted, not queued" {
    const gpa = testing.allocator;
    var scratch = try ring.Ring.init(gpa, 64);
    defer scratch.deinit(gpa);
    var s = stubSession(&scratch);

    const paste = try gpa.alloc(u8, input_capacity + 500);
    defer gpa.free(paste);
    @memset(paste, 'x');

    s.queueInput(paste);
    // The session's memory does not grow with what someone pasted into a busy
    // agent, and the loss is recorded rather than silent.
    try testing.expectEqual(input_capacity, s.input_len);
    try testing.expectEqual(@as(u32, 500), s.input_dropped);
    try testing.expect(s.dirty);
}

test "a status change marks the registry dirty; repeating one does not" {
    const gpa = testing.allocator;
    var scratch = try ring.Ring.init(gpa, 64);
    defer scratch.deinit(gpa);
    var s = stubSession(&scratch);
    s.dirty = false;

    try testing.expect(s.note(.waiting, 1010));
    try testing.expectEqual(sessions.Status.waiting, s.status);
    try testing.expectEqual(@as(i64, 1010), s.status_at);
    try testing.expect(s.dirty);

    // The same status again is not a change. Without this, PreToolUse on every
    // tool call would rewrite the registry file continuously through a long turn.
    s.dirty = false;
    try testing.expect(!s.note(.waiting, 1020));
    try testing.expect(!s.dirty);
    // But the event still counts as activity, or the decay would fire mid-turn.
    try testing.expectEqual(@as(i64, 1020), s.last_event_at);
}

test "exitCode tells an exit status from a signal" {
    const gpa = testing.allocator;
    var scratch = try ring.Ring.init(gpa, 64);
    defer scratch.deinit(gpa);
    var s = stubSession(&scratch);

    try testing.expect(s.exitCode() == null);
    s.exit = .{ .code = 1 };
    try testing.expectEqual(@as(i32, 1), s.exitCode().?);
    // Negated rather than a second field: "exited 9" and "killed by SIGKILL"
    // are different outcomes and a dashboard that conflated them would report
    // a crash as a clean exit.
    s.exit = .{ .signal = 9 };
    try testing.expectEqual(@as(i32, -9), s.exitCode().?);
}

test "the registry entry carries the status as text" {
    const gpa = testing.allocator;
    var scratch = try ring.Ring.init(gpa, 64);
    defer scratch.deinit(gpa);
    var s = stubSession(&scratch);
    _ = s.note(.active, 1010);

    const row = s.entry();
    try testing.expectEqualStrings("active", row.status);
    try testing.expectEqualStrings("s-test", row.id);
    try testing.expectEqualStrings("PE-1", row.issue.?);
    // And it round-trips back through the reader's side.
    try testing.expectEqual(sessions.Status.active, row.parsedStatus());
}

test "a decayed session goes idle, and a waiting one never does" {
    const gpa = testing.allocator;
    var scratch = try ring.Ring.init(gpa, 64);
    defer scratch.deinit(gpa);
    var s = stubSession(&scratch);

    _ = s.note(.active, 1000);
    try testing.expect(!s.tick(1000 + watch_status.active_decay_seconds));
    try testing.expect(s.tick(1000 + watch_status.active_decay_seconds + 1));
    try testing.expectEqual(sessions.Status.idle, s.status);

    // An unanswered permission prompt is still unanswered a day later, and
    // ageing it into `idle` would hide it exactly when the user has been away
    // longest.
    _ = s.note(.waiting, 2000);
    try testing.expect(!s.tick(2000 + watch_status.active_decay_seconds * 100));
    try testing.expectEqual(sessions.Status.waiting, s.status);
}
