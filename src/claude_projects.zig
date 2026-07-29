//! Claude Code session transcripts under `~/.claude/projects`, and reclaiming
//! the ones whose working directory is gone.
//!
//! Claude Code keys each directory on the cwd it was launched in, flattened into
//! a single name. That flattening is lossy — `/` and `.` both become `-`, so
//! `LocationTracker3.0.worktrees/pe-224` and `LocationTracker3-0-worktrees-pe-224`
//! are indistinguishable afterwards. Rather than guess at the inverse, lcc reads
//! the `cwd` field out of a transcript: the sessions record the real path.

const std = @import("std");
const Io = std.Io;
const disk = @import("disk.zig");

pub const Entry = struct {
    /// Absolute path of the directory, e.g. `~/.claude/projects/-Users-me-…`.
    path: []const u8,
    /// Directory name — the flattened cwd Claude Code derived it from.
    name: []const u8,
    /// The directory Claude Code was launched in, read from a transcript.
    cwd: []const u8,
    /// How many `.jsonl` transcripts the directory holds.
    sessions: usize,
};

pub const Sized = struct {
    entry: Entry,
    /// Disk usage in bytes.
    size: u64,
};

pub const Error = error{RefusingToDelete} || std.mem.Allocator.Error;

/// A transcript records its cwd in the first user message, which in practice
/// lands within the first few KB. Reading a bounded prefix keeps the scan cheap
/// even when a transcript has grown to tens of MB.
const prefix_limit = 64 * 1024;

/// Where Claude Code keeps its per-project session state.
/// `LCC_CLAUDE_PROJECTS` overrides it.
pub fn root(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]const u8 {
    const home = environ.get("HOME") orelse return error.NoHomeDirectory;

    if (environ.get("LCC_CLAUDE_PROJECTS")) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) {
            if (std.mem.eql(u8, override, "~")) return home;
            if (std.mem.startsWith(u8, override, "~/")) {
                return std.fs.path.join(gpa, &.{ home, override[2..] });
            }
            return gpa.dupe(u8, override);
        }
    }

    return std.fs.path.join(gpa, &.{ home, ".claude", "projects" });
}

/// The directory name Claude Code derives from a cwd: every byte that is not
/// alphanumeric becomes `-`. Forward only — the note at the top of the file is
/// about the inverse, which is what cannot be recovered.
pub fn dirName(gpa: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const name = try gpa.dupe(u8, cwd);
    for (name) |*c| {
        if (!std.ascii.isAlphanumeric(c.*)) c.* = '-';
    }
    return name;
}

/// Whether Claude Code holds a transcript for `cwd` itself. `claude --resume`
/// keys on the exact directory it is launched in, so this is the question that
/// decides whether its picker would have anything to show; transcripts from a
/// subdirectory live in their own project directory and do not count.
pub fn hasSessionsFor(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    cwd: []const u8,
) bool {
    const projects = root(gpa, environ) catch return false;
    // Claude Code names the directory after the resolved path, same as the `cwd`
    // it records — and `git worktree list` can hand us an unresolved one.
    const resolved = disk.realPath(gpa, io, cwd);
    if (transcriptCount(gpa, io, projects, resolved) > 0) return true;
    if (std.mem.eql(u8, resolved, cwd)) return false;
    return transcriptCount(gpa, io, projects, cwd) > 0;
}

/// Transcripts in the project directory belonging to `cwd`. Counting only —
/// unlike `scanSessions` it never opens a transcript.
fn transcriptCount(
    gpa: std.mem.Allocator,
    io: Io,
    projects: []const u8,
    cwd: []const u8,
) usize {
    const name = dirName(gpa, cwd) catch return 0;
    const dir_path = std.fs.path.join(gpa, &.{ projects, name }) catch return 0;

    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var count: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |dirent| {
        if (dirent.kind == .file and std.mem.endsWith(u8, dirent.name, ".jsonl")) count += 1;
    }
    return count;
}

/// Every project directory under `dir_path` whose origin cwd could be read.
/// A directory whose transcripts never name a cwd is left out entirely — lcc
/// cannot tell whether its project still exists, so it must not offer to delete it.
pub fn list(gpa: std.mem.Allocator, io: Io, dir_path: []const u8) ![]Entry {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |dirent| {
        if (dirent.kind != .directory) continue;
        const name = try gpa.dupe(u8, dirent.name);
        const full = try std.fs.path.join(gpa, &.{ dir_path, name });

        const scanned = try scanSessions(gpa, io, full);
        const cwd = scanned.cwd orelse continue;
        try entries.append(gpa, .{
            .path = full,
            .name = name,
            .cwd = cwd,
            .sessions = scanned.count,
        });
    }
    return entries.toOwnedSlice(gpa);
}

const Scan = struct {
    cwd: ?[]const u8,
    count: usize,
};

/// Counts the transcripts in one project directory and returns the first cwd any
/// of them records. All sessions in a directory share it — the name was derived
/// from it — so the first hit is the answer.
fn scanSessions(gpa: std.mem.Allocator, io: Io, dir_path: []const u8) !Scan {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch
        return .{ .cwd = null, .count = 0 };
    defer dir.close(io);

    var found: ?[]const u8 = null;
    var count: usize = 0;

    var it = dir.iterate();
    while (it.next(io) catch null) |dirent| {
        if (dirent.kind != .file or !std.mem.endsWith(u8, dirent.name, ".jsonl")) continue;
        count += 1;
        if (found != null) continue;

        const file_path = try std.fs.path.join(gpa, &.{ dir_path, dirent.name });
        const prefix = readPrefix(gpa, io, file_path) orelse continue;
        found = try extractCwd(gpa, prefix);
    }
    return .{ .cwd = found, .count = count };
}

/// The first `prefix_limit` bytes of a file, or fewer if that is all there is.
/// Null when the file cannot be opened or read at all.
///
/// `readFileAlloc` cannot do this: its limit is a ceiling on the whole file, so
/// a transcript past it comes back as `error.StreamTooLong` with no bytes —
/// which is exactly the case this needs to serve, since a worked-in worktree
/// has nothing but multi-megabyte transcripts.
fn readPrefix(gpa: std.mem.Allocator, io: Io, file_path: []const u8) ?[]const u8 {
    var file = Io.Dir.cwd().openFile(io, file_path, .{}) catch return null;
    defer file.close(io);

    const buf = gpa.alloc(u8, prefix_limit) catch return null;
    var reader = file.reader(io, &.{});
    const n = reader.interface.readSliceShort(buf) catch return null;
    return buf[0..n];
}

/// Pulls the first `"cwd":"…"` value out of a transcript prefix, undoing JSON
/// string escaping. Null when the prefix holds no complete cwd field.
pub fn extractCwd(gpa: std.mem.Allocator, prefix: []const u8) !?[]const u8 {
    const key = "\"cwd\":\"";
    const key_at = std.mem.indexOf(u8, prefix, key) orelse return null;
    const start = key_at + key.len;

    var i = start;
    while (i < prefix.len) {
        switch (prefix[i]) {
            '\\' => i += 2, // Skip the escape and whatever it escapes.
            '"' => {
                const value = try unescape(gpa, prefix[start..i]);
                return if (value.len == 0) null else value;
            },
            else => i += 1,
        }
    }
    return null; // Truncated mid-value.
}

/// The escapes a path can realistically carry: `\\`, `\"`, `\/`, and `\uXXXX`
/// for anything Claude Code chose to escape. Unknown escapes keep their literal
/// character, which is what every JSON parser does for the two-character forms.
fn unescape(gpa: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return gpa.dupe(u8, raw);

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\' or i + 1 >= raw.len) {
            try out.append(gpa, raw[i]);
            i += 1;
            continue;
        }
        switch (raw[i + 1]) {
            'n' => try out.append(gpa, '\n'),
            'r' => try out.append(gpa, '\r'),
            't' => try out.append(gpa, '\t'),
            'b' => try out.append(gpa, 0x08),
            'f' => try out.append(gpa, 0x0c),
            'u' => {
                if (i + 6 > raw.len) return out.toOwnedSlice(gpa);
                const code = std.fmt.parseInt(u21, raw[i + 2 .. i + 6], 16) catch {
                    i += 6;
                    continue;
                };
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(code, &buf) catch {
                    i += 6;
                    continue;
                };
                try out.appendSlice(gpa, buf[0..len]);
                i += 6;
                continue;
            },
            else => try out.append(gpa, raw[i + 1]),
        }
        i += 2;
    }
    return out.toOwnedSlice(gpa);
}

/// Directories whose cwd is the worktree itself or something inside it. A single
/// worktree can own several: one per directory Claude Code was launched from.
pub fn forWorktree(
    gpa: std.mem.Allocator,
    io: Io,
    entries: []const Entry,
    worktree_path: []const u8,
) ![]Entry {
    // Claude Code records the resolved path; `git worktree list` does not.
    const resolved = disk.realPath(gpa, io, worktree_path);

    var matched: std.ArrayList(Entry) = .empty;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.cwd, resolved) or
            std.mem.eql(u8, entry.cwd, worktree_path) or
            disk.isInside(gpa, resolved, entry.cwd))
        {
            try matched.append(gpa, entry);
        }
    }
    return matched.toOwnedSlice(gpa);
}

/// Entries whose working directory is gone from disk — the worktree was removed
/// long ago and the transcripts outlived it.
pub fn orphans(gpa: std.mem.Allocator, io: Io, entries: []const Entry) ![]Entry {
    var dead: std.ArrayList(Entry) = .empty;
    for (entries) |entry| {
        Io.Dir.cwd().access(io, entry.cwd, .{}) catch {
            try dead.append(gpa, entry);
            continue;
        };
    }
    return dead.toOwnedSlice(gpa);
}

/// Attaches disk usage to each entry.
pub fn withSizes(gpa: std.mem.Allocator, io: Io, entries: []const Entry) ![]Sized {
    const paths = try gpa.alloc([]const u8, entries.len);
    for (entries, 0..) |entry, i| paths[i] = entry.path;
    const sizes = try disk.usage(gpa, io, paths);

    const sized = try gpa.alloc(Sized, entries.len);
    for (entries, 0..) |entry, i| sized[i] = .{ .entry = entry, .size = sizes[i] };
    return sized;
}

/// Delete one project directory. Refuses anything that is not a direct child of
/// `dir_path`, so `~/.claude` itself and its siblings can never be hit.
pub fn remove(gpa: std.mem.Allocator, io: Io, entry: Entry, dir_path: []const u8) !void {
    _ = gpa;
    if (entry.name.len == 0) return Error.RefusingToDelete;
    disk.removeChild(io, dir_path, entry.path) catch return Error.RefusingToDelete;
}

test "extractCwd reads the path a transcript records" {
    const gpa = std.testing.allocator;

    const line =
        \\{"parentUuid":null,"cwd":"/Users/me/Projects/App.worktrees/pe-1","sessionId":"x"}
    ;
    const got = (try extractCwd(gpa, line)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/Users/me/Projects/App.worktrees/pe-1", got);
}

test "extractCwd skips the metadata lines that carry no cwd" {
    const gpa = std.testing.allocator;

    const prefix =
        \\{"type":"mode","sessionId":"x"}
        \\{"type":"summary","summary":"talked about cwd handling"}
        \\{"type":"user","cwd":"/Users/me/x","uuid":"y"}
    ;
    const got = (try extractCwd(gpa, prefix)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/Users/me/x", got);
}

test "extractCwd undoes escaping and refuses a truncated value" {
    const gpa = std.testing.allocator;

    const escaped =
        \\{"cwd":"/Users/me/Say \"hi\"\/there","x":1}
    ;
    const got = (try extractCwd(gpa, escaped)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/Users/me/Say \"hi\"/there", got);

    // A prefix that stops inside the value must not yield half a path.
    try std.testing.expect((try extractCwd(gpa, "{\"cwd\":\"/Users/me/Proj")) == null);
    try std.testing.expect((try extractCwd(gpa, "{\"type\":\"mode\"}")) == null);
    try std.testing.expect((try extractCwd(gpa, "{\"cwd\":\"\"}")) == null);
}

/// A transcript that names `cwd` on its first line and then runs well past
/// `prefix_limit` — the shape every worked-in worktree leaves behind, and the
/// one a whole-file read under a ceiling cannot see at all.
fn oversizedTranscript(arena: std.mem.Allocator, cwd_path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, try std.fmt.allocPrint(
        arena,
        "{{\"type\":\"user\",\"cwd\":\"{s}\"}}\n",
        .{cwd_path},
    ));
    while (out.items.len <= prefix_limit * 2) {
        try out.appendSlice(arena, "{\"type\":\"assistant\",\"pad\":\"" ++ ("x" ** 512) ++ "\"}\n");
    }
    return out.items;
}

test "a transcript larger than the prefix limit still yields its cwd" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const projects = try std.fs.path.join(arena, &.{ base, "projects" });
    const cwd = Io.Dir.cwd();

    const worktree = try std.fs.path.join(arena, &.{ base, "App.worktrees", "pe-1" });
    try cwd.createDirPath(io, worktree);

    // What a worked-in worktree actually holds: one transcript, megabytes long,
    // naming its cwd on the first line. Reading it whole under a small ceiling
    // yields nothing at all, so the directory would vanish from the listing and
    // the worktree would report no usage.
    const project_dir = try std.fs.path.join(arena, &.{ projects, try dirName(arena, worktree) });
    try cwd.createDirPath(io, project_dir);

    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ project_dir, "a.jsonl" }),
        .data = try oversizedTranscript(arena, worktree),
    });

    const entries = try list(arena, io, projects);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings(worktree, entries[0].cwd);

    const mine = try forWorktree(arena, io, entries, worktree);
    try std.testing.expectEqual(@as(usize, 1), mine.len);
}

test "clean reclaims an orphan whose transcripts are all oversized" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const projects = try std.fs.path.join(arena, &.{ base, "projects" });
    const cwd = Io.Dir.cwd();

    // `lcc clean` walks list → orphans → remove, and every step is downstream of
    // reading the cwd. A worktree deleted after real work on it leaves exactly
    // the transcripts that read is worst at: big ones, and no small one beside
    // them. Miss it and the megabytes stay on disk forever, unreclaimable —
    // which is the failure mode that hurts, since the whole point of the command
    // is the space.
    const gone = try std.fs.path.join(arena, &.{ base, "App.worktrees", "pe-removed" });
    const project_dir = try std.fs.path.join(arena, &.{ projects, try dirName(arena, gone) });
    try cwd.createDirPath(io, project_dir);
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ project_dir, "a.jsonl" }),
        .data = try oversizedTranscript(arena, gone),
    });

    // A live worktree alongside it, to pin that `orphans` still tells them apart.
    const alive = try std.fs.path.join(arena, &.{ base, "App.worktrees", "pe-1" });
    try cwd.createDirPath(io, alive);
    const alive_dir = try std.fs.path.join(arena, &.{ projects, try dirName(arena, alive) });
    try cwd.createDirPath(io, alive_dir);
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ alive_dir, "b.jsonl" }),
        .data = try oversizedTranscript(arena, alive),
    });

    const entries = try list(arena, io, projects);
    try std.testing.expectEqual(@as(usize, 2), entries.len);

    const dead = try orphans(arena, io, entries);
    try std.testing.expectEqual(@as(usize, 1), dead.len);
    try std.testing.expectEqualStrings(gone, dead[0].cwd);

    try remove(arena, io, dead[0], projects);
    try std.testing.expectError(
        error.FileNotFound,
        cwd.access(io, project_dir, .{}),
    );
    // The live worktree's transcripts were never in danger.
    try cwd.access(io, alive_dir, .{});
}

test "hasSessionsFor answers for the launch directory only" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const projects = try std.fs.path.join(arena, &.{ base, "projects" });
    const cwd = Io.Dir.cwd();

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", base);
    try environ.put("LCC_CLAUDE_PROJECTS", projects);

    // A worktree path with a `.` in it, to pin the flattening.
    const worktree = try std.fs.path.join(arena, &.{ base, "App.worktrees", "pe-1" });
    try cwd.createDirPath(io, worktree);
    try std.testing.expect(!hasSessionsFor(arena, io, &environ, worktree));

    // A directory holding no transcript is still no reason to resume.
    const project_dir = try std.fs.path.join(arena, &.{ projects, try dirName(arena, worktree) });
    try cwd.createDirPath(io, project_dir);
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ project_dir, "memory" }));
    try std.testing.expect(!hasSessionsFor(arena, io, &environ, worktree));

    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ project_dir, "a.jsonl" }),
        .data = "{\"type\":\"mode\"}\n",
    });
    try std.testing.expect(hasSessionsFor(arena, io, &environ, worktree));

    // A transcript from a subdirectory belongs to that subdirectory, and
    // `claude --resume` at the parent would not list it.
    const sub = try std.fs.path.join(arena, &.{ worktree, "Common" });
    try cwd.createDirPath(io, sub);
    try std.testing.expect(!hasSessionsFor(arena, io, &environ, sub));
}

test "list reads origins and skips directories with no discoverable cwd" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const projects = try std.fs.path.join(arena, &.{ base, "projects" });
    const cwd = Io.Dir.cwd();

    const alive = try std.fs.path.join(arena, &.{ base, "alive-worktree" });
    try cwd.createDirPath(io, alive);

    const with_cwd = try std.fs.path.join(arena, &.{ projects, "-alive" });
    try cwd.createDirPath(io, with_cwd);
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ with_cwd, "a.jsonl" }),
        .data = try std.fmt.allocPrint(arena, "{{\"type\":\"mode\"}}\n{{\"cwd\":\"{s}\"}}\n", .{alive}),
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ with_cwd, "b.jsonl" }),
        .data = "{\"type\":\"mode\"}\n",
    });

    const gone = try std.fs.path.join(arena, &.{ projects, "-gone" });
    try cwd.createDirPath(io, gone);
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ gone, "c.jsonl" }),
        .data = try std.fmt.allocPrint(
            arena,
            "{{\"cwd\":\"{s}/removed-worktree\"}}\n",
            .{base},
        ),
    });

    // No transcript names a cwd — must be invisible to lcc.
    const unknown = try std.fs.path.join(arena, &.{ projects, "-unknown" });
    try cwd.createDirPath(io, unknown);
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ unknown, "d.jsonl" }),
        .data = "{\"type\":\"mode\"}\n",
    });

    const entries = try list(arena, io, projects);
    try std.testing.expectEqual(@as(usize, 2), entries.len);

    const dead = try orphans(arena, io, entries);
    try std.testing.expectEqual(@as(usize, 1), dead.len);
    try std.testing.expectEqualStrings("-gone", dead[0].name);

    const mine = try forWorktree(arena, io, entries, alive);
    try std.testing.expectEqual(@as(usize, 1), mine.len);
    try std.testing.expectEqualStrings("-alive", mine[0].name);
    try std.testing.expectEqual(@as(usize, 2), mine[0].sessions);
}
