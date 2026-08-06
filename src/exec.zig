//! Thin wrapper over `std.process` — the `execa` replacement.

const std = @import("std");
const Io = std.Io;

pub const Error = error{
    /// The program could not be started (missing binary, bad cwd, …).
    SpawnFailed,
    /// The program ran but exited non-zero.
    CommandFailed,
} || std.mem.Allocator.Error;

pub const Output = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    pub fn deinit(self: Output, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }

    pub fn ok(self: Output) bool {
        return self.code == 0;
    }

    /// stdout without surrounding whitespace — what every caller actually wants.
    pub fn trimmed(self: Output) []const u8 {
        return std.mem.trim(u8, self.stdout, " \t\r\n");
    }
};

fn cwdOption(cwd: ?[]const u8) std.process.Child.Cwd {
    return if (cwd) |path| .{ .path = path } else .inherit;
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

/// Runs to completion, capturing both streams. Caller owns the result.
pub fn run(gpa: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8) Error!Output {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = cwdOption(cwd),
    }) catch return Error.SpawnFailed;
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .code = exitCode(result.term),
    };
}

/// Trimmed stdout, or `CommandFailed` when the program exits non-zero.
/// Caller owns the returned memory.
pub fn capture(gpa: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8) Error![]u8 {
    const out = try run(gpa, io, argv, cwd);
    defer out.deinit(gpa);
    if (!out.ok()) return Error.CommandFailed;
    return gpa.dupe(u8, out.trimmed());
}

/// True when the program exits zero. Used for git's `--quiet` probes, where the
/// exit status *is* the answer.
pub fn succeeds(gpa: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8) bool {
    const out = run(gpa, io, argv, cwd) catch return false;
    defer out.deinit(gpa);
    return out.ok();
}

/// Runs with stdio wired to the terminal, for commands whose output belongs to
/// the user (`git worktree add`) or that take over the session (`claude`).
pub fn inherit(io: Io, argv: []const []const u8, cwd: ?[]const u8) Error!u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwdOption(cwd),
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return Error.SpawnFailed;
    const term = child.wait(io) catch return Error.SpawnFailed;
    return exitCode(term);
}

/// Spawns and never waits, for a process meant to outlive this one.
///
/// stdio goes to `log_path` rather than being discarded: a daemon that dies
/// during startup has no terminal to complain to, and without a log the only
/// symptom is a client reporting that nothing answered.
pub fn detached(io: Io, argv: []const []const u8, log_path: []const u8) Error!void {
    const log = Io.Dir.cwd().createFile(io, log_path, .{ .truncate = false }) catch null;
    defer if (log) |f| f.close(io);

    const sink: std.process.SpawnOptions.StdIo = if (log) |f| .{ .file = f } else .ignore;
    // No `pgid`: `setpgid(0, 0)` would make the child a process-group leader,
    // and `setsid` fails with EPERM for a leader — which is exactly what the
    // daemon does first.
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = sink,
        .stderr = sink,
    }) catch return Error.SpawnFailed;
    // Deliberately not waited on. The first of the daemon's two forks exits
    // immediately, so this reaps in milliseconds and the grandchild is
    // reparented to launchd.
    _ = child.wait(io) catch {};
}

/// The absolute path of the running binary.
///
/// `std.fs.selfExePath` is gone in 0.16, and `argv[0]` will not do: `lcc` on
/// PATH is a symlink into `zig-out/bin`, so re-execing it would run whichever
/// build the symlink points at now rather than the one that is running.
pub fn selfPath(gpa: std.mem.Allocator, io: Io) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var size: u32 = buf.len;
    if (std.c._NSGetExecutablePath(&buf, &size) != 0) return error.NameTooLong;
    const raw = std.mem.sliceTo(&buf, 0);
    // `_NSGetExecutablePath` can return a path with symlinks and `..` still in
    // it; resolving keeps the hook command stable across rebuilds.
    return Io.Dir.cwd().realPathFileAlloc(io, raw, gpa) catch gpa.dupe(u8, raw);
}

/// When the running binary was last written, in whole seconds.
///
/// Null when it cannot be determined, and callers must treat that as "no
/// opinion": the one thing this feeds is a warning, and a warning invented from
/// a failed stat is worse than none.
pub fn selfModified(gpa: std.mem.Allocator, io: Io) ?i64 {
    const path = selfPath(gpa, io) catch return null;
    const info = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    // Nanoseconds are `i96` at the source, and seconds are what the registry
    // records its own timestamps in — comparing the two needs one unit.
    const ns = std.math.cast(i64, info.mtime.nanoseconds) orelse return null;
    return @divFloor(ns, std.time.ns_per_s);
}

/// Combined output, trimmed — for error messages that should quote what the
/// failing command said.
pub fn message(out: Output) []const u8 {
    const err = std.mem.trim(u8, out.stderr, " \t\r\n");
    if (err.len > 0) return err;
    return std.mem.trim(u8, out.stdout, " \t\r\n");
}
