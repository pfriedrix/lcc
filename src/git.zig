//! Everything lcc does with git. Same shell-outs as the TypeScript version —
//! `execa` becomes `std.process`, nothing else changes.

const std = @import("std");
const Io = std.Io;
const exec = @import("exec.zig");

pub const Error = error{
    NotAGitRepository,
    WorktreePathExists,
    GitFailed,
} || std.mem.Allocator.Error;

/// Absolute path of the repository containing `cwd` (or the process cwd).
pub fn repoRoot(gpa: std.mem.Allocator, io: Io, cwd: ?[]const u8) Error![]u8 {
    return exec.capture(gpa, io, &.{ "git", "rev-parse", "--show-toplevel" }, cwd) catch
        return Error.NotAGitRepository;
}

pub const Repo = struct {
    gpa: std.mem.Allocator,
    io: Io,
    root: []const u8,

    fn capture(self: Repo, argv: []const []const u8) ?[]u8 {
        return exec.capture(self.gpa, self.io, argv, self.root) catch null;
    }

    fn succeeds(self: Repo, argv: []const []const u8) bool {
        return exec.succeeds(self.gpa, self.io, argv, self.root);
    }

    /// origin/HEAD when it is set, else a local `main`/`master`, else whatever
    /// HEAD currently points at.
    pub fn defaultBranch(self: Repo) Error![]const u8 {
        if (self.capture(&.{ "git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })) |out| {
            if (std.mem.startsWith(u8, out, "origin/")) return out["origin/".len..];
            return out;
        }
        for ([_][]const u8{ "main", "master" }) |candidate| {
            const ref = try std.fmt.allocPrint(self.gpa, "refs/heads/{s}", .{candidate});
            if (self.succeeds(&.{ "git", "show-ref", "--verify", "--quiet", ref })) return candidate;
        }
        return self.capture(&.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }) orelse
            return Error.GitFailed;
    }

    /// Null when HEAD is detached.
    pub fn currentBranch(self: Repo) Error!?[]const u8 {
        const out = self.capture(&.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }) orelse
            return Error.GitFailed;
        if (std.mem.eql(u8, out, "HEAD")) return null;
        return out;
    }

    /// Local and remote branches, `origin/` stripped, deduplicated, sorted.
    pub fn listBranches(self: Repo) Error![][]const u8 {
        const out = self.capture(&.{
            "git",                     "for-each-ref",
            "--format=%(refname:short)", "refs/heads/",
            "refs/remotes/",
        }) orelse return Error.GitFailed;

        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            const ref = std.mem.trim(u8, line, " \t\r");
            if (ref.len == 0 or std.mem.endsWith(u8, ref, "/HEAD")) continue;
            const name = if (std.mem.startsWith(u8, ref, "origin/")) ref["origin/".len..] else ref;
            try seen.put(self.gpa, name, {});
        }

        const names = try self.gpa.dupe([]const u8, seen.keys());
        std.mem.sort([]const u8, names, {}, lessThan);
        return names;
    }

    /// One `for-each-ref` for every local branch: its upstream, how far the two
    /// have drifted, and when the tip was committed. A single call, so the cost
    /// does not grow with the number of worktrees on screen.
    pub fn branchStatuses(self: Repo) Error![]BranchStatus {
        const out = self.capture(&.{
            "git",
            "for-each-ref",
            "--format=%(refname:short)%09%(upstream:short)%09%(upstream:track)%09%(committerdate:unix)",
            "refs/heads/",
        }) orelse return Error.GitFailed;

        var statuses: std.ArrayList(BranchStatus) = .empty;
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r");
            if (line.len == 0) continue;

            var fields = std.mem.splitScalar(u8, line, '\t');
            const name = fields.next() orelse continue;
            const upstream = fields.next() orelse "";
            const track = fields.next() orelse "";
            const committed = fields.next() orelse "";
            if (name.len == 0) continue;

            const drift = parseTrack(track);
            try statuses.append(self.gpa, .{
                .branch = name,
                .upstream = if (upstream.len == 0) null else upstream,
                .ahead = drift.ahead,
                .behind = drift.behind,
                .gone = drift.gone,
                .committed_at = std.fmt.parseInt(i64, committed, 10) catch 0,
            });
        }
        return statuses.toOwnedSlice(self.gpa);
    }

    /// Number of entries `git status --porcelain` reports in a worktree, or null
    /// when the worktree cannot be inspected — a prunable one whose directory
    /// has already been deleted, say.
    pub fn dirtyCount(self: Repo, worktree_path: []const u8) ?u32 {
        const out = exec.capture(self.gpa, self.io, &.{
            "git", "status", "--porcelain",
        }, worktree_path) catch return null;

        var count: u32 = 0;
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len > 0) count += 1;
        }
        return count;
    }

    fn localBranchExists(self: Repo, branch: []const u8) bool {
        const ref = std.fmt.allocPrint(self.gpa, "refs/heads/{s}", .{branch}) catch return false;
        return self.succeeds(&.{ "git", "show-ref", "--verify", "--quiet", ref });
    }

    fn remoteBranchExists(self: Repo, branch: []const u8) bool {
        const ref = std.fmt.allocPrint(self.gpa, "refs/remotes/origin/{s}", .{branch}) catch return false;
        return self.succeeds(&.{ "git", "show-ref", "--verify", "--quiet", ref });
    }

    pub fn resolveStrategy(self: Repo, branch: []const u8) Strategy {
        if (self.localBranchExists(branch)) return .reused_local;
        if (self.remoteBranchExists(branch)) return .tracking_remote;
        return .new;
    }

    pub fn createWorktree(
        self: Repo,
        branch: []const u8,
        worktree_path: []const u8,
        base: []const u8,
    ) !WorktreeResult {
        if (pathExists(self.io, worktree_path)) return Error.WorktreePathExists;

        if (std.fs.path.dirname(worktree_path)) |parent| {
            try Io.Dir.cwd().createDirPath(self.io, parent);
        }
        try self.ensureLocalIgnore(worktree_path);

        if (self.localBranchExists(branch)) {
            try self.runInherit(&.{ "git", "worktree", "add", worktree_path, branch });
            return .{ .path = worktree_path, .branch = branch, .created = .reused_local };
        }
        if (self.remoteBranchExists(branch)) {
            const upstream = try std.fmt.allocPrint(self.gpa, "origin/{s}", .{branch});
            try self.runInherit(&.{
                "git", "worktree", "add", "--track", "-b", branch, worktree_path, upstream,
            });
            return .{ .path = worktree_path, .branch = branch, .created = .tracking_remote };
        }
        try self.runInherit(&.{ "git", "worktree", "add", "-b", branch, worktree_path, base });
        return .{ .path = worktree_path, .branch = branch, .created = .new };
    }

    fn runInherit(self: Repo, argv: []const []const u8) Error!void {
        const code = exec.inherit(self.io, argv, self.root) catch return Error.GitFailed;
        if (code != 0) return Error.GitFailed;
    }

    /// Adds the worktree's top-level directory to `.git/info/exclude`, so a
    /// worktree nested inside the repo does not show up as untracked.
    fn ensureLocalIgnore(self: Repo, worktree_path: []const u8) !void {
        const rel = std.fs.path.relativePosix(self.gpa, self.root, self.root, worktree_path) catch return;
        if (rel.len == 0 or std.mem.startsWith(u8, rel, "..") or std.fs.path.isAbsolute(rel)) return;

        var parts = std.mem.splitScalar(u8, rel, std.fs.path.sep);
        const top = parts.first();
        if (top.len == 0) return;

        const entry = try std.fmt.allocPrint(self.gpa, "/{s}/", .{top});
        const with_slash = try std.fmt.allocPrint(self.gpa, "{s}/", .{top});
        const exclude_path = try std.fs.path.join(self.gpa, &.{ self.root, ".git", "info", "exclude" });

        const cwd = Io.Dir.cwd();
        const current = cwd.readFileAlloc(self.io, exclude_path, self.gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };

        var lines = std.mem.splitScalar(u8, current, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.eql(u8, trimmed, entry) or
                std.mem.eql(u8, trimmed, top) or
                std.mem.eql(u8, trimmed, with_slash)) return;
        }

        var next: std.ArrayList(u8) = .empty;
        try next.appendSlice(self.gpa, current);
        if (current.len > 0 and current[current.len - 1] != '\n') try next.append(self.gpa, '\n');
        try next.appendSlice(self.gpa, entry);
        try next.append(self.gpa, '\n');

        if (std.fs.path.dirname(exclude_path)) |parent| {
            try cwd.createDirPath(self.io, parent);
        }
        try cwd.writeFile(self.io, .{ .sub_path = exclude_path, .data = next.items });
    }

    pub fn listWorktrees(self: Repo) Error![]WorktreeEntry {
        const out = self.capture(&.{ "git", "worktree", "list", "--porcelain" }) orelse
            return Error.GitFailed;

        var entries: std.ArrayList(WorktreeEntry) = .empty;
        var current: ?WorktreeEntry = null;

        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, line, "worktree ")) {
                if (current) |entry| try entries.append(self.gpa, entry);
                current = .{
                    .path = std.mem.trim(u8, line["worktree ".len..], " \t"),
                    .branch = null,
                    .head = "",
                    .locked = false,
                    .prunable = false,
                    .is_main = false,
                };
            } else if (current == null) {
                continue;
            } else if (std.mem.startsWith(u8, line, "HEAD ")) {
                current.?.head = std.mem.trim(u8, line["HEAD ".len..], " \t");
            } else if (std.mem.startsWith(u8, line, "branch ")) {
                const ref = std.mem.trim(u8, line["branch ".len..], " \t");
                current.?.branch = if (std.mem.startsWith(u8, ref, "refs/heads/"))
                    ref["refs/heads/".len..]
                else
                    ref;
            } else if (std.mem.eql(u8, line, "locked") or std.mem.startsWith(u8, line, "locked ")) {
                current.?.locked = true;
            } else if (std.mem.eql(u8, line, "prunable") or std.mem.startsWith(u8, line, "prunable ")) {
                current.?.prunable = true;
            }
        }
        if (current) |entry| try entries.append(self.gpa, entry);

        const slice = try entries.toOwnedSlice(self.gpa);
        if (slice.len > 0) slice[0].is_main = true;
        return slice;
    }

    /// Decide whether a branch can be deleted along with its worktree.
    ///
    /// Being an ancestor of the default branch is the plain case. A *gone* upstream is
    /// the other one: the branch was pushed and the remote branch has since been
    /// deleted, which is what a squash-merged PR looks like locally — the commits are
    /// in the default branch under different SHAs, so ancestry can never prove it.
    pub fn branchDisposition(self: Repo, branch: []const u8) Error!BranchDisposition {
        const base = try self.defaultBranch();
        if (std.mem.eql(u8, branch, base)) {
            return .{ .branch = branch, .safe = false, .unmerged = 0, .reason = .default_branch };
        }

        const origin_base = try std.fmt.allocPrint(self.gpa, "origin/{s}", .{base});
        for ([_][]const u8{ base, origin_base }) |ref| {
            if (self.succeeds(&.{ "git", "merge-base", "--is-ancestor", branch, ref })) {
                return .{ .branch = branch, .safe = true, .unmerged = 0, .reason = .merged };
            }
        }

        const unmerged = self.countUnmerged(branch, base);
        if (self.upstreamGone(branch)) {
            return .{ .branch = branch, .safe = true, .unmerged = unmerged, .reason = .upstream_gone };
        }
        return .{ .branch = branch, .safe = false, .unmerged = unmerged, .reason = .unmerged };
    }

    fn upstreamGone(self: Repo, branch: []const u8) bool {
        const ref = std.fmt.allocPrint(self.gpa, "refs/heads/{s}", .{branch}) catch return false;
        const out = self.capture(&.{ "git", "for-each-ref", "--format=%(upstream:track)", ref }) orelse
            return false;
        return std.mem.eql(u8, out, "[gone]");
    }

    fn countUnmerged(self: Repo, branch: []const u8, base: []const u8) u32 {
        const origin_base = std.fmt.allocPrint(self.gpa, "origin/{s}", .{base}) catch return 0;
        for ([_][]const u8{ origin_base, base }) |ref| {
            const range = std.fmt.allocPrint(self.gpa, "{s}..{s}", .{ ref, branch }) catch continue;
            const out = self.capture(&.{ "git", "rev-list", "--count", range }) orelse continue;
            return std.fmt.parseInt(u32, out, 10) catch continue;
        }
        return 0;
    }

    pub fn deleteBranch(self: Repo, branch: []const u8, force: bool) Error!void {
        const flag: []const u8 = if (force) "-D" else "-d";
        const out = exec.run(self.gpa, self.io, &.{ "git", "branch", flag, branch }, self.root) catch
            return Error.GitFailed;
        if (!out.ok()) return Error.GitFailed;
    }

    pub fn removeWorktree(self: Repo, worktree_path: []const u8, force: bool) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.gpa, &.{ "git", "worktree", "remove" });
        if (force) try argv.append(self.gpa, "--force");
        try argv.append(self.gpa, worktree_path);

        const out = exec.run(self.gpa, self.io, argv.items, self.root) catch return Error.GitFailed;
        if (!out.ok()) {
            last_error = exec.message(out);
            return Error.GitFailed;
        }
    }
};

/// stderr of the last failed `removeWorktree`, so the caller can show git's own
/// explanation before offering `--force`.
pub var last_error: []const u8 = "";

pub const Strategy = enum { reused_local, tracking_remote, new };

pub const WorktreeResult = struct {
    path: []const u8,
    branch: []const u8,
    created: Strategy,
};

pub const WorktreeEntry = struct {
    path: []const u8,
    branch: ?[]const u8,
    head: []const u8,
    locked: bool,
    prunable: bool,
    is_main: bool,
};

pub const BranchStatus = struct {
    branch: []const u8,
    /// `origin/feature/x`, or null when the branch was never pushed.
    upstream: ?[]const u8,
    ahead: u32,
    behind: u32,
    /// The upstream existed and has since been deleted — what a squash-merged PR
    /// looks like locally.
    gone: bool,
    /// Commit timestamp of the branch tip, Unix seconds. 0 when unknown.
    committed_at: i64,
};

pub const Drift = struct { ahead: u32 = 0, behind: u32 = 0, gone: bool = false };

/// `%(upstream:track)` renders as `[ahead 2]`, `[behind 3]`, `[ahead 2, behind 3]`,
/// `[gone]`, or nothing at all — the last meaning either in sync or no upstream,
/// which `%(upstream:short)` tells apart.
pub fn parseTrack(track: []const u8) Drift {
    const body = std.mem.trim(u8, track, " \t[]");
    if (body.len == 0) return .{};
    if (std.mem.eql(u8, body, "gone")) return .{ .gone = true };

    var drift: Drift = .{};
    var parts = std.mem.splitScalar(u8, body, ',');
    while (parts.next()) |part| {
        var words = std.mem.tokenizeAny(u8, part, " \t");
        const label = words.next() orelse continue;
        const count = std.fmt.parseInt(u32, words.next() orelse continue, 10) catch continue;
        if (std.mem.eql(u8, label, "ahead")) {
            drift.ahead = count;
        } else if (std.mem.eql(u8, label, "behind")) {
            drift.behind = count;
        }
    }
    return drift;
}

pub const DispositionReason = enum { merged, upstream_gone, unmerged, default_branch };

pub const BranchDisposition = struct {
    branch: []const u8,
    /// True when the commits survive elsewhere, so deleting the branch loses nothing.
    safe: bool,
    /// Commits on the branch that the default branch does not have.
    unmerged: u32,
    reason: DispositionReason,
};

/// `PE-42/some-title` from Linear becomes `feature/some-title`.
pub fn rewriteBranchName(gpa: std.mem.Allocator, linear_branch: []const u8, prefix: []const u8) ![]u8 {
    const tail = if (std.mem.indexOfScalar(u8, linear_branch, '/')) |slash|
        linear_branch[slash + 1 ..]
    else
        linear_branch;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, tail });
}

pub fn renderWorktreePath(
    gpa: std.mem.Allocator,
    template: []const u8,
    repo_root: []const u8,
    branch: []const u8,
) ![]u8 {
    const repo_name = std.fs.path.basename(repo_root);
    const repo_parent = std.fs.path.dirname(repo_root) orelse repo_root;
    const branch_leaf = if (std.mem.lastIndexOfScalar(u8, branch, '/')) |slash|
        branch[slash + 1 ..]
    else
        branch;

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, template, i, '}')) |close| {
                const key = template[i + 1 .. close];
                const value: ?[]const u8 =
                    if (std.mem.eql(u8, key, "repoRoot")) repo_root
                    else if (std.mem.eql(u8, key, "repoParent")) repo_parent
                    else if (std.mem.eql(u8, key, "repoName")) repo_name
                    else if (std.mem.eql(u8, key, "branch")) branch
                    else if (std.mem.eql(u8, key, "branchLeaf")) branch_leaf
                    else null;
                if (value) |v| {
                    try out.appendSlice(gpa, v);
                    i = close + 1;
                    continue;
                }
            }
        }
        try out.append(gpa, template[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn pathExists(io: Io, target: []const u8) bool {
    Io.Dir.cwd().access(io, target, .{}) catch return false;
    return true;
}

test "renderWorktreePath expands every placeholder" {
    const gpa = std.testing.allocator;
    const got = try renderWorktreePath(gpa, "{repoParent}/{repoName}.worktrees/{branchLeaf}", "/tmp/proj", "feature/pe-1-thing");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/tmp/proj.worktrees/pe-1-thing", got);

    const nested = try renderWorktreePath(gpa, "{repoRoot}/.lcc/worktrees/{branchLeaf}", "/tmp/proj", "feature/x");
    defer gpa.free(nested);
    try std.testing.expectEqualStrings("/tmp/proj/.lcc/worktrees/x", nested);

    const whole = try renderWorktreePath(gpa, "{repoRoot}/wt/{branch}", "/tmp/proj", "feature/x");
    defer gpa.free(whole);
    try std.testing.expectEqualStrings("/tmp/proj/wt/feature/x", whole);
}

test "parseTrack covers every shape for-each-ref emits" {
    try std.testing.expectEqual(Drift{}, parseTrack(""));
    try std.testing.expectEqual(Drift{ .gone = true }, parseTrack("[gone]"));
    try std.testing.expectEqual(Drift{ .ahead = 2 }, parseTrack("[ahead 2]"));
    try std.testing.expectEqual(Drift{ .behind = 14 }, parseTrack("[behind 14]"));
    try std.testing.expectEqual(
        Drift{ .ahead = 5, .behind = 14 },
        parseTrack("[ahead 5, behind 14]"),
    );
    // Junk must read as "no information", never as a bogus count.
    try std.testing.expectEqual(Drift{}, parseTrack("[ahead]"));
}

test "rewriteBranchName keeps only the tail" {
    const gpa = std.testing.allocator;
    const got = try rewriteBranchName(gpa, "pfriedrix/pe-42-do-the-thing", "feature");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("feature/pe-42-do-the-thing", got);

    const bare = try rewriteBranchName(gpa, "pe-42-do-the-thing", "feature");
    defer gpa.free(bare);
    try std.testing.expectEqualStrings("feature/pe-42-do-the-thing", bare);
}

test "ensureLocalIgnore adds the worktree root once" {
    const gpa = std.testing.allocator;

    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    const repo: Repo = .{ .gpa = gpa, .io = io, .root = root };
    const worktree = try std.fs.path.join(gpa, &.{ root, ".lcc", "worktrees", "x" });
    defer gpa.free(worktree);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena_repo: Repo = .{ .gpa = arena_state.allocator(), .io = io, .root = root };

    try arena_repo.ensureLocalIgnore(worktree);
    try arena_repo.ensureLocalIgnore(worktree); // second call must be a no-op

    const exclude = try std.fs.path.join(gpa, &.{ root, ".git", "info", "exclude" });
    defer gpa.free(exclude);
    const contents = try Io.Dir.cwd().readFileAlloc(io, exclude, gpa, .limited(4096));
    defer gpa.free(contents);

    try std.testing.expectEqualStrings("/.lcc/\n", contents);
    _ = repo;
}

test "ensureLocalIgnore ignores worktrees outside the repo" {
    const gpa = std.testing.allocator;

    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const repo: Repo = .{ .gpa = arena_state.allocator(), .io = io, .root = root };

    try repo.ensureLocalIgnore("/somewhere/else/wt");

    const exclude = try std.fs.path.join(gpa, &.{ root, ".git", "info", "exclude" });
    defer gpa.free(exclude);
    try std.testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().readFileAlloc(io, exclude, gpa, .limited(4096)),
    );
}
