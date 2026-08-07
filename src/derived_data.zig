const std = @import("std");
const Io = std.Io;
const disk = @import("disk.zig");
const exec = @import("exec.zig");

pub const Entry = struct {
    path: []const u8,
    name: []const u8,
    workspace_path: []const u8,
};

pub const Sized = struct {
    entry: Entry,
    size: u64,
};

pub const Error = error{RefusingToDelete} || std.mem.Allocator.Error;

pub fn root(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) ![]const u8 {
    const home = environ.get("HOME") orelse return error.NoHomeDirectory;

    if (environ.get("LCC_DERIVED_DATA")) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) {
            if (std.mem.eql(u8, override, "~")) return home;
            if (std.mem.startsWith(u8, override, "~/")) {
                return std.fs.path.join(gpa, &.{ home, override[2..] });
            }
            return gpa.dupe(u8, override);
        }
    }

    if (exec.capture(gpa, io, &.{
        "defaults", "read", "com.apple.dt.Xcode", "IDECustomDerivedDataLocation",
    }, null)) |custom| {
        if (custom.len > 0 and std.fs.path.isAbsolute(custom)) return custom;
    } else |_| {}

    return std.fs.path.join(gpa, &.{ home, "Library", "Developer", "Xcode", "DerivedData" });
}

pub fn list(gpa: std.mem.Allocator, io: Io, dir_path: []const u8) ![]Entry {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |dirent| {
        if (dirent.kind != .directory or std.mem.startsWith(u8, dirent.name, ".")) continue;
        const name = try gpa.dupe(u8, dirent.name);
        const full = try std.fs.path.join(gpa, &.{ dir_path, name });
        const workspace = (try readWorkspacePath(gpa, io, full)) orelse continue;
        try entries.append(gpa, .{ .path = full, .name = name, .workspace_path = workspace });
    }
    return entries.toOwnedSlice(gpa);
}

fn readWorkspacePath(gpa: std.mem.Allocator, io: Io, dir_path: []const u8) !?[]const u8 {
    const plist = try std.fs.path.join(gpa, &.{ dir_path, "info.plist" });
    const raw = Io.Dir.cwd().readFileAlloc(io, plist, gpa, .limited(1 << 20)) catch return null;

    if (try matchWorkspacePath(gpa, raw)) |value| return value;

    const converted = exec.capture(gpa, io, &.{
        "plutil", "-convert", "xml1", "-o", "-", plist,
    }, null) catch return null;
    return matchWorkspacePath(gpa, converted);
}

fn matchWorkspacePath(gpa: std.mem.Allocator, xml: []const u8) !?[]const u8 {
    const key = "<key>WorkspacePath</key>";
    const key_at = std.mem.indexOf(u8, xml, key) orelse return null;
    const after = xml[key_at + key.len ..];

    const open_at = std.mem.indexOf(u8, after, "<string>") orelse return null;
    for (after[0..open_at]) |c| {
        if (!std.ascii.isWhitespace(c)) return null;
    }
    const value_start = open_at + "<string>".len;
    const close_at = std.mem.indexOfPos(u8, after, value_start, "</string>") orelse return null;

    const value = std.mem.trim(u8, after[value_start..close_at], " \t\r\n");
    if (value.len == 0) return null;
    return try decodeEntities(gpa, value);
}

fn decodeEntities(gpa: std.mem.Allocator, value: []const u8) ![]const u8 {
    const replacements = [_][2][]const u8{
        .{ "&lt;", "<" },
        .{ "&gt;", ">" },
        .{ "&quot;", "\"" },
        .{ "&apos;", "'" },
        .{ "&amp;", "&" },
    };
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < value.len) {
        if (value[i] == '&') {
            for (replacements) |pair| {
                if (std.mem.startsWith(u8, value[i..], pair[0])) {
                    try out.appendSlice(gpa, pair[1]);
                    i += pair[0].len;
                    continue :outer;
                }
            }
        }
        try out.append(gpa, value[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

pub fn forWorktree(
    gpa: std.mem.Allocator,
    io: Io,
    entries: []const Entry,
    worktree_path: []const u8,
) ![]Entry {
    const resolved = disk.realPath(gpa, io, worktree_path);

    var matched: std.ArrayList(Entry) = .empty;
    for (entries) |entry| {
        if (disk.isInside(gpa, resolved, entry.workspace_path)) try matched.append(gpa, entry);
    }
    return matched.toOwnedSlice(gpa);
}

pub fn orphans(gpa: std.mem.Allocator, io: Io, entries: []const Entry) ![]Entry {
    var dead: std.ArrayList(Entry) = .empty;
    for (entries) |entry| {
        Io.Dir.cwd().access(io, entry.workspace_path, .{}) catch {
            try dead.append(gpa, entry);
            continue;
        };
    }
    return dead.toOwnedSlice(gpa);
}

pub fn withSizes(gpa: std.mem.Allocator, io: Io, entries: []const Entry) ![]Sized {
    const paths = try gpa.alloc([]const u8, entries.len);
    for (entries, 0..) |entry, i| paths[i] = entry.path;
    const sizes = try disk.usage(gpa, io, paths);

    const sized = try gpa.alloc(Sized, entries.len);
    for (entries, 0..) |entry, i| sized[i] = .{ .entry = entry, .size = sizes[i] };
    return sized;
}

pub fn remove(gpa: std.mem.Allocator, io: Io, entry: Entry, dir_path: []const u8) !void {
    _ = gpa;
    if (entry.name.len == 0) return Error.RefusingToDelete;
    disk.removeChild(io, dir_path, entry.path) catch return Error.RefusingToDelete;
}

test "workspace path is pulled out of plist xml" {
    const gpa = std.testing.allocator;
    const xml =
        \\<plist><dict>
        \\<key>WorkspacePath</key>
        \\<string>/Users/me/Projects/App &amp; Co/App.xcodeproj</string>
        \\</dict></plist>
    ;
    const got = (try matchWorkspacePath(gpa, xml)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/Users/me/Projects/App & Co/App.xcodeproj", got);
}

test "unrelated key is not mistaken for the workspace path" {
    const gpa = std.testing.allocator;
    const xml = "<key>Other</key><string>/nope</string>";
    try std.testing.expect((try matchWorkspacePath(gpa, xml)) == null);
}
