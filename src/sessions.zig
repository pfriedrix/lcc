const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const disk = @import("disk.zig");
const watch_paths = @import("watch_paths.zig");

const version: u32 = 1;
const state_limit = 4 * 1024 * 1024;

pub const Status = enum {
    starting,
    active,
    waiting,
    idle,
    plan,
    exited,
    orphan,
    unknown,

    pub fn label(self: Status) []const u8 {
        return @tagName(self);
    }
};

pub const Session = struct {
    id: []const u8 = "",
    worktree: []const u8 = "",
    branch: []const u8 = "",
    issue: ?[]const u8 = null,
    repo_root: []const u8 = "",
    pid: i32 = 0,
    status: []const u8 = "unknown",
    status_at: i64 = 0,
    started_at: i64 = 0,
    last_activity_at: i64 = 0,
    exit_code: ?i32 = null,

    pub fn parsedStatus(self: Session) Status {
        return std.meta.stringToEnum(Status, self.status) orelse .unknown;
    }
};

pub const Daemon = struct {
    pid: i32 = 0,
    started_at: i64 = 0,
    socket: []const u8 = "",
    protocol: u32 = 0,
    wrote_at: i64 = 0,
};

pub const State = struct {
    daemon: ?Daemon = null,
    sessions: []const Session = &.{},
};

const Wire = struct {
    version: u32 = 0,
    daemon: ?Daemon = null,
    sessions: []const Session = &.{},
};

pub fn path(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("LCC_SESSIONS")) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) return gpa.dupe(u8, override);
    }
    const dir = try watch_paths.dir(gpa, environ);
    return std.fs.path.join(gpa, &.{ dir, "sessions.json" });
}

pub fn load(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) State {
    const file_path = path(gpa, environ) catch return .{};
    const raw = Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(state_limit)) catch return .{};
    const wire = std.json.parseFromSliceLeaky(Wire, gpa, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return .{};
    if (wire.version != version) return .{};
    return .{ .daemon = wire.daemon, .sessions = wire.sessions };
}

pub fn save(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    state: State,
) !void {
    const file_path = try path(gpa, environ);
    const body = try std.json.Stringify.valueAlloc(gpa, Wire{
        .version = version,
        .daemon = state.daemon,
        .sessions = state.sessions,
    }, .{ .whitespace = .indent_2 });
    defer gpa.free(body);

    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(file_path)) |parent| try cwd.createDirPath(io, parent);

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{file_path});
    defer gpa.free(tmp_path);
    try cwd.writeFile(io, .{ .sub_path = tmp_path, .data = body });
    try Io.Dir.renameAbsolute(tmp_path, file_path, io);
}

pub fn alive(state: State) bool {
    const d = state.daemon orelse return false;
    if (d.pid <= 0) return false;
    std.posix.kill(d.pid, @enumFromInt(0)) catch |err| return switch (err) {
        error.PermissionDenied => true,
        else => false,
    };
    return true;
}

pub const Resolved = struct {
    session: Session,
    status: Status,
    stale: bool,
};

pub const stale_after_seconds: i64 = 10;

pub fn daemonOutdated(state: State, binary_modified: ?i64) bool {
    const built = binary_modified orelse return false;
    const daemon = state.daemon orelse return false;
    if (daemon.started_at == 0) return false;
    if (!alive(state)) return false;
    return built > daemon.started_at;
}

pub fn resolved(
    gpa: std.mem.Allocator,
    io: Io,
    state: State,
    now: i64,
) ![]const Resolved {
    const out = try gpa.alloc(Resolved, state.sessions.len);
    const daemon_alive = alive(state);
    const wrote_at = if (state.daemon) |d| d.wrote_at else 0;
    const age = @max(0, now - wrote_at);

    for (state.sessions, 0..) |session, i| {
        var status = session.parsedStatus();
        if (!daemon_alive) {
            status = .unknown;
        } else if (status != .exited and !worktreeExists(io, session.worktree)) {
            status = .orphan;
        }
        out[i] = .{
            .session = session,
            .status = status,
            .stale = daemon_alive and age > stale_after_seconds,
        };
    }
    return out;
}

fn worktreeExists(io: Io, worktree: []const u8) bool {
    if (worktree.len == 0) return false;
    const info = Io.Dir.cwd().statFile(io, worktree, .{}) catch return false;
    return info.kind == .directory;
}

pub fn owning(gpa: std.mem.Allocator, state: State, target: []const u8) ?Session {
    for (state.sessions) |session| {
        if (std.mem.eql(u8, session.worktree, target)) return session;
        if (disk.isInside(gpa, session.worktree, target)) return session;
    }
    return null;
}

const testing = std.testing;

fn testEnviron(arena: std.mem.Allocator, base: []const u8) !std.process.Environ.Map {
    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_SESSIONS", try std.fs.path.join(arena, &.{ base, "sessions.json" }));
    return environ;
}

test "state survives a round trip through the file" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ = try testEnviron(arena, base);

    try save(arena, io, &environ, .{
        .daemon = .{ .pid = 4123, .started_at = 100, .socket = "/s.sock", .protocol = 1, .wrote_at = 200 },
        .sessions = &.{.{
            .id = "s-1a2b3c4d",
            .worktree = "/r/.lcc/worktrees/pe-256",
            .branch = "feature/pe-256-fix",
            .issue = "PE-256",
            .repo_root = "/r",
            .pid = 4188,
            .status = "waiting",
            .status_at = 190,
            .started_at = 120,
            .last_activity_at = 190,
        }},
    });

    const back = load(arena, io, &environ);
    try testing.expectEqual(@as(usize, 1), back.sessions.len);
    try testing.expectEqualStrings("s-1a2b3c4d", back.sessions[0].id);
    try testing.expectEqualStrings("PE-256", back.sessions[0].issue.?);
    try testing.expectEqual(Status.waiting, back.sessions[0].parsedStatus());
    try testing.expectEqual(@as(i32, 4123), back.daemon.?.pid);
}

test "garbage on disk is an empty registry, not a failed command" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ = try testEnviron(arena, base);

    const file_path = try path(arena, &environ);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "{\"sessions\": [" });
    try testing.expectEqual(@as(usize, 0), load(arena, io, &environ).sessions.len);

    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = file_path,
        .data = "{\"version\":99,\"sessions\":[{\"id\":\"s-x\"}]}",
    });
    const dropped = load(arena, io, &environ);
    try testing.expectEqual(@as(usize, 0), dropped.sessions.len);
    try testing.expect(dropped.daemon == null);
}

test "a missing file is empty rather than an error" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ = try testEnviron(arena, base);

    const empty = load(arena, io, &environ);
    try testing.expectEqual(@as(usize, 0), empty.sessions.len);
    try testing.expect(empty.daemon == null);
    try testing.expect(!alive(empty));
}

test "a dead daemon makes every status unknown, whatever the file claims" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const live: State = .{
        .daemon = .{ .pid = 1, .wrote_at = 1000 },
        .sessions = &.{.{ .id = "s-a", .worktree = "/", .status = "active", .last_activity_at = 990 }},
    };
    try testing.expect(alive(live));
    const live_rows = try resolved(arena, io, live, 1005);
    try testing.expectEqual(Status.active, live_rows[0].status);
    try testing.expect(!live_rows[0].stale);

    const dead: State = .{
        .daemon = .{ .pid = 0x7fff_fffe, .wrote_at = 1000 },
        .sessions = &.{.{ .id = "s-a", .worktree = "/", .status = "active" }},
    };
    try testing.expect(!alive(dead));
    const dead_rows = try resolved(arena, io, dead, 1005);
    try testing.expectEqual(Status.unknown, dead_rows[0].status);
    try testing.expectEqual(@as(usize, 1), dead_rows.len);
}

test "staleness is reported past the window, and a backwards clock is not freshness" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const state: State = .{
        .daemon = .{ .pid = 1, .wrote_at = 1000 },
        .sessions = &.{.{ .id = "s-a", .worktree = "/", .status = "idle" }},
    };

    try testing.expect(!(try resolved(arena, io, state, 1000 + stale_after_seconds))[0].stale);
    try testing.expect((try resolved(arena, io, state, 1000 + stale_after_seconds + 1))[0].stale);
    try testing.expect(!(try resolved(arena, io, state, 900))[0].stale);
}

test "a daemon started before this binary was built is reported as the older build" {
    const running: State = .{ .daemon = .{ .pid = @intCast(std.c.getpid()), .started_at = 1_000 } };

    try testing.expect(daemonOutdated(running, 1_001));
    try testing.expect(!daemonOutdated(running, 999));
    try testing.expect(!daemonOutdated(running, 1_000));
}

test "nothing is out of date when there is no daemon to be out of date" {
    const pid: i32 = @intCast(std.c.getpid());

    try testing.expect(!daemonOutdated(.{}, 5_000));

    try testing.expect(!daemonOutdated(.{ .daemon = .{ .pid = 0, .started_at = 1 } }, 5_000));

    try testing.expect(!daemonOutdated(.{ .daemon = .{ .pid = pid, .started_at = 1 } }, null));

    try testing.expect(!daemonOutdated(.{ .daemon = .{ .pid = pid, .started_at = 0 } }, 5_000));
}

test "a worktree that is gone reads as orphan, and the row stays" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const state: State = .{
        .daemon = .{ .pid = 1, .wrote_at = 1000 },
        .sessions = &.{
            .{ .id = "s-here", .worktree = base, .status = "active" },
            .{ .id = "s-gone", .worktree = try std.fs.path.join(arena, &.{ base, "removed" }), .status = "active" },
            .{ .id = "s-done", .worktree = try std.fs.path.join(arena, &.{ base, "removed" }), .status = "exited" },
            .{ .id = "s-plan", .worktree = try std.fs.path.join(arena, &.{ base, "removed" }), .status = "plan" },
        },
    };

    const rows = try resolved(arena, io, state, 1001);
    try testing.expectEqual(Status.active, rows[0].status);
    try testing.expectEqual(Status.orphan, rows[1].status);
    try testing.expectEqual(Status.exited, rows[2].status);
    try testing.expectEqual(Status.orphan, rows[3].status);
}

test "plan round-trips as text, like every other status" {
    const s: Session = .{ .status = "plan" };
    try testing.expectEqual(Status.plan, s.parsedStatus());
    try testing.expectEqualStrings("plan", Status.plan.label());
}

test "owning matches the worktree and what is inside it, never a sibling prefix" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const state: State = .{ .sessions = &.{
        .{ .id = "s-256", .worktree = "/r/.lcc/worktrees/pe-256" },
    } };

    try testing.expectEqualStrings("s-256", owning(arena, state, "/r/.lcc/worktrees/pe-256").?.id);
    try testing.expectEqualStrings("s-256", owning(arena, state, "/r/.lcc/worktrees/pe-256/src").?.id);

    try testing.expect(owning(arena, state, "/r/.lcc/worktrees/pe-2567") == null);
    try testing.expect(owning(arena, state, "/r/.lcc/worktrees") == null);
    try testing.expect(owning(arena, state, "/elsewhere") == null);
}

test "an unrecognised status from a newer daemon reads as unknown, not a parse failure" {
    const session: Session = .{ .id = "s-a", .status = "thinking_very_hard" };
    try testing.expectEqual(Status.unknown, session.parsedStatus());
}
