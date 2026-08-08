const std = @import("std");
const Io = std.Io;
const disk = @import("disk.zig");
const sessions = @import("sessions.zig");
const watch_hooks = @import("watch_hooks.zig");
const watch_paths = @import("watch_paths.zig");
const watch_status = @import("watch_status.zig");

pub const version: u32 = 1;

const record_limit = 64 * 1024;

pub const Record = struct {
    version: u32 = 0,
    event: []const u8 = "",
    cwd: []const u8 = "",
    claude_session: []const u8 = "",
    lcc_session: []const u8 = "",
    permission_mode: []const u8 = "",
    at: i64 = 0,
};

pub fn recover(record: Record) ?sessions.Status {
    const event = watch_hooks.Event.parse(record.event) orelse return null;
    const status: sessions.Status = switch (event) {
        .ended => return null,
        .active, .waiting => .waiting,
        .idle => .idle,
    };
    return watch_status.present(status, watch_hooks.isPlan(record.permission_mode));
}

pub fn newestFor(records: []const Record, cwd: []const u8) ?Record {
    var best: ?Record = null;
    for (records) |record| {
        if (!std.mem.eql(u8, record.cwd, cwd)) continue;
        if (best) |current| {
            if (record.at <= current.at) continue;
        }
        best = record;
    }
    return best;
}

pub fn statusFor(records: []const Record, cwd: []const u8) ?Resolved {
    const record = newestFor(records, cwd) orelse return null;
    const status = recover(record) orelse return null;
    return .{ .status = status, .last_activity_at = record.at };
}

pub const Resolved = struct {
    status: sessions.Status,
    last_activity_at: i64,
};

pub fn write(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    record: Record,
) void {
    if (record.claude_session.len == 0 or record.cwd.len == 0) return;
    const file_path = watch_paths.stateFor(gpa, environ, record.claude_session) catch return;

    var merged = record;
    merged.version = version;
    if (merged.permission_mode.len == 0) {
        if (readAt(gpa, io, file_path)) |previous| merged.permission_mode = previous.permission_mode;
    }

    const body = std.json.Stringify.valueAlloc(gpa, merged, .{ .whitespace = .indent_2 }) catch return;
    defer gpa.free(body);

    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(file_path)) |parent| cwd.createDirPath(io, parent) catch return;

    const tmp_path = std.fmt.allocPrint(gpa, "{s}.tmp", .{file_path}) catch return;
    cwd.writeFile(io, .{ .sub_path = tmp_path, .data = body }) catch return;
    Io.Dir.renameAbsolute(tmp_path, file_path, io) catch {
        cwd.deleteFile(io, tmp_path) catch {};
    };
}

pub fn clear(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    claude_session: []const u8,
) void {
    if (claude_session.len == 0) return;
    const file_path = watch_paths.stateFor(gpa, environ, claude_session) catch return;
    Io.Dir.cwd().deleteFile(io, file_path) catch {};
}

fn readAt(gpa: std.mem.Allocator, io: Io, file_path: []const u8) ?Record {
    const raw = Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(record_limit)) catch return null;
    const parsed = std.json.parseFromSliceLeaky(Record, gpa, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    if (parsed.version != version) return null;
    return parsed;
}

pub fn load(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) []const Record {
    const base = watch_paths.dir(gpa, environ) catch return &.{};
    var dir = Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var out: std.ArrayList(Record) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |dirent| {
        if (dirent.kind != .file) continue;
        if (watch_paths.stateName(dirent.name) == null) continue;

        const file_path = std.fs.path.join(gpa, &.{ base, dirent.name }) catch continue;
        var record = readAt(gpa, io, file_path) orelse continue;
        if (record.cwd.len == 0) continue;
        if (disk.isGone(io, record.cwd)) continue;

        record.cwd = disk.realPath(gpa, io, record.cwd);
        out.append(gpa, record) catch continue;
    }
    return out.toOwnedSlice(gpa) catch &.{};
}

const testing = std.testing;

fn testEnviron(arena: std.mem.Allocator, base: []const u8) !std.process.Environ.Map {
    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_WATCH_DIR", base);
    return environ;
}

test "a turn cut off by a dead daemon asks for a person, rather than claiming it is still running" {
    const interrupted: Record = .{ .version = version, .event = "active", .cwd = "/w", .at = 1000 };
    const got = recover(interrupted).?;
    if (got != .waiting) {
        std.debug.print(
            "an interrupted turn reads {s}: the dashboard paints a green turn-in-flight for an " ++
                "agent that no longer has a process, so the one worktree that actually needs " ++
                "opening looks like the busy one to leave alone.\n",
            .{@tagName(got)},
        );
        return error.TestExpectedEqual;
    }

    try testing.expect(recover(interrupted).? != .active);
}

test "a session that ended cleanly leaves no row to recover" {
    const ended: Record = .{ .version = version, .event = "ended", .cwd = "/w", .at = 1000 };
    try testing.expect(recover(ended) == null);

    const nonsense: Record = .{ .version = version, .event = "thinking_very_hard", .cwd = "/w", .at = 1000 };
    try testing.expect(recover(nonsense) == null);

    const silent: Record = .{ .version = version, .event = "", .cwd = "/w", .at = 1000 };
    try testing.expect(recover(silent) == null);
}

test "a finished turn and a blocked one stay the two different things they were" {
    const idle: Record = .{ .version = version, .event = "idle", .cwd = "/w", .at = 1000 };
    try testing.expectEqual(sessions.Status.idle, recover(idle).?);

    const waiting: Record = .{ .version = version, .event = "waiting", .cwd = "/w", .at = 1000 };
    try testing.expectEqual(sessions.Status.waiting, recover(waiting).?);
}

test "a recovered status is never one only a live session can be in" {
    for ([_][]const u8{ "waiting", "active", "idle" }) |event| {
        const status = recover(.{ .version = version, .event = event, .cwd = "/w", .at = 1000 }).?;
        try testing.expect(status != .active);
        try testing.expect(status != .starting);
        try testing.expect(status != .exited);
        try testing.expect(status != .unknown);
    }
}

test "being blocked outranks plan mode, here as everywhere else" {
    const planning: Record = .{
        .version = version,
        .event = "idle",
        .cwd = "/w",
        .permission_mode = "plan",
        .at = 1000,
    };
    try testing.expectEqual(sessions.Status.plan, recover(planning).?);

    var blocked = planning;
    blocked.event = "waiting";
    try testing.expectEqual(sessions.Status.waiting, recover(blocked).?);

    var working = planning;
    working.event = "active";
    try testing.expectEqual(sessions.Status.waiting, recover(working).?);
}

test "the newest record wins when one worktree held two sessions" {
    const older: Record = .{ .version = version, .event = "idle", .cwd = "/w", .claude_session = "a", .at = 1000 };
    const newer: Record = .{ .version = version, .event = "waiting", .cwd = "/w", .claude_session = "b", .at = 2000 };

    try testing.expectEqualStrings("b", newestFor(&.{ older, newer }, "/w").?.claude_session);
    try testing.expectEqualStrings("b", newestFor(&.{ newer, older }, "/w").?.claude_session);
    try testing.expect(newestFor(&.{ older, newer }, "/elsewhere") == null);

    const resolved = statusFor(&.{ older, newer }, "/w").?;
    try testing.expectEqual(sessions.Status.waiting, resolved.status);
    try testing.expectEqual(@as(i64, 2000), resolved.last_activity_at);
}

test "a worktree whose only record is a finished session reports nothing, not a stale row" {
    const ended: Record = .{ .version = version, .event = "ended", .cwd = "/w", .at = 1000 };
    try testing.expect(statusFor(&.{ended}, "/w") == null);
}

test "plan mode survives the events that report no mode at all" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ = try testEnviron(arena, base);

    write(arena, io, &environ, .{
        .event = "active",
        .cwd = base,
        .claude_session = "uuid-1",
        .permission_mode = "plan",
        .at = 1000,
    });

    write(arena, io, &environ, .{
        .event = "waiting",
        .cwd = base,
        .claude_session = "uuid-1",
        .at = 1010,
    });

    const records = load(arena, io, &environ);
    try testing.expectEqual(@as(usize, 1), records.len);
    if (!watch_hooks.isPlan(records[0].permission_mode)) {
        std.debug.print(
            "the mode came back {s} after a Notification that carried none: every permission " ++
                "prompt would drop the session out of plan mode on the dashboard, so `plan` " ++
                "only ever survives until the agent next asks for something.\n",
            .{records[0].permission_mode},
        );
        return error.TestExpectedEqual;
    }
    try testing.expectEqualStrings("waiting", records[0].event);
    try testing.expectEqual(@as(i64, 1010), records[0].at);
}

test "a mode that is reported replaces the one remembered, rather than sticking" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ = try testEnviron(arena, base);

    write(arena, io, &environ, .{
        .event = "active",
        .cwd = base,
        .claude_session = "uuid-1",
        .permission_mode = "plan",
        .at = 1000,
    });
    write(arena, io, &environ, .{
        .event = "active",
        .cwd = base,
        .claude_session = "uuid-1",
        .permission_mode = "default",
        .at = 1010,
    });

    const records = load(arena, io, &environ);
    try testing.expectEqual(@as(usize, 1), records.len);
    try testing.expect(!watch_hooks.isPlan(records[0].permission_mode));
}

test "a state file survives a round trip, and ending the session removes it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ = try testEnviron(arena, base);

    try testing.expectEqual(@as(usize, 0), load(arena, io, &environ).len);

    write(arena, io, &environ, .{
        .event = "waiting",
        .cwd = base,
        .claude_session = "uuid-1",
        .lcc_session = "s-00000003",
        .at = 1000,
    });

    const records = load(arena, io, &environ);
    try testing.expectEqual(@as(usize, 1), records.len);
    try testing.expectEqualStrings("uuid-1", records[0].claude_session);
    try testing.expectEqualStrings("s-00000003", records[0].lcc_session);
    try testing.expectEqualStrings("waiting", records[0].event);
    try testing.expectEqual(version, records[0].version);

    clear(arena, io, &environ, "uuid-1");
    try testing.expectEqual(@as(usize, 0), load(arena, io, &environ).len);
}

test "a record with no session to name it is never written" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ = try testEnviron(arena, base);

    write(arena, io, &environ, .{ .event = "waiting", .cwd = base, .claude_session = "", .at = 1000 });
    write(arena, io, &environ, .{ .event = "waiting", .cwd = "", .claude_session = "uuid-1", .at = 1000 });

    try testing.expectEqual(@as(usize, 0), load(arena, io, &environ).len);
}

test "a record from a newer lcc is ignored rather than half-read" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ = try testEnviron(arena, base);

    const future = try watch_paths.stateFor(arena, &environ, "uuid-future");
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = future,
        .data = try std.fmt.allocPrint(
            arena,
            "{{\"version\":99,\"event\":\"waiting\",\"cwd\":\"{s}\",\"at\":1000}}",
            .{base},
        ),
    });

    const broken = try watch_paths.stateFor(arena, &environ, "uuid-broken");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = broken, .data = "{not json" });

    try testing.expectEqual(@as(usize, 0), load(arena, io, &environ).len);
}

test "a record whose worktree is gone is dropped, not shown against a directory that no longer exists" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ = try testEnviron(arena, base);

    write(arena, io, &environ, .{
        .event = "waiting",
        .cwd = try std.fs.path.join(arena, &.{ base, "removed" }),
        .claude_session = "uuid-gone",
        .at = 1000,
    });
    write(arena, io, &environ, .{
        .event = "waiting",
        .cwd = base,
        .claude_session = "uuid-here",
        .at = 1000,
    });

    const records = load(arena, io, &environ);
    try testing.expectEqual(@as(usize, 1), records.len);
    try testing.expectEqualStrings("uuid-here", records[0].claude_session);
}

test "nothing in the watch directory but a state file is read as one" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ = try testEnviron(arena, base);

    const cwd = Io.Dir.cwd();
    for ([_][]const u8{ "sessions.json", "hooks-s-00000001.json", "repos.json", "config.json" }) |name| {
        try cwd.writeFile(io, .{
            .sub_path = try std.fs.path.join(arena, &.{ base, name }),
            .data = "{\"version\":1,\"event\":\"waiting\",\"cwd\":\"/\",\"at\":1}",
        });
    }

    try testing.expectEqual(@as(usize, 0), load(arena, io, &environ).len);
}
