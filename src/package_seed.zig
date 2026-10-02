const std = @import("std");
const Io = std.Io;
const dd = @import("derived_data.zig");
const disk = @import("disk.zig");

extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: u32) c_int;

pub const Donor = struct {
    entry: dd.Entry,
    root: []const u8,
};

pub const Outcome = union(enum) {
    seeded: Donor,
    exists,
    failed: []const u8,
};

pub fn folderName(gpa: std.mem.Allocator, workspace_path: []const u8) ![]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(workspace_path, &digest, .{});

    var hash: [28]u8 = undefined;
    for (0..2) |half| {
        var value = std.mem.readInt(u64, digest[half * 8 ..][0..8], .big);
        var i: usize = 14;
        while (i > 0) {
            i -= 1;
            hash[half * 14 + i] = 'a' + @as(u8, @intCast(value % 26));
            value /= 26;
        }
    }
    return std.fmt.allocPrint(gpa, "{s}-{s}", .{ std.fs.path.stem(workspace_path), hash });
}

pub fn resolvedFile(gpa: std.mem.Allocator, workspace_path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, workspace_path, ".xcworkspace")) {
        return std.fs.path.join(gpa, &.{ workspace_path, "xcshareddata", "swiftpm", "Package.resolved" });
    }
    return std.fs.path.join(gpa, &.{ workspace_path, "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved" });
}

fn stateFile(gpa: std.mem.Allocator, folder: []const u8) ![]const u8 {
    return std.fs.path.join(gpa, &.{ folder, "SourcePackages", "workspace-state.json" });
}

pub fn pickDonor(
    gpa: std.mem.Allocator,
    io: Io,
    entries: []const dd.Entry,
    roots: []const []const u8,
    target_root: []const u8,
    relative_workspace: []const u8,
) !?Donor {
    const wanted = readOrNull(gpa, io, try resolvedFile(gpa, try std.fs.path.join(gpa, &.{ target_root, relative_workspace })));

    var best: ?Donor = null;
    var best_matches = false;
    var best_mtime: i96 = std.math.minInt(i96);

    for (roots) |root| {
        if (std.mem.eql(u8, root, target_root)) continue;
        const workspace = try std.fs.path.join(gpa, &.{ root, relative_workspace });
        for (entries) |entry| {
            if (!std.mem.eql(u8, entry.workspace_path, workspace)) continue;
            const stat = Io.Dir.cwd().statFile(io, try stateFile(gpa, entry.path), .{}) catch continue;
            const mtime = stat.mtime.nanoseconds;

            const theirs = readOrNull(gpa, io, try resolvedFile(gpa, workspace));
            const matches = wanted != null and theirs != null and std.mem.eql(u8, wanted.?, theirs.?);

            const better = if (best == null)
                true
            else if (matches != best_matches)
                matches
            else
                mtime > best_mtime;
            if (!better) continue;

            best = .{ .entry = entry, .root = root };
            best_matches = matches;
            best_mtime = mtime;
        }
    }
    return best;
}

fn readOrNull(gpa: std.mem.Allocator, io: Io, path: []const u8) ?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch null;
}

pub fn seed(
    gpa: std.mem.Allocator,
    io: Io,
    dd_root: []const u8,
    donor: Donor,
    target_root: []const u8,
    target_workspace: []const u8,
) !Outcome {
    const name = try folderName(gpa, target_workspace);
    const final = try std.fs.path.join(gpa, &.{ dd_root, name });
    if (disk.presence(io, final) != .missing) return .exists;

    const staging = try std.fs.path.join(gpa, &.{ dd_root, try std.fmt.allocPrint(gpa, ".lcc-seed-{s}", .{name}) });
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, staging) catch {};
    cwd.createDirPath(io, staging) catch return .{ .failed = "could not create a folder in DerivedData" };
    errdefer cwd.deleteTree(io, staging) catch {};

    const outcome = try fill(gpa, io, staging, final, donor, target_root, target_workspace);
    if (outcome != .seeded) {
        cwd.deleteTree(io, staging) catch {};
        return outcome;
    }
    Io.Dir.rename(cwd, staging, cwd, final, io) catch {
        cwd.deleteTree(io, staging) catch {};
        return .{ .failed = "could not move the seeded folder into place" };
    };
    return outcome;
}

fn fill(
    gpa: std.mem.Allocator,
    io: Io,
    staging: []const u8,
    final: []const u8,
    donor: Donor,
    target_root: []const u8,
    target_workspace: []const u8,
) !Outcome {
    const source = try std.fs.path.joinZ(gpa, &.{ donor.entry.path, "SourcePackages" });
    const destination = try std.fs.path.joinZ(gpa, &.{ staging, "SourcePackages" });
    if (clonefile(source, destination, 0) != 0) {
        return .{ .failed = "the volume cannot clone files (clonefile failed)" };
    }

    const state_path = try stateFile(gpa, staging);
    const raw = Io.Dir.cwd().readFileAlloc(io, state_path, gpa, .limited(64 << 20)) catch
        return .{ .failed = "the donor has no workspace-state.json" };
    const rewritten = (try rewriteState(gpa, raw, .{
        .from_folder = donor.entry.path,
        .to_folder = final,
        .from_root = donor.root,
        .to_root = target_root,
    })) orelse return .{ .failed = "workspace-state.json is not JSON lcc can rewrite" };
    Io.Dir.cwd().writeFile(io, .{ .sub_path = state_path, .data = rewritten }) catch
        return .{ .failed = "could not write workspace-state.json" };

    const plist_path = try std.fs.path.join(gpa, &.{ staging, "info.plist" });
    Io.Dir.cwd().writeFile(io, .{ .sub_path = plist_path, .data = try infoPlist(gpa, target_workspace) }) catch
        return .{ .failed = "could not write info.plist" };

    return .{ .seeded = donor };
}

pub const Moves = struct {
    from_folder: []const u8,
    to_folder: []const u8,
    from_root: []const u8,
    to_root: []const u8,
};

pub fn rewriteState(gpa: std.mem.Allocator, raw: []const u8, moves: Moves) !?[]u8 {
    var value = std.json.parseFromSliceLeaky(std.json.Value, gpa, raw, .{}) catch return null;
    try rewriteValue(gpa, &value, moves);
    return try std.json.Stringify.valueAlloc(gpa, value, .{});
}

fn rewriteValue(gpa: std.mem.Allocator, value: *std.json.Value, moves: Moves) !void {
    switch (value.*) {
        .string => |text| {
            if (try moved(gpa, text, moves.from_folder, moves.to_folder)) |next| {
                value.* = .{ .string = next };
            } else if (try moved(gpa, text, moves.from_root, moves.to_root)) |next| {
                value.* = .{ .string = next };
            }
        },
        .array => |array| for (array.items) |*item| try rewriteValue(gpa, item, moves),
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |kv| try rewriteValue(gpa, kv.value_ptr, moves);
        },
        else => {},
    }
}

fn moved(gpa: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) !?[]const u8 {
    if (from.len == 0 or !std.mem.startsWith(u8, text, from)) return null;
    const rest = text[from.len..];
    if (rest.len > 0 and rest[0] != '/') return null;
    return try std.mem.concat(gpa, u8, &.{ to, rest });
}

fn infoPlist(gpa: std.mem.Allocator, workspace_path: []const u8) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    for (workspace_path) |c| switch (c) {
        '&' => try escaped.appendSlice(gpa, "&amp;"),
        '<' => try escaped.appendSlice(gpa, "&lt;"),
        '>' => try escaped.appendSlice(gpa, "&gt;"),
        else => try escaped.append(gpa, c),
    };
    return std.fmt.allocPrint(gpa,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>WorkspacePath</key>
        \\    <string>{s}</string>
        \\</dict>
        \\</plist>
        \\
    , .{escaped.items});
}

test "the folder name is the one Xcode derives from the workspace path" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { path: []const u8, name: []const u8 }{
        .{ .path = "/Users/me/Projects/App/App.xcodeproj", .name = "App-fpcqhebjbecxvegaxbcqemnobqph" },
        .{ .path = "/Users/me/Projects/App.worktrees/pe-1-thing/App.xcworkspace", .name = "App-ebiyytiddisqpvalpcralhjjxhtq" },
    };
    for (cases) |case| {
        const got = try folderName(arena, case.path);
        if (!std.mem.eql(u8, got, case.name)) {
            std.debug.print(
                "{s} hashed to {s}, Xcode names it {s}: the seeded packages land in a folder Xcode " ++
                    "never opens, and the worktree downloads every package anyway.\n",
                .{ case.path, got, case.name },
            );
            return error.TestUnexpectedResult;
        }
    }
}

test "a worktree nested inside the donor checkout gets its own paths, not the donor's twice over" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{"object":{"dependencies":[
        \\{"packageRef":{"location":"/x/App/Tracking","kind":"fileSystem"},"subpath":"Tracking"},
        \\{"packageRef":{"location":"https://github.com/getsentry/sentry-cocoa"},"subpath":"sentry-cocoa"},
        \\{"path":"/dd/App-aaa/SourcePackages/checkouts/sentry-cocoa"},
        \\{"path":"/x/AppOther/y"},
        \\{"path":"\/x\/App\/Launch"}
        \\]},"version":7}
    ;
    const out = (try rewriteState(arena, raw, .{
        .from_folder = "/dd/App-aaa",
        .to_folder = "/dd/App-bbb",
        .from_root = "/x/App",
        .to_root = "/x/App/.lcc/worktrees/pe-1",
    })).?;

    const expected = [_][]const u8{
        "\"/x/App/.lcc/worktrees/pe-1/Tracking\"",
        "\"https://github.com/getsentry/sentry-cocoa\"",
        "\"/dd/App-bbb/SourcePackages/checkouts/sentry-cocoa\"",
        "\"/x/AppOther/y\"",
        "\"/x/App/.lcc/worktrees/pe-1/Launch\"",
    };
    for (expected) |needle| {
        if (std.mem.indexOf(u8, out, needle) == null) {
            std.debug.print(
                "the rewritten state is missing {s}: Xcode reads a local package or a checkout at " ++
                    "the donor's path, builds the donor's sources into this worktree, or " ++
                    "re-resolves from scratch.\n{s}\n",
                .{ needle, out },
            );
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, out, "/dd/App-aaa") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pe-1/.lcc") == null);
}

test "a state file that is not JSON is refused rather than copied with the donor's paths" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expect((try rewriteState(arena_state.allocator(), "{\"object\":", .{
        .from_folder = "/a",
        .to_folder = "/b",
        .from_root = "/c",
        .to_root = "/d",
    })) == null);
}

fn fakeDonor(io: Io, dir: Io.Dir, folder: []const u8, workspace: []const u8, state: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try dir.createDirPath(io, try std.fmt.allocPrint(arena, "{s}/SourcePackages/checkouts/sentry-cocoa", .{folder}));
    try dir.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/SourcePackages/checkouts/sentry-cocoa/Package.swift", .{folder}),
        .data = "// swift-tools-version:5.9\n",
    });
    try dir.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/SourcePackages/workspace-state.json", .{folder}),
        .data = state,
    });
    try dir.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/info.plist", .{folder}),
        .data = try infoPlist(arena, workspace),
    });
}

test "a seeded worktree finds the donor's packages under its own DerivedData name, with its own paths" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "DerivedData");
    try tmp.dir.createDirPath(io, "App/App.xcodeproj");
    try tmp.dir.createDirPath(io, "App.worktrees/pe-1/App.xcodeproj");
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const dd_root = try std.fs.path.join(arena, &.{ base, "DerivedData" });
    const main_root = try std.fs.path.join(arena, &.{ base, "App" });
    const wt_root = try std.fs.path.join(arena, &.{ base, "App.worktrees", "pe-1" });
    const main_ws = try std.fs.path.join(arena, &.{ main_root, "App.xcodeproj" });
    const wt_ws = try std.fs.path.join(arena, &.{ wt_root, "App.xcodeproj" });

    const donor_folder = try std.fs.path.join(arena, &.{ dd_root, try folderName(arena, main_ws) });
    const state = try std.fmt.allocPrint(arena, "{{\"object\":{{\"a\":\"{s}/SourcePackages/checkouts/sentry-cocoa\",\"b\":\"{s}/Tracking\"}},\"version\":7}}", .{ donor_folder, main_root });
    try fakeDonor(io, tmp.dir, try std.fmt.allocPrint(arena, "DerivedData/{s}", .{std.fs.path.basename(donor_folder)}), main_ws, state);

    const entries = try dd.list(arena, io, dd_root);
    const donor = (try pickDonor(arena, io, entries, &.{ main_root, wt_root }, wt_root, "App.xcodeproj")) orelse {
        std.debug.print("the main checkout's DerivedData was not picked as a donor for its own worktree.\n", .{});
        return error.TestUnexpectedResult;
    };
    const outcome = try seed(arena, io, dd_root, donor, wt_root, wt_ws);
    if (outcome != .seeded) {
        std.debug.print("seed answered {s}\n", .{@tagName(outcome)});
        if (outcome == .failed) std.debug.print("  {s}\n", .{outcome.failed});
        return error.TestUnexpectedResult;
    }

    const seeded = try std.fs.path.join(arena, &.{ dd_root, try folderName(arena, wt_ws) });
    try std.testing.expect(disk.isDirectory(io, try std.fs.path.join(arena, &.{ seeded, "SourcePackages", "checkouts", "sentry-cocoa" })));

    const rewritten = try Io.Dir.cwd().readFileAlloc(io, try stateFile(arena, seeded), arena, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, rewritten, try std.fmt.allocPrint(arena, "\"{s}/SourcePackages/checkouts/sentry-cocoa\"", .{seeded})) != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, try std.fmt.allocPrint(arena, "\"{s}/Tracking\"", .{wt_root})) != null);

    const original = try Io.Dir.cwd().readFileAlloc(io, try stateFile(arena, donor_folder), arena, .limited(1 << 20));
    try std.testing.expectEqualStrings(state, original);

    var found = false;
    for (try dd.list(arena, io, dd_root)) |entry| {
        if (std.mem.eql(u8, entry.workspace_path, wt_ws)) found = true;
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".lcc-seed-"));
    }
    if (!found) {
        std.debug.print(
            "the seeded folder carries no WorkspacePath lcc can read: lcc remove never matches it " ++
                "to the worktree, and lcc clean never finds it once the worktree is gone.\n",
            .{},
        );
        return error.TestUnexpectedResult;
    }
}

test "a worktree Xcode already made a DerivedData folder for is left exactly as it is" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const wt_ws = try std.fs.path.join(arena, &.{ base, "wt", "App.xcodeproj" });
    const name = try folderName(arena, wt_ws);
    try tmp.dir.createDirPath(io, try std.fmt.allocPrint(arena, "DerivedData/{s}/Build", .{name}));

    const donor: Donor = .{
        .entry = .{ .path = "/nowhere", .name = "App-x", .workspace_path = "/main/App.xcodeproj" },
        .root = "/main",
    };
    const outcome = try seed(arena, io, try std.fs.path.join(arena, &.{ base, "DerivedData" }), donor, try std.fs.path.join(arena, &.{ base, "wt" }), wt_ws);
    try std.testing.expect(outcome == .exists);
}

test "a donor resolved to the same package versions wins over a fresher one that is not" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const resolved_at = "project.xcworkspace/xcshareddata/swiftpm";
    for ([_][]const u8{ "same", "other", "target" }) |root| {
        try tmp.dir.createDirPath(io, try std.fmt.allocPrint(arena, "{s}/App.xcodeproj/{s}", .{ root, resolved_at }));
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "target/App.xcodeproj/" ++ resolved_at ++ "/Package.resolved", .data = "v1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "same/App.xcodeproj/" ++ resolved_at ++ "/Package.resolved", .data = "v1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other/App.xcodeproj/" ++ resolved_at ++ "/Package.resolved", .data = "v2" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const same_ws = try std.fs.path.join(arena, &.{ base, "same", "App.xcodeproj" });
    const other_ws = try std.fs.path.join(arena, &.{ base, "other", "App.xcodeproj" });
    try fakeDonor(io, tmp.dir, "DerivedData/App-same", same_ws, "{}");
    try fakeDonor(io, tmp.dir, "DerivedData/App-other", other_ws, "{}");

    const entries = try dd.list(arena, io, try std.fs.path.join(arena, &.{ base, "DerivedData" }));
    const roots = [_][]const u8{
        try std.fs.path.join(arena, &.{ base, "other" }),
        try std.fs.path.join(arena, &.{ base, "same" }),
        try std.fs.path.join(arena, &.{ base, "target" }),
    };
    const donor = (try pickDonor(arena, io, entries, &roots, roots[2], "App.xcodeproj")).?;
    try std.testing.expectEqualStrings("App-same", donor.entry.name);
}
