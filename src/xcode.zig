const std = @import("std");
const Io = std.Io;
const disk = @import("disk.zig");
const exec = @import("exec.zig");

const ignore_dirs = [_][]const u8{ "node_modules", "Pods", "Carthage", "DerivedData", "vendor" };

pub const Kind = enum {
    workspace,
    project,
    package,

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

pub const Error = error{ XcodeLaunchFailed, XcodeCloseFailed } || std.mem.Allocator.Error;

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
                continue;
            }
            if (std.mem.endsWith(u8, entry.name, ".xcodeproj")) {
                try out.append(gpa, .{ .path = full, .kind = .project, .depth = depth });
                continue;
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

pub fn open(gpa: std.mem.Allocator, io: Io, target: []const u8) Error!void {
    const out = exec.run(gpa, io, &.{ "open", "-a", "Xcode", target }, null) catch
        return Error.XcodeLaunchFailed;
    if (!out.ok()) {
        last_error = exec.message(out);
        return Error.XcodeLaunchFailed;
    }
}

pub var last_error: []const u8 = "";

pub const Document = struct {
    app: []const u8,
    path: []const u8,
    resolved: []const u8,

    pub fn name(self: Document) []const u8 {
        return std.fs.path.basename(self.path);
    }
};

pub const Open = struct {
    workspaces: []const Document = &.{},
    unsaved: []const Document = &.{},
    unanswered: bool = false,

    pub fn empty(self: Open) bool {
        return self.workspaces.len == 0 and self.unsaved.len == 0;
    }

    pub fn inside(self: Open, gpa: std.mem.Allocator, io: Io, worktree: []const u8) !Open {
        const root_path = disk.realPath(gpa, io, worktree);
        return .{
            .workspaces = try under(gpa, self.workspaces, root_path),
            .unsaved = try under(gpa, self.unsaved, root_path),
            .unanswered = self.unanswered,
        };
    }
};

fn under(gpa: std.mem.Allocator, docs: []const Document, root_path: []const u8) ![]const Document {
    var kept: std.ArrayList(Document) = .empty;
    for (docs) |doc| {
        const at_root = std.mem.eql(u8, doc.resolved, root_path);
        if (!at_root and !disk.isInside(gpa, root_path, doc.resolved)) continue;
        try kept.append(gpa, doc);
    }
    return kept.toOwnedSlice(gpa);
}

pub fn openDocuments(gpa: std.mem.Allocator, io: Io) !Open {
    var workspaces: std.ArrayList(Document) = .empty;
    var unsaved: std.ArrayList(Document) = .empty;
    var unanswered = false;

    for (try runningApps(gpa, io)) |bundle| {
        const listing = query(gpa, io, bundle) orelse {
            unanswered = true;
            continue;
        };
        try collect(gpa, io, bundle, listing, &workspaces, &unsaved);
    }

    return .{
        .workspaces = workspaces.items,
        .unsaved = unsaved.items,
        .unanswered = unanswered,
    };
}

pub fn closeDocuments(gpa: std.mem.Allocator, io: Io, docs: []const Document) Error!void {
    var told: std.ArrayList([]const u8) = .empty;
    for (docs) |doc| {
        for (told.items) |seen| {
            if (std.mem.eql(u8, seen, doc.app)) break;
        } else {
            try told.append(gpa, doc.app);
            try closeIn(gpa, io, doc.app, docs);
        }
    }
}

fn closeIn(gpa: std.mem.Allocator, io: Io, bundle: []const u8, docs: []const Document) Error!void {
    const script = try std.fmt.allocPrint(gpa, close_script, .{try quote(gpa, bundle)});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{ "osascript", "-e", script, "--" });
    for (docs) |doc| {
        if (std.mem.eql(u8, doc.app, bundle)) try argv.append(gpa, doc.path);
    }

    const out = exec.run(gpa, io, argv.items, null) catch return Error.XcodeCloseFailed;
    if (!out.ok()) {
        last_error = exec.message(out);
        return Error.XcodeCloseFailed;
    }
}

fn runningApps(gpa: std.mem.Allocator, io: Io) ![]const []const u8 {
    const out = exec.run(gpa, io, &.{ "ps", "-axo", "comm=" }, null) catch return &.{};
    defer out.deinit(gpa);
    if (!out.ok()) return &.{};
    return parseApps(gpa, out.stdout);
}

const executable_suffix = "/Contents/MacOS/Xcode";

fn parseApps(gpa: std.mem.Allocator, listing: []const u8) ![]const []const u8 {
    var apps: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.endsWith(u8, line, executable_suffix)) continue;
        const bundle = line[0 .. line.len - executable_suffix.len];
        if (!std.mem.endsWith(u8, bundle, ".app")) continue;
        for (apps.items) |seen| {
            if (std.mem.eql(u8, seen, bundle)) break;
        } else try apps.append(gpa, try gpa.dupe(u8, bundle));
    }
    return apps.toOwnedSlice(gpa);
}

fn query(gpa: std.mem.Allocator, io: Io, bundle: []const u8) ?[]const u8 {
    const script = std.fmt.allocPrint(gpa, list_script, .{quote(gpa, bundle) catch return null}) catch
        return null;
    const out = exec.run(gpa, io, &.{ "osascript", "-e", script }, null) catch return null;
    if (!out.ok()) {
        last_error = exec.message(out);
        return null;
    }
    return out.stdout;
}

fn collect(
    gpa: std.mem.Allocator,
    io: Io,
    bundle: []const u8,
    listing: []const u8,
    workspaces: *std.ArrayList(Document),
    unsaved: *std.ArrayList(Document),
) !void {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const path = line[tab + 1 ..];
        if (path.len == 0) continue;

        const owned = try gpa.dupe(u8, path);
        const doc: Document = .{
            .app = bundle,
            .path = owned,
            .resolved = disk.realPath(gpa, io, owned),
        };
        switch (line[0]) {
            'w' => try workspaces.append(gpa, doc),
            'm' => try unsaved.append(gpa, doc),
            else => {},
        }
    }
}

fn quote(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (path) |c| {
        if (c == '\\' or c == '"') try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

const list_script =
    \\set out to ""
    \\with timeout of 5 seconds
    \\tell application "{s}"
    \\repeat with d in workspace documents
    \\set out to out & "w" & tab & (path of d) & linefeed
    \\end repeat
    \\repeat with d in (every document whose modified is true)
    \\set out to out & "m" & tab & (path of d) & linefeed
    \\end repeat
    \\end tell
    \\end timeout
    \\return out
;

const close_script =
    \\on run argv
    \\with timeout of 10 seconds
    \\tell application "{s}"
    \\repeat with p in argv
    \\repeat with d in (every workspace document whose path is (p as text))
    \\close d saving no
    \\end repeat
    \\end repeat
    \\end tell
    \\end timeout
    \\end run
;

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
    try tmp.dir.createDirPath(io, "node_modules/thing.xcodeproj");

    const found = (try findTarget(arena_state.allocator(), io, root, 4)).?;
    try std.testing.expectEqual(Kind.package, found.kind);
}

test "a beta running beside the release build is two instances, not one" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const listing =
        \\/Applications/Xcode.app/Contents/MacOS/Xcode
        \\/Users/me/Downloads/Xcode-beta.app/Contents/MacOS/Xcode
        \\/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge
        \\/Applications/Xcode.app/Contents/MacOS/Xcode
        \\/Applications/Safari.app/Contents/MacOS/Safari
        \\
    ;
    const apps = try parseApps(arena_state.allocator(), listing);
    try std.testing.expectEqual(@as(usize, 2), apps.len);
    try std.testing.expectEqualStrings("/Applications/Xcode.app", apps[0]);
    try std.testing.expectEqualStrings("/Users/me/Downloads/Xcode-beta.app", apps[1]);
}

test "a listing splits into windows and unsaved work" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var workspaces: std.ArrayList(Document) = .empty;
    var unsaved: std.ArrayList(Document) = .empty;
    const listing =
        "w\t/Users/me/Projects/App/.lcc/worktrees/pe-101/App.xcodeproj\n" ++
        "w\t/Users/me/Projects/Other/Other.xcworkspace\n" ++
        "m\t/Users/me/Projects/App/.lcc/worktrees/pe-101/App/View.swift\n" ++
        "\n";
    try collect(arena, io, "/Applications/Xcode.app", listing, &workspaces, &unsaved);

    try std.testing.expectEqual(@as(usize, 2), workspaces.items.len);
    try std.testing.expectEqual(@as(usize, 1), unsaved.items.len);
    try std.testing.expectEqualStrings("App.xcodeproj", workspaces.items[0].name());

    const held: Open = .{ .workspaces = workspaces.items, .unsaved = unsaved.items };
    const here = try held.inside(arena, io, "/Users/me/Projects/App/.lcc/worktrees/pe-101");
    try std.testing.expectEqual(@as(usize, 1), here.workspaces.len);
    try std.testing.expectEqual(@as(usize, 1), here.unsaved.len);
    try std.testing.expectEqualStrings("App.xcodeproj", here.workspaces[0].name());
}

test "a package opened by its folder is the worktree root itself" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_path = "/Users/me/Projects/Pkg/.lcc/worktrees/pe-7";
    const held: Open = .{ .workspaces = &.{.{
        .app = "/Applications/Xcode.app",
        .path = root_path,
        .resolved = root_path,
    }} };

    const here = try held.inside(arena, io, root_path);
    try std.testing.expectEqual(@as(usize, 1), here.workspaces.len);
}

test "an unanswered Xcode is not an empty one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const held: Open = .{ .unanswered = true };
    try std.testing.expect(held.empty());
    const here = try held.inside(arena_state.allocator(), io, "/Users/me/Projects/App");
    try std.testing.expect(here.unanswered);
}

test "quoting a path that would otherwise end the string literal" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const quoted = try quote(arena_state.allocator(), "/Users/me/we\"ird\\path.app");
    try std.testing.expectEqualStrings("/Users/me/we\\\"ird\\\\path.app", quoted);
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
