//! What the transcripts said, distilled, so a second run does not read them again.
//!
//! Counting tokens means parsing every line of every transcript, and the pile
//! only grows: transcripts are append-only and Claude Code never prunes them.
//! On a repo worked in daily that is hundreds of megabytes of JSON re-parsed to
//! redraw a table, and almost none of it changed since the last run — a session
//! in progress appends to one file, and the other two hundred are frozen.
//!
//! So each transcript is reduced to the assistant messages that carried usage,
//! and that is what is kept. It is two orders of magnitude smaller than the
//! transcript, and a file is reused whenever its size and mtime still match —
//! append-only means either one moving is enough to notice.
//!
//! What is *not* stored is anything derived. Cost is recomputed from the token
//! counts on every read, so correcting the price table takes effect at once
//! instead of being frozen into a file nobody would think to delete. And
//! deduplication is not applied here: entries are deduplicated within their own
//! transcript only, which keeps a file's entry a pure function of that file.
//! The cross-file pass belongs to the scanner, which is the only thing that
//! knows which transcripts a given question spans.
//!
//! Every failure is silent. This is a cache — losing it costs one slow run, and
//! nothing it can do is worth failing the command that wanted a number.

const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");

/// Bumped when the stored shape changes. An older file is dropped rather than
/// migrated: rebuilding costs one slow run.
const version: u32 = 1;

/// A ceiling, so a corrupt or hostile file cannot be read into memory unbounded.
const file_limit = 128 * 1024 * 1024;

/// One assistant message that reported usage — the whole of what a transcript
/// contributes. Raw token counts only; see the note on derived values above.
pub const Message = struct {
    /// `message.id`, or empty when the transcript recorded none. An empty id is
    /// not deduplicated against anything: there is nothing to match it on, and
    /// treating them all as one message would lose real spend.
    id: []const u8 = "",
    model: []const u8 = "",
    input: u64 = 0,
    output: u64 = 0,
    cache_write_5m: u64 = 0,
    cache_write_1h: u64 = 0,
    cache_read: u64 = 0,
    /// Verbatim ISO 8601, the form `Totals.last` compares and renders.
    timestamp: []const u8 = "",
};

/// One transcript's distilled contents, plus what identifies the version of it
/// that produced them.
pub const Entry = struct {
    size: u64 = 0,
    /// Modification time in nanoseconds. Together with `size` this is the whole
    /// test: for a file only ever appended to, either one moving means new
    /// content, and a rewrite that lands on the same size within the same
    /// nanosecond is not a thing that happens.
    mtime: i64 = 0,
    /// The transcript was past the scanner's ceiling and never read. Worth
    /// remembering — otherwise every run pays to rediscover that it cannot read it.
    skipped: bool = false,
    messages: []const Message = &.{},
};

/// An entry as stored, which is `Entry` plus the path it belongs to. The file
/// is a flat list rather than an object so it round-trips through a plain
/// struct with no dynamic keys.
const Stored = struct {
    path: []const u8 = "",
    size: u64 = 0,
    mtime: i64 = 0,
    skipped: bool = false,
    messages: []const Message = &.{},
};

const Wire = struct {
    version: u32 = 0,
    files: []const Stored = &.{},
};

pub const Cache = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Where it lives, or null when lcc could not work that out. A null path is
    /// a working cache that remembers nothing: every lookup misses, nothing is
    /// written, and the scan simply pays full price.
    path: ?[]const u8 = null,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Paths this run looked at. An entry nobody asked about is still kept —
    /// another repository's transcripts must survive a run that never mentions
    /// them — but only the ones asked about are known to still exist.
    used: std.StringHashMapUnmanaged(void) = .empty,
    /// Something was learned that the file does not already hold. A run that
    /// changed nothing writes nothing.
    dirty: bool = false,

    /// A cache that remembers nothing, for callers that must not touch the disk.
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

        for (wire.files) |stored| {
            if (stored.path.len == 0) continue;
            self.entries.put(gpa, stored.path, .{
                .size = stored.size,
                .mtime = stored.mtime,
                .skipped = stored.skipped,
                .messages = stored.messages,
            }) catch return self;
        }
        return self;
    }

    /// What is known about `file_path`, if what is known is about the file that
    /// is there now.
    pub fn lookup(self: *Cache, file_path: []const u8, size: u64, mtime: i64) ?Entry {
        const entry = self.entries.get(file_path) orelse return null;
        if (entry.size != size or entry.mtime != mtime) return null;
        self.markUsed(file_path);
        return entry;
    }

    pub fn put(self: *Cache, file_path: []const u8, entry: Entry) void {
        if (self.path == null) return;
        const key = self.gpa.dupe(u8, file_path) catch return;
        self.entries.put(self.gpa, key, entry) catch return;
        self.markUsed(key);
        self.dirty = true;
    }

    fn markUsed(self: *Cache, file_path: []const u8) void {
        self.used.put(self.gpa, file_path, {}) catch {};
    }

    /// Writes back what was learned. A run that learned nothing writes nothing,
    /// which is the common case and keeps a repeat run free of disk writes.
    pub fn save(self: *Cache) void {
        if (!self.dirty) return;
        const file_path = self.path orelse return;

        var files: std.ArrayList(Stored) = .empty;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            // A transcript nobody asked about this run is kept only while it is
            // still on disk — otherwise a deleted worktree's sessions would sit
            // in here forever, and `lcc clean` would have reclaimed the space
            // for nothing.
            if (self.used.get(kv.key_ptr.*) == null) {
                Io.Dir.cwd().access(self.io, kv.key_ptr.*, .{}) catch continue;
            }
            files.append(self.gpa, .{
                .path = kv.key_ptr.*,
                .size = kv.value_ptr.size,
                .mtime = kv.value_ptr.mtime,
                .skipped = kv.value_ptr.skipped,
                .messages = kv.value_ptr.messages,
            }) catch return;
        }

        const body = std.json.Stringify.valueAlloc(self.gpa, Wire{
            .version = version,
            .files = files.items,
        }, .{}) catch return;

        const cwd = Io.Dir.cwd();
        if (std.fs.path.dirname(file_path)) |parent| {
            cwd.createDirPath(self.io, parent) catch return;
        }
        cwd.writeFile(self.io, .{ .sub_path = file_path, .data = body }) catch return;
    }
};

/// `LCC_USAGE_CACHE` overrides it. Otherwise `~/.cache/lcc`, not the
/// `~/.config/lcc` the rest of lcc's state uses: this file is regenerable,
/// rewritten constantly, and the size of the transcripts behind it. Config
/// directories get committed to dotfile repos, and this does not belong in one.
pub fn path(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]const u8 {
    if (environ.get("LCC_USAGE_CACHE")) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) return gpa.dupe(u8, override);
    }
    _ = try config.dir(gpa, environ); // Fails the same way when HOME is unset.
    const home = environ.get("HOME").?;
    return std.fs.path.join(gpa, &.{ home, ".cache", "lcc", "usage.json" });
}

test "a cache round-trips through the file and notices a changed transcript" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cwd = Io.Dir.cwd();

    const transcript = try std.fs.path.join(arena, &.{ base, "a.jsonl" });
    try cwd.writeFile(io, .{ .sub_path = transcript, .data = "{}\n" });

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_USAGE_CACHE", try std.fs.path.join(arena, &.{ base, "usage.json" }));

    {
        var cache: Cache = .open(arena, io, &environ);
        try std.testing.expect(cache.lookup(transcript, 3, 100) == null);
        cache.put(transcript, .{
            .size = 3,
            .mtime = 100,
            .messages = &.{.{ .id = "msg_a", .model = "claude-opus-5", .output = 7 }},
        });
        cache.save();
    }

    var reopened: Cache = .open(arena, io, &environ);
    const hit = reopened.lookup(transcript, 3, 100).?;
    try std.testing.expectEqual(@as(usize, 1), hit.messages.len);
    try std.testing.expectEqualStrings("msg_a", hit.messages[0].id);
    try std.testing.expectEqual(@as(u64, 7), hit.messages[0].output);

    // Either half of the fingerprint moving is a miss — an appended transcript
    // grows, and a rewritten one changes mtime.
    try std.testing.expect(reopened.lookup(transcript, 4, 100) == null);
    try std.testing.expect(reopened.lookup(transcript, 3, 101) == null);
    try std.testing.expect(reopened.lookup("/nowhere.jsonl", 3, 100) == null);
}

test "saving drops entries whose transcript is gone, and keeps the untouched" {
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
    try environ.put("LCC_USAGE_CACHE", try std.fs.path.join(arena, &.{ base, "usage.json" }));

    // `alive` belongs to another repository this run never asks about; `dead`
    // was reclaimed by `lcc clean` since the run that recorded it.
    const alive = try std.fs.path.join(arena, &.{ base, "alive.jsonl" });
    const dead = try std.fs.path.join(arena, &.{ base, "dead.jsonl" });
    try cwd.writeFile(io, .{ .sub_path = alive, .data = "{}\n" });

    {
        var cache: Cache = .none(arena, io);
        cache.path = try path(arena, &environ);
        cache.put(alive, .{ .size = 3, .mtime = 1 });
        cache.put(dead, .{ .size = 3, .mtime = 1 });
        cache.save();
    }

    // A fresh run that touches neither still keeps the one that exists.
    {
        var cache: Cache = .open(arena, io, &environ);
        try std.testing.expectEqual(@as(u32, 2), cache.entries.size);
        cache.dirty = true; // Stand in for a run that learned something else.
        cache.save();
    }

    var final: Cache = .open(arena, io, &environ);
    try std.testing.expect(final.lookup(alive, 3, 1) != null);
    try std.testing.expect(final.lookup(dead, 3, 1) == null);
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
    try std.testing.expect(cache.path == null);

    cache.put("/tmp/x.jsonl", .{ .size = 1, .mtime = 1 });
    try std.testing.expect(cache.lookup("/tmp/x.jsonl", 1, 1) == null);
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
    const file_path = try std.fs.path.join(arena, &.{ base, "usage.json" });

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_USAGE_CACHE", file_path);

    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = file_path,
        .data =
        \\{"version":999,"files":[{"path":"/a.jsonl","size":1,"mtime":1,"messages":[]}]}
        ,
    });
    const stale: Cache = .open(arena, io, &environ);
    try std.testing.expectEqual(@as(u32, 0), stale.entries.size);

    // And so is a file that is not the shape at all.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "not json" });
    const broken: Cache = .open(arena, io, &environ);
    try std.testing.expectEqual(@as(u32, 0), broken.entries.size);
}
