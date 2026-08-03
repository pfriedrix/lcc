const std = @import("std");
const Io = std.Io;
const codex_cache = @import("codex_cache.zig");

/// Codex writes `session_meta` as a rollout's first line, so `id` and `cwd` are
/// in the first few KB — that line carries the environment context with them and
/// runs to around seven. Reading a bounded prefix is what keeps discovery
/// affordable: `~/.codex/sessions` accumulates every session from every directory
/// Codex has ever run in, tens of thousands of rollouts and hundreds of
/// megabytes, and none of that bulk is metadata. The ceiling is set well above
/// the observed size because overshooting costs nothing on a file smaller than
/// it, while undershooting silently loses the session.
const metadata_prefix_limit = 64 * 1024;
const max_depth = 16;

pub const Entry = struct {
    identity: []const u8,
    session_id: []const u8,
    rollout_path: []const u8,
    session_root: []const u8,
    cwd: []const u8,
    archived: bool,

    pub fn remove(self: Entry) !void {
        return removeRollout(self.session_root, self.rollout_path);
    }
};

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry,

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn findByIdentity(self: Catalog, identity: []const u8) ?Entry {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.identity, identity)) return entry;
        }
        return null;
    }

    pub fn orphans(self: Catalog, gpa: std.mem.Allocator) ![]Entry {
        return self.orphansWithIo(gpa, testIo());
    }

    pub fn orphansWithIo(self: Catalog, gpa: std.mem.Allocator, io: Io) ![]Entry {
        var out: std.ArrayList(Entry) = .empty;
        for (self.entries) |entry| {
            Io.Dir.cwd().access(io, entry.cwd, .{}) catch |err| switch (err) {
                error.FileNotFound => try out.append(gpa, entry),
                else => {},
            };
        }
        return out.toOwnedSlice(gpa);
    }
};

pub fn home(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    for ([_][]const u8{ "LCC_CODEX_HOME", "CODEX_HOME" }) |name| {
        if (environ.get(name)) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len > 0) return gpa.dupe(u8, trimmed);
        }
    }
    const user_home = environ.get("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ user_home, ".codex" });
}

pub fn scan(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) !Catalog {
    return scanWithIo(gpa, testIo(), environ);
}

pub fn scanWithIo(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) !Catalog {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    const codex_home = try home(arena, environ);
    const active_root = try std.fs.path.join(arena, &.{ codex_home, "sessions" });
    const archived_root = try std.fs.path.join(arena, &.{ codex_home, "archived_sessions" });

    var entries: std.ArrayList(Entry) = .empty;
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    var reader: MetadataReader = .init(gpa, io, .open(gpa, io, environ));
    defer reader.deinit();
    try scanRoot(arena, io, &reader, active_root, false, 0, &entries, &ids);
    try scanRoot(arena, io, &reader, archived_root, true, 0, &entries, &ids);
    return .{ .arena = arena_state, .entries = try entries.toOwnedSlice(arena) };
}

fn scanRoot(
    arena: std.mem.Allocator,
    io: Io,
    reader: *MetadataReader,
    root: []const u8,
    archived: bool,
    depth: usize,
    entries: *std.ArrayList(Entry),
    ids: *std.StringHashMapUnmanaged(void),
) !void {
    if (depth > max_depth) return;
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |item| {
        const path = try std.fs.path.join(arena, &.{ root, item.name });
        switch (item.kind) {
            .directory => try scanRoot(arena, io, reader, path, archived, depth + 1, entries, ids),
            .file => {
                if (!std.mem.endsWith(u8, item.name, ".jsonl")) continue;
                const metadata = try reader.read(arena, path) orelse continue;
                if (ids.contains(metadata.id)) continue;
                try ids.put(arena, metadata.id, {});
                try entries.append(arena, .{
                    .identity = try std.fmt.allocPrint(arena, "codex:{s}", .{metadata.id}),
                    .session_id = metadata.id,
                    .rollout_path = path,
                    .session_root = rootForPath(path, archived, root),
                    .cwd = metadata.cwd,
                    .archived = archived,
                });
            },
            else => {},
        }
    }
}

/// Where the walk gets each rollout's identity and cwd: from what an earlier run
/// recorded when it can, and from the rollout itself otherwise.
///
/// It also owns the prefix buffer and the JSON scratch space, and both have to be
/// reused. `~/.codex` runs to tens of thousands of rollouts, so a prefix buffer
/// per file is gigabytes of allocation for a few hundred bytes of answer, and it
/// lands in the catalog's arena where nothing frees it until the command exits.
/// What a rollout contributes is copied into that arena; the scratch is reset
/// behind it.
const MetadataReader = struct {
    gpa: std.mem.Allocator,
    io: Io,
    cache: codex_cache.Cache,
    buffer: ?[]u8 = null,
    scratch: std.heap.ArenaAllocator,

    fn init(gpa: std.mem.Allocator, io: Io, cache: codex_cache.Cache) MetadataReader {
        return .{ .gpa = gpa, .io = io, .cache = cache, .scratch = .init(gpa) };
    }

    /// Teardown writes the cache back, so a caller cannot forget to — the same
    /// reasoning as `usage.Scanner.deinit`.
    fn deinit(self: *MetadataReader) void {
        self.cache.save();
        self.cache.deinit();
        if (self.buffer) |buf| self.gpa.free(buf);
        self.scratch.deinit();
        self.* = undefined;
    }

    /// One rollout's identity and working directory, copied into `arena`. Null
    /// when the file cannot be read or records no usable metadata — neither is an
    /// error, just a rollout that cannot be attributed to anything.
    fn read(self: *MetadataReader, arena: std.mem.Allocator, path: []const u8) !?Metadata {
        if (self.cache.lookup(path)) |hit| {
            return .{
                .id = try arena.dupe(u8, hit.id),
                .cwd = try arena.dupe(u8, hit.cwd),
            };
        }

        if (self.buffer == null) self.buffer = try self.gpa.alloc(u8, metadata_prefix_limit);
        defer _ = self.scratch.reset(.retain_capacity);

        const prefix = readPrefix(self.buffer.?, self.io, path) orelse return null;
        const found = parseMetadata(self.scratch.allocator(), prefix) orelse return null;
        self.cache.put(path, .{ .id = found.id, .cwd = found.cwd });
        return .{
            .id = try arena.dupe(u8, found.id),
            .cwd = try arena.dupe(u8, found.cwd),
        };
    }
};

fn rootForPath(_: []const u8, _: bool, root: []const u8) []const u8 {
    var current = root;
    while (std.fs.path.dirname(current)) |parent| {
        const base = std.fs.path.basename(current);
        if (std.mem.eql(u8, base, "sessions") or std.mem.eql(u8, base, "archived_sessions")) return current;
        current = parent;
    }
    return root;
}

const Metadata = struct { id: []const u8, cwd: []const u8 };
const MetadataLine = struct {
    type: ?[]const u8 = null,
    payload: ?struct {
        id: ?[]const u8 = null,
        cwd: ?[]const u8 = null,
    } = null,
};

/// The `id` and `cwd` a rollout prefix records, borrowed from `scratch` and from
/// `prefix` itself — `MetadataReader.read` is what copies them somewhere durable.
fn parseMetadata(scratch: std.mem.Allocator, prefix: []const u8) ?Metadata {
    var lines = std.mem.splitScalar(u8, prefix, '\n');
    while (lines.next()) |line| {
        const parsed = std.json.parseFromSliceLeaky(MetadataLine, scratch, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        if (!std.mem.eql(u8, parsed.type orelse continue, "session_meta")) continue;
        const payload = parsed.payload orelse continue;
        const id = payload.id orelse continue;
        const cwd = payload.cwd orelse continue;
        if (id.len == 0 or cwd.len == 0 or !std.fs.path.isAbsolute(cwd)) return null;
        return .{ .id = id, .cwd = cwd };
    }
    return null;
}

/// As much of a rollout's start as `buf` holds, or less if that is all there is.
/// Null when the file cannot be opened or read at all.
///
/// The final line will usually be cut mid-JSON, which needs no handling: a line
/// that does not parse is skipped, exactly like a line that is not
/// `session_meta`. A rollout whose metadata somehow falls outside the prefix is
/// skipped the same way one recording no metadata at all already was.
///
/// `readFileAlloc` cannot do this — its limit is a ceiling on the whole file, so
/// a rollout past it comes back as `error.StreamTooLong` with no bytes.
fn readPrefix(buf: []u8, io: Io, path: []const u8) ?[]const u8 {
    var file = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const n = reader.interface.readSliceShort(buf) catch return null;
    return buf[0..n];
}

pub fn removeRollout(session_root: []const u8, rollout_path: []const u8) !void {
    return removeRolloutWithIo(testIo(), session_root, rollout_path);
}

pub fn removeRolloutWithIo(io: Io, session_root: []const u8, rollout_path: []const u8) !void {
    const gpa = std.heap.page_allocator;
    const root = Io.Dir.cwd().realPathFileAlloc(io, session_root, gpa) catch return error.PathOutsideSessionRoot;
    defer gpa.free(root);
    const target = Io.Dir.cwd().realPathFileAlloc(io, rollout_path, gpa) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.PathOutsideSessionRoot,
    };
    defer gpa.free(target);
    if (!contained(root, target)) return error.PathOutsideSessionRoot;
    try Io.Dir.cwd().deleteFile(io, rollout_path);
}

fn contained(root: []const u8, path: []const u8) bool {
    if (!std.fs.path.isAbsolute(root) or !std.fs.path.isAbsolute(path)) return false;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len <= root.len) return false;
    return path[root.len] == std.fs.path.sep;
}

fn testIo() Io {
    if (!@import("builtin").is_test) @panic("use the WithIo API outside tests");
    return std.testing.io;
}
