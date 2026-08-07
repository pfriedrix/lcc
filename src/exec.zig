const std = @import("std");
const Io = std.Io;

pub const Error = error{
    SpawnFailed,
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

pub fn capture(gpa: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8) Error![]u8 {
    const out = try run(gpa, io, argv, cwd);
    defer out.deinit(gpa);
    if (!out.ok()) return Error.CommandFailed;
    return gpa.dupe(u8, out.trimmed());
}

pub fn succeeds(gpa: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8) bool {
    const out = run(gpa, io, argv, cwd) catch return false;
    defer out.deinit(gpa);
    return out.ok();
}

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

pub fn detached(io: Io, argv: []const []const u8, log_path: []const u8) Error!void {
    const log = Io.Dir.cwd().createFile(io, log_path, .{ .truncate = false }) catch null;
    defer if (log) |f| f.close(io);

    const sink: std.process.SpawnOptions.StdIo = if (log) |f| .{ .file = f } else .ignore;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = sink,
        .stderr = sink,
    }) catch return Error.SpawnFailed;
    _ = child.wait(io) catch {};
}

pub fn selfPath(gpa: std.mem.Allocator, io: Io) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var size: u32 = buf.len;
    if (std.c._NSGetExecutablePath(&buf, &size) != 0) return error.NameTooLong;
    const raw = std.mem.sliceTo(&buf, 0);
    return Io.Dir.cwd().realPathFileAlloc(io, raw, gpa) catch gpa.dupe(u8, raw);
}

pub fn selfModified(gpa: std.mem.Allocator, io: Io) ?i64 {
    const path = selfPath(gpa, io) catch return null;
    const info = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    const ns = std.math.cast(i64, info.mtime.nanoseconds) orelse return null;
    return @divFloor(ns, std.time.ns_per_s);
}

pub fn message(out: Output) []const u8 {
    const err = std.mem.trim(u8, out.stderr, " \t\r\n");
    if (err.len > 0) return err;
    return std.mem.trim(u8, out.stdout, " \t\r\n");
}
