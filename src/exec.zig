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

/// Combined output, trimmed — for error messages that should quote what the
/// failing command said.
pub fn message(out: Output) []const u8 {
    const err = std.mem.trim(u8, out.stderr, " \t\r\n");
    if (err.len > 0) return err;
    return std.mem.trim(u8, out.stdout, " \t\r\n");
}
