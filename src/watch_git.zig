const std = @import("std");
const git = @import("git.zig");

pub const capacity = 32;
pub const path_limit = 256;
pub const sync_interval_seconds: i64 = 5;
pub const dirty_floor_seconds: i64 = 3;

pub const Facts = struct {
    known: bool = false,
    dirty: ?u32 = null,
    ahead: u32 = 0,
    behind: u32 = 0,
    gone: bool = false,
    checked_at: i64 = 0,
};

pub fn dirtyInterval(row_count: usize) i64 {
    const rows: i64 = @intCast(@min(row_count, capacity));
    return @max(dirty_floor_seconds, rows);
}

pub const Cache = struct {
    paths: [capacity][path_limit]u8 = @splat(@splat(0)),
    lens: [capacity]usize = @splat(0),
    facts: [capacity]Facts = @splat(.{}),
    used: usize = 0,
    synced_at: i64 = 0,

    pub fn get(self: *const Cache, path: []const u8) Facts {
        const at = self.find(path) orelse return .{};
        return self.facts[at];
    }

    pub fn note(self: *Cache, path: []const u8, dirty: ?u32, now: i64) void {
        const at = self.claim(path) orelse return;
        self.facts[at].dirty = dirty;
        self.facts[at].known = true;
        self.facts[at].checked_at = now;
    }

    pub fn setSync(self: *Cache, path: []const u8, status: git.BranchStatus) void {
        const at = self.claim(path) orelse return;
        self.facts[at].ahead = status.ahead;
        self.facts[at].behind = status.behind;
        self.facts[at].gone = status.gone;
    }

    pub fn dueForSync(self: *const Cache, now: i64) bool {
        return now -| self.synced_at >= sync_interval_seconds;
    }

    pub fn synced(self: *Cache, now: i64) void {
        self.synced_at = now;
    }

    pub fn stalest(self: *const Cache, paths: []const []const u8, now: i64, interval: i64) ?[]const u8 {
        var pick: ?[]const u8 = null;
        var oldest: i64 = 0;
        for (paths) |path| {
            const at = self.find(path) orelse return path;
            const facts = self.facts[at];
            if (!facts.known) return path;
            const age = now -| facts.checked_at;
            if (age < interval) continue;
            if (pick != null and age <= oldest) continue;
            pick = path;
            oldest = age;
        }
        return pick;
    }

    pub fn invalidate(self: *Cache) void {
        for (0..self.used) |at| self.facts[at].checked_at = 0;
        self.synced_at = 0;
    }

    fn find(self: *const Cache, path: []const u8) ?usize {
        for (0..self.used) |at| {
            if (std.mem.eql(u8, self.paths[at][0..self.lens[at]], path)) return at;
        }
        return null;
    }

    fn claim(self: *Cache, path: []const u8) ?usize {
        if (path.len == 0 or path.len > path_limit) return null;
        if (self.find(path)) |at| return at;

        const at = if (self.used < capacity) grow: {
            const slot = self.used;
            self.used += 1;
            break :grow slot;
        } else self.evict();

        @memcpy(self.paths[at][0..path.len], path);
        self.lens[at] = path.len;
        self.facts[at] = .{};
        return at;
    }

    fn evict(self: *const Cache) usize {
        var at: usize = 0;
        for (1..self.used) |other| {
            if (self.facts[other].checked_at < self.facts[at].checked_at) at = other;
        }
        return at;
    }
};

pub fn cell(buf: []u8, facts: Facts) []const u8 {
    if (!facts.known) return "—";

    var writer: std.Io.Writer = .fixed(buf);
    if (facts.dirty) |count| {
        if (count == 0) {
            writer.writeAll("clean") catch return "clean";
        } else {
            writer.print("{d} dirty", .{count}) catch return "dirty";
        }
    } else {
        writer.writeAll("missing") catch return "missing";
    }

    if (facts.ahead > 0) writer.print(" ↑{d}", .{facts.ahead}) catch {};
    if (facts.behind > 0) writer.print(" ↓{d}", .{facts.behind}) catch {};
    if (facts.gone) writer.writeAll(" gone") catch {};

    return writer.buffered();
}

const testing = std.testing;

test "a worktree nothing has measured yet says so, rather than claiming to be clean" {
    var cache: Cache = .{};
    var buf: [64]u8 = undefined;

    try testing.expectEqualStrings("—", cell(&buf, cache.get("/w/pe-256")));

    cache.note("/w/pe-256", 0, 1000);
    try testing.expectEqualStrings("clean", cell(&buf, cache.get("/w/pe-256")));
}

test "a worktree whose checkout was emptied reads missing, not clean" {
    var cache: Cache = .{};
    var buf: [64]u8 = undefined;

    cache.note("/w/gone", null, 1000);
    if (std.mem.eql(u8, cell(&buf, cache.get("/w/gone")), "clean")) {
        std.debug.print(
            "a worktree that lost its .git link reported `clean`: git discovers a repo by " ++
                "walking up from cwd, so `git status` in there answers for the main checkout " ++
                "and the row claims there is nothing to lose.\n",
            .{},
        );
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("missing", cell(&buf, cache.get("/w/gone")));
}

test "the cell carries the drift only when there is drift to carry" {
    var cache: Cache = .{};
    var buf: [64]u8 = undefined;

    cache.note("/w/a", 3, 1000);
    cache.setSync("/w/a", .{ .branch = "feature/a", .upstream = "origin/feature/a", .ahead = 2, .behind = 0, .gone = false, .committed_at = 0 });
    try testing.expectEqualStrings("3 dirty ↑2", cell(&buf, cache.get("/w/a")));

    cache.note("/w/b", 0, 1000);
    cache.setSync("/w/b", .{ .branch = "feature/b", .upstream = null, .ahead = 0, .behind = 14, .gone = false, .committed_at = 0 });
    try testing.expectEqualStrings("clean ↓14", cell(&buf, cache.get("/w/b")));

    cache.note("/w/c", 0, 1000);
    cache.setSync("/w/c", .{ .branch = "feature/c", .upstream = "origin/feature/c", .ahead = 0, .behind = 0, .gone = true, .committed_at = 0 });
    try testing.expectEqualStrings("clean gone", cell(&buf, cache.get("/w/c")));
}

test "a frame refreshes the worktree that has waited longest, and only one of them" {
    var cache: Cache = .{};
    const paths = [_][]const u8{ "/w/a", "/w/b", "/w/c" };

    try testing.expectEqualStrings("/w/a", cache.stalest(&paths, 1000, 3).?);
    cache.note("/w/a", 0, 1000);
    try testing.expectEqualStrings("/w/b", cache.stalest(&paths, 1000, 3).?);
    cache.note("/w/b", 0, 1001);
    try testing.expectEqualStrings("/w/c", cache.stalest(&paths, 1000, 3).?);
    cache.note("/w/c", 0, 1002);

    if (cache.stalest(&paths, 1002, 3) != null) {
        std.debug.print(
            "a worktree measured a second ago was picked for another `git status`: the frame " ++
                "redraws once a second, so every row would be re-measured every second and the " ++
                "dashboard would spawn one git per worktree per tick.\n",
            .{},
        );
        return error.TestUnexpectedResult;
    }

    try testing.expectEqualStrings("/w/a", cache.stalest(&paths, 1010, 3).?);
}

test "asking for a refresh does not wait out the rotation" {
    var cache: Cache = .{};
    const paths = [_][]const u8{"/w/a"};

    cache.note("/w/a", 0, 1000);
    cache.synced(1000);
    try testing.expect(cache.stalest(&paths, 1001, 3) == null);
    try testing.expect(!cache.dueForSync(1001));

    cache.invalidate();
    try testing.expectEqualStrings("/w/a", cache.stalest(&paths, 1001, 3).?);
    try testing.expect(cache.dueForSync(1001));
}

test "an invalidated entry keeps its last answer until a new one arrives" {
    var cache: Cache = .{};
    var buf: [64]u8 = undefined;

    cache.note("/w/a", 7, 1000);
    cache.invalidate();
    if (!std.mem.eql(u8, cell(&buf, cache.get("/w/a")), "7 dirty")) {
        std.debug.print(
            "pressing r blanked the column it was asked to refresh: the cell reads `—` for a " ++
                "whole frame before the answer lands, which reads as the worktree having gone " ++
                "away rather than as a refresh in flight.\n",
            .{},
        );
        return error.TestExpectedEqual;
    }
}

test "the rotation covers every row within its own length" {
    var cache: Cache = .{};
    try testing.expectEqual(@as(i64, dirty_floor_seconds), dirtyInterval(1));
    try testing.expectEqual(@as(i64, dirty_floor_seconds), dirtyInterval(3));
    try testing.expectEqual(@as(i64, 9), dirtyInterval(9));

    var paths: [12][]const u8 = undefined;
    var storage: [12][8]u8 = undefined;
    for (0..12) |i| {
        paths[i] = std.fmt.bufPrint(&storage[i], "/w/{d}", .{i}) catch unreachable;
    }

    const interval = dirtyInterval(paths.len);
    var now: i64 = 1000;
    for (0..paths.len) |_| {
        const due = cache.stalest(&paths, now, interval).?;
        cache.note(due, 0, now);
        now += 1;
    }
    for (paths) |path| try testing.expect(cache.get(path).known);
}

test "a worktree past the cache's capacity takes the slot of the one measured longest ago" {
    var cache: Cache = .{};
    var storage: [capacity + 1][16]u8 = undefined;

    for (0..capacity) |i| {
        const path = try std.fmt.bufPrint(&storage[i], "/w/{d}", .{i});
        cache.note(path, @intCast(i), 1000 + @as(i64, @intCast(i)));
    }
    try testing.expectEqual(@as(usize, capacity), cache.used);

    const extra = try std.fmt.bufPrint(&storage[capacity], "/w/{d}", .{capacity});
    cache.note(extra, 5, 2000);

    try testing.expectEqual(@as(usize, capacity), cache.used);
    try testing.expect(cache.get(extra).known);
    try testing.expect(!cache.get("/w/0").known);
    try testing.expect(cache.get("/w/1").known);
}

test "a path too long for a slot is not cached, and does not corrupt the one beside it" {
    var cache: Cache = .{};
    const long = "/" ++ ("w" ** path_limit);

    cache.note("/w/a", 2, 1000);
    cache.note(long, 9, 1000);

    try testing.expect(!cache.get(long).known);
    try testing.expectEqual(@as(?u32, 2), cache.get("/w/a").dirty);
    try testing.expectEqual(@as(usize, 1), cache.used);
}
