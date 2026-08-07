const std = @import("std");
const Io = std.Io;
const pty = @import("pty.zig");
const ring = @import("ring.zig");
const sessions = @import("sessions.zig");
const watch_hooks = @import("watch_hooks.zig");
const watch_status = @import("watch_status.zig");

const input_capacity = 8 * 1024;

pub const Session = struct {
    id: []const u8,
    worktree: []const u8,
    branch: []const u8,
    issue: ?[]const u8,
    repo_root: []const u8,

    pid: std.posix.pid_t,
    master: std.posix.fd_t,
    master_open: bool = true,

    scrollback: ring.Ring,
    size: pty.Size,

    status: sessions.Status = .starting,
    status_at: i64,
    started_at: i64,
    last_event_at: i64,
    plan: bool = false,
    exit: ?pty.Exit = null,

    input: [input_capacity]u8 = undefined,
    input_len: usize = 0,
    input_dropped: u32 = 0,

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

    pub fn shown(self: Session) sessions.Status {
        return watch_status.present(self.status, self.plan);
    }

    fn setStatus(self: *Session, status: sessions.Status, now: i64) void {
        const before = self.shown();
        self.status = status;
        if (self.shown() == before) return;
        self.status_at = now;
        self.dirty = true;
    }

    fn setPlan(self: *Session, plan: bool, now: i64) void {
        const before = self.shown();
        self.plan = plan;
        if (self.shown() == before) return;
        self.status_at = now;
        self.dirty = true;
    }

    pub fn onReadable(self: *Session, now: i64) bool {
        if (!self.master_open) return true;
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            switch (pty.read(self.master, &buf)) {
                .n => |n| {
                    self.scrollback.append(buf[0..n]);
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

    pub fn note(self: *Session, event: watch_hooks.Event, permission_mode: []const u8, now: i64) bool {
        const before = self.shown();
        self.last_event_at = now;
        if (permission_mode.len > 0) self.setPlan(watch_hooks.isPlan(permission_mode), now);
        self.setStatus(watch_status.apply(self.status, event), now);
        return before != self.shown();
    }

    pub fn tick(self: *Session, now: i64) bool {
        const before = self.shown();
        self.setStatus(watch_status.resolve(self.status, self.last_event_at, now), now);
        return before != self.shown();
    }

    pub fn reap(self: *Session, now: i64) bool {
        if (self.exit != null) return true;
        const status = pty.reap(self.pid) orelse return false;
        self.exit = status;
        self.closeMaster();
        self.setStatus(.exited, now);
        return true;
    }

    pub fn stop(self: *Session, force: bool) void {
        pty.signalGroup(self.pid, if (force) .KILL else .TERM);
    }

    pub fn exitCode(self: Session) ?i32 {
        const e = self.exit orelse return null;
        return switch (e) {
            .code => |c| @intCast(c),
            .signal => |s| -@as(i32, @intCast(s)),
        };
    }

    pub fn entry(self: Session) sessions.Session {
        return .{
            .id = self.id,
            .worktree = self.worktree,
            .branch = self.branch,
            .issue = self.issue,
            .repo_root = self.repo_root,
            .pid = @intCast(self.pid),
            .status = @tagName(self.shown()),
            .status_at = self.status_at,
            .started_at = self.started_at,
            .last_activity_at = self.last_event_at,
            .exit_code = self.exitCode(),
        };
    }
};

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

pub fn pokeSizes(current: pty.Size) [2]pty.Size {
    const shrunk: pty.Size = .{ .rows = if (current.rows > 1) current.rows - 1 else 1, .cols = current.cols };
    return .{ shrunk, current };
}

const testing = std.testing;

test "two attachers get the smaller terminal, componentwise" {
    const got = negotiateSize(&.{
        .{ .rows = 40, .cols = 200 },
        .{ .rows = 60, .cols = 120 },
    }).?;
    try testing.expectEqual(@as(u16, 40), got.rows);
    try testing.expectEqual(@as(u16, 120), got.cols);
}

test "the last size survives the last detach" {
    try testing.expect(negotiateSize(&.{}) == null);
    try testing.expect(negotiateSize(&.{.{ .rows = 0, .cols = 80 }}) == null);
    try testing.expect(negotiateSize(&.{.{ .rows = 24, .cols = 0 }}) == null);
}

test "the repaint poke moves rows, never columns" {
    const poke = pokeSizes(.{ .rows = 40, .cols = 120 });
    try testing.expectEqual(@as(u16, 39), poke[0].rows);
    try testing.expectEqual(@as(u16, 40), poke[1].rows);
    try testing.expectEqual(@as(u16, 120), poke[0].cols);
    try testing.expectEqual(@as(u16, 120), poke[1].cols);

    const tiny = pokeSizes(.{ .rows = 1, .cols = 80 });
    try testing.expectEqual(@as(u16, 1), tiny[0].rows);
}

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

    try testing.expect(s.note(.waiting, "", 1010));
    try testing.expectEqual(sessions.Status.waiting, s.status);
    try testing.expectEqual(@as(i64, 1010), s.status_at);
    try testing.expect(s.dirty);

    s.dirty = false;
    try testing.expect(!s.note(.waiting, "", 1020));
    try testing.expect(!s.dirty);
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
    s.exit = .{ .signal = 9 };
    try testing.expectEqual(@as(i32, -9), s.exitCode().?);
}

test "the registry entry carries the status as text" {
    const gpa = testing.allocator;
    var scratch = try ring.Ring.init(gpa, 64);
    defer scratch.deinit(gpa);
    var s = stubSession(&scratch);
    _ = s.note(.active, "", 1010);

    const row = s.entry();
    try testing.expectEqualStrings("active", row.status);
    try testing.expectEqualStrings("s-test", row.id);
    try testing.expectEqualStrings("PE-1", row.issue.?);
    try testing.expectEqual(sessions.Status.active, row.parsedStatus());
}

test "a session that went silent mid-turn asks to be opened" {
    const gpa = testing.allocator;
    var scratch = try ring.Ring.init(gpa, 64);
    defer scratch.deinit(gpa);
    var s = stubSession(&scratch);

    _ = s.note(.active, "", 1000);
    try testing.expect(!s.tick(1000 + watch_status.active_decay_seconds));
    try testing.expect(s.tick(1000 + watch_status.active_decay_seconds + 1));
    try testing.expectEqual(sessions.Status.waiting, s.status);

    _ = s.note(.waiting, "", 2000);
    try testing.expect(!s.tick(2000 + watch_status.active_decay_seconds * 100));
    try testing.expectEqual(sessions.Status.waiting, s.status);
}

test "a session reports plan mode, and keeps reporting it through events that omit it" {
    const gpa = testing.allocator;
    var scratch = try ring.Ring.init(gpa, 64);
    defer scratch.deinit(gpa);
    var s = stubSession(&scratch);

    try testing.expect(s.note(.active, "plan", 1010));
    try testing.expectEqualStrings("plan", s.entry().status);
    try testing.expectEqual(sessions.Status.active, s.status);

    try testing.expect(!s.note(.active, "", 1020));
    try testing.expectEqualStrings("plan", s.entry().status);

    try testing.expect(s.note(.waiting, "", 1030));
    try testing.expectEqualStrings("waiting", s.entry().status);
    try testing.expect(s.plan);

    try testing.expect(s.note(.active, "default", 1040));
    try testing.expectEqualStrings("active", s.entry().status);
    try testing.expect(!s.plan);
}

test "a mode this build has never heard of is not plan mode" {
    const gpa = testing.allocator;
    var scratch = try ring.Ring.init(gpa, 64);
    defer scratch.deinit(gpa);
    var s = stubSession(&scratch);

    _ = s.note(.active, "plan", 1000);
    _ = s.note(.active, "some-mode-from-2027", 1010);
    try testing.expectEqualStrings("active", s.entry().status);
}

test "a change no reader can see costs no registry write" {
    const gpa = testing.allocator;
    var scratch = try ring.Ring.init(gpa, 64);
    defer scratch.deinit(gpa);
    var s = stubSession(&scratch);

    _ = s.note(.active, "plan", 1000);
    s.dirty = false;

    try testing.expect(!s.note(.idle, "plan", 1100));
    try testing.expect(!s.dirty);
    try testing.expectEqual(sessions.Status.idle, s.status);
    try testing.expectEqualStrings("plan", s.entry().status);

    try testing.expect(s.note(.idle, "acceptEdits", 2000));
    try testing.expectEqualStrings("idle", s.entry().status);
}
