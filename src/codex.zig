const std = @import("std");
const Io = std.Io;
const exec = @import("exec.zig");

pub const Error = error{CodexNotFound} || std.mem.Allocator.Error;

pub const Action = union(enum) {
    start: ?[]const u8,
    resume_last,
};

fn resolveBin(gpa: std.mem.Allocator, io: Io) Error![]u8 {
    return exec.capture(gpa, io, &.{ "which", "codex" }, null) catch
        return Error.CodexNotFound;
}

pub fn launch(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: []const u8,
    action: Action,
) !u8 {
    const bin = try resolveBin(gpa, io);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa, bin);
    switch (action) {
        .start => |initial_prompt| if (initial_prompt) |value| try argv.append(gpa, value),
        .resume_last => try argv.appendSlice(gpa, &.{ "resume", "--last" }),
    }

    return exec.inherit(io, argv.items, cwd);
}
