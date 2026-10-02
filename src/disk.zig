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

pub const Presence = enum { present, missing, unknown };

pub fn presence(io: Io, path: []const u8) Presence {
    if (path.len == 0) return .missing;
    const info = Io.Dir.cwd().statFile(io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .missing,
        else => .unknown,
    };
    return if (info.kind == .directory) .present else .missing;
}

pub fn isDirectory(io: Io, path: []const u8) bool {
    return presence(io, path) == .present;
}

pub fn isGone(io: Io, path: []const u8) bool {
    return presence(io, path) == .missing;
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

pub const low_free_bytes: u64 = 20 * 1024 * 1024 * 1024;

pub fn available(gpa: std.mem.Allocator, io: Io, path: []const u8) ?u64 {
    const out = exec.run(gpa, io, &.{ "df", "-k", "-P", path }, null) catch return null;
    defer out.deinit(gpa);
    if (!out.ok()) return null;
    return parseAvailable(out.stdout);
}

pub fn parseAvailable(text: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next() orelse return null;
    const row = lines.next() orelse return null;
    var fields = std.mem.tokenizeAny(u8, row, " \t");
    var previous: ?[]const u8 = null;
    while (fields.next()) |field| {
        if (isPercent(field)) {
            const kb = std.fmt.parseInt(u64, previous orelse return null, 10) catch return null;
            return kb * 1024;
        }
        previous = field;
    }
    return null;
}

fn isPercent(field: []const u8) bool {
    if (field.len < 2 or field[field.len - 1] != '%') return false;
    for (field[0 .. field.len - 1]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test "free space is the Available column of df -P, in bytes" {
    const out =
        \\Filesystem     1024-blocks      Used Available Capacity  Mounted on
        \\/dev/disk3s5     482797652 351145564  88218552    80%    /System/Volumes/Data
        \\
    ;
    try std.testing.expectEqual(@as(?u64, 88218552 * 1024), parseAvailable(out));
}

test "df output that does not carry a number where Available goes reads as unknown, not as a full disk" {
    try std.testing.expectEqual(@as(?u64, null), parseAvailable(""));
    try std.testing.expectEqual(@as(?u64, null), parseAvailable("Filesystem 1024-blocks Used Available\n"));
}

test "a filesystem name with a space does not shift which column is read as free" {
    const out = "Filesystem 1024-blocks Used Available Capacity Mounted on\nmap auto home 10 4 6 40% /System/Volumes/Data/home\n";
    try std.testing.expectEqual(@as(?u64, 6 * 1024), parseAvailable(out));
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

test "a directory we are not allowed to look at is not the same answer as one that was deleted" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const sealed = try std.fs.path.join(arena, &.{ base, "sealed" });
    const inside = try std.fs.path.join(arena, &.{ sealed, "worktree" });
    try Io.Dir.cwd().createDirPath(io, inside);

    var dir = try Io.Dir.cwd().openDir(io, sealed, .{});
    defer dir.close(io);
    try dir.setPermissions(io, @enumFromInt(0o000));
    defer dir.setPermissions(io, @enumFromInt(0o700)) catch {};

    switch (presence(io, inside)) {
        .unknown, .present => {},
        .missing => {
            std.debug.print(
                "a worktree behind a directory this process cannot enter answered `gone`: a " ++
                    "permission error, an unmounted volume or a stalled network mount deletes " ++
                    "every live session's row, and the agents still running have nothing left " ++
                    "to attach to or kill.\n",
                .{},
            );
            return error.TestUnexpectedResult;
        },
    }

    const removed = try std.fs.path.join(arena, &.{ base, "removed" });
    try std.testing.expect(isGone(io, removed));
    try std.testing.expect(isGone(io, ""));
    try std.testing.expect(!isGone(io, base));
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
