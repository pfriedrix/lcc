const std = @import("std");
const Io = std.Io;
const cp = @import("claude_projects.zig");
const disk = @import("disk.zig");

pub const Entry = struct {
    path: []const u8,
    name: []const u8,
    stopped: []const []const u8,
    running: usize,
};

pub const Sized = struct {
    entry: Entry,
    size: u64,
};

pub const Live = union(enum) {
    known: []const []const u8,
    unknown,

    pub fn has(self: Live, session_id: []const u8) bool {
        return switch (self) {
            .unknown => true,
            .known => |ids| for (ids) |id| {
                if (std.mem.eql(u8, id, session_id)) break true;
            } else false,
        };
    }
};

pub const Error = error{RefusingToDelete} || std.mem.Allocator.Error;

pub fn root(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (try override(gpa, environ, "LCC_CLAUDE_TMP")) |path| return path;
    return std.fmt.allocPrint(gpa, "/private/tmp/claude-{d}", .{std.c.getuid()});
}

pub fn sessionsRoot(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (try override(gpa, environ, "LCC_CLAUDE_SESSIONS")) |path| return path;
    const home = environ.get("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ home, ".claude", "sessions" });
}

fn override(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    key: []const u8,
) !?[]const u8 {
    const raw = environ.get(key) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return null;
    const home = environ.get("HOME") orelse return try gpa.dupe(u8, trimmed);
    if (std.mem.eql(u8, trimmed, "~")) return try gpa.dupe(u8, home);
    if (std.mem.startsWith(u8, trimmed, "~/")) return try std.fs.path.join(gpa, &.{ home, trimmed[2..] });
    return try gpa.dupe(u8, trimmed);
}

pub fn live(gpa: std.mem.Allocator, io: Io, sessions_dir: []const u8) !Live {
    var dir = Io.Dir.cwd().openDir(io, sessions_dir, .{ .iterate = true }) catch return .unknown;
    defer dir.close(io);

    var ids: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch return .unknown) |dirent| {
        if (dirent.kind != .file or !std.mem.endsWith(u8, dirent.name, ".json")) continue;
        const stem = dirent.name[0 .. dirent.name.len - ".json".len];
        const pid = std.fmt.parseInt(i64, stem, 10) catch continue;
        if (!pidAlive(pid)) continue;

        const file_path = try std.fs.path.join(gpa, &.{ sessions_dir, dirent.name });
        const raw = Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(1 << 20)) catch return .unknown;
        const id = sessionIdIn(raw) orelse return .unknown;
        try ids.append(gpa, id);
    }
    return .{ .known = try ids.toOwnedSlice(gpa) };
}

pub fn sessionIdIn(record: []const u8) ?[]const u8 {
    const key = "\"sessionId\":\"";
    const at = std.mem.indexOf(u8, record, key) orelse return null;
    const start = at + key.len;
    if (record.len < start + 36) return null;
    const id = record[start .. start + 36];
    if (!isSessionId(id)) return null;
    if (record.len > start + 36 and record[start + 36] != '"') return null;
    return id;
}

fn pidAlive(pid: i64) bool {
    if (pid <= 0 or pid > std.math.maxInt(std.c.pid_t)) return false;
    std.posix.kill(@intCast(pid), @enumFromInt(0)) catch |err| return switch (err) {
        error.PermissionDenied => true,
        else => false,
    };
    return true;
}

pub fn isSessionId(name: []const u8) bool {
    if (name.len != 36) return false;
    for (name, 0..) |c, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

pub fn list(gpa: std.mem.Allocator, io: Io, root_path: []const u8, running: Live) ![]Entry {
    if (running == .unknown) return &.{};

    var dir = Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |dirent| {
        if (dirent.kind != .directory or std.mem.startsWith(u8, dirent.name, ".")) continue;
        const name = try gpa.dupe(u8, dirent.name);
        const full = try std.fs.path.join(gpa, &.{ root_path, name });

        var project = Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch continue;
        defer project.close(io);

        var stopped: std.ArrayList([]const u8) = .empty;
        var still_running: usize = 0;
        var sessions = project.iterate();
        while (sessions.next(io) catch null) |session| {
            if (session.kind != .directory or !isSessionId(session.name)) continue;
            if (running.has(session.name)) {
                still_running += 1;
                continue;
            }
            try stopped.append(gpa, try std.fs.path.join(gpa, &.{ full, session.name }));
        }
        if (stopped.items.len == 0) continue;
        try entries.append(gpa, .{
            .path = full,
            .name = name,
            .stopped = try stopped.toOwnedSlice(gpa),
            .running = still_running,
        });
    }
    return entries.toOwnedSlice(gpa);
}

pub fn forWorktree(gpa: std.mem.Allocator, io: Io, entries: []const Entry, worktree_path: []const u8) ![]Entry {
    const as_given = try cp.dirName(gpa, worktree_path);
    const resolved = try cp.dirName(gpa, disk.realPath(gpa, io, worktree_path));

    var matched: std.ArrayList(Entry) = .empty;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, as_given) or std.mem.eql(u8, entry.name, resolved)) {
            try matched.append(gpa, entry);
        }
    }
    return matched.toOwnedSlice(gpa);
}

pub fn withSizes(gpa: std.mem.Allocator, io: Io, entries: []const Entry) ![]Sized {
    var paths: std.ArrayList([]const u8) = .empty;
    for (entries) |entry| try paths.appendSlice(gpa, entry.stopped);
    const sizes = try disk.usage(gpa, io, paths.items);

    const sized = try gpa.alloc(Sized, entries.len);
    var at: usize = 0;
    for (entries, 0..) |entry, i| {
        var total: u64 = 0;
        for (entry.stopped) |_| {
            total += sizes[at];
            at += 1;
        }
        sized[i] = .{ .entry = entry, .size = total };
    }
    return sized;
}

pub fn remove(io: Io, entry: Entry, root_path: []const u8) Error!void {
    if (entry.name.len == 0) return Error.RefusingToDelete;
    const trimmed = std.mem.trimEnd(u8, root_path, "/");
    const parent = std.fs.path.dirname(entry.path) orelse return Error.RefusingToDelete;
    if (!std.mem.eql(u8, parent, trimmed)) return Error.RefusingToDelete;

    for (entry.stopped) |session| {
        disk.removeChild(io, entry.path, session) catch return Error.RefusingToDelete;
    }
    Io.Dir.cwd().deleteDir(io, entry.path) catch {};
}

const session_a = "11111111-2222-3333-4444-555555555555";
const session_b = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";

test "a session id is the uuid shape claude names its scratch folders with, nothing looser" {
    try std.testing.expect(isSessionId(session_a));
    try std.testing.expect(isSessionId("78d6bd1f-bf1e-43c3-a8fb-d6e447685b75"));
    try std.testing.expect(!isSessionId("pe399-dd"));
    try std.testing.expect(!isSessionId("cdp-profile-1790701750450"));
    try std.testing.expect(!isSessionId("11111111-2222-3333-4444-55555555555"));
    try std.testing.expect(!isSessionId("1111111122223333-4444-555555555555xx"));
}

test "a scratch folder whose session is still running is never offered for deletion" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "-Users-me-App/" ++ session_a ++ "/scratchpad");
    try tmp.dir.createDirPath(io, "-Users-me-App/" ++ session_b ++ "/scratchpad");
    try tmp.dir.createDirPath(io, "-Users-me-App/notes");
    try tmp.dir.createDirPath(io, "pe399-dd/Build");
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const entries = try list(arena, io, base, .{ .known = &.{session_a} });
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("-Users-me-App", entries[0].name);
    try std.testing.expectEqual(@as(usize, 1), entries[0].running);
    try std.testing.expectEqual(@as(usize, 1), entries[0].stopped.len);
    if (!std.mem.endsWith(u8, entries[0].stopped[0], session_b)) {
        std.debug.print(
            "the stopped list named {s}: the agent still running there loses its scratchpad " ++
                "mid-task, along with every build and trace it parked in it.\n",
            .{entries[0].stopped[0]},
        );
        return error.TestUnexpectedResult;
    }
}

test "not knowing which sessions run offers nothing, rather than everything" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "-Users-me-App/" ++ session_a);
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const entries = try list(arena, io, base, .unknown);
    if (entries.len != 0) {
        std.debug.print(
            "an unreadable session registry still produced {d} folder(s) to delete: every " ++
                "running agent's scratchpad would go with the stopped ones.\n",
            .{entries.len},
        );
        return error.TestUnexpectedResult;
    }
}

test "the running set comes from records whose process is alive" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const me = std.c.getpid();
    const mine = try std.fmt.allocPrint(arena, "{d}.json", .{me});
    try tmp.dir.writeFile(io, .{
        .sub_path = mine,
        .data = try std.fmt.allocPrint(arena, "{{\"pid\":{d},\"sessionId\":\"{s}\",\"cwd\":\"/x\"}}", .{ me, session_a }),
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "999999.json",
        .data = "{\"pid\":999999,\"sessionId\":\"" ++ session_b ++ "\"}",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "x" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const got = try live(arena, io, base);
    try std.testing.expect(got == .known);
    try std.testing.expect(got.has(session_a));
    try std.testing.expect(!got.has(session_b));
}

test "a record claude rewrote shorter in place still names its session" {
    const record =
        \\{"pid":53872,"sessionId":"353ed565-23b8-48fd-8947-22a60a1be748","status":"idle"}k","waitingFor":"input needed"}
    ;
    const got = sessionIdIn(record) orelse {
        std.debug.print(
            "a record with the tail of its previous, longer version left behind gave no session: " ++
                "claude leaves files like that routinely, and every one of them made the running " ++
                "set unknown, so no scratch folder was ever reclaimed.\n",
            .{},
        );
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings("353ed565-23b8-48fd-8947-22a60a1be748", got);
    try std.testing.expect(sessionIdIn("{\"sessionId\":\"353ed565-23b8-48fd-8947-22a60a1be7\"}") == null);
    try std.testing.expect(sessionIdIn("{\"pid\":1}") == null);
}

test "a running process whose record names no session makes the whole answer unknown" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const mine = try std.fmt.allocPrint(arena, "{d}.json", .{std.c.getpid()});
    try tmp.dir.writeFile(io, .{ .sub_path = mine, .data = "{\"pid\":" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    if ((try live(arena, io, base)) != .unknown) {
        std.debug.print(
            "a half-written record for a live process was skipped: its session reads as " ++
                "stopped and its scratchpad is deleted under it.\n",
            .{},
        );
        return error.TestUnexpectedResult;
    }
}

test "no session registry at all is unknown, not an empty machine" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const missing = try std.fs.path.join(arena, &.{ base, "sessions" });

    try std.testing.expect((try live(arena, io, missing)) == .unknown);
}

test "remove deletes the stopped sessions and keeps the running one" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "-Users-me-App/" ++ session_a ++ "/scratchpad");
    try tmp.dir.createDirPath(io, "-Users-me-App/" ++ session_b ++ "/scratchpad/dd");
    try tmp.dir.createDirPath(io, "-Users-me-Gone/" ++ session_b);
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const entries = try list(arena, io, base, .{ .known = &.{session_a} });
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    for (entries) |entry| try remove(io, entry, base);

    try std.testing.expect(disk.isDirectory(io, try std.fs.path.join(arena, &.{ base, "-Users-me-App", session_a })));
    try std.testing.expect(disk.isGone(io, try std.fs.path.join(arena, &.{ base, "-Users-me-App", session_b })));
    try std.testing.expect(disk.isGone(io, try std.fs.path.join(arena, &.{ base, "-Users-me-Gone" })));
}

test "remove refuses an entry that does not sit directly under the root it was listed from" {
    const io = std.testing.io;
    const entry: Entry = .{
        .path = "/elsewhere/-Users-me-App",
        .name = "-Users-me-App",
        .stopped = &.{"/elsewhere/-Users-me-App/" ++ session_b},
        .running = 0,
    };
    try std.testing.expectError(Error.RefusingToDelete, remove(io, entry, "/private/tmp/claude-501"));
}

test "a worktree finds its scratch by the folder name claude derives from its path" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]Entry{
        .{ .path = "/t/-Users-me-App-worktrees-pe-1-a-b", .name = "-Users-me-App-worktrees-pe-1-a-b", .stopped = &.{}, .running = 0 },
        .{ .path = "/t/-Users-me-App", .name = "-Users-me-App", .stopped = &.{}, .running = 0 },
    };
    const got = try forWorktree(arena, io, &entries, "/Users/me/App.worktrees/pe-1-a_b");
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("-Users-me-App-worktrees-pe-1-a-b", got[0].name);
}
