//! The Xcode side of a worktree: finding its entry point, opening it, and asking
//! a running Xcode to let go of it before the directory is deleted.

const std = @import("std");
const Io = std.Io;
const disk = @import("disk.zig");
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

pub const Error = error{ XcodeLaunchFailed, XcodeCloseFailed } || std.mem.Allocator.Error;

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

/// One document open in one running Xcode.
pub const Document = struct {
    /// App bundle of the instance holding it, e.g. `/Applications/Xcode.app`.
    app: []const u8,
    /// Path exactly as Xcode reported it — the string `close` is matched against.
    path: []const u8,
    /// The same path with symlinks resolved, which is what containment is judged
    /// by: Xcode answers `/tmp/…` where git says `/private/tmp/…`.
    resolved: []const u8,

    pub fn name(self: Document) []const u8 {
        return std.fs.path.basename(self.path);
    }
};

/// What the running Xcodes are holding right now.
pub const Open = struct {
    /// Project and workspace windows — the documents that can be closed. Closing
    /// one takes the editors inside it along.
    workspaces: []const Document = &.{},
    /// Documents with edits that are not on disk, of any kind. Xcode's scripting
    /// interface has no `save` (its documents answer `close` and nothing else), so
    /// these are a reason to stop rather than something lcc can settle on the
    /// user's behalf.
    unsaved: []const Document = &.{},
    /// A running Xcode that could not be asked — automation not permitted, or one
    /// too busy to answer in time. An empty list from that run means "we don't
    /// know", not "nothing is open", and the caller should say so.
    unanswered: bool = false,

    pub fn empty(self: Open) bool {
        return self.workspaces.len == 0 and self.unsaved.len == 0;
    }

    /// The subset sitting at or below `worktree`.
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
        // A Swift package opened by its folder is reported as that folder, so the
        // worktree root can *be* the document rather than contain one.
        const at_root = std.mem.eql(u8, doc.resolved, root_path);
        if (!at_root and !disk.isInside(gpa, root_path, doc.resolved)) continue;
        try kept.append(gpa, doc);
    }
    return kept.toOwnedSlice(gpa);
}

/// Every document open in every running Xcode.
///
/// Nothing running, automation refused, an Xcode wedged mid-index — none of those
/// is an error here. They cost lcc the chance to close a window, not the ability
/// to remove the worktree, so they come back as an empty `Open` with `unanswered`
/// set where a live Xcode actually stonewalled us.
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

/// Closes `docs`, telling each Xcode instance once.
///
/// `saving no` is deliberate: a CLI must not be able to raise a save dialog nobody
/// is looking at. Callers refuse to get this far while anything under the worktree
/// is unsaved, so by now there is nothing to discard.
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

    // The paths go as arguments rather than into the script, so a path lcc did not
    // write cannot end up as AppleScript source.
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

/// The app bundle of every Xcode running right now, deduplicated.
///
/// Found through `ps` rather than asked of macOS, because the question is which
/// *bundles* are live: a beta carries the release build's bundle id, so
/// `application id "com.apple.dt.Xcode"` silently picks one of the two — and on a
/// machine running both, the wrong pick is the one holding the worktree. Addressed
/// by path, each instance answers for itself.
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

/// One round trip per instance: its windows, then whatever it has unsaved.
/// Null when that Xcode did not answer.
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

/// A path as an AppleScript string literal.
fn quote(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (path) |c| {
        if (c == '\\' or c == '"') try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

/// `with timeout` keeps a busy Xcode from holding the whole command hostage — the
/// default Apple event timeout is a full minute.
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

test "a beta running beside the release build is two instances, not one" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    // What `ps -axo comm=` looks like with both open: helper processes belonging to
    // Xcode are all over it, and only the app executables count.
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

    // Only what belongs to this worktree comes back, and the other project's
    // window is left out of both lists.
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
    // The doubt has to survive the filter, or the caller reports silence as safety.
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
