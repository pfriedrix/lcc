const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const exec = @import("exec.zig");
const linear = @import("linear.zig");

const state_limit = 4 * 1024 * 1024;

pub const Pair = struct {
    identifier: []const u8,
    repo: []const u8,
};

pub const State = struct {
    known: []const []const u8 = &.{},
    issues: []const Pair = &.{},
};

pub fn path(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]const u8 {
    if (environ.get("LCC_REPOS")) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) return gpa.dupe(u8, override);
    }
    const dir = try config.dir(gpa, environ);
    return std.fs.path.join(gpa, &.{ dir, "repos.json" });
}

pub fn load(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) State {
    const file_path = path(gpa, environ) catch return .{};
    const raw = Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(state_limit)) catch return .{};
    return std.json.parseFromSliceLeaky(State, gpa, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch .{};
}

pub fn save(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    state: State,
) !void {
    const file_path = try path(gpa, environ);
    const body = try std.json.Stringify.valueAlloc(gpa, state, .{ .whitespace = .indent_2 });

    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(file_path)) |parent| try cwd.createDirPath(io, parent);
    try cwd.writeFile(io, .{ .sub_path = file_path, .data = body });
}

pub fn recall(state: State, identifier: []const u8) ?[]const u8 {
    for (state.issues) |pair| {
        if (linear.sameIssue(pair.identifier, identifier)) return pair.repo;
    }
    return null;
}

pub fn remember(
    gpa: std.mem.Allocator,
    state: State,
    identifier: []const u8,
    repo_root: []const u8,
) !State {
    var issues: std.ArrayList(Pair) = .empty;
    try issues.append(gpa, .{ .identifier = identifier, .repo = repo_root });
    for (state.issues) |pair| {
        if (linear.sameIssue(pair.identifier, identifier)) continue;
        try issues.append(gpa, pair);
    }

    var known: std.ArrayList([]const u8) = .empty;
    try known.append(gpa, repo_root);
    for (state.known) |root| {
        if (std.mem.eql(u8, root, repo_root)) continue;
        try known.append(gpa, root);
    }

    return .{
        .known = try known.toOwnedSlice(gpa),
        .issues = try issues.toOwnedSlice(gpa),
    };
}

pub fn candidates(
    gpa: std.mem.Allocator,
    io: Io,
    state: State,
    first: ?[]const u8,
    beside: ?[]const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;

    if (first) |root| if (isMainCheckout(gpa, io, root)) {
        try seen.put(gpa, root, {});
        try out.append(gpa, root);
    };

    for (state.known) |root| {
        if (seen.contains(root)) continue;
        if (!isMainCheckout(gpa, io, root)) continue;
        try seen.put(gpa, root, {});
        try out.append(gpa, root);
    }

    if (beside) |anchor| {
        const parent = std.fs.path.dirname(anchor) orelse return out.toOwnedSlice(gpa);
        var dir = Io.Dir.cwd().openDir(io, parent, .{ .iterate = true }) catch
            return out.toOwnedSlice(gpa);
        defer dir.close(io);

        var it = dir.iterate();
        while (it.next(io) catch null) |dirent| {
            if (dirent.kind != .directory) continue;
            const full = try std.fs.path.join(gpa, &.{ parent, dirent.name });
            if (seen.contains(full)) continue;
            if (!isMainCheckout(gpa, io, full)) continue;
            try seen.put(gpa, full, {});
            try out.append(gpa, full);
        }
    }

    return out.toOwnedSlice(gpa);
}

fn isMainCheckout(gpa: std.mem.Allocator, io: Io, root: []const u8) bool {
    const dot_git = std.fs.path.join(gpa, &.{ root, ".git" }) catch return false;
    var dir = Io.Dir.cwd().openDir(io, dot_git, .{}) catch return false;
    dir.close(io);
    return true;
}

pub fn withIssueBranch(
    gpa: std.mem.Allocator,
    io: Io,
    roots: []const []const u8,
    identifier: []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (roots) |root| {
        const refs = exec.capture(gpa, io, &.{
            "git", "for-each-ref", "--format=%(refname:short)", "refs/heads/",
        }, root) catch continue;
        if (hasIssueBranch(refs, identifier)) try out.append(gpa, root);
    }
    return out.toOwnedSlice(gpa);
}

pub fn hasIssueBranch(refs: []const u8, identifier: []const u8) bool {
    var lines = std.mem.splitScalar(u8, refs, '\n');
    while (lines.next()) |line| {
        const branch = std.mem.trim(u8, line, " \t\r");
        if (branch.len == 0) continue;
        if (linear.sameIssue(branch, identifier)) return true;
    }
    return false;
}

test "recall matches on the issue, not the spelling" {
    const state: State = .{ .issues = &.{
        .{ .identifier = "PE-236", .repo = "/repo/app" },
        .{ .identifier = "PE-9", .repo = "/repo/other" },
    } };

    try std.testing.expectEqualStrings("/repo/app", recall(state, "PE-236").?);
    try std.testing.expectEqualStrings("/repo/app", recall(state, "pe-236").?);
    try std.testing.expectEqualStrings("/repo/other", recall(state, "PE-9").?);
    try std.testing.expect(recall(state, "PE-23") == null);
    try std.testing.expect(recall(state, "PE-999") == null);
}

test "remember replaces the issue's answer and leads with the repo" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const before: State = .{
        .known = &.{ "/repo/other", "/repo/app" },
        .issues = &.{
            .{ .identifier = "PE-236", .repo = "/repo/other" },
            .{ .identifier = "PE-9", .repo = "/repo/other" },
        },
    };

    const after = try remember(arena, before, "PE-236", "/repo/app");

    try std.testing.expectEqual(@as(usize, 2), after.issues.len);
    try std.testing.expectEqualStrings("/repo/app", recall(after, "PE-236").?);
    try std.testing.expectEqualStrings("/repo/other", recall(after, "PE-9").?);

    try std.testing.expectEqual(@as(usize, 2), after.known.len);
    try std.testing.expectEqualStrings("/repo/app", after.known[0]);
    try std.testing.expectEqualStrings("/repo/other", after.known[1]);
}

test "hasIssueBranch reads for-each-ref output" {
    const refs =
        \\main
        \\feature/pe-236-logallvalues-fires-amplitude-exposure
        \\release/2.4.1
    ;
    try std.testing.expect(hasIssueBranch(refs, "PE-236"));
    try std.testing.expect(hasIssueBranch(refs, "PE-236"));
    try std.testing.expect(!hasIssueBranch(refs, "PE-23"));
    try std.testing.expect(!hasIssueBranch(refs, "PE-9"));
    try std.testing.expect(!hasIssueBranch("", "PE-236"));
}

test "state survives a round trip through the file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", base);

    try std.testing.expectEqual(@as(usize, 0), load(arena, io, &environ).known.len);

    const written = try remember(arena, .{}, "PE-236", "/repo/app");
    try save(arena, io, &environ, written);

    const read = load(arena, io, &environ);
    try std.testing.expectEqualStrings("/repo/app", recall(read, "PE-236").?);
    try std.testing.expectEqualStrings("/repo/app", read.known[0]);

    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try path(arena, &environ),
        .data = "{\"known\": [",
    });
    try std.testing.expectEqual(@as(usize, 0), load(arena, io, &environ).issues.len);
}

test "candidates lead with the current repo and skip linked worktrees" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cwd = Io.Dir.cwd();

    const app = try std.fs.path.join(arena, &.{ base, "app" });
    const other = try std.fs.path.join(arena, &.{ base, "other" });
    const worktree = try std.fs.path.join(arena, &.{ base, "app.worktrees-pe-1" });
    for ([_][]const u8{ app, other }) |root| {
        try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ root, ".git" }));
    }
    try cwd.createDirPath(io, worktree);
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ worktree, ".git" }),
        .data = "gitdir: /elsewhere\n",
    });

    const fresh = try candidates(arena, io, .{}, other, app);
    try std.testing.expectEqual(@as(usize, 2), fresh.len);
    try std.testing.expectEqualStrings(other, fresh[0]);
    try std.testing.expectEqualStrings(app, fresh[1]);

    const gone = try std.fs.path.join(arena, &.{ base, "deleted" });
    const with_state = try candidates(arena, io, .{ .known = &.{ app, gone } }, null, null);
    try std.testing.expectEqual(@as(usize, 1), with_state.len);
    try std.testing.expectEqualStrings(app, with_state[0]);
}
