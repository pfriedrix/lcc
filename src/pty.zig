const std = @import("std");

extern "c" fn forkpty(
    amaster: *c_int,
    name: ?[*:0]u8,
    termp: ?*const std.posix.termios,
    winp: ?*const std.posix.winsize,
) c_int;

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

const TIOCSWINSZ: c_ulong = 0x80000000 | (@sizeOf(std.posix.winsize) << 16) | ('t' << 8) | 103;

pub const Error = error{ PtyUnavailable, ForkFailed } || std.mem.Allocator.Error;

pub const Size = struct { rows: u16, cols: u16 };

pub const Spec = struct {
    program: []const u8,
    argv: []const []const u8,
    env: []const []const u8,
    cwd: []const u8,
    size: Size,
};

pub const Spawned = struct {
    master: std.posix.fd_t,
    pid: std.posix.pid_t,
};

const reset_to_default = [_]std.c.SIG{ .HUP, .INT, .QUIT, .PIPE, .TSTP, .TTIN, .TTOU, .CHLD, .IO };

pub fn spawn(gpa: std.mem.Allocator, spec: Spec) Error!Spawned {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();

    const program_z = try a.dupeZ(u8, spec.program);
    const cwd_z = try a.dupeZ(u8, spec.cwd);

    const argv_z = try a.allocSentinel(?[*:0]const u8, spec.argv.len + 1, null);
    argv_z[0] = program_z.ptr;
    for (spec.argv, 1..) |arg, i| argv_z[i] = (try a.dupeZ(u8, arg)).ptr;

    const envp_z = try a.allocSentinel(?[*:0]const u8, spec.env.len, null);
    for (spec.env, 0..) |entry, i| envp_z[i] = (try a.dupeZ(u8, entry)).ptr;

    const ws: std.posix.winsize = .{
        .row = spec.size.rows,
        .col = spec.size.cols,
        .xpixel = 0,
        .ypixel = 0,
    };

    var master: c_int = -1;
    const pid = forkpty(&master, null, null, &ws);
    if (pid < 0) return Error.ForkFailed;

    if (pid == 0) {
        var empty = std.posix.sigemptyset();
        std.posix.sigprocmask(std.c.SIG.SETMASK, &empty, null);
        const dfl: std.posix.Sigaction = .{
            .handler = .{ .handler = std.c.SIG.DFL },
            .mask = empty,
            .flags = 0,
        };
        for (reset_to_default) |sig| std.posix.sigaction(sig, &dfl, null);

        if (std.c.chdir(cwd_z.ptr) != 0) std.c._exit(126);
        _ = std.c.execve(program_z.ptr, argv_z.ptr, envp_z.ptr);
        std.c._exit(127);
    }

    _ = std.c.fcntl(master, std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC));
    const flags = std.c.fcntl(master, std.posix.F.GETFL, @as(c_int, 0));
    if (flags >= 0) {
        var o: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
        o.NONBLOCK = true;
        _ = std.c.fcntl(master, std.posix.F.SETFL, @as(c_int, @bitCast(o)));
    }

    return .{ .master = master, .pid = pid };
}

pub fn resize(master: std.posix.fd_t, size: Size) void {
    const ws: std.posix.winsize = .{
        .row = size.rows,
        .col = size.cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    _ = ioctl(master, TIOCSWINSZ, &ws);
}

pub const Read = union(enum) {
    n: usize,
    again,
    closed,
};

pub fn read(master: std.posix.fd_t, buf: []u8) Read {
    while (true) {
        const rc = std.c.read(master, buf.ptr, buf.len);
        if (rc > 0) return .{ .n = @intCast(rc) };
        if (rc == 0) return .closed;
        switch (std.posix.errno(rc)) {
            .INTR => continue,
            .AGAIN => return .again,
            .IO => return .closed,
            else => return .closed,
        }
    }
}

pub const Write = union(enum) { n: usize, again, closed };

pub fn write(master: std.posix.fd_t, bytes: []const u8) Write {
    while (true) {
        const rc = std.c.write(master, bytes.ptr, bytes.len);
        if (rc >= 0) return .{ .n = @intCast(rc) };
        switch (std.posix.errno(rc)) {
            .INTR => continue,
            .AGAIN => return .again,
            else => return .closed,
        }
    }
}

pub const Exit = union(enum) { code: u8, signal: u8 };

pub fn reap(pid: std.posix.pid_t) ?Exit {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, 1);
        if (rc == 0) return null;
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return null;
        }
        const raw: u32 = @bitCast(status);
        if (std.posix.W.IFEXITED(raw)) return .{ .code = std.posix.W.EXITSTATUS(raw) };
        if (std.posix.W.IFSIGNALED(raw)) {
            return .{ .signal = @intCast(@intFromEnum(std.posix.W.TERMSIG(raw))) };
        }
        return null;
    }
}

pub fn signalGroup(pid: std.posix.pid_t, sig: std.c.SIG) void {
    _ = std.c.kill(-pid, sig);
}

pub fn close(master: std.posix.fd_t) void {
    _ = std.c.close(master);
}

const test_deadline_ms: i32 = 10_000;

fn testEnv() []const []const u8 {
    return &.{ "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TERM=xterm-256color" };
}

fn drain(gpa: std.mem.Allocator, master: std.posix.fd_t) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [4096]u8 = undefined;
    var waited: i32 = 0;

    while (waited < test_deadline_ms) {
        switch (read(master, &buf)) {
            .n => |n| try out.appendSlice(gpa, buf[0..n]),
            .closed => break,
            .again => {
                var fds = [_]std.posix.pollfd{
                    .{ .fd = master, .events = std.posix.POLL.IN, .revents = 0 },
                };
                _ = std.posix.poll(&fds, 100) catch break;
                waited += 100;
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

fn waitExit(pid: std.posix.pid_t) ?Exit {
    var waited: i32 = 0;
    while (waited < test_deadline_ms) {
        if (reap(pid)) |e| return e;
        var none: [0]std.posix.pollfd = .{};
        _ = std.posix.poll(&none, 20) catch {};
        waited += 20;
    }
    return null;
}

test "a child on the pty has a controlling terminal, not merely a tty fd" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(cwd);

    const spawned = try spawn(gpa, .{
        .program = "/bin/sh",
        .argv = &.{ "-c", "printf 'STDIN=%s CTTY=%s\\n' \"$(tty)\" \"$(ps -o tty= -p $$ | tr -d ' ')\"" },
        .env = testEnv(),
        .cwd = cwd,
        .size = .{ .rows = 24, .cols = 80 },
    });
    defer close(spawned.master);

    const out = try drain(gpa, spawned.master);
    defer gpa.free(out);

    const stdin_at = std.mem.indexOf(u8, out, "STDIN=/dev/") orelse {
        std.debug.print("child never reported its tty; got \"{f}\"\n", .{std.zig.fmtString(out)});
        return error.TestExpectedEqual;
    };
    const leaf_start = stdin_at + "STDIN=/dev/".len;
    const leaf_end = std.mem.indexOfAnyPos(u8, out, leaf_start, " \r\n") orelse out.len;
    const leaf = out[leaf_start..leaf_end];
    try std.testing.expect(leaf.len > 0);

    const ctty_at = std.mem.indexOf(u8, out, "CTTY=") orelse return error.TestExpectedEqual;
    const ctty_end = std.mem.indexOfAnyPos(u8, out, ctty_at, "\r\n") orelse out.len;
    const ctty = out[ctty_at + "CTTY=".len .. ctty_end];

    if (!std.mem.eql(u8, std.mem.trim(u8, ctty, " "), leaf)) {
        std.debug.print(
            "the child's controlling terminal is not its pty: stdin is {s}, ctty is \"{s}\". " ++
                "SIGWINCH will go to another session and Claude Code will never repaint.\n",
            .{ leaf, ctty },
        );
        return error.TestExpectedEqual;
    }
}

test "the size we asked for is the size the child sees" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(cwd);

    const spawned = try spawn(gpa, .{
        .program = "/bin/sh",
        .argv = &.{ "-c", "stty size" },
        .env = testEnv(),
        .cwd = cwd,
        .size = .{ .rows = 30, .cols = 100 },
    });
    defer close(spawned.master);

    const out = try drain(gpa, spawned.master);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "30 100") != null);
}

test "the child starts in the cwd it was given, not the daemon's" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(cwd);

    const spawned = try spawn(gpa, .{
        .program = "/bin/sh",
        .argv = &.{ "-c", "pwd -P" },
        .env = testEnv(),
        .cwd = cwd,
        .size = .{ .rows = 24, .cols = 80 },
    });
    defer close(spawned.master);

    const out = try drain(gpa, spawned.master);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, cwd) != null);
}

test "a resize reaches the child as SIGWINCH" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(cwd);

    const spawned = try spawn(gpa, .{
        .program = "/bin/sh",
        .argv = &.{ "-c", "trap 'echo GOT_WINCH; exit 0' WINCH; echo READY; while :; do sleep 0.05; done" },
        .env = testEnv(),
        .cwd = cwd,
        .size = .{ .rows = 24, .cols = 80 },
    });
    defer close(spawned.master);

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(gpa);
    var buf: [1024]u8 = undefined;
    var waited: i32 = 0;
    var resized = false;

    while (waited < test_deadline_ms) {
        switch (read(spawned.master, &buf)) {
            .n => |n| try seen.appendSlice(gpa, buf[0..n]),
            .closed => break,
            .again => {
                var fds = [_]std.posix.pollfd{
                    .{ .fd = spawned.master, .events = std.posix.POLL.IN, .revents = 0 },
                };
                _ = std.posix.poll(&fds, 100) catch break;
                waited += 100;
            },
        }
        if (std.mem.indexOf(u8, seen.items, "GOT_WINCH") != null) break;
        if (!resized and std.mem.indexOf(u8, seen.items, "READY") != null) {
            resize(spawned.master, .{ .rows = 40, .cols = 120 });
            resized = true;
        }
    }

    try std.testing.expect(resized);
    if (std.mem.indexOf(u8, seen.items, "GOT_WINCH") == null) {
        std.debug.print(
            "no SIGWINCH reached the child; Ink repaint on resize is what breaks. saw: \"{f}\"\n",
            .{std.zig.fmtString(seen.items)},
        );
        return error.TestExpectedEqual;
    }
}

test "a missing program is exit 127, not a session that hangs" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(cwd);

    const spawned = try spawn(gpa, .{
        .program = "/nonexistent/claude",
        .argv = &.{},
        .env = testEnv(),
        .cwd = cwd,
        .size = .{ .rows = 24, .cols = 80 },
    });
    defer close(spawned.master);

    const status = waitExit(spawned.pid) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(Exit{ .code = 127 }, status);
}

test "an unreachable cwd is 126, told apart from a missing program" {
    const gpa = std.testing.allocator;

    const spawned = try spawn(gpa, .{
        .program = "/bin/sh",
        .argv = &.{ "-c", "echo hi" },
        .env = testEnv(),
        .cwd = "/nonexistent/worktree",
        .size = .{ .rows = 24, .cols = 80 },
    });
    defer close(spawned.master);

    const status = waitExit(spawned.pid) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(Exit{ .code = 126 }, status);
}

test "the master is close-on-exec and non-blocking" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(cwd);

    const spawned = try spawn(gpa, .{
        .program = "/bin/sh",
        .argv = &.{ "-c", "sleep 30" },
        .env = testEnv(),
        .cwd = cwd,
        .size = .{ .rows = 24, .cols = 80 },
    });
    defer {
        signalGroup(spawned.pid, .KILL);
        _ = waitExit(spawned.pid);
        close(spawned.master);
    }

    const fd_flags = std.c.fcntl(spawned.master, std.posix.F.GETFD, @as(c_int, 0));
    try std.testing.expect(fd_flags >= 0);
    try std.testing.expect((fd_flags & std.posix.FD_CLOEXEC) != 0);

    const fl = std.c.fcntl(spawned.master, std.posix.F.GETFL, @as(c_int, 0));
    try std.testing.expect(fl >= 0);
    const o: std.posix.O = @bitCast(@as(u32, @intCast(fl)));
    try std.testing.expect(o.NONBLOCK);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(Read.again, read(spawned.master, &buf));
}

test "signalGroup reaches past the child into what it spawned" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(cwd);

    const spawned = try spawn(gpa, .{
        .program = "/bin/sh",
        .argv = &.{ "-c", "sleep 30 & echo STARTED; wait" },
        .env = testEnv(),
        .cwd = cwd,
        .size = .{ .rows = 24, .cols = 80 },
    });
    defer close(spawned.master);

    var buf: [256]u8 = undefined;
    var waited: i32 = 0;
    var started = false;
    while (waited < test_deadline_ms and !started) {
        switch (read(spawned.master, &buf)) {
            .n => |n| started = std.mem.indexOf(u8, buf[0..n], "STARTED") != null,
            .closed => break,
            .again => {
                var fds = [_]std.posix.pollfd{
                    .{ .fd = spawned.master, .events = std.posix.POLL.IN, .revents = 0 },
                };
                _ = std.posix.poll(&fds, 100) catch break;
                waited += 100;
            },
        }
    }
    try std.testing.expect(started);

    signalGroup(spawned.pid, .KILL);
    const status = waitExit(spawned.pid) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(Exit{ .signal = 9 }, status);

    var drained: [4096]u8 = undefined;
    var closed = false;
    waited = 0;
    while (waited < test_deadline_ms and !closed) {
        switch (read(spawned.master, &drained)) {
            .closed => closed = true,
            .n => {},
            .again => {
                var fds = [_]std.posix.pollfd{
                    .{ .fd = spawned.master, .events = std.posix.POLL.IN, .revents = 0 },
                };
                _ = std.posix.poll(&fds, 100) catch break;
                waited += 100;
            },
        }
    }
    try std.testing.expect(closed);
}
