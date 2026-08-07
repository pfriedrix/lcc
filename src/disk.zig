const std = @import("std");
const Io = std.Io;
const exec = @import("exec.zig");

pub fn usage(gpa: std.mem.Allocator, io: Io, paths: []const []const u8) ![]u64 {
    const sizes = try gpa.alloc(u64, paths.len);
    @memset(sizes, 0);
    if (paths.len == 0) return sizes;

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{ "du", "-sk" });
    for (paths) |path| try argv.append(gpa, path);

    const out = exec.run(gpa, io, argv.items, null) catch return sizes;
    defer out.deinit(gpa);

    var lines = std.mem.splitScalar(u8, out.stdout, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const kb = std.fmt.parseInt(u64, std.mem.trim(u8, line[0..tab], " "), 10) catch continue;
        const path = std.mem.trim(u8, line[tab + 1 ..], " \r");
        for (paths, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, path)) {
                sizes[i] = kb * 1024;
                break;
            }
        }
    }
    return sizes;
}

pub fn isInside(gpa: std.mem.Allocator, parent: []const u8, child: []const u8) bool {
    const rel = std.fs.path.relativePosix(gpa, parent, parent, child) catch return false;
    return rel.len != 0 and !std.mem.startsWith(u8, rel, "..") and !std.fs.path.isAbsolute(rel);
}

pub fn realPath(gpa: std.mem.Allocator, io: Io, target: []const u8) []const u8 {
    return Io.Dir.cwd().realPathFileAlloc(io, target, gpa) catch target;
}

pub fn isDirectory(io: Io, path: []const u8) bool {
    if (path.len == 0) return false;
    const info = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return info.kind == .directory;
}

pub fn removeChild(io: Io, parent: []const u8, path: []const u8) !void {
    const dirname = std.fs.path.dirname(path) orelse return error.RefusingToDelete;
    const trimmed = std.mem.trimEnd(u8, parent, "/");
    const leaf = std.fs.path.basename(path);
    if (!std.mem.eql(u8, dirname, trimmed) or leaf.len == 0) return error.RefusingToDelete;
    try Io.Dir.cwd().deleteTree(io, path);
}

pub fn abbreviate(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, path: []const u8) []const u8 {
    const home = environ.get("HOME") orelse return path;
    if (home.len == 0 or !std.mem.startsWith(u8, path, home)) return path;
    if (path.len == home.len) return "~";
    if (path[home.len] != '/') return path;
    return std.fmt.allocPrint(gpa, "~{s}", .{path[home.len..]}) catch path;
}

test "a worktree is a directory that is there, not a name that used to be one" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    try std.testing.expect(isDirectory(io, base));

    const gone = try std.fs.path.join(arena, &.{ base, "removed" });
    try std.testing.expect(!isDirectory(io, gone));

    const file = try std.fs.path.join(arena, &.{ base, "a-file" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "" });
    if (isDirectory(io, file)) {
        std.debug.print(
            "a plain file answered yes: a session whose worktree was replaced by a file of the " ++
                "same name keeps its row, and enter on it starts an agent in a directory that " ++
                "does not exist.\n",
            .{},
        );
        return error.TestUnexpectedResult;
    }

    try std.testing.expect(!isDirectory(io, ""));
}

test "isInside distinguishes containment from a shared prefix" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(isInside(arena, "/a/b", "/a/b/c"));
    try std.testing.expect(isInside(arena, "/a/b", "/a/b/c/d.xcodeproj"));
    try std.testing.expect(!isInside(arena, "/a/b", "/a/b"));
    try std.testing.expect(!isInside(arena, "/a/b", "/a/bc/d"));
    try std.testing.expect(!isInside(arena, "/a/b", "/a"));
}

test "removeChild refuses anything that is not a direct child" {
    const io = std.testing.io;
    try std.testing.expectError(
        error.RefusingToDelete,
        removeChild(io, "/root", "/root/nested/deep"),
    );
    try std.testing.expectError(
        error.RefusingToDelete,
        removeChild(io, "/root", "/elsewhere/thing"),
    );
}

test "abbreviate only collapses a whole path segment" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", "/Users/me");

    try std.testing.expectEqualStrings("~/Projects/x", abbreviate(arena, &environ, "/Users/me/Projects/x"));
    try std.testing.expectEqualStrings("~", abbreviate(arena, &environ, "/Users/me"));
    try std.testing.expectEqualStrings("/Users/mercury/x", abbreviate(arena, &environ, "/Users/mercury/x"));
}
