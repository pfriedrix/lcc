//! Which directory each Codex rollout belongs to, remembered so a later run does
//! not have to open every one of them again.
//!
//! Attributing a rollout to a worktree means knowing the cwd its session ran in,
//! and that is recorded inside the file — `~/.codex/sessions` is a tree of dates,
//! so nothing in a path says whose session it holds. Answering it from disk costs
//! one open and one read per rollout, and the pile only grows: Codex never prunes
//! sessions, and an SDK driving it in a loop leaves tens of thousands behind. On a
//! machine like that the reads alone were most of `lcc list`, for an answer that
//! is a handful of distinct directories.
//!
//! So each rollout's identity and cwd are kept here, keyed on the rollout's path
//! and nothing else. That is sound because the answer cannot change: `session_meta`
//! is the first line Codex writes, before any turn, and a rollout is only ever
//! appended to afterwards. Paths are not reused either — a name carries the
//! session's start timestamp and its uuid. A file whose metadata this does not
//! hold is read as before, which is what makes a new session appear.
//!
//! Stored grouped by cwd, because that is where the repetition is: thousands of
//! rollouts share ten directories, and a flat list would spell each one out again
//! per entry.
//!
//! Every failure is silent, like `usage_cache`: losing this costs one slow run,
//! and nothing a cache does is worth failing the command that wanted a number.

const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");

/// Bumped when the stored shape changes. An older file is dropped rather than
/// migrated: rebuilding costs one slow run.
const version: u32 = 1;

/// A ceiling, so a corrupt or hostile file cannot be read into memory unbounded.
/// Generous next to what this holds — a hundred thousand rollouts fit well
/// inside it — because the cost of guessing low is a cache that silently stops
/// working on the machines that need it most.
const file_limit = 64 * 1024 * 1024;

/// What a rollout's `session_meta` line said.
pub const Entry = struct {
    id: []const u8,
    cwd: []const u8,
};

/// One rollout as stored: its path, and the id that goes with the cwd it is
/// filed under.
const Stored = struct {
    path: []const u8 = "",
    id: []const u8 = "",
};

const Group = struct {
    cwd: []const u8 = "",
    sessions: []const Stored = &.{},
};

const Wire = struct {
    version: u32 = 0,
    dirs: []const Group = &.{},
};

pub const Cache = struct {
    /// Everything the cache holds — the loaded file, the keys, the strings, the
    /// maps — so teardown is one free and no entry has to remember whether it was
    /// read from disk or learned this run.
    store: std.heap.ArenaAllocator,
    io: Io,
    /// Where it lives, or null when lcc could not work that out. A null path is a
    /// working cache that remembers nothing: every lookup misses, nothing is
    /// written, and the scan simply pays full price.
    path: ?[]const u8 = null,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Rollouts this run saw on disk. The walk that fills this is exhaustive over
    /// the session roots, so an entry it never mentions is a rollout that is
    /// probably gone — `save` is where that guess gets checked.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// Something was learned that the file does not already hold. A run that
    /// changed nothing writes nothing, which is the common case.
    dirty: bool = false,

    /// A cache that remembers nothing, for callers that must not touch the disk.
    pub fn none(gpa: std.mem.Allocator, io: Io) Cache {
        return .{ .store = .init(gpa), .io = io };
    }

    /// The cache on disk, loaded. Never fails: an unreadable, corrupt, or
    /// older-version file is the same as an empty one.
    pub fn open(
        gpa: std.mem.Allocator,
        io: Io,
        environ: *const std.process.Environ.Map,
    ) Cache {
        var self: Cache = .none(gpa, io);
        // Taken before the struct is returned by value, and not used after: the
        // interface closes over the arena's address, and `save` and `put` re-derive
        // it from the field once it has landed.
        const store = self.store.allocator();
        self.path = path(store, environ) catch null;
        const file_path = self.path orelse return self;

        const raw = Io.Dir.cwd().readFileAlloc(io, file_path, store, .limited(file_limit)) catch
            return self;
        const wire = std.json.parseFromSliceLeaky(Wire, store, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return self;
        if (wire.version != version) return self;

        for (wire.dirs) |group| {
            if (group.cwd.len == 0) continue;
            for (group.sessions) |stored| {
                if (stored.path.len == 0) continue;
                self.entries.put(store, stored.path, .{
                    .id = stored.id,
                    .cwd = group.cwd,
                }) catch return self;
            }
        }
        return self;
    }

    pub fn deinit(self: *Cache) void {
        self.store.deinit();
        self.* = undefined;
    }

    /// What `rollout_path` recorded, if this has been told. Marks the rollout as
    /// still present either way — a caller only asks about paths it just walked.
    pub fn lookup(self: *Cache, rollout_path: []const u8) ?Entry {
        const entry = self.entries.get(rollout_path) orelse return null;
        self.markSeen(rollout_path);
        return entry;
    }

    /// Remembers what a rollout recorded. `id` and `cwd` are copied: they come
    /// from scratch space the caller is about to reuse.
    pub fn put(self: *Cache, rollout_path: []const u8, entry: Entry) void {
        if (self.path == null) return;
        const store = self.store.allocator();
        const key = store.dupe(u8, rollout_path) catch return;
        self.entries.put(store, key, .{
            .id = store.dupe(u8, entry.id) catch return,
            .cwd = store.dupe(u8, entry.cwd) catch return,
        }) catch return;
        self.markSeen(key);
        self.dirty = true;
    }

    /// Says a rollout is still on disk without asking what it holds — for a
    /// caller that walked past it but had no reason to read it.
    pub fn markSeen(self: *Cache, rollout_path: []const u8) void {
        self.seen.put(self.store.allocator(), rollout_path, {}) catch {};
    }

    /// Writes back what was learned. A run that learned nothing writes nothing.
    ///
    /// Rollouts the walk never reached are dropped, but only once the filesystem
    /// agrees they are gone. The walk skips a root it cannot open, so "not seen"
    /// on its own would throw the whole cache away the first time `CODEX_HOME`
    /// pointed somewhere else for a command.
    pub fn save(self: *Cache) void {
        if (!self.dirty) return;
        const file_path = self.path orelse return;

        const store = self.store.allocator();
        var groups: std.ArrayList(Group) = .empty;
        var index: std.StringHashMapUnmanaged(usize) = .empty;
        var buckets: std.ArrayList(std.ArrayList(Stored)) = .empty;

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (self.seen.get(kv.key_ptr.*) == null) {
                Io.Dir.cwd().access(self.io, kv.key_ptr.*, .{}) catch continue;
            }
            const cwd = kv.value_ptr.cwd;
            const at = index.get(cwd) orelse blk: {
                const next = buckets.items.len;
                buckets.append(store, .empty) catch return;
                groups.append(store, .{ .cwd = cwd }) catch return;
                index.put(store, cwd, next) catch return;
                break :blk next;
            };
            buckets.items[at].append(store, .{
                .path = kv.key_ptr.*,
                .id = kv.value_ptr.id,
            }) catch return;
        }
        for (groups.items, buckets.items) |*group, bucket| group.sessions = bucket.items;

        const body = std.json.Stringify.valueAlloc(store, Wire{
            .version = version,
            .dirs = groups.items,
        }, .{}) catch return;

        const cwd = Io.Dir.cwd();
        if (std.fs.path.dirname(file_path)) |parent| {
            cwd.createDirPath(self.io, parent) catch return;
        }
        cwd.writeFile(self.io, .{ .sub_path = file_path, .data = body }) catch return;
    }
};

/// `LCC_CODEX_CACHE` overrides it. Otherwise alongside the transcript cache in
/// `~/.cache/lcc` — same reasoning as `usage_cache.path`: regenerable, rewritten
/// constantly, and no business in a directory that gets committed to a dotfile
/// repo.
pub fn path(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]const u8 {
    if (environ.get("LCC_CODEX_CACHE")) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) return gpa.dupe(u8, override);
    }
    _ = try config.dir(gpa, environ); // Fails the same way when HOME is unset.
    const home = environ.get("HOME").?;
    return std.fs.path.join(gpa, &.{ home, ".cache", "lcc", "codex.json" });
}

test "a cache round-trips rollout metadata through the file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cwd = Io.Dir.cwd();

    const rollout = try std.fs.path.join(arena, &.{ base, "a.jsonl" });
    try cwd.writeFile(io, .{ .sub_path = rollout, .data = "{}\n" });

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_CODEX_CACHE", try std.fs.path.join(arena, &.{ base, "codex.json" }));

    {
        var cache: Cache = .open(arena, io, &environ);
        defer cache.deinit();
        try std.testing.expect(cache.lookup(rollout) == null);
        cache.put(rollout, .{ .id = "session-a", .cwd = "/repo/worktree" });
        cache.save();
    }

    var reopened: Cache = .open(arena, io, &environ);
    defer reopened.deinit();
    const hit = reopened.lookup(rollout).?;
    try std.testing.expectEqualStrings("session-a", hit.id);
    try std.testing.expectEqualStrings("/repo/worktree", hit.cwd);
    try std.testing.expect(reopened.lookup("/nowhere.jsonl") == null);
}

test "rollouts sharing a cwd are stored under it once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const file_path = try std.fs.path.join(arena, &.{ base, "codex.json" });

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_CODEX_CACHE", file_path);

    const cwd = Io.Dir.cwd();
    const shared = "/repo/shared";
    for ([_][]const u8{ "a.jsonl", "b.jsonl", "c.jsonl" }) |name| {
        try cwd.writeFile(io, .{
            .sub_path = try std.fs.path.join(arena, &.{ base, name }),
            .data = "{}\n",
        });
    }

    {
        var cache: Cache = .open(arena, io, &environ);
        defer cache.deinit();
        cache.put(try std.fs.path.join(arena, &.{ base, "a.jsonl" }), .{ .id = "a", .cwd = shared });
        cache.put(try std.fs.path.join(arena, &.{ base, "b.jsonl" }), .{ .id = "b", .cwd = shared });
        cache.put(try std.fs.path.join(arena, &.{ base, "c.jsonl" }), .{ .id = "c", .cwd = "/repo/other" });
        cache.save();
    }

    // The point of grouping: the shared directory is spelled out once, not once
    // per rollout that ran in it.
    const raw = try cwd.readFileAlloc(io, file_path, arena, .limited(1 << 20));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, raw, shared));

    var reopened: Cache = .open(arena, io, &environ);
    defer reopened.deinit();
    try std.testing.expectEqualStrings(shared, reopened.lookup(try std.fs.path.join(arena, &.{ base, "a.jsonl" })).?.cwd);
    try std.testing.expectEqualStrings(shared, reopened.lookup(try std.fs.path.join(arena, &.{ base, "b.jsonl" })).?.cwd);
    try std.testing.expectEqualStrings("/repo/other", reopened.lookup(try std.fs.path.join(arena, &.{ base, "c.jsonl" })).?.cwd);
}

test "saving drops rollouts that are gone and keeps the ones never asked about" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cwd = Io.Dir.cwd();

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_CODEX_CACHE", try std.fs.path.join(arena, &.{ base, "codex.json" }));

    const alive = try std.fs.path.join(arena, &.{ base, "alive.jsonl" });
    const dead = try std.fs.path.join(arena, &.{ base, "dead.jsonl" });
    try cwd.writeFile(io, .{ .sub_path = alive, .data = "{}\n" });

    {
        var cache: Cache = .open(arena, io, &environ);
        defer cache.deinit();
        cache.put(alive, .{ .id = "alive", .cwd = "/repo/a" });
        cache.put(dead, .{ .id = "dead", .cwd = "/repo/a" });
        cache.save();
    }

    // A run that walks neither — `CODEX_HOME` pointed elsewhere, say — must not
    // throw away the rollout that is still there.
    {
        var cache: Cache = .open(arena, io, &environ);
        defer cache.deinit();
        try std.testing.expectEqual(@as(u32, 2), cache.entries.size);
        cache.dirty = true; // Stand in for a run that learned something else.
        cache.save();
    }

    var final: Cache = .open(arena, io, &environ);
    defer final.deinit();
    try std.testing.expect(final.lookup(alive) != null);
    try std.testing.expect(final.lookup(dead) == null);
}

test "a cache with nowhere to live is a cache that remembers nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No HOME and no override: `path` cannot be resolved, and nothing may touch
    // the disk on the way to finding that out.
    var environ: std.process.Environ.Map = .init(arena);
    var cache: Cache = .open(arena, io, &environ);
    defer cache.deinit();
    try std.testing.expect(cache.path == null);

    cache.put("/tmp/rollout.jsonl", .{ .id = "x", .cwd = "/repo" });
    try std.testing.expect(cache.lookup("/tmp/rollout.jsonl") == null);
    try std.testing.expect(!cache.dirty);
    cache.save();
}

test "a file from another version is ignored rather than misread" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const file_path = try std.fs.path.join(arena, &.{ base, "codex.json" });

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_CODEX_CACHE", file_path);

    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = file_path,
        .data =
        \\{"version":999,"dirs":[{"cwd":"/repo","sessions":[{"path":"/a.jsonl","id":"a"}]}]}
        ,
    });
    var stale: Cache = .open(arena, io, &environ);
    defer stale.deinit();
    try std.testing.expectEqual(@as(u32, 0), stale.entries.size);

    // And so is a file that is not the shape at all.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "not json" });
    var broken: Cache = .open(arena, io, &environ);
    defer broken.deinit();
    try std.testing.expectEqual(@as(u32, 0), broken.entries.size);
}
