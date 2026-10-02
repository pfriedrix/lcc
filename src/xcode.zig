const std = @import("std");
const Io = std.Io;
const disk = @import("disk.zig");
const exec = @import("exec.zig");
const plist = @import("plist.zig");

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

pub const Install = struct {
    path: []const u8,
    name: []const u8,
    version: []const u8 = "",
    build: []const u8 = "",
    active: bool = false,

    pub fn title(self: Install, gpa: std.mem.Allocator) ![]const u8 {
        if (self.version.len == 0) return self.name;
        return std.fmt.allocPrint(gpa, "{s} {s}", .{ self.name, self.version });
    }
};

const spotlight_query = "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'";

pub fn installs(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) ![]const Install {
    var paths: std.ArrayList([]const u8) = .empty;
    if (exec.run(gpa, io, &.{ "mdfind", spotlight_query }, null)) |out| {
        if (out.ok()) {
            for (try parseSpotlight(gpa, out.stdout)) |path| try remember(gpa, &paths, path);
        }
    } else |_| {}

    try scanApps(gpa, io, "/Applications", &paths);
    if (environ.get("HOME")) |home| {
        try scanApps(gpa, io, try std.fs.path.join(gpa, &.{ home, "Applications" }), &paths);
    }

    const selected = activeApp(gpa, io);

    var found: std.ArrayList(Install) = .empty;
    for (paths.items) |path| {
        var install = (try describeApp(gpa, io, path)) orelse continue;
        install.active = std.mem.eql(u8, install.path, selected);
        try found.append(gpa, install);
    }
    std.mem.sort(Install, found.items, {}, preferred);
    return found.toOwnedSlice(gpa);
}

pub fn describeApp(gpa: std.mem.Allocator, io: Io, path: []const u8) !?Install {
    const bundle = std.mem.trimEnd(u8, path, "/");
    if (bundle.len == 0) return null;

    const executable = try std.fs.path.join(gpa, &.{ bundle, "Contents", "MacOS", "Xcode" });
    Io.Dir.cwd().access(io, executable, .{}) catch return null;

    var install: Install = .{ .path = try gpa.dupe(u8, bundle), .name = bundleName(bundle) };
    const version_plist = try std.fs.path.join(gpa, &.{ bundle, "Contents", "version.plist" });
    if (readPlist(gpa, io, version_plist)) |xml| {
        install.version = (try plist.string(gpa, xml, "CFBundleShortVersionString")) orelse "";
        install.build = (try plist.string(gpa, xml, "ProductBuildVersion")) orelse "";
    }
    return install;
}

pub fn match(found: []const Install, raw: []const u8) ?Install {
    const value = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \t\r\n"), "/");
    if (value.len == 0) return null;

    for (found) |install| {
        if (std.mem.eql(u8, install.path, value)) return install;
        if (std.ascii.eqlIgnoreCase(install.name, value)) return install;
        if (std.ascii.eqlIgnoreCase(std.fs.path.basename(install.path), value)) return install;
        if (install.build.len > 0 and std.ascii.eqlIgnoreCase(install.build, value)) return install;
    }
    for (found) |install| {
        if (install.version.len == 0) continue;
        if (std.mem.eql(u8, install.version, value)) return install;
        if (std.mem.startsWith(u8, install.version, value) and
            install.version.len > value.len and install.version[value.len] == '.') return install;
    }
    return null;
}

fn bundleName(bundle: []const u8) []const u8 {
    const leaf = std.fs.path.basename(bundle);
    return if (std.mem.endsWith(u8, leaf, ".app")) leaf[0 .. leaf.len - ".app".len] else leaf;
}

fn readPlist(gpa: std.mem.Allocator, io: Io, path: []const u8) ?[]const u8 {
    const raw = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return null;
    if (std.mem.indexOf(u8, raw, "<key>") != null) return raw;
    return exec.capture(gpa, io, &.{ "plutil", "-convert", "xml1", "-o", "-", path }, null) catch null;
}

fn parseSpotlight(gpa: std.mem.Allocator, listing: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.endsWith(u8, line, ".app")) continue;
        try remember(gpa, &out, line);
    }
    return out.toOwnedSlice(gpa);
}

fn scanApps(
    gpa: std.mem.Allocator,
    io: Io,
    dir_path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".app")) continue;
        try remember(gpa, out, try std.fs.path.join(gpa, &.{ dir_path, entry.name }));
    }
}

fn remember(gpa: std.mem.Allocator, out: *std.ArrayList([]const u8), path: []const u8) !void {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return;
    for (out.items) |seen| {
        if (std.mem.eql(u8, seen, trimmed)) return;
    }
    try out.append(gpa, try gpa.dupe(u8, trimmed));
}

const developer_suffix = "/Contents/Developer";

fn activeApp(gpa: std.mem.Allocator, io: Io) []const u8 {
    const developer = exec.capture(gpa, io, &.{ "xcode-select", "-p" }, null) catch return "";
    if (!std.mem.endsWith(u8, developer, developer_suffix)) return "";
    return developer[0 .. developer.len - developer_suffix.len];
}

fn preferred(_: void, a: Install, b: Install) bool {
    if (a.active != b.active) return a.active;
    const order = compareVersions(a.version, b.version);
    if (order != .eq) return order == .gt;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    var left = std.mem.splitScalar(u8, a, '.');
    var right = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const next_left = left.next();
        const next_right = right.next();
        if (next_left == null and next_right == null) return .eq;
        const order = std.math.order(component(next_left), component(next_right));
        if (order != .eq) return order;
    }
}

fn component(part: ?[]const u8) u64 {
    const text = std.mem.trim(u8, part orelse return 0, " \t");
    return std.fmt.parseUnsigned(u64, text, 10) catch 0;
}

pub const Error = error{ XcodeLaunchFailed, XcodeCloseFailed, XcodeStillOpen } || std.mem.Allocator.Error;

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

pub fn open(
    gpa: std.mem.Allocator,
    io: Io,
    application: []const u8,
    target: []const u8,
) Error!void {
    const out = exec.run(gpa, io, &.{ "open", "-a", application, target }, null) catch
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
    documents: []const Document = &.{},
    unsaved: []const Document = &.{},
    unanswered: bool = false,

    pub fn empty(self: Open) bool {
        return !self.holds() and self.unsaved.len == 0;
    }

    pub fn holds(self: Open) bool {
        return self.workspaces.len > 0 or self.documents.len > 0;
    }

    pub fn closable(self: Open, gpa: std.mem.Allocator) ![]const Document {
        return std.mem.concat(gpa, Document, &.{ self.workspaces, self.documents });
    }

    pub fn inside(self: Open, gpa: std.mem.Allocator, io: Io, worktree: []const u8) !Open {
        const root_path = disk.realPath(gpa, io, worktree);
        return .{
            .workspaces = try under(gpa, self.workspaces, root_path),
            .documents = try under(gpa, self.documents, root_path),
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
    var found: Found = .{};
    var unanswered = false;

    for (try runningApps(gpa, io)) |bundle| {
        const listing = query(gpa, io, bundle) orelse {
            unanswered = true;
            continue;
        };
        try collect(gpa, io, bundle, listing, &found);
    }

    return found.open(unanswered);
}

pub fn heldBy(gpa: std.mem.Allocator, io: Io, worktree: []const u8) !Open {
    const all = try openDocuments(gpa, io);
    return all.inside(gpa, io, worktree);
}

pub const confirm_polls = 50;
const confirm_poll_ms = 200;

pub fn closeAndConfirm(gpa: std.mem.Allocator, io: Io, held: Open, worktree: []const u8) Error!void {
    try closeDocuments(gpa, io, try held.closable(gpa));

    var polls: usize = 0;
    while (true) : (polls += 1) {
        const left = try heldBy(gpa, io, worktree);
        if (!left.unanswered and !left.holds()) return;
        if (polls >= confirm_polls) {
            last_error = if (left.holds())
                try std.fmt.allocPrint(gpa, "{s} is still open after the close", .{(try left.closable(gpa))[0].name()})
            else
                "Xcode stopped answering after the close";
            return Error.XcodeStillOpen;
        }
        io.sleep(.fromMilliseconds(confirm_poll_ms), .awake) catch {};
    }
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

const Found = struct {
    workspaces: std.ArrayList(Document) = .empty,
    documents: std.ArrayList(Document) = .empty,
    unsaved: std.ArrayList(Document) = .empty,

    fn open(self: Found, unanswered: bool) Open {
        return .{
            .workspaces = self.workspaces.items,
            .documents = self.documents.items,
            .unsaved = self.unsaved.items,
            .unanswered = unanswered,
        };
    }
};

fn collect(
    gpa: std.mem.Allocator,
    io: Io,
    bundle: []const u8,
    listing: []const u8,
    found: *Found,
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
            'w' => try found.workspaces.append(gpa, doc),
            'd' => try found.documents.append(gpa, doc),
            'm' => try found.unsaved.append(gpa, doc),
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
    \\repeat with d in documents
    \\if class of d is not workspace document then set out to out & "d" & tab & (path of d) & linefeed
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
    \\repeat with d in (every document whose path is (p as text))
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

test "a listing splits into windows, loose documents and unsaved work" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var found: Found = .{};
    const listing =
        "w\t/Users/me/Projects/App/.lcc/worktrees/pe-101/App.xcodeproj\n" ++
        "w\t/Users/me/Projects/Other/Other.xcworkspace\n" ++
        "d\t/Users/me/Projects/App/.lcc/worktrees/pe-101/Tracking/Package.swift\n" ++
        "d\t/56AD3E3F-A5C6-41E6-A42B-B1254A16FA12\n" ++
        "m\t/Users/me/Projects/App/.lcc/worktrees/pe-101/App/View.swift\n" ++
        "\n";
    try collect(arena, io, "/Applications/Xcode.app", listing, &found);
    const held = found.open(false);

    try std.testing.expectEqual(@as(usize, 2), held.workspaces.len);
    try std.testing.expectEqual(@as(usize, 2), held.documents.len);
    try std.testing.expectEqual(@as(usize, 1), held.unsaved.len);
    try std.testing.expectEqualStrings("App.xcodeproj", held.workspaces[0].name());

    const here = try held.inside(arena, io, "/Users/me/Projects/App/.lcc/worktrees/pe-101");
    try std.testing.expectEqual(@as(usize, 1), here.workspaces.len);
    try std.testing.expectEqual(@as(usize, 1), here.unsaved.len);
    try std.testing.expectEqualStrings("App.xcodeproj", here.workspaces[0].name());
    if (here.documents.len != 1) {
        std.debug.print(
            "a Package.swift standing in its own window was not counted: it is never closed, and " ++
                "Xcode raises a files-deleted alert in that window the moment the worktree goes\n",
            .{},
        );
        return error.TestExpectedEqual;
    }
    try std.testing.expectEqual(@as(usize, 2), (try here.closable(arena)).len);
}

test "closing a worktree's windows leaves the main checkout's windows open" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var found: Found = .{};
    const listing =
        "w\t/Users/me/Projects/App/App.xcodeproj\n" ++
        "d\t/Users/me/Projects/App/Tracking/Package.swift\n" ++
        "w\t/Users/me/Projects/App.worktrees/pe-1/App.xcodeproj\n" ++
        "w\t/Users/me/Projects/App.worktrees/pe-10/App.xcodeproj\n";
    try collect(arena, io, "/Applications/Xcode.app", listing, &found);

    const here = try found.open(false).inside(arena, io, "/Users/me/Projects/App.worktrees/pe-1");
    const closing = try here.closable(arena);
    if (closing.len != 1 or !std.mem.eql(u8, closing[0].path, "/Users/me/Projects/App.worktrees/pe-1/App.xcodeproj")) {
        std.debug.print(
            "removing pe-1 would close {d} window(s), not just its own: the main checkout or a " ++
                "sibling worktree loses its Xcode window over a removal it was not part of\n",
            .{closing.len},
        );
        return error.TestUnexpectedResult;
    }

    const main_only = try found.open(false).inside(arena, io, "/Users/me/Projects/App.worktrees/pe-2");
    try std.testing.expect(!main_only.holds());
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

test "an Xcode Spotlight found outside /Applications counts, and a duplicate does not" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const listing =
        \\/Applications/Xcode.app
        \\/Users/me/Downloads/Xcode-beta.app
        \\/Applications/Xcode.app
        \\/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
        \\
    ;
    const paths = try parseSpotlight(arena_state.allocator(), listing);
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("/Applications/Xcode.app", paths[0]);
    try std.testing.expectEqualStrings("/Users/me/Downloads/Xcode-beta.app", paths[1]);
}

test "an app is an Xcode by the executable it carries, and names the version it reports" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "Xcode-beta.app/Contents/MacOS");
    try tmp.dir.writeFile(io, .{ .sub_path = "Xcode-beta.app/Contents/MacOS/Xcode", .data = "" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "Xcode-beta.app/Contents/version.plist",
        .data =
        \\<plist><dict>
        \\<key>CFBundleShortVersionString</key>
        \\<string>27.0</string>
        \\<key>ProductBuildVersion</key>
        \\<string>27A5218g</string>
        \\</dict></plist>
        ,
    });
    try tmp.dir.createDirPath(io, "Safari.app/Contents/MacOS");

    const beta = (try describeApp(arena, io, try std.fs.path.join(arena, &.{ root, "Xcode-beta.app" }))).?;
    try std.testing.expectEqualStrings("Xcode-beta", beta.name);
    try std.testing.expectEqualStrings("27.0", beta.version);
    try std.testing.expectEqualStrings("27A5218g", beta.build);

    const safari = try describeApp(arena, io, try std.fs.path.join(arena, &.{ root, "Safari.app" }));
    try std.testing.expect(safari == null);
}

test "an Xcode with no readable version is still offered, by name alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "Xcode.app/Contents/MacOS");
    try tmp.dir.writeFile(io, .{ .sub_path = "Xcode.app/Contents/MacOS/Xcode", .data = "" });

    const found = (try describeApp(arena, io, try std.fs.path.join(arena, &.{ root, "Xcode.app" }))).?;
    try std.testing.expectEqualStrings("Xcode", found.name);
    try std.testing.expectEqualStrings("", found.version);
    try std.testing.expectEqualStrings("Xcode", try found.title(arena));
}

test "naming the release build does not hand back the beta standing next to it" {
    const found = [_]Install{
        .{ .path = "/Applications/Xcode.app", .name = "Xcode", .version = "26.6", .build = "17F113" },
        .{ .path = "/Users/me/Downloads/Xcode-beta.app", .name = "Xcode-beta", .version = "27.0", .build = "27A5218g" },
    };

    try std.testing.expectEqualStrings("/Applications/Xcode.app", match(&found, "Xcode").?.path);
    try std.testing.expectEqualStrings("/Applications/Xcode.app", match(&found, "xcode").?.path);
    try std.testing.expectEqualStrings("/Applications/Xcode.app", match(&found, "Xcode.app").?.path);
    try std.testing.expectEqualStrings("/Applications/Xcode.app", match(&found, "26.6").?.path);
    try std.testing.expectEqualStrings("/Applications/Xcode.app", match(&found, "26").?.path);
    try std.testing.expectEqualStrings("/Applications/Xcode.app", match(&found, "17F113").?.path);

    const beta = "/Users/me/Downloads/Xcode-beta.app";
    try std.testing.expectEqualStrings(beta, match(&found, "Xcode-beta").?.path);
    try std.testing.expectEqualStrings(beta, match(&found, beta).?.path);
    try std.testing.expectEqualStrings(beta, match(&found, beta ++ "/").?.path);
    try std.testing.expectEqualStrings(beta, match(&found, "27").?.path);

    try std.testing.expect(match(&found, "Xcode-") == null);
    try std.testing.expect(match(&found, "25") == null);
    try std.testing.expect(match(&found, "") == null);
    try std.testing.expect(match(&.{}, "Xcode") == null);
}

test "the picker leads with the Xcode the toolchain already points at" {
    var found = [_]Install{
        .{ .path = "/Applications/Xcode-15.app", .name = "Xcode-15", .version = "15.4" },
        .{ .path = "/Applications/Xcode-beta.app", .name = "Xcode-beta", .version = "27.0" },
        .{ .path = "/Applications/Xcode.app", .name = "Xcode", .version = "26.6", .active = true },
    };
    std.mem.sort(Install, &found, {}, preferred);

    try std.testing.expectEqualStrings("Xcode", found[0].name);
    try std.testing.expectEqualStrings("Xcode-beta", found[1].name);
    try std.testing.expectEqualStrings("Xcode-15", found[2].name);
}

test "9.9 is older than 10.0, and a version nobody reported sorts last" {
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("9.9", "10.0"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("26.6", "26.5.1"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("26.6", "26.6.0"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("", "1.0"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("", ""));
}
