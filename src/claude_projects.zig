const std = @import("std");
const Io = std.Io;
const disk = @import("disk.zig");

pub const Entry = struct {
    path: []const u8,
    name: []const u8,
    cwd: []const u8,
    sessions: usize,
};

pub const Sized = struct {
    entry: Entry,
    size: u64,
};

pub const Error = error{RefusingToDelete} || std.mem.Allocator.Error;

const prefix_limit = 64 * 1024;

pub fn root(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]const u8 {
    const home = environ.get("HOME") orelse return error.NoHomeDirectory;

    if (environ.get("LCC_CLAUDE_PROJECTS")) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) {
            if (std.mem.eql(u8, override, "~")) return home;
            if (std.mem.startsWith(u8, override, "~/")) {
                return std.fs.path.join(gpa, &.{ home, override[2..] });
            }
            return gpa.dupe(u8, override);
        }
    }

    return std.fs.path.join(gpa, &.{ home, ".claude", "projects" });
}

pub fn dirName(gpa: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const name = try gpa.dupe(u8, cwd);
    for (name) |*c| {
        if (!std.ascii.isAlphanumeric(c.*)) c.* = '-';
    }
    return name;
}

pub fn hasSessionsFor(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    cwd: []const u8,
) bool {
    const projects = root(gpa, environ) catch return false;
    const resolved = disk.realPath(gpa, io, cwd);
    if (transcriptCount(gpa, io, projects, resolved) > 0) return true;
    if (std.mem.eql(u8, resolved, cwd)) return false;
    return transcriptCount(gpa, io, projects, cwd) > 0;
}

fn transcriptCount(
    gpa: std.mem.Allocator,
    io: Io,
    projects: []const u8,
    cwd: []const u8,
) usize {
    const name = dirName(gpa, cwd) catch return 0;
    const dir_path = std.fs.path.join(gpa, &.{ projects, name }) catch return 0;

    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var count: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |dirent| {
        if (dirent.kind == .file and std.mem.endsWith(u8, dirent.name, ".jsonl")) count += 1;
    }
    return count;
}

pub fn list(gpa: std.mem.Allocator, io: Io, dir_path: []const u8) ![]Entry {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |dirent| {
        if (dirent.kind != .directory) continue;
        const name = try gpa.dupe(u8, dirent.name);
        const full = try std.fs.path.join(gpa, &.{ dir_path, name });

        const scanned = try scanSessions(gpa, io, full);
        const cwd = scanned.cwd orelse continue;
        try entries.append(gpa, .{
            .path = full,
            .name = name,
            .cwd = cwd,
            .sessions = scanned.count,
        });
    }
    return entries.toOwnedSlice(gpa);
}

const Scan = struct {
    cwd: ?[]const u8,
    count: usize,
};

fn scanSessions(gpa: std.mem.Allocator, io: Io, dir_path: []const u8) !Scan {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch
        return .{ .cwd = null, .count = 0 };
    defer dir.close(io);

    var found: ?[]const u8 = null;
    var count: usize = 0;

    var it = dir.iterate();
    while (it.next(io) catch null) |dirent| {
        if (dirent.kind != .file or !std.mem.endsWith(u8, dirent.name, ".jsonl")) continue;
        count += 1;
        if (found != null) continue;

        const file_path = try std.fs.path.join(gpa, &.{ dir_path, dirent.name });
        const prefix = readPrefix(gpa, io, file_path) orelse continue;
        found = try extractCwd(gpa, prefix);
    }
    return .{ .cwd = found, .count = count };
}

fn readPrefix(gpa: std.mem.Allocator, io: Io, file_path: []const u8) ?[]const u8 {
    var file = Io.Dir.cwd().openFile(io, file_path, .{}) catch return null;
    defer file.close(io);

    const buf = gpa.alloc(u8, prefix_limit) catch return null;
    var reader = file.reader(io, &.{});
    const n = reader.interface.readSliceShort(buf) catch return null;
    return buf[0..n];
}

pub fn extractCwd(gpa: std.mem.Allocator, prefix: []const u8) !?[]const u8 {
    const key = "\"cwd\":\"";
    const key_at = std.mem.indexOf(u8, prefix, key) orelse return null;
    const start = key_at + key.len;

    var i = start;
    while (i < prefix.len) {
        switch (prefix[i]) {
            '\\' => i += 2,
            '"' => {
                const value = try unescape(gpa, prefix[start..i]);
                return if (value.len == 0) null else value;
            },
            else => i += 1,
        }
    }
    return null;
}

fn unescape(gpa: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return gpa.dupe(u8, raw);

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\' or i + 1 >= raw.len) {
            try out.append(gpa, raw[i]);
            i += 1;
            continue;
        }
        switch (raw[i + 1]) {
            'n' => try out.append(gpa, '\n'),
            'r' => try out.append(gpa, '\r'),
            't' => try out.append(gpa, '\t'),
            'b' => try out.append(gpa, 0x08),
            'f' => try out.append(gpa, 0x0c),
            'u' => {
                if (i + 6 > raw.len) return out.toOwnedSlice(gpa);
                const code = std.fmt.parseInt(u21, raw[i + 2 .. i + 6], 16) catch {
                    i += 6;
                    continue;
                };
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(code, &buf) catch {
                    i += 6;
                    continue;
                };
                try out.appendSlice(gpa, buf[0..len]);
                i += 6;
                continue;
            },
            else => try out.append(gpa, raw[i + 1]),
        }
        i += 2;
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
        if (std.mem.eql(u8, entry.cwd, resolved) or
            std.mem.eql(u8, entry.cwd, worktree_path) or
            disk.isInside(gpa, resolved, entry.cwd))
        {
            try matched.append(gpa, entry);
        }
    }
    return matched.toOwnedSlice(gpa);
}

pub fn orphans(gpa: std.mem.Allocator, io: Io, entries: []const Entry) ![]Entry {
    var dead: std.ArrayList(Entry) = .empty;
    for (entries) |entry| {
        Io.Dir.cwd().access(io, entry.cwd, .{}) catch {
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

test "extractCwd reads the path a transcript records" {
    const gpa = std.testing.allocator;

    const line =
        \\{"parentUuid":null,"cwd":"/Users/me/Projects/App.worktrees/pe-1","sessionId":"x"}
    ;
    const got = (try extractCwd(gpa, line)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/Users/me/Projects/App.worktrees/pe-1", got);
}

test "extractCwd skips the metadata lines that carry no cwd" {
    const gpa = std.testing.allocator;

    const prefix =
        \\{"type":"mode","sessionId":"x"}
        \\{"type":"summary","summary":"talked about cwd handling"}
        \\{"type":"user","cwd":"/Users/me/x","uuid":"y"}
    ;
    const got = (try extractCwd(gpa, prefix)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/Users/me/x", got);
}

test "extractCwd undoes escaping and refuses a truncated value" {
    const gpa = std.testing.allocator;

    const escaped =
        \\{"cwd":"/Users/me/Say \"hi\"\/there","x":1}
    ;
    const got = (try extractCwd(gpa, escaped)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/Users/me/Say \"hi\"/there", got);

    try std.testing.expect((try extractCwd(gpa, "{\"cwd\":\"/Users/me/Proj")) == null);
    try std.testing.expect((try extractCwd(gpa, "{\"type\":\"mode\"}")) == null);
    try std.testing.expect((try extractCwd(gpa, "{\"cwd\":\"\"}")) == null);
}

fn oversizedTranscript(arena: std.mem.Allocator, cwd_path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, try std.fmt.allocPrint(
        arena,
        "{{\"type\":\"user\",\"cwd\":\"{s}\"}}\n",
        .{cwd_path},
    ));
    while (out.items.len <= prefix_limit * 2) {
        try out.appendSlice(arena, "{\"type\":\"assistant\",\"pad\":\"" ++ ("x" ** 512) ++ "\"}\n");
    }
    return out.items;
}

test "a transcript larger than the prefix limit still yields its cwd" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const projects = try std.fs.path.join(arena, &.{ base, "projects" });
    const cwd = Io.Dir.cwd();

    const worktree = try std.fs.path.join(arena, &.{ base, "App.worktrees", "pe-1" });
    try cwd.createDirPath(io, worktree);

    const project_dir = try std.fs.path.join(arena, &.{ projects, try dirName(arena, worktree) });
    try cwd.createDirPath(io, project_dir);

    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ project_dir, "a.jsonl" }),
        .data = try oversizedTranscript(arena, worktree),
    });

    const entries = try list(arena, io, projects);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings(worktree, entries[0].cwd);

    const mine = try forWorktree(arena, io, entries, worktree);
    try std.testing.expectEqual(@as(usize, 1), mine.len);
}

test "clean reclaims an orphan whose transcripts are all oversized" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const projects = try std.fs.path.join(arena, &.{ base, "projects" });
    const cwd = Io.Dir.cwd();

    const gone = try std.fs.path.join(arena, &.{ base, "App.worktrees", "pe-removed" });
    const project_dir = try std.fs.path.join(arena, &.{ projects, try dirName(arena, gone) });
    try cwd.createDirPath(io, project_dir);
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ project_dir, "a.jsonl" }),
        .data = try oversizedTranscript(arena, gone),
    });

    const alive = try std.fs.path.join(arena, &.{ base, "App.worktrees", "pe-1" });
    try cwd.createDirPath(io, alive);
    const alive_dir = try std.fs.path.join(arena, &.{ projects, try dirName(arena, alive) });
    try cwd.createDirPath(io, alive_dir);
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ alive_dir, "b.jsonl" }),
        .data = try oversizedTranscript(arena, alive),
    });

    const entries = try list(arena, io, projects);
    try std.testing.expectEqual(@as(usize, 2), entries.len);

    const dead = try orphans(arena, io, entries);
    try std.testing.expectEqual(@as(usize, 1), dead.len);
    try std.testing.expectEqualStrings(gone, dead[0].cwd);

    try remove(arena, io, dead[0], projects);
    try std.testing.expectError(
        error.FileNotFound,
        cwd.access(io, project_dir, .{}),
    );
    try cwd.access(io, alive_dir, .{});
}

test "hasSessionsFor answers for the launch directory only" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const projects = try std.fs.path.join(arena, &.{ base, "projects" });
    const cwd = Io.Dir.cwd();

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", base);
    try environ.put("LCC_CLAUDE_PROJECTS", projects);

    const worktree = try std.fs.path.join(arena, &.{ base, "App.worktrees", "pe-1" });
    try cwd.createDirPath(io, worktree);
    try std.testing.expect(!hasSessionsFor(arena, io, &environ, worktree));

    const project_dir = try std.fs.path.join(arena, &.{ projects, try dirName(arena, worktree) });
    try cwd.createDirPath(io, project_dir);
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ project_dir, "memory" }));
    try std.testing.expect(!hasSessionsFor(arena, io, &environ, worktree));

    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ project_dir, "a.jsonl" }),
        .data = "{\"type\":\"mode\"}\n",
    });
    try std.testing.expect(hasSessionsFor(arena, io, &environ, worktree));

    const sub = try std.fs.path.join(arena, &.{ worktree, "Common" });
    try cwd.createDirPath(io, sub);
    try std.testing.expect(!hasSessionsFor(arena, io, &environ, sub));
}

test "list reads origins and skips directories with no discoverable cwd" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const projects = try std.fs.path.join(arena, &.{ base, "projects" });
    const cwd = Io.Dir.cwd();

    const alive = try std.fs.path.join(arena, &.{ base, "alive-worktree" });
    try cwd.createDirPath(io, alive);

    const with_cwd = try std.fs.path.join(arena, &.{ projects, "-alive" });
    try cwd.createDirPath(io, with_cwd);
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ with_cwd, "a.jsonl" }),
        .data = try std.fmt.allocPrint(arena, "{{\"type\":\"mode\"}}\n{{\"cwd\":\"{s}\"}}\n", .{alive}),
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ with_cwd, "b.jsonl" }),
        .data = "{\"type\":\"mode\"}\n",
    });

    const gone = try std.fs.path.join(arena, &.{ projects, "-gone" });
    try cwd.createDirPath(io, gone);
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ gone, "c.jsonl" }),
        .data = try std.fmt.allocPrint(
            arena,
            "{{\"cwd\":\"{s}/removed-worktree\"}}\n",
            .{base},
        ),
    });

    const unknown = try std.fs.path.join(arena, &.{ projects, "-unknown" });
    try cwd.createDirPath(io, unknown);
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ unknown, "d.jsonl" }),
        .data = "{\"type\":\"mode\"}\n",
    });

    const entries = try list(arena, io, projects);
    try std.testing.expectEqual(@as(usize, 2), entries.len);

    const dead = try orphans(arena, io, entries);
    try std.testing.expectEqual(@as(usize, 1), dead.len);
    try std.testing.expectEqualStrings("-gone", dead[0].name);

    const mine = try forWorktree(arena, io, entries, alive);
    try std.testing.expectEqual(@as(usize, 1), mine.len);
    try std.testing.expectEqualStrings("-alive", mine[0].name);
    try std.testing.expectEqual(@as(usize, 2), mine[0].sessions);
}
