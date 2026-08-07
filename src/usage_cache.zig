const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");

const version: u32 = 1;

const file_limit = 128 * 1024 * 1024;

pub const Message = struct {
    id: []const u8 = "",
    model: []const u8 = "",
    input: u64 = 0,
    output: u64 = 0,
    cache_write_5m: u64 = 0,
    cache_write_1h: u64 = 0,
    cache_read: u64 = 0,
    timestamp: []const u8 = "",
};

pub const Entry = struct {
    size: u64 = 0,
    mtime: i64 = 0,
    skipped: bool = false,
    messages: []const Message = &.{},
};

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
    path: ?[]const u8 = null,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    used: std.StringHashMapUnmanaged(void) = .empty,
    dirty: bool = false,

    pub fn none(gpa: std.mem.Allocator, io: Io) Cache {
        return .{ .gpa = gpa, .io = io };
    }

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

    pub fn save(self: *Cache) void {
        if (!self.dirty) return;
        const file_path = self.path orelse return;

        var files: std.ArrayList(Stored) = .empty;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
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

pub fn path(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]const u8 {
    if (environ.get("LCC_USAGE_CACHE")) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) return gpa.dupe(u8, override);
    }
    _ = try config.dir(gpa, environ);
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

    {
        var cache: Cache = .open(arena, io, &environ);
        try std.testing.expectEqual(@as(u32, 2), cache.entries.size);
        cache.dirty = true;
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

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "not json" });
    const broken: Cache = .open(arena, io, &environ);
    try std.testing.expectEqual(@as(u32, 0), broken.entries.size);
}
