//! Finding and opening the Xcode entry point inside a worktree.

const std = @import("std");
const Io = std.Io;
const exec = @import("exec.zig");

// Directories that never hold the project we want to open — skip them while
// searching so we don't descend into dependencies or build output.
const ignore_dirs = [_][]const u8{ "node_modules", "Pods", "Carthage", "DerivedData", "vendor" };

pub const Kind = enum {
    workspace,
    project,
    package,

    /// Same depth wins by kind: a workspace references its projects, so prefer it.
    fn rank(self: Kind) u8 {
        return switch (self) {
            .workspace => 0,
            .project => 1,
            .package => 2,
        };
    }

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .workspace => "workspace",
            .project => "project",
            .package => "Swift package",
        };
    }
};

pub const Target = struct {
    path: []const u8,
    kind: Kind,
};

const Candidate = struct {
    path: []const u8,
    kind: Kind,
    depth: u8,
};

pub const Error = error{XcodeLaunchFailed} || std.mem.Allocator.Error;

/// Best Xcode entry point under `root`: shallowest match, then
/// workspace > project > package at the same depth. Null when nothing matches.
pub fn findTarget(gpa: std.mem.Allocator, io: Io, root: []const u8, max_depth: u8) !?Target {
    var found: std.ArrayList(Candidate) = .empty;
    try walk(gpa, io, root, 0, max_depth, &found);
    if (found.items.len == 0) return null;

    std.mem.sort(Candidate, found.items, {}, betterCandidate);
    const best = found.items[0];
    return .{ .path = best.path, .kind = best.kind };
}

fn betterCandidate(_: void, a: Candidate, b: Candidate) bool {
    if (a.depth != b.depth) return a.depth < b.depth;
    if (a.kind != b.kind) return a.kind.rank() < b.kind.rank();
    return a.path.len < b.path.len;
}

fn walk(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    depth: u8,
    max_depth: u8,
    out: *std.ArrayList(Candidate),
) !void {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const full = try std.fs.path.join(gpa, &.{ path, entry.name });
        if (entry.kind == .directory) {
            if (std.mem.endsWith(u8, entry.name, ".xcworkspace")) {
                try out.append(gpa, .{ .path = full, .kind = .workspace, .depth = depth });
                continue; // bundle — don't descend
            }
            if (std.mem.endsWith(u8, entry.name, ".xcodeproj")) {
                try out.append(gpa, .{ .path = full, .kind = .project, .depth = depth });
                continue; // bundle — don't descend
            }
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            var ignored = false;
            for (ignore_dirs) |name| {
                if (std.mem.eql(u8, name, entry.name)) {
                    ignored = true;
                    break;
                }
            }
            if (ignored) continue;
            if (depth < max_depth) try walk(gpa, io, full, depth + 1, max_depth, out);
        } else if (entry.kind == .file and std.mem.eql(u8, entry.name, "Package.swift")) {
            try out.append(gpa, .{ .path = full, .kind = .package, .depth = depth });
        }
    }
}

pub fn describe(gpa: std.mem.Allocator, target: Target) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} ({s})", .{
        std.fs.path.basename(target.path),
        target.kind.label(),
    });
}

/// `open -a Xcode` returns as soon as the app is handed the document — Xcode is
/// a GUI app, not attached to this process.
pub fn open(gpa: std.mem.Allocator, io: Io, target: []const u8) Error!void {
    const out = exec.run(gpa, io, &.{ "open", "-a", "Xcode", target }, null) catch
        return Error.XcodeLaunchFailed;
    if (!out.ok()) {
        last_error = exec.message(out);
        return Error.XcodeLaunchFailed;
    }
}

pub var last_error: []const u8 = "";

test "shallowest match wins, workspace beats project at equal depth" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A deep project, plus a workspace and a project side by side one level up.
    try tmp.dir.createDirPath(io, "App/Deep/Nested/Thing.xcodeproj");
    try tmp.dir.createDirPath(io, "App/Thing.xcodeproj");
    try tmp.dir.createDirPath(io, "App/Thing.xcworkspace");

    const found = (try findTarget(arena, io, root, 4)).?;
    try std.testing.expectEqual(Kind.workspace, found.kind);
    try std.testing.expect(std.mem.endsWith(u8, found.path, "App/Thing.xcworkspace"));
}

test "Package.swift is found when nothing else is" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "Package.swift", .data = "// swift-tools-version:5.9\n" });
    // Dependency output must never be picked up.
    try tmp.dir.createDirPath(io, "node_modules/thing.xcodeproj");

    const found = (try findTarget(arena_state.allocator(), io, root, 4)).?;
    try std.testing.expectEqual(Kind.package, found.kind);
}

test "no target at all" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    try std.testing.expect((try findTarget(arena_state.allocator(), io, root, 4)) == null);
}
