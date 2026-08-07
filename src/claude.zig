const std = @import("std");
const Io = std.Io;
const exec = @import("exec.zig");

pub const Error = error{ClaudeNotFound} || std.mem.Allocator.Error;

pub fn resolvePath(gpa: std.mem.Allocator, io: Io) Error![]u8 {
    return exec.capture(gpa, io, &.{ "which", "claude" }, null) catch
        return Error.ClaudeNotFound;
}

pub fn launch(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: []const u8,
    extra_args: []const []const u8,
) !u8 {
    const bin = try resolvePath(gpa, io);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, extra_args);

    return exec.inherit(io, argv.items, cwd);
}
