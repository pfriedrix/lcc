//! Finding `.env` files at the repo root and symlinking them into a worktree.

const std = @import("std");
const Io = std.Io;

/// Top-level glob: `*` matches any run of characters, `?` exactly one. Names
/// never contain a separator here, so no path semantics are needed.
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

/// Absolute paths of matching files at the top level of `repo_root`, sorted.
pub fn findEnvFiles(
    gpa: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    patterns: []const []const u8,
    exclude: []const []const u8,
) ![][]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, repo_root, .{ .iterate = true });
    defer dir.close(io);

    var found: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        var excluded = false;
        for (exclude) |name| {
            if (std.mem.eql(u8, name, entry.name)) {
                excluded = true;
                break;
            }
        }
        if (excluded) continue;

        for (patterns) |pattern| {
            if (globMatch(pattern, entry.name)) {
                try found.append(gpa, try std.fs.path.join(gpa, &.{ repo_root, entry.name }));
                break;
            }
        }
    }

    const files = try found.toOwnedSlice(gpa);
    std.mem.sort([]const u8, files, {}, lessThan);
    return files;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub const LinkStatus = enum { linked, skipped_exists };

pub const LinkResult = struct {
    source: []const u8,
    target: []const u8,
    status: LinkStatus,
};

/// Symlinks each file into the worktree. An existing entry of any kind is left
/// alone — the worktree's own file wins.
pub fn linkEnvFiles(
    gpa: std.mem.Allocator,
    io: Io,
    files: []const []const u8,
    worktree_path: []const u8,
) ![]LinkResult {
    const results = try gpa.alloc(LinkResult, files.len);
    const cwd = Io.Dir.cwd();

    for (files, 0..) |source, i| {
        const name = std.fs.path.basename(source);
        const target = try std.fs.path.join(gpa, &.{ worktree_path, name });

        if (cwd.statFile(io, target, .{ .follow_symlinks = false })) |_| {
            results[i] = .{ .source = source, .target = target, .status = .skipped_exists };
            continue;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        try cwd.symLink(io, source, target, .{});
        results[i] = .{ .source = source, .target = target, .status = .linked };
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
