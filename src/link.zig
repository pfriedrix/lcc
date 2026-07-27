//! Finding gitignored files in the repo and symlinking them into a worktree.
//!
//! A pattern is a relative path whose every segment may glob: `.env`, `.env.*`,
//! `.claude/settings.local.json`, `*/credentials.plist`. `*` and `?` never cross
//! a separator, so the walk only ever visits the directories a pattern names —
//! it never descends the whole repository.

const std = @import("std");
const Io = std.Io;

/// Single path segment: `*` matches any run of characters, `?` exactly one.
/// Segments never contain a separator, so no path semantics are needed here.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var star_n: usize = 0;

    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_n = n;
            p += 1;
        } else if (star) |s| {
            p = s + 1;
            star_n += 1;
            n = star_n;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Whole-path match: segment counts must agree and every segment must glob-match.
/// `.env` therefore matches only a root-level `.env`, never `config/.env`.
pub fn matchPath(pattern: []const u8, rel_path: []const u8) bool {
    var pattern_segments = std.mem.splitScalar(u8, pattern, '/');
    var path_segments = std.mem.splitScalar(u8, rel_path, '/');
    while (true) {
        const p = pattern_segments.next();
        const s = path_segments.next();
        if (p == null and s == null) return true;
        if (p == null or s == null) return false;
        if (!globMatch(p.?, s.?)) return false;
    }
}

pub const Found = struct {
    /// Path relative to the repo root — the same path the symlink gets in the
    /// worktree, so `.claude/settings.local.json` lands in `.claude/`.
    rel: []const u8,
    /// Absolute path of the source file.
    abs: []const u8,
};

/// Every file in `repo_root` matched by `patterns` and not by `exclude`, sorted
/// by relative path and deduplicated (two patterns may name the same file).
pub fn findFiles(
    gpa: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    patterns: []const []const u8,
    exclude: []const []const u8,
) ![]Found {
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (patterns) |pattern| {
        const segments = try splitPattern(gpa, pattern) orelse continue;
        try resolve(gpa, io, repo_root, segments, &seen);
    }

    var kept: std.ArrayList(Found) = .empty;
    for (seen.keys()) |rel| {
        if (isExcluded(rel, exclude)) continue;
        try kept.append(gpa, .{
            .rel = rel,
            .abs = try std.fs.path.join(gpa, &.{ repo_root, rel }),
        });
    }

    const files = try kept.toOwnedSlice(gpa);
    std.mem.sort(Found, files, {}, relLessThan);
    return files;
}

fn isExcluded(rel: []const u8, exclude: []const []const u8) bool {
    for (exclude) |pattern| {
        if (matchPath(pattern, rel)) return true;
    }
    return false;
}

/// Splits a pattern into segments, or null when it is not a safe relative path.
/// An absolute pattern, or one with a `.`/`..`/empty segment, is skipped rather
/// than clamped: silently linking the wrong file is worse than linking nothing.
fn splitPattern(gpa: std.mem.Allocator, pattern: []const u8) !?[]const []const u8 {
    if (pattern.len == 0 or std.fs.path.isAbsolute(pattern)) return null;

    var segments: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, pattern, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) return null;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return null;
        try segments.append(gpa, segment);
    }
    return try segments.toOwnedSlice(gpa);
}

/// Walks one pattern segment by segment, collecting the relative paths of the
/// files the last segment matches.
fn resolve(
    gpa: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    segments: []const []const u8,
    out: *std.StringArrayHashMapUnmanaged(void),
) !void {
    // Directories reached so far, relative to the repo root; "" is the root.
    var current: std.ArrayList([]const u8) = .empty;
    try current.append(gpa, "");

    for (segments, 0..) |segment, depth| {
        const last = depth + 1 == segments.len;
        var next: std.ArrayList([]const u8) = .empty;

        for (current.items) |base| {
            if (hasGlob(segment)) {
                try expandGlob(gpa, io, repo_root, base, segment, last, &next);
            } else {
                const rel = try joinRel(gpa, base, segment);
                if (accepts(gpa, io, repo_root, rel, last)) try next.append(gpa, rel);
            }
        }

        if (next.items.len == 0) return;
        current = next;
    }

    for (current.items) |rel| try out.put(gpa, rel, {});
}

fn expandGlob(
    gpa: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    base: []const u8,
    segment: []const u8,
    last: bool,
    out: *std.ArrayList([]const u8),
) !void {
    const abs_base = if (base.len == 0)
        repo_root
    else
        try std.fs.path.join(gpa, &.{ repo_root, base });

    var dir = Io.Dir.cwd().openDir(io, abs_base, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |dirent| {
        if (!globMatch(segment, dirent.name)) continue;
        if (last) {
            if (dirent.kind != .file and dirent.kind != .sym_link) continue;
        } else {
            if (dirent.kind != .directory and dirent.kind != .sym_link) continue;
            // A glob must never wander into the object database.
            if (std.mem.eql(u8, dirent.name, ".git")) continue;
        }
        try out.append(gpa, try joinRel(gpa, base, dirent.name));
    }
}

/// Whether `rel` exists and is the kind this position in the pattern needs:
/// a file (or a symlink to one) at the end, a directory anywhere before it.
fn accepts(gpa: std.mem.Allocator, io: Io, repo_root: []const u8, rel: []const u8, last: bool) bool {
    const abs = std.fs.path.join(gpa, &.{ repo_root, rel }) catch return false;

    if (last) {
        // Do not follow: a symlink to a file is itself worth linking, and the
        // symlink is what the worktree should point at.
        const stat = Io.Dir.cwd().statFile(io, abs, .{ .follow_symlinks = false }) catch return false;
        return stat.kind == .file or stat.kind == .sym_link;
    }
    const stat = Io.Dir.cwd().statFile(io, abs, .{}) catch return false;
    return stat.kind == .directory;
}

fn hasGlob(segment: []const u8) bool {
    return std.mem.indexOfAny(u8, segment, "*?") != null;
}

fn joinRel(gpa: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    if (base.len == 0) return gpa.dupe(u8, name);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, name });
}

fn relLessThan(_: void, a: Found, b: Found) bool {
    return std.mem.lessThan(u8, a.rel, b.rel);
}

pub const LinkStatus = enum { linked, skipped_exists };

pub const LinkResult = struct {
    source: []const u8,
    /// Path relative to the worktree — what the user is told was linked.
    rel: []const u8,
    target: []const u8,
    status: LinkStatus,
};

/// Symlinks each file into the worktree at the same relative path, creating the
/// parent directories it needs. An existing entry of any kind is left alone —
/// the worktree's own file wins.
pub fn linkFiles(
    gpa: std.mem.Allocator,
    io: Io,
    files: []const Found,
    worktree_path: []const u8,
) ![]LinkResult {
    const results = try gpa.alloc(LinkResult, files.len);
    const cwd = Io.Dir.cwd();

    for (files, 0..) |file, i| {
        const target = try std.fs.path.join(gpa, &.{ worktree_path, file.rel });
        results[i] = .{
            .source = file.abs,
            .rel = file.rel,
            .target = target,
            .status = .skipped_exists,
        };

        if (cwd.statFile(io, target, .{ .follow_symlinks = false })) |_| {
            continue;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        // Only matters for nested patterns: `.claude/` may not exist in a fresh
        // worktree, and `symLink` will not create it.
        if (std.fs.path.dirname(target)) |parent| {
            try cwd.createDirPath(io, parent);
        }

        try cwd.symLink(io, file.abs, target, .{});
        results[i].status = .linked;
    }
    return results;
}

test "glob matches env patterns" {
    try std.testing.expect(globMatch(".env", ".env"));
    try std.testing.expect(!globMatch(".env", ".env.local"));
    try std.testing.expect(globMatch(".env.*", ".env.local"));
    try std.testing.expect(globMatch(".env.*", ".env."));
    try std.testing.expect(!globMatch(".env.*", ".envlocal"));
    try std.testing.expect(!globMatch(".env.*", "env.local"));
}

test "matchPath is segment-wise and a glob never crosses a separator" {
    try std.testing.expect(matchPath(".env", ".env"));
    // A bare name is root-level only.
    try std.testing.expect(!matchPath(".env", "config/.env"));
    try std.testing.expect(!matchPath("*", ".claude/settings.local.json"));

    try std.testing.expect(matchPath(".claude/settings.local.json", ".claude/settings.local.json"));
    try std.testing.expect(!matchPath(".claude/settings.local.json", "settings.local.json"));
    try std.testing.expect(matchPath("*/credentials.plist", "Config/credentials.plist"));
    try std.testing.expect(!matchPath("*/credentials.plist", "a/b/credentials.plist"));
    try std.testing.expect(matchPath(".claude/*.json", ".claude/settings.local.json"));
}

test "splitPattern rejects anything that could escape the repo root" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect((try splitPattern(arena, "/etc/passwd")) == null);
    try std.testing.expect((try splitPattern(arena, "../../.ssh/id_rsa")) == null);
    try std.testing.expect((try splitPattern(arena, ".claude/../.git/config")) == null);
    try std.testing.expect((try splitPattern(arena, ".claude//x")) == null);
    try std.testing.expect((try splitPattern(arena, "")) == null);

    const ok = (try splitPattern(arena, ".claude/settings.local.json")).?;
    try std.testing.expectEqual(@as(usize, 2), ok.len);
    try std.testing.expectEqualStrings(".claude", ok[0]);
    try std.testing.expectEqualStrings("settings.local.json", ok[1]);
}

test "findFiles resolves nested patterns and honours exclusions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const cwd = Io.Dir.cwd();
    for ([_][]const u8{ ".claude", "Config", ".git" }) |sub| {
        try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ root, sub }));
    }
    for ([_][]const u8{
        ".env",
        ".env.local",
        ".env.example",
        ".claude/settings.local.json",
        ".claude/settings.json",
        "Config/credentials.plist",
        ".git/config",
        "README.md",
    }) |rel| {
        try cwd.writeFile(io, .{
            .sub_path = try std.fs.path.join(arena, &.{ root, rel }),
            .data = "x",
        });
    }

    const found = try findFiles(arena, io, root, &.{
        ".env",
        ".env.*",
        ".claude/settings.local.json",
        "*/credentials.plist",
        // Must not reach into .git even though the glob would match the name.
        "*/config",
    }, &.{".env.example"});

    var rels: std.ArrayList([]const u8) = .empty;
    for (found) |f| try rels.append(arena, f.rel);
    const joined = try std.mem.join(arena, " ", rels.items);

    try std.testing.expectEqualStrings(
        ".claude/settings.local.json .env .env.local Config/credentials.plist",
        joined,
    );
}

test "linkFiles creates parent directories and never overwrites" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const repo = try std.fs.path.join(arena, &.{ base, "repo" });
    const worktree = try std.fs.path.join(arena, &.{ base, "wt" });

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ repo, ".claude" }));
    try cwd.createDirPath(io, worktree);
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ repo, ".claude", "settings.local.json" }),
        .data = "{}",
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ repo, ".env" }),
        .data = "K=V",
    });
    // Already present in the worktree — must be left alone.
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ worktree, ".env" }),
        .data = "MINE=1",
    });

    const files = try findFiles(arena, io, repo, &.{ ".env", ".claude/settings.local.json" }, &.{});
    const results = try linkFiles(arena, io, files, worktree);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings(".claude/settings.local.json", results[0].rel);
    try std.testing.expectEqual(LinkStatus.linked, results[0].status);
    try std.testing.expectEqualStrings(".env", results[1].rel);
    try std.testing.expectEqual(LinkStatus.skipped_exists, results[1].status);

    // The nested link resolves to the repo's file, and .env still has the
    // worktree's own contents.
    const linked = try cwd.readFileAlloc(
        io,
        try std.fs.path.join(arena, &.{ worktree, ".claude", "settings.local.json" }),
        arena,
        .limited(64),
    );
    try std.testing.expectEqualStrings("{}", linked);

    const untouched = try cwd.readFileAlloc(
        io,
        try std.fs.path.join(arena, &.{ worktree, ".env" }),
        arena,
        .limited(64),
    );
    try std.testing.expectEqualStrings("MINE=1", untouched);
}
