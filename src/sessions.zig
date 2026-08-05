//! `sessions.json` — what other commands may know about live sessions without
//! a daemon to ask.
//!
//! A **projection**, never the authority. The daemon holds the pty fds and the
//! child pids; a file can only describe them, and anything read out of it is
//! stale the moment it is read. Making it authoritative would not change that,
//! it would only hide it — and it would mean two writers, which this repo has
//! no locking for.
//!
//! It has exactly two read-only jobs: letting `lcc list` show a session column
//! without a socket round trip, and leaving a breadcrumb naming orphaned pids
//! when the daemon dies.

const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const disk = @import("disk.zig");
const watch_paths = @import("watch_paths.zig");

/// Bumped when the stored shape changes. An older file is dropped rather than
/// migrated: this is a projection, and the daemon rewrites it within a second.
const version: u32 = 1;
const state_limit = 4 * 1024 * 1024;

pub const Status = enum {
    starting,
    active,
    waiting,
    idle,
    exited,
    /// The worktree is gone from disk but the agent is still running in it.
    orphan,
    /// No daemon is alive, so nothing on disk can be believed.
    unknown,

    pub fn label(self: Status) []const u8 {
        return @tagName(self);
    }
};

pub const Session = struct {
    id: []const u8 = "",
    worktree: []const u8 = "",
    branch: []const u8 = "",
    /// Null for a worktree whose branch names no issue.
    issue: ?[]const u8 = null,
    repo_root: []const u8 = "",
    /// The `claude` child, not the daemon.
    pid: i32 = 0,
    /// Stored as TEXT, never the enum's tag number. The numbering is an
    /// implementation detail, and reordering the tags would otherwise silently
    /// repaint every row on disk — the reason `remote_cache.zig` gives for the
    /// same decision.
    status: []const u8 = "unknown",
    status_at: i64 = 0,
    started_at: i64 = 0,
    last_activity_at: i64 = 0,
    exit_code: ?i32 = null,

    /// Text back to the enum. An unrecognised value — a newer daemon's status
    /// this build has never heard of — reads as `unknown` rather than failing
    /// the whole file.
    pub fn parsedStatus(self: Session) Status {
        return std.meta.stringToEnum(Status, self.status) orelse .unknown;
    }
};

/// Without this block a dead daemon's file reports its sessions `active`
/// forever and every reader believes it.
pub const Daemon = struct {
    pid: i32 = 0,
    started_at: i64 = 0,
    socket: []const u8 = "",
    protocol: u32 = 0,
    /// When the projection was written. Everything beside it is at least this
    /// stale, and a debounced writer can promise nothing better.
    wrote_at: i64 = 0,
};

pub const State = struct {
    daemon: ?Daemon = null,
    sessions: []const Session = &.{},
};

/// Every field defaulted, so a file written by an older build still parses
/// rather than costing a command.
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

/// Infallible. A missing or unreadable file is an empty registry, because
/// losing this costs a safety check rather than a command — `repos.load`'s
/// contract, for the same reason.
pub fn load(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) State {
    const file_path = path(gpa, environ) catch return .{};
    const raw = Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(state_limit)) catch return .{};
    const wire = std.json.parseFromSliceLeaky(Wire, gpa, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return .{};
    // Drop, never migrate.
    if (wire.version != version) return .{};
    return .{ .daemon = wire.daemon, .sessions = wire.sessions };
}

/// Written by the daemon and nobody else.
///
/// Temp-then-rename, which no other state file in this repo bothers with. The
/// difference is who reads it: `lcc remove` consults this to decide whether a
/// worktree has a live agent in it, and a torn read there means deleting a
/// worktree someone is working in. `repos.json` losing a write costs a
/// remembered answer; this one costs work.
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

    // Same directory, so the rename cannot cross a filesystem and degrade into
    // a copy that can itself be interrupted.
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{file_path});
    defer gpa.free(tmp_path);
    try cwd.writeFile(io, .{ .sub_path = tmp_path, .data = body });
    try Io.Dir.renameAbsolute(tmp_path, file_path, io);
}

/// Whether the daemon that wrote this is still there.
///
/// `PermissionDenied` counts as alive: the pid was recycled by another user's
/// process, which is not our daemon but is also not an invitation to treat the
/// file as a corpse.
pub fn alive(state: State) bool {
    const d = state.daemon orelse return false;
    if (d.pid <= 0) return false;
    // Signal 0 tests for existence without delivering anything. `SIG` is a
    // non-exhaustive enum, so zero is representable.
    std.posix.kill(d.pid, @enumFromInt(0)) catch |err| return switch (err) {
        error.PermissionDenied => true,
        else => false,
    };
    return true;
}

pub const Resolved = struct {
    session: Session,
    status: Status,
    /// The daemon is alive but has not written recently.
    stale: bool,
};

/// How long a projection stays believable. Longer than the daemon's write
/// debounce, so ordinary quiet does not read as staleness.
pub const stale_after_seconds: i64 = 10;

/// What a reader may believe, given who wrote the file and when.
///
/// Readers never re-derive a status from timestamps: the daemon computed it
/// from events readers do not see, and a reader that guessed would contradict
/// the dashboard for the same session.
pub fn resolved(
    gpa: std.mem.Allocator,
    io: Io,
    state: State,
    now: i64,
) ![]const Resolved {
    const out = try gpa.alloc(Resolved, state.sessions.len);
    const daemon_alive = alive(state);
    const wrote_at = if (state.daemon) |d| d.wrote_at else 0;
    // Clamped: a clock that moved backwards must read as expired rather than
    // infinitely fresh, the way `remote_cache.fresh` treats the same case.
    const age = @max(0, now - wrote_at);

    for (state.sessions, 0..) |session, i| {
        var status = session.parsedStatus();
        if (!daemon_alive) {
            // Nothing in the file can be believed, whatever it says.
            status = .unknown;
        } else if (status != .exited and !worktreeExists(io, session.worktree)) {
            // Not dropped. An agent still running in a directory that no longer
            // exists is the row most worth seeing.
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

/// The session, if any, whose worktree is `target` or contains it.
///
/// What `lcc remove` has to answer before deleting a directory, with no daemon
/// required. A wrong answer in either direction is expensive: a false negative
/// deletes a worktree with a live agent in it, a false positive refuses to
/// clean up an idle one.
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

    // `lcc remove` and `lcc list` must still work when this file is truncated
    // or hand-edited. Losing it costs a column, never a command.
    const file_path = try path(arena, &environ);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "{\"sessions\": [" });
    try testing.expectEqual(@as(usize, 0), load(arena, io, &environ).sessions.len);

    // And a version this build does not know is dropped, not guessed at.
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
    // Nothing has ever run, so there is nothing to be alive.
    try testing.expect(!alive(empty));
}

test "a dead daemon makes every status unknown, whatever the file claims" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // pid 1 is launchd: alive, and not ours — `kill` answers PermissionDenied,
    // which still means alive.
    const live: State = .{
        .daemon = .{ .pid = 1, .wrote_at = 1000 },
        .sessions = &.{.{ .id = "s-a", .worktree = "/", .status = "active", .last_activity_at = 990 }},
    };
    try testing.expect(alive(live));
    const live_rows = try resolved(arena, io, live, 1005);
    try testing.expectEqual(Status.active, live_rows[0].status);
    try testing.expect(!live_rows[0].stale);

    // A pid that cannot exist. Without the daemon block this file would report
    // "active" forever and every reader would believe it.
    const dead: State = .{
        .daemon = .{ .pid = 0x7fff_fffe, .wrote_at = 1000 },
        .sessions = &.{.{ .id = "s-a", .worktree = "/", .status = "active" }},
    };
    try testing.expect(!alive(dead));
    const dead_rows = try resolved(arena, io, dead, 1005);
    try testing.expectEqual(Status.unknown, dead_rows[0].status);
    // The row survives: a session that silently vanished would read as a bug.
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

    // Inside the window: believable.
    try testing.expect(!(try resolved(arena, io, state, 1000 + stale_after_seconds))[0].stale);
    // Past it: the only honest thing a debounced writer can say.
    try testing.expect((try resolved(arena, io, state, 1000 + stale_after_seconds + 1))[0].stale);
    // A clock that jumped backwards must not read as infinitely fresh.
    try testing.expect(!(try resolved(arena, io, state, 900))[0].stale);
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
            // An exited session's worktree being gone is ordinary cleanup, not
            // an orphan — there is no agent left to be stranded.
            .{ .id = "s-done", .worktree = try std.fs.path.join(arena, &.{ base, "removed" }), .status = "exited" },
        },
    };

    const rows = try resolved(arena, io, state, 1001);
    try testing.expectEqual(Status.active, rows[0].status);
    try testing.expectEqual(Status.orphan, rows[1].status);
    try testing.expectEqual(Status.exited, rows[2].status);
}

test "owning matches the worktree and what is inside it, never a sibling prefix" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const state: State = .{ .sessions = &.{
        .{ .id = "s-256", .worktree = "/r/.lcc/worktrees/pe-256" },
    } };

    // The directory itself, and anything under it.
    try testing.expectEqualStrings("s-256", owning(arena, state, "/r/.lcc/worktrees/pe-256").?.id);
    try testing.expectEqualStrings("s-256", owning(arena, state, "/r/.lcc/worktrees/pe-256/src").?.id);

    // A sibling that merely shares the prefix is a different worktree. Getting
    // this wrong means `lcc remove` refuses to clean up pe-2567, or — with the
    // comparison the other way round — deletes pe-256 while an agent works in it.
    try testing.expect(owning(arena, state, "/r/.lcc/worktrees/pe-2567") == null);
    try testing.expect(owning(arena, state, "/r/.lcc/worktrees") == null);
    try testing.expect(owning(arena, state, "/elsewhere") == null);
}

test "an unrecognised status from a newer daemon reads as unknown, not a parse failure" {
    // Forward compatibility in the direction that actually happens: the daemon
    // is rebuilt first and starts writing a status this reader has never heard
    // of. One odd row beats an empty registry.
    const session: Session = .{ .id = "s-a", .status = "thinking_very_hard" };
    try testing.expectEqual(Status.unknown, session.parsedStatus());
}
