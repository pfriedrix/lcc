//! What GitHub and Linear last said, so a dashboard redrawn a minute later does
//! not ask them again.
//!
//! The two network columns are most of what `lcc list` costs, and neither is
//! bound by how much work there is to do — both are one round trip to a host on
//! the other side of the internet, ~0.5s each before either has said anything.
//! Nothing local comes close. Yet a PR does not change state between two runs a
//! minute apart, and neither does a Linear issue: the answer that took half a
//! second is still the right answer.
//!
//! So each answer is kept with the time it arrived, and reused while it is
//! younger than `ttl_seconds`. Staleness is never hidden — `lcc list` says when
//! a column came from here, and `--refresh` skips the cache outright.
//!
//! Only successes are stored. A failed lookup is a different situation on every
//! run — `gh` not installed, a token that needs refreshing, a flaky network —
//! and remembering one would keep showing its note after the cause was fixed.
//!
//! Every failure here is silent, for the same reason `usage_cache` is: losing
//! the file costs one slow run, and nothing a cache does is worth failing the
//! command that wanted a number.

const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const github = @import("github.zig");
const linear = @import("linear.zig");

/// Bumped when the stored shape changes. An older file is dropped rather than
/// migrated: rebuilding costs one slow run.
const version: u32 = 2;

/// A ceiling, so a corrupt or hostile file cannot be read into memory unbounded.
const file_limit = 8 * 1024 * 1024;

/// How long an answer stands in for a fresh one. Long enough that the runs which
/// annoy — the dashboard redrawn while working through a task — are free, short
/// enough that a PR merged in another window shows up without being asked twice.
pub const ttl_seconds: i64 = 300;

/// `github.PullRequest` with the state as text. The enum's numbering is an
/// implementation detail and must not end up on disk, where reordering the tags
/// would silently repaint every cached row.
const StoredPr = struct {
    number: u32 = 0,
    branch: []const u8 = "",
    state: []const u8 = "open",
    draft: bool = false,
};

const StoredIssue = struct {
    identifier: []const u8 = "",
    state_name: []const u8 = "",
    state_type: []const u8 = "",
};

const Stored = struct {
    /// Main worktree path — what makes two repos two entries.
    root: []const u8 = "",
    prs_at: i64 = 0,
    /// The branches the stored pull requests were *asked* about. The lookup is
    /// per-branch, so — exactly as with `issues_asked` — a branch with no row
    /// means GitHub was asked and had nothing, and a worktree the stored answer
    /// never covered has to miss rather than read a dash out of it.
    prs_asked: []const []const u8 = &.{},
    prs: []const StoredPr = &.{},
    issues_at: i64 = 0,
    /// The issue identifiers the stored statuses were *asked* about, which is not
    /// the same as the ones that came back: an identifier with no row means Linear
    /// was asked and had nothing, and that is an answer worth reusing. Without
    /// this a new worktree would read a cached reply that never mentioned it and
    /// show a dash forever.
    issues_asked: []const []const u8 = &.{},
    issues: []const StoredIssue = &.{},
};

const Wire = struct {
    version: u32 = 0,
    repos: []const Stored = &.{},
};

pub const PrHit = struct {
    list: []const github.PullRequest,
    age_seconds: i64,
};

pub const IssueHit = struct {
    list: []const linear.IssueStatus,
    age_seconds: i64,
};

pub const Cache = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Where it lives, or null when lcc could not work that out. A null path is a
    /// working cache that remembers nothing: every lookup misses and nothing is
    /// written.
    path: ?[]const u8 = null,
    repos: std.ArrayList(Stored) = .empty,
    /// Something was learned that the file does not already hold. A run that
    /// changed nothing writes nothing.
    dirty: bool = false,

    /// A cache that remembers nothing, for `--refresh` and for callers that must
    /// not read the disk.
    pub fn none(gpa: std.mem.Allocator, io: Io) Cache {
        return .{ .gpa = gpa, .io = io };
    }

    /// The cache on disk, loaded. Never fails: an unreadable, corrupt, or
    /// older-version file is the same as an empty one.
    pub fn open(
        gpa: std.mem.Allocator,
        io: Io,
        environ: *const std.process.Environ.Map,
    ) Cache {
        var self: Cache = .{ .gpa = gpa, .io = io, .path = path(gpa, environ) catch null };
        const file_path = self.path orelse return self;

        const raw = Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(file_limit)) catch
            return self;
        const wire = std.json.parseFromSliceLeaky(Wire, gpa, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return self;
        if (wire.version != version) return self;

        for (wire.repos) |stored| {
            if (stored.root.len == 0) continue;
            self.repos.append(gpa, stored) catch return self;
        }
        return self;
    }

    fn find(self: *Cache, root: []const u8) ?*Stored {
        for (self.repos.items) |*candidate| {
            if (std.mem.eql(u8, candidate.root, root)) return candidate;
        }
        return null;
    }

    /// The entry for `root`, created empty if this is the first time it is named.
    fn entry(self: *Cache, root: []const u8) ?*Stored {
        if (self.find(root)) |found| return found;
        const key = self.gpa.dupe(u8, root) catch return null;
        self.repos.append(self.gpa, .{ .root = key }) catch return null;
        return &self.repos.items[self.repos.items.len - 1];
    }

    /// The pull requests from an answer still inside the TTL, provided that
    /// answer covered every branch being asked about now.
    pub fn prs(self: *Cache, root: []const u8, asked: []const []const u8, now: i64) ?PrHit {
        if (self.path == null) return null;
        const found = self.find(root) orelse return null;
        if (!fresh(found.prs_at, now)) return null;
        const age = now - found.prs_at;
        for (asked) |want| {
            if (!contains(found.prs_asked, want)) return null;
        }

        const list = self.gpa.alloc(github.PullRequest, found.prs.len) catch return null;
        for (found.prs, 0..) |stored, i| {
            list[i] = .{
                .number = stored.number,
                .branch = stored.branch,
                .state = parseState(stored.state),
                .draft = stored.draft,
            };
        }
        return .{ .list = list, .age_seconds = age };
    }

    pub fn putPrs(
        self: *Cache,
        root: []const u8,
        asked: []const []const u8,
        now: i64,
        list: []const github.PullRequest,
    ) void {
        if (self.path == null) return;
        const target = self.entry(root) orelse return;

        const kept_asked = self.gpa.alloc([]const u8, asked.len) catch return;
        for (asked, 0..) |branch, i| {
            kept_asked[i] = self.gpa.dupe(u8, branch) catch return;
        }

        const stored = self.gpa.alloc(StoredPr, list.len) catch return;
        for (list, 0..) |pr, i| {
            stored[i] = .{
                .number = pr.number,
                .branch = self.gpa.dupe(u8, pr.branch) catch return,
                .state = @tagName(pr.state),
                .draft = pr.draft,
            };
        }
        target.prs_asked = kept_asked;
        target.prs = stored;
        target.prs_at = now;
        self.dirty = true;
    }

    /// The issue statuses from an answer still inside the TTL, provided that
    /// answer covered every identifier being asked about now.
    pub fn issues(
        self: *Cache,
        root: []const u8,
        asked: []const []const u8,
        now: i64,
    ) ?IssueHit {
        if (self.path == null) return null;
        const found = self.find(root) orelse return null;
        if (!fresh(found.issues_at, now)) return null;
        const age = now - found.issues_at;
        for (asked) |want| {
            if (!contains(found.issues_asked, want)) return null;
        }

        const list = self.gpa.alloc(linear.IssueStatus, found.issues.len) catch return null;
        for (found.issues, 0..) |stored, i| {
            list[i] = .{
                .identifier = stored.identifier,
                .state_name = stored.state_name,
                .state_type = stored.state_type,
            };
        }
        return .{ .list = list, .age_seconds = age };
    }

    pub fn putIssues(
        self: *Cache,
        root: []const u8,
        asked: []const []const u8,
        now: i64,
        list: []const linear.IssueStatus,
    ) void {
        if (self.path == null) return;
        const target = self.entry(root) orelse return;

        const kept_asked = self.gpa.alloc([]const u8, asked.len) catch return;
        for (asked, 0..) |identifier, i| {
            kept_asked[i] = self.gpa.dupe(u8, identifier) catch return;
        }

        const stored = self.gpa.alloc(StoredIssue, list.len) catch return;
        for (list, 0..) |status, i| {
            stored[i] = .{
                .identifier = self.gpa.dupe(u8, status.identifier) catch return,
                .state_name = self.gpa.dupe(u8, status.state_name) catch return,
                .state_type = self.gpa.dupe(u8, status.state_type) catch return,
            };
        }
        target.issues_asked = kept_asked;
        target.issues = stored;
        target.issues_at = now;
        self.dirty = true;
    }

    /// Writes back what was learned. A run that learned nothing writes nothing,
    /// which is the common case once the file is warm.
    ///
    /// An entry with nothing left inside the TTL is dropped rather than carried:
    /// it can never produce a hit again, and a file rewritten this often should
    /// not accumulate every repo the user has ever run `lcc list` in. That does
    /// mean switching between two repos more slowly than the TTL never gets a
    /// hit — but those entries had expired, so there was no hit to lose.
    pub fn save(self: *Cache, now: i64) void {
        if (!self.dirty) return;
        const file_path = self.path orelse return;

        var keep: std.ArrayList(Stored) = .empty;
        for (self.repos.items) |stored| {
            if (!fresh(stored.prs_at, now) and !fresh(stored.issues_at, now)) continue;
            // A repo that has been deleted keeps no entry, however fresh.
            Io.Dir.cwd().access(self.io, stored.root, .{}) catch continue;
            keep.append(self.gpa, stored) catch return;
        }

        const body = std.json.Stringify.valueAlloc(self.gpa, Wire{
            .version = version,
            .repos = keep.items,
        }, .{}) catch return;

        const cwd = Io.Dir.cwd();
        if (std.fs.path.dirname(file_path)) |parent| {
            cwd.createDirPath(self.io, parent) catch return;
        }
        cwd.writeFile(self.io, .{ .sub_path = file_path, .data = body }) catch return;
    }
};

/// Whether an answer stamped `at` is one this run may reuse. Zero means nothing
/// was ever stored, and a negative age means the clock moved backwards — which
/// makes every age here meaningless, so the entry reads as expired rather than
/// as infinitely fresh.
fn fresh(at: i64, now: i64) bool {
    if (at == 0) return false;
    const age = now - at;
    return age >= 0 and age <= ttl_seconds;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

/// Mirrors `github.parseState`, which is private to that module. Anything
/// unrecognised reads as open, the state that shows the most detail.
fn parseState(raw: []const u8) github.State {
    if (std.ascii.eqlIgnoreCase(raw, "merged")) return .merged;
    if (std.ascii.eqlIgnoreCase(raw, "closed")) return .closed;
    return .open;
}

/// `LCC_REMOTE_CACHE` overrides it. Otherwise `~/.cache/lcc`, beside the usage
/// cache and for the same reason: this file is regenerable and does not belong
/// in the config directory people commit to dotfile repos.
pub fn path(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]const u8 {
    if (environ.get("LCC_REMOTE_CACHE")) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) return gpa.dupe(u8, override);
    }
    _ = try config.dir(gpa, environ); // Fails the same way when HOME is unset.
    const home = environ.get("HOME").?;
    return std.fs.path.join(gpa, &.{ home, ".cache", "lcc", "remote.json" });
}

fn testCache(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) Cache {
    return .open(arena, std.testing.io, environ);
}

test "a PR list round-trips through the file and expires with the TTL" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_REMOTE_CACHE", try std.fs.path.join(arena, &.{ base, "remote.json" }));

    // `save` keeps an entry only while its repo is still on disk, so the root has
    // to be a directory that exists.
    const root = base;

    const asked = [_][]const u8{ "feature/x", "feature/y" };

    {
        var cache = testCache(arena, &environ);
        try std.testing.expect(cache.prs(root, &asked, 1_000) == null);
        cache.putPrs(root, &asked, 1_000, &.{
            .{ .number = 412, .branch = "feature/x", .state = .merged, .draft = false },
        });
        cache.save(1_000);
    }

    var reopened = testCache(arena, &environ);
    const hit = reopened.prs(root, &asked, 1_060).?;
    try std.testing.expectEqual(@as(usize, 1), hit.list.len);
    try std.testing.expectEqual(@as(u32, 412), hit.list[0].number);
    // The state survives as a state, not as whatever integer the enum happened to use.
    try std.testing.expectEqual(github.State.merged, hit.list[0].state);
    try std.testing.expectEqualStrings("feature/x", hit.list[0].branch);
    try std.testing.expectEqual(@as(i64, 60), hit.age_seconds);

    // feature/y was asked about and had no pull request. That is an answer, so a
    // run that only wants feature/y still hits rather than paying a round trip to
    // be told the same nothing.
    try std.testing.expect(reopened.prs(root, &.{"feature/y"}, 1_060) != null);
    try std.testing.expectEqual(@as(usize, 1), reopened.prs(root, &.{"feature/y"}, 1_060).?.list.len);

    // A worktree cut since the answer was stored was never covered by it.
    try std.testing.expect(reopened.prs(root, &.{ "feature/x", "feature/new" }, 1_060) == null);

    // Past the TTL, and for a repo nobody stored.
    try std.testing.expect(reopened.prs(root, &asked, 1_000 + ttl_seconds + 1) == null);
    try std.testing.expect(reopened.prs("/other", &asked, 1_060) == null);
    // A clock that jumped backwards must not read as an infinitely fresh entry.
    try std.testing.expect(reopened.prs(root, &asked, 900) == null);
}

test "saving drops entries that can never hit again, and keeps the live one" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    const live = try std.fs.path.join(arena, &.{ base, "live" });
    try Io.Dir.cwd().createDirPath(std.testing.io, live);
    const deleted = try std.fs.path.join(arena, &.{ base, "deleted" });

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_REMOTE_CACHE", try std.fs.path.join(arena, &.{ base, "remote.json" }));

    {
        var cache = testCache(arena, &environ);
        cache.putPrs(live, &.{"b"}, 1_000, &.{});
        // Expired: nothing left inside the TTL by the time the file is written.
        cache.putPrs(base, &.{"b"}, 1_000 - ttl_seconds - 1, &.{});
        // Fresh, but its repo is gone from disk.
        cache.putPrs(deleted, &.{"b"}, 1_000, &.{});
        cache.save(1_000);
    }

    const reopened = testCache(arena, &environ);
    try std.testing.expectEqual(@as(usize, 1), reopened.repos.items.len);
    try std.testing.expectEqualStrings(live, reopened.repos.items[0].root);
}

test "issue statuses are reused only for an answer that covered what is being asked" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_REMOTE_CACHE", try std.fs.path.join(arena, &.{ base, "remote.json" }));

    var cache = testCache(arena, &environ);
    // PE-9 was asked about and came back with nothing — a real answer, and one
    // that must not be mistaken for never having been asked.
    cache.putPrs("/repo", &.{"b"}, 500, &.{});
    cache.putIssues("/repo", &.{ "PE-7", "PE-9" }, 500, &.{
        .{ .identifier = "PE-7", .state_name = "In Progress", .state_type = "started" },
    });

    const hit = cache.issues("/repo", &.{"PE-7"}, 500).?;
    try std.testing.expectEqual(@as(usize, 1), hit.list.len);
    try std.testing.expectEqualStrings("In Progress", hit.list[0].state_name);

    // A subset of what was asked still hits — removing a worktree must not cost
    // a round trip.
    try std.testing.expect(cache.issues("/repo", &.{"PE-9"}, 500) != null);
    try std.testing.expect(cache.issues("/repo", &.{ "PE-7", "PE-9" }, 500) != null);

    // A new worktree names an issue the stored answer never covered.
    try std.testing.expect(cache.issues("/repo", &.{ "PE-7", "PE-11" }, 500) == null);

    // The two halves expire independently: PRs are repo-wide, issues are not.
    try std.testing.expect(cache.prs("/repo", &.{"b"}, 500) != null);
    try std.testing.expect(cache.issues("/repo", &.{"PE-7"}, 500 + ttl_seconds + 1) == null);
}

test "a cache with nowhere to live keeps working and remembers nothing" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cache: Cache = .none(arena, std.testing.io);
    cache.putPrs("/repo", &.{"b"}, 100, &.{
        .{ .number = 1, .branch = "b", .state = .open, .draft = false },
    });
    cache.putIssues("/repo", &.{"PE-1"}, 100, &.{});

    try std.testing.expect(cache.prs("/repo", &.{"b"}, 100) == null);
    try std.testing.expect(cache.issues("/repo", &.{"PE-1"}, 100) == null);
    try std.testing.expect(!cache.dirty);
    cache.save(100); // Writes nothing, and must not fail doing it.
}

test "an unreadable or wrong-version file reads as an empty cache" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const file_path = try std.fs.path.join(arena, &.{ base, "remote.json" });

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_REMOTE_CACHE", file_path);

    const cwd = Io.Dir.cwd();
    try cwd.writeFile(std.testing.io, .{ .sub_path = file_path, .data = "not json at all" });
    var corrupt = testCache(arena, &environ);
    try std.testing.expect(corrupt.prs("/repo", &.{}, 0) == null);

    try cwd.writeFile(std.testing.io, .{
        .sub_path = file_path,
        .data = "{\"version\":99,\"repos\":[{\"root\":\"/repo\",\"prs_at\":10,\"prs\":[]}]}",
    });
    var future = testCache(arena, &environ);
    try std.testing.expect(future.prs("/repo", &.{}, 10) == null);
}
