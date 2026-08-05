//! A pseudo-terminal with a real session and controlling terminal behind it.
//!
//! `forkpty`, not `openpty` plus a spawn. `std.process.SpawnOptions.stdin`
//! accepts an arbitrary fd, so handing a child the slave end would give it
//! something `isatty` agrees is a terminal — but not a *controlling* terminal,
//! because 0.16 offers no `setsid` option and no pre-exec hook. Without one the
//! kernel never delivers SIGWINCH, and Claude Code is an Ink program: it
//! repaints on resize and on nothing else. `forkpty` does fork, `setsid`,
//! `TIOCSCTTY` and the three `dup2`s in one call, and the test at the bottom of
//! this file is what keeps that true.
//!
//! Nothing here takes an `Io`. Every call is a libc call with no `Io` vtable
//! entry behind it, and threading a fake one through would be a lie about what
//! is being awaited. `oauth.zig`'s `waitReadable` sets the precedent.
//!
//! **The daemon that owns this must stay single-threaded.** `fork` in a process
//! with a thread pool leaves the child holding locks no surviving thread will
//! release, and libc's allocator lock is one of them — so everything between
//! the fork and the `execve` below is async-signal-safe only, and every
//! allocation happens before the fork.

const std = @import("std");

/// `<util.h>`. Not in std — grep it and you get nothing — but it lives in
/// libSystem, so `link_libc` resolves it and `build.zig` needs no new linkage.
extern "c" fn forkpty(
    amaster: *c_int,
    name: ?[*:0]u8,
    termp: ?*const std.posix.termios,
    winp: ?*const std.posix.winsize,
) c_int;

/// Declared here rather than taken from `std.c.ioctl` for the request type:
/// std types it `c_int`, and `TIOCSWINSZ` has bit 31 set. Same shape
/// `prompt.zig` used for `TIOCGWINSZ`.
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

/// `_IOW('t', 103, struct winsize)`, spelled out because Darwin's `std.c.T`
/// defines only `IOCGWINSZ` — the `0x80087467` that turns up when grepping std
/// is in the FreeBSD arm. It matches, since both come from the same BSD macro,
/// but borrowing another platform's constant is not a thing to do quietly.
///
///   IOC_IN | ((sizeof(winsize) & IOCPARM_MASK) << 16) | ('t' << 8) | 103
const TIOCSWINSZ: c_ulong = 0x80000000 | (@sizeOf(std.posix.winsize) << 16) | ('t' << 8) | 103;

pub const Error = error{ PtyUnavailable, ForkFailed } || std.mem.Allocator.Error;

pub const Size = struct { rows: u16, cols: u16 };

pub const Spec = struct {
    /// Absolute. A `PATH` search must not happen on the child side of a fork,
    /// so the caller resolves it first — `claude.resolvePath` exists for this.
    program: []const u8,
    /// The arguments *after* `argv[0]`, which is `program`. Mirrors
    /// `claude.launch`'s `extra_args`, so the one mistake that produces a
    /// confusing failure — an argv missing its zeroth element, silently eating
    /// the first real argument — cannot be made here.
    argv: []const []const u8,
    /// `"K=V"` pairs, the whole environment. Must be the *client's*, never the
    /// daemon's own: a daemon started days ago by one shell would otherwise
    /// give every later session that shell's `PATH`.
    env: []const []const u8,
    cwd: []const u8,
    size: Size,
};

pub const Spawned = struct {
    master: std.posix.fd_t,
    pid: std.posix.pid_t,
};

/// The signals a parent may have set to `SIG_IGN`, which — unlike a handler —
/// survives `execve`. A daemon that ignores these to stay detached would
/// otherwise hand Claude Code a process that cannot be stopped with `^C`.
///
/// `KILL` and `STOP` are deliberately absent: `sigaction` on either is EINVAL,
/// which `std.posix.sigaction` treats as `unreachable`.
const reset_to_default = [_]std.c.SIG{ .HUP, .INT, .QUIT, .PIPE, .TSTP, .TTIN, .TTOU, .CHLD, .IO };

pub fn spawn(gpa: std.mem.Allocator, spec: Spec) Error!Spawned {
    // Everything the child needs is built here, before the fork, because after
    // it an allocation can deadlock against a lock no thread is left to unlock.
    //
    // An arena, released on the way out: the child gets a copy-on-write image
    // of all of this and reads it until `execve` replaces the address space, so
    // freeing the parent's copy after the fork cannot reach it. The `defer`
    // runs only in the parent — the child leaves this scope through `execve` or
    // `_exit` and never reaches the end of it. Without this a daemon holding a
    // process arena would keep one copy of every session's environment for as
    // long as it lived.
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
        // `login_tty` has already run inside forkpty: fds 0/1/2 are the slave,
        // we lead a new session, and the pty is our controlling terminal.
        // Async-signal-safe only from here to the execve.
        //
        // The mask is inherited across exec, so a daemon that blocks SIGCHLD
        // around a critical section would otherwise start every agent with it
        // blocked.
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
        // 127 is the shell's convention for "not found", and the caller reads
        // it back through `reap` to tell a missing binary from a crash.
        std.c._exit(127);
    }

    // CLOEXEC so a *later* session's fork cannot inherit this master and hold
    // the pty device open past our own close — which would keep the slave from
    // ever reporting EOF, and with it hide that the child had died.
    _ = std.c.fcntl(master, std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC));
    // NONBLOCK so one child that has stopped reading cannot stall the single
    // poll loop every other session shares.
    const flags = std.c.fcntl(master, std.posix.F.GETFL, @as(c_int, 0));
    if (flags >= 0) {
        var o: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
        o.NONBLOCK = true;
        _ = std.c.fcntl(master, std.posix.F.SETFL, @as(c_int, @bitCast(o)));
    }

    return .{ .master = master, .pid = pid };
}

/// Best-effort: a resize is decoration on a session, never a reason to fail one.
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
    /// Nothing buffered right now. Not an error, and not a closed pty.
    again,
    /// The slave is gone: the child has exited or closed its last handle.
    closed,
};

pub fn read(master: std.posix.fd_t, buf: []u8) Read {
    while (true) {
        const rc = std.c.read(master, buf.ptr, buf.len);
        if (rc > 0) return .{ .n = @intCast(rc) };
        if (rc == 0) return .closed;
        switch (std.posix.errno(rc)) {
            // `Io.Threaded`'s SIGPIPE handler carries no SA_RESTART, so an
            // interrupted read is ours to retry — nothing else will.
            .INTR => continue,
            .AGAIN => return .again,
            // Darwin reports a hung-up pty master as EIO rather than EOF, and
            // reads it as an error where every other platform reads it as the
            // end. Treating it as anything but "closed" leaves dead sessions
            // in the table forever.
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

/// `waitpid(WNOHANG)`. Null while the child is still running.
///
/// Only ever called with a pid this module produced. A wildcard `waitpid(-1, …)`
/// would steal a status `std.process.Child.wait` is blocked on elsewhere in the
/// process and hang it.
pub fn reap(pid: std.posix.pid_t) ?Exit {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, 1); // WNOHANG
        if (rc == 0) return null; // still running
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return null; // already reaped, or never ours
        }
        const raw: u32 = @bitCast(status);
        if (std.posix.W.IFEXITED(raw)) return .{ .code = std.posix.W.EXITSTATUS(raw) };
        if (std.posix.W.IFSIGNALED(raw)) {
            return .{ .signal = @intCast(@intFromEnum(std.posix.W.TERMSIG(raw))) };
        }
        return null; // stopped or continued: not an exit
    }
}

/// Signals the child's whole process group, not just the child.
///
/// `login_tty` made it a process-group leader, so the negative pid reaches
/// everything Claude Code spawned — the shells it ran, the builds they started
/// — rather than leaving them orphaned and holding the pty open.
pub fn signalGroup(pid: std.posix.pid_t, sig: std.c.SIG) void {
    _ = std.c.kill(-pid, sig);
}

pub fn close(master: std.posix.fd_t) void {
    _ = std.c.close(master);
}

// ---------------------------------------------------------------------------
// Tests
//
// These fork real processes on a real pty inside the test runner, which is
// multithreaded — precisely the hazard the module header is about. That makes
// them a check on the between-fork-and-exec code as well as on the behaviour
// each one names. Every wait carries a deadline, because the failure mode
// without one is a CI job that hangs instead of a test that fails.
// ---------------------------------------------------------------------------

const test_deadline_ms: i32 = 10_000;

fn testEnv() []const []const u8 {
    return &.{ "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TERM=xterm-256color" };
}

/// Reads until the pty closes or the deadline passes. Test-only: the daemon
/// never blocks on a session, it polls every fd at once.
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

/// Polls `reap` to a deadline. Test-only, for the same reason as `drain`.
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

    // The two must name the *same* terminal, and asking whether /dev/tty merely
    // opens is not enough to tell: a controlling terminal is inherited across
    // fork, so a child handed a slave fd by `std.process.spawn` still has one —
    // the terminal lcc itself was launched from. `tty` reports what is on
    // stdin (our pty); `ps -o tty=` reports the controlling terminal. Equal
    // means the pty was actually taken over; different is precisely the
    // openpty-without-setsid arrangement in which the kernel sends SIGWINCH to
    // some other session and Claude Code never repaints.
    //
    // This is the whole reason this module calls forkpty. If it stops holding,
    // resize dies quietly and nothing else in the suite notices.
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

    // `tty` prints `/dev/ttys004`; `ps` prints `ttys004`. Compare on the leaf.
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

    // Ink lays out against this. Getting it wrong renders Claude Code at 24x80
    // inside a full-screen terminal, which looks like a Claude Code bug.
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

    // The worktree is the entire point of `lcc start`. A session that came up
    // in the daemon's cwd would be an agent editing the wrong checkout.
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
    // `realPathFileAlloc` already resolved /var -> /private/var, and `pwd -P`
    // resolves it the same way on the child's side.
    try std.testing.expect(std.mem.indexOf(u8, out, cwd) != null);
}

test "a resize reaches the child as SIGWINCH" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(cwd);

    // The payoff of the controlling terminal. If this breaks, Claude Code
    // never repaints after a window resize and the pane stays the size it was
    // when the session started.
    //
    // `sleep` in a loop rather than one long sleep: a non-interactive sh runs
    // a pending trap only between commands, so the poll interval sets how
    // quickly the handler fires.
    const spawned = try spawn(gpa, .{
        .program = "/bin/sh",
        .argv = &.{ "-c", "trap 'echo GOT_WINCH; exit 0' WINCH; echo READY; while :; do sleep 0.05; done" },
        .env = testEnv(),
        .cwd = cwd,
        .size = .{ .rows = 24, .cols = 80 },
    });
    defer close(spawned.master);

    // Wait for READY before resizing: a SIGWINCH delivered before the trap is
    // installed proves nothing and would make this flaky rather than wrong.
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

    // forkpty succeeds even when the exec cannot: the fork happened. So a
    // typo'd `claude` path shows up as an immediate 127, and the session state
    // machine reads that as `failed` rather than sitting in `starting` forever.
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

    // A worktree removed under a live session is a real case, and it must not
    // report itself as a missing binary — the two send you looking in
    // completely different places.
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

    // CLOEXEC: without it a later session's fork inherits this master, the pty
    // never reports EOF, and a dead session stays `running` forever.
    const fd_flags = std.c.fcntl(spawned.master, std.posix.F.GETFD, @as(c_int, 0));
    try std.testing.expect(fd_flags >= 0);
    try std.testing.expect((fd_flags & std.posix.FD_CLOEXEC) != 0);

    // NONBLOCK: without it one child that stopped reading blocks the single
    // poll loop, and every other session stops with it.
    const fl = std.c.fcntl(spawned.master, std.posix.F.GETFL, @as(c_int, 0));
    try std.testing.expect(fl >= 0);
    const o: std.posix.O = @bitCast(@as(u32, @intCast(fl)));
    try std.testing.expect(o.NONBLOCK);

    // And the consequence a caller depends on: reading an idle pty returns
    // `.again` immediately rather than parking the thread.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(Read.again, read(spawned.master, &buf));
}

test "signalGroup reaches past the child into what it spawned" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(cwd);

    // Claude Code runs builds and shells; killing only the node process would
    // orphan them still holding the pty. The negative pid is what makes
    // stopping a session actually stop it.
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

    // The pty reports the hangup rather than staying open on the backgrounded
    // `sleep` — which is what it would do if only the leader had been killed.
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
