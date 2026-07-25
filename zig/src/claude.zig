//! Launching Claude Code in a worktree.

const std = @import("std");
const Io = std.Io;
const exec = @import("exec.zig");

pub const Error = error{ClaudeNotFound} || std.mem.Allocator.Error;

fn resolveBin(gpa: std.mem.Allocator, io: Io) Error![]u8 {
    return exec.capture(gpa, io, &.{ "which", "claude" }, null) catch
        return Error.ClaudeNotFound;
}

/// Hands the terminal to Claude Code and returns its exit status.
pub fn launch(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: []const u8,
    extra_args: []const []const u8,
) !u8 {
    const bin = try resolveBin(gpa, io);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, extra_args);

    return exec.inherit(io, argv.items, cwd);
}
