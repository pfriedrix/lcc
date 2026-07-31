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

/// Absolute path of the *main* worktree of the repository containing `cwd` (or
/// the process cwd).
///
/// Deliberately not `--show-toplevel`: inside a linked worktree that answers the
/// worktree itself, and everything lcc derives from the root — the worktree path
/// template, `.git/info/exclude`, the repo-root `.env` files — has to hang off
/// the main checkout. `--git-common-dir` is the shared `.git` either way, so its
/// parent is the main worktree.
pub fn repoRoot(gpa: std.mem.Allocator, io: Io, cwd: ?[]const u8) Error![]u8 {
    const toplevel = exec.capture(gpa, io, &.{ "git", "rev-parse", "--show-toplevel" }, cwd) catch
        return Error.NotAGitRepository;

    const common = exec.capture(gpa, io, &.{
        "git", "rev-parse", "--path-format=absolute", "--git-common-dir",
    }, cwd) catch return toplevel;
    defer gpa.free(common);

    // `<main-worktree>/.git` is the only shape whose parent is the checkout; a
    // bare repo or `--separate-git-dir` puts the common dir somewhere unrelated.
    if (!std.mem.eql(u8, std.fs.path.basename(common), ".git")) return toplevel;
    const main_root = std.fs.path.dirname(common) orelse return toplevel;
    gpa.free(toplevel);
    return gpa.dupe(u8, main_root);
}

pub const Repo = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Main worktree — the anchor for derived paths and `.git` writes.
    root: []const u8,
    /// Where lcc was actually invoked, which is what "the current branch" means
    /// when that place is a linked worktree. Null inherits the process cwd.
    cwd: ?[]const u8 = null,
    /// stdout is carrying a machine-readable payload, so no child may write to it.
    /// Set by `--json`, where a stray line of git progress would corrupt the output.
    stdout_reserved: bool = false,

    fn captureIn(self: Repo, cwd: ?[]const u8, argv: []const []const u8) ?[]u8 {
        return exec.capture(self.gpa, self.io, argv, cwd) catch null;
    }

    fn capture(self: Repo, argv: []const []const u8) ?[]u8 {
        return self.captureIn(self.root, argv);
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

    /// The branch checked out where lcc was invoked — not `root`'s, which is a
    /// different branch whenever the user is standing in a linked worktree.
    /// Null when HEAD is detached.
    pub fn currentBranch(self: Repo) Error!?[]const u8 {
        const out = self.captureIn(self.cwd, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }) orelse
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
        // Not `capture`: that runs in `root`, the main worktree, which would report
        // the same status for every row on the dashboard.
        const out = self.captureIn(worktree_path, &.{ "git", "status", "--porcelain" }) orelse
            return null;

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

    /// git's progress belongs to the user, so its stdio is the terminal's — unless
    /// stdout is spoken for, in which case the run is captured and only its failure
    /// is passed on, through `last_error`.
    fn runInherit(self: Repo, argv: []const []const u8) Error!void {
        if (self.stdout_reserved) {
            const out = exec.run(self.gpa, self.io, argv, self.root) catch return Error.GitFailed;
            if (!out.ok()) {
                last_error = exec.message(out);
                return Error.GitFailed;
            }
            return;
        }
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

    /// Brings the remote-tracking refs up to date and drops the ones whose remote
    /// branch is gone.
    ///
    /// Every signal a removal decision rests on is read out of those refs, and
    /// none of them move on their own: `origin/master` only grows once something
    /// fetches it, and `%(upstream:track)` cannot say `[gone]` until the pruning
    /// happens. Without this, `lcc` is deciding what to delete from whatever the
    /// last `git pull` happened to leave behind.
    pub fn fetchPrune(self: Repo) Error!void {
        // Captured rather than inherited: this runs under a progress line, and
        // fetch's own output would break it apart for no gain.
        const out = exec.run(self.gpa, self.io, &.{ "git", "fetch", "--prune" }, self.root) catch
            return Error.GitFailed;
        if (!out.ok()) {
            last_error = exec.message(out);
            return Error.GitFailed;
        }
    }

    /// Decide whether a branch can be deleted along with its worktree.
    ///
    /// Being an ancestor of the default branch is the plain case. A *gone* upstream is
    /// the other one: the branch was pushed and the remote branch has since been
    /// deleted, which is what a squash-merged PR looks like locally — the commits are
    /// in the default branch under different SHAs, so ancestry can never prove it.
    ///
    /// Both are read from local refs, so both are only as current as the last fetch,
    /// and neither can speak for a squash-merged branch whose remote branch is still
    /// there. `BranchDisposition.withMergedPr` covers that case from GitHub.
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
        if (!out.ok()) {
            last_error = exec.message(out);
            return Error.GitFailed;
        }
    }

    /// Deletes a branch this repo has already vouched for, and does not take git's
    /// "not fully merged" for an answer when lcc's own check says otherwise. True
    /// when it took the force to do it.
    ///
    /// `-d` re-checks the merge against HEAD and the branch's upstream, and those two
    /// are the whole of what it can see. A branch merged into `origin/<default>`
    /// while local `<default>` is behind sits in neither — and `lcc remove`'s own
    /// `fetch --prune` is what takes the upstream away, so the ordinary case (pull
    /// request merged, remote branch deleted with it, nothing pulled since) is
    /// refused. Ancestry against `origin/<default>` already proved those commits
    /// survive, so the retry spends nothing but a second opinion that was blind.
    pub fn deleteVerified(self: Repo, d: BranchDisposition) Error!bool {
        self.deleteBranch(d.branch, d.needsForce()) catch |err| {
            // Nothing left to escalate to: `-D` is what already failed.
            if (d.needsForce()) return err;
            try self.deleteBranch(d.branch, true);
            return true;
        };
        return false;
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

/// The worktree `branch` is checked out in, wherever it sits. Not derived from the
/// path template: a worktree created before the template changed, or by hand, is
/// still the one place that branch can be checked out — git allows only one.
pub fn worktreeForBranch(entries: []const WorktreeEntry, branch: []const u8) ?WorktreeEntry {
    for (entries) |entry| {
        const name = entry.branch orelse continue;
        if (std.mem.eql(u8, name, branch)) return entry;
    }
    return null;
}

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

pub const DispositionReason = enum { merged, merged_pr, upstream_gone, unmerged, default_branch };

pub const BranchDisposition = struct {
    branch: []const u8,
    /// True when the commits survive elsewhere, so deleting the branch loses nothing.
    safe: bool,
    /// Commits on the branch that the default branch does not have.
    unmerged: u32,
    reason: DispositionReason,
    /// The pull request that vouched for the branch, when that is what did.
    pr: u32 = 0,

    /// The same verdict, with GitHub's answer folded in: it says the branch's pull
    /// request is merged.
    ///
    /// That vouches for commits local ancestry never can. A squash merge rewrites
    /// them, so `merge-base --is-ancestor` will keep failing however long you wait,
    /// and the `[gone]` upstream that stands in for it only appears once the remote
    /// branch has been deleted *and* pruned. A merged pull request is the state
    /// both of those are trying to infer.
    ///
    /// Never overrides a verdict that already stands: the default branch stays
    /// undeletable whatever a pull request says, and a plain merge is a better
    /// reason than this one.
    pub fn withMergedPr(self: BranchDisposition, number: u32) BranchDisposition {
        if (self.safe or self.reason == .default_branch) return self;
        return .{
            .branch = self.branch,
            .safe = true,
            .unmerged = self.unmerged,
            .reason = .merged_pr,
            .pr = number,
        };
    }

    /// Whether git has to be told not to re-check the merge itself.
    ///
    /// It re-checks against HEAD and the branch's own upstream, and that is the
    /// whole of what it can see. `upstream_gone` and `merged_pr` are both ways of
    /// surviving a rewrite those two cannot describe, so they need `-D` outright.
    /// A plain merge asks for `-d` and keeps git's second opinion — which it can
    /// still withhold, since ancestry here is judged against `origin/<default>` as
    /// well, and that is a ref `-d` never consults. `deleteVerified` is where that
    /// refusal is dealt with.
    pub fn needsForce(self: BranchDisposition) bool {
        return self.reason != .merged;
    }
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

/// The leading part of `template` that does not depend on the branch, i.e. the
/// prefix shared by every path it renders. Tells worktrees lcc created from ones
/// added by hand. Comes back empty for a template that opens with a branch
/// placeholder — such a template attributes nothing.
pub fn worktreePathPrefix(
    gpa: std.mem.Allocator,
    template: []const u8,
    repo_root: []const u8,
) ![]u8 {
    // NUL cannot appear in a path, so it cannot collide with whatever the
    // repo placeholders expand to.
    const rendered = try renderWorktreePath(gpa, template, repo_root, "\x00");
    const cut = std.mem.indexOfScalar(u8, rendered, 0) orelse return rendered;
    defer gpa.free(rendered);
    return gpa.dupe(u8, rendered[0..cut]);
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

test "worktreePathPrefix cuts the template at the branch" {
    const gpa = std.testing.allocator;

    const sibling = try worktreePathPrefix(gpa, "{repoParent}/{repoName}.worktrees/{branchLeaf}", "/tmp/proj");
    defer gpa.free(sibling);
    try std.testing.expectEqualStrings("/tmp/proj.worktrees/", sibling);

    const nested = try worktreePathPrefix(gpa, "{repoRoot}/.lcc/worktrees/{branchLeaf}", "/tmp/proj");
    defer gpa.free(nested);
    try std.testing.expectEqualStrings("/tmp/proj/.lcc/worktrees/", nested);

    // A branch baked into the directory name, not just a segment of its own.
    const infix = try worktreePathPrefix(gpa, "{repoRoot}/wt-{branch}-x", "/tmp/proj");
    defer gpa.free(infix);
    try std.testing.expectEqualStrings("/tmp/proj/wt-", infix);

    // No branch placeholder at all: the whole rendered path is the prefix.
    const fixed = try worktreePathPrefix(gpa, "{repoRoot}/wt", "/tmp/proj");
    defer gpa.free(fixed);
    try std.testing.expectEqualStrings("/tmp/proj/wt", fixed);

    const leading = try worktreePathPrefix(gpa, "{branchLeaf}", "/tmp/proj");
    defer gpa.free(leading);
    try std.testing.expectEqualStrings("", leading);
}

test "worktreeForBranch matches on the branch, not the path" {
    const entries = [_]WorktreeEntry{
        .{ .path = "/r", .branch = "main", .head = "a", .locked = false, .prunable = false, .is_main = true },
        // The path is no longer what the template would render — a renamed issue,
        // or a worktree added by hand. The branch is what settles it.
        .{ .path = "/elsewhere/old", .branch = "feature/pe-1-x", .head = "b", .locked = false, .prunable = false, .is_main = false },
        .{ .path = "/r/detached", .branch = null, .head = "c", .locked = false, .prunable = false, .is_main = false },
    };

    try std.testing.expectEqualStrings("/elsewhere/old", worktreeForBranch(&entries, "feature/pe-1-x").?.path);
    try std.testing.expect(worktreeForBranch(&entries, "main").?.is_main);
    try std.testing.expect(worktreeForBranch(&entries, "feature/pe-2-y") == null);
    // A prefix of a branch name is a different branch.
    try std.testing.expect(worktreeForBranch(&entries, "feature/pe-1") == null);
}

test "repoRoot answers the main worktree from inside a linked worktree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);

    const main = try std.fs.path.join(gpa, &.{ base, "proj" });
    defer gpa.free(main);
    const linked = try std.fs.path.join(gpa, &.{ base, "proj.worktrees", "x" });
    defer gpa.free(linked);

    try runGit(gpa, io, base, &.{ "init", "-q", "-b", "master", "proj" });
    try runGit(gpa, io, main, &.{ "commit", "-q", "--allow-empty", "-m", "init" });
    try runGit(gpa, io, main, &.{ "worktree", "add", "-q", linked, "-b", "feature/x" });

    const from_main = try repoRoot(gpa, io, main);
    defer gpa.free(from_main);
    const from_linked = try repoRoot(gpa, io, linked);
    defer gpa.free(from_linked);

    // The bug this pins: `--show-toplevel` answers the worktree, so a template
    // like `{repoParent}/{repoName}.worktrees/…` nested itself one level deeper
    // on every start from inside a worktree.
    const toplevel = try exec.capture(gpa, io, &.{ "git", "rev-parse", "--show-toplevel" }, linked);
    defer gpa.free(toplevel);
    try std.testing.expect(!std.mem.eql(u8, toplevel, from_linked));

    try std.testing.expectEqualStrings(from_main, from_linked);

    // `root` anchors derived paths, but "the current branch" is still the one
    // checked out where lcc was invoked — `start` offers it as the base.
    const repo: Repo = .{ .gpa = gpa, .io = io, .root = from_main, .cwd = linked };
    const branch = (try repo.currentBranch()).?;
    defer gpa.free(branch);
    try std.testing.expectEqualStrings("feature/x", branch);
}

test "a squash-merged branch reads as unmerged until a pull request vouches for it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const origin = try std.fs.path.join(arena, &.{ base, "origin.git" });
    const proj = try std.fs.path.join(arena, &.{ base, "proj" });

    try runGit(gpa, io, base, &.{ "init", "-q", "--bare", "origin.git" });
    try runGit(gpa, io, base, &.{ "init", "-q", "-b", "master", "proj" });
    try runGit(gpa, io, proj, &.{ "commit", "-q", "--allow-empty", "-m", "init" });
    try runGit(gpa, io, proj, &.{ "remote", "add", "origin", origin });
    try runGit(gpa, io, proj, &.{ "push", "-q", "-u", "origin", "master" });

    try runGit(gpa, io, proj, &.{ "checkout", "-q", "-b", "feature/x" });
    try runGit(gpa, io, proj, &.{ "commit", "-q", "--allow-empty", "-m", "the work" });
    try runGit(gpa, io, proj, &.{ "push", "-q", "-u", "origin", "feature/x" });

    // The squash: master gains the same work under a different SHA, and the remote
    // branch stays — the repo setting that deletes it on merge is off.
    try runGit(gpa, io, proj, &.{ "checkout", "-q", "master" });
    try runGit(gpa, io, proj, &.{ "commit", "-q", "--allow-empty", "-m", "squashed feature/x" });
    try runGit(gpa, io, proj, &.{ "push", "-q", "origin", "master" });

    const repo: Repo = .{ .gpa = arena, .io = io, .root = proj };
    try repo.fetchPrune();

    // The bug this pins: the work is safely in master, and neither local signal can
    // say so. Ancestry fails because the SHA changed, and the upstream is not gone
    // because the remote branch is still there — so `lcc remove --merged` offered
    // nothing right after the merge, which is exactly when it gets run.
    const local = try repo.branchDisposition("feature/x");
    try std.testing.expect(!local.safe);
    try std.testing.expectEqual(DispositionReason.unmerged, local.reason);
    try std.testing.expectEqual(@as(u32, 1), local.unmerged);

    const vouched = local.withMergedPr(412);
    try std.testing.expect(vouched.safe);
    try std.testing.expectEqual(DispositionReason.merged_pr, vouched.reason);
    try std.testing.expectEqual(@as(u32, 412), vouched.pr);
    // `-d` would still refuse: the commits are not in master's ancestry and never
    // will be.
    try std.testing.expect(vouched.needsForce());
    // The count survives the upgrade — it is what the confirmation shows.
    try std.testing.expectEqual(@as(u32, 1), vouched.unmerged);
}

test "a branch merged where only origin can see it still gets deleted" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const origin = try std.fs.path.join(arena, &.{ base, "origin.git" });
    const proj = try std.fs.path.join(arena, &.{ base, "proj" });
    const other = try std.fs.path.join(arena, &.{ base, "other" });

    try runGit(gpa, io, base, &.{ "init", "-q", "--bare", "origin.git" });
    try runGit(gpa, io, base, &.{ "init", "-q", "-b", "master", "proj" });
    try runGit(gpa, io, proj, &.{ "commit", "-q", "--allow-empty", "-m", "init" });
    try runGit(gpa, io, proj, &.{ "remote", "add", "origin", origin });
    try runGit(gpa, io, proj, &.{ "push", "-q", "-u", "origin", "master" });

    try runGit(gpa, io, proj, &.{ "checkout", "-q", "-b", "feature/x" });
    try runGit(gpa, io, proj, &.{ "commit", "-q", "--allow-empty", "-m", "the work" });
    try runGit(gpa, io, proj, &.{ "push", "-q", "-u", "origin", "feature/x" });
    try runGit(gpa, io, proj, &.{ "checkout", "-q", "master" });

    // The merge happens elsewhere, the way it really does: on GitHub, followed by
    // the remote branch being deleted. Nothing pulls master here afterwards.
    try runGit(gpa, io, base, &.{ "clone", "-q", origin, "other" });
    // A bare repo's HEAD names whatever `init.defaultBranch` says, which need not be
    // the branch that was pushed — so the clone is put on master explicitly.
    try runGit(gpa, io, other, &.{ "checkout", "-q", "-B", "master", "origin/master" });
    try runGit(gpa, io, other, &.{ "merge", "-q", "--no-ff", "origin/feature/x", "-m", "merge" });
    try runGit(gpa, io, other, &.{ "push", "-q", "origin", "HEAD:master" });
    try runGit(gpa, io, other, &.{ "push", "-q", "origin", "--delete", "feature/x" });

    const repo: Repo = .{ .gpa = arena, .io = io, .root = proj };
    try repo.fetchPrune();

    // lcc sees the merge, because it looks at origin/master too.
    const d = try repo.branchDisposition("feature/x");
    try std.testing.expect(d.safe);
    try std.testing.expectEqual(DispositionReason.merged, d.reason);

    // git does not: local master is behind, and the upstream that could have
    // vouched was pruned a moment ago by lcc's own fetch. `-d` alone refuses.
    try std.testing.expectError(Error.GitFailed, repo.deleteBranch("feature/x", false));
    try std.testing.expect(std.mem.indexOf(u8, last_error, "not fully merged") != null);

    try std.testing.expect(try repo.deleteVerified(d));
    try std.testing.expect(!repo.succeeds(&.{ "git", "rev-parse", "--verify", "-q", "refs/heads/feature/x" }));
}

test "withMergedPr never overrides a verdict that already stands" {
    const merged: BranchDisposition = .{ .branch = "b", .safe = true, .unmerged = 0, .reason = .merged };
    // A plain merge is the better reason, and it is the one `-d` accepts.
    try std.testing.expectEqual(DispositionReason.merged, merged.withMergedPr(1).reason);
    try std.testing.expect(!merged.needsForce());

    // The default branch is not deletable, whatever pull request came off it.
    const base: BranchDisposition = .{ .branch = "master", .safe = false, .unmerged = 0, .reason = .default_branch };
    const still_base = base.withMergedPr(2);
    try std.testing.expectEqual(DispositionReason.default_branch, still_base.reason);
    try std.testing.expect(!still_base.safe);

    const gone: BranchDisposition = .{ .branch = "b", .safe = true, .unmerged = 3, .reason = .upstream_gone };
    try std.testing.expectEqual(DispositionReason.upstream_gone, gone.withMergedPr(3).reason);
    try std.testing.expect(gone.needsForce());
}

fn runGit(gpa: std.mem.Allocator, io: Io, cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    // The test repo must not depend on the developer's global git config.
    try argv.appendSlice(gpa, &.{
        "git",
        "-c", "user.email=lcc@example.com",
        "-c", "user.name=lcc",
        "-c", "commit.gpgsign=false",
    });
    try argv.appendSlice(gpa, args);

    const out = try exec.run(gpa, io, argv.items, cwd);
    defer out.deinit(gpa);
    if (!out.ok()) {
        std.debug.print("git {s} failed: {s}\n", .{ args[0], exec.message(out) });
        return error.GitFailed;
    }
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
