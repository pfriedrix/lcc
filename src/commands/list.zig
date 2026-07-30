//! `lcc list` — a dashboard of the worktrees in the current repo. Working-tree
//! state, drift from the upstream, and how the work is tracked, in one screen.
//!
//! Everything local comes from two git calls plus one `git status` per worktree.
//! The PR and Linear columns are one batched request each, and both degrade to a
//! dash when they cannot be answered — an unauthenticated shell still gets the
//! rest of the table.
//!
//! None of that work depends on any of the rest of it, so none of it waits: the
//! two hosts, the `git status` calls and the transcript scan all go out at once
//! and the table is assembled from whatever comes back. Done in sequence the
//! network alone was most of the command's runtime, and the slower of the two
//! round trips is now the whole of it.
//!
//! What that still cannot fix is that a round trip is half a second no matter
//! how little is being asked. So the two answers are cached for a few minutes —
//! see `remote_cache` — and `--refresh` is how you say you want them asked again.

const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const config = @import("../config.zig");
const cp = @import("../claude_projects.zig");
const disk = @import("../disk.zig");
const git = @import("../git.zig");
const github = @import("../github.zig");
const linear = @import("../linear.zig");
const oauth = @import("../oauth.zig");
const rc = @import("../remote_cache.zig");
const ui = @import("../ui.zig");
const usage = @import("../usage.zig");

pub const Opts = struct {
    /// Skip the two network columns.
    local: bool = false,
    /// Show what each worktree has spent on Claude Code. On by default: the
    /// question "how much has this task cost" comes up every time the dashboard
    /// does. Off is for when reading the transcripts is not worth the wait.
    tokens: bool = true,
    /// Ask GitHub and Linear again instead of reusing a recent answer. For the
    /// moment right after merging a PR, when the cached state is the one thing
    /// you know to be wrong.
    refresh: bool = false,
};

const Tree = enum { clean, dirty, missing };

const Row = struct {
    choice: app_mod.Choice,
    branch: []const u8,
    tree: Tree,
    status: []const u8,
    sync: []const u8,
    /// True once the remote branch the worktree tracked has been deleted.
    remote_gone: bool,
    age: []const u8,
    /// Context tokens this worktree's Claude Code sessions have read, or a dash
    /// when it has none and when the column is off.
    tokens: []const u8,
    pr: []const u8,
    pr_state: ?github.State,
    issue: []const u8,
};

pub fn run(app: app_mod.App, opts: Opts) !void {
    const repo = try app.repo();
    const choices = try app_mod.worktreeChoices(app, repo);

    if (choices.len == 0) {
        app.ui.hint("No worktrees.", .{});
        return;
    }

    const now = app_mod.nowSeconds(app.io);

    // Only branches that name an issue are worth asking Linear about, and the
    // identifiers they resolve to are also what says whether a cached answer
    // covered this set of worktrees.
    const refs = try issueRefs(app, choices);
    const asked = try identifiers(app, refs);

    // The cache is read here, before anything is spawned, and written after
    // everything has been joined. A task never touches it, so there is nothing
    // for two of them to race over.
    var cache: rc.Cache = if (opts.local)
        .none(app.gpa, app.io)
    else
        .open(app.gpa, app.io, app.environ);

    var prs: PrColumn = .{};
    var issues: IssueColumn = .{};
    if (!opts.local and !opts.refresh) {
        if (cache.prs(repo.root, now)) |hit| {
            prs = .{ .list = hit.list, .cached_age = hit.age_seconds };
        }
        if (asked.len > 0) {
            if (cache.issues(repo.root, asked, now)) |hit| {
                issues = .{ .list = hit.list, .cached_age = hit.age_seconds };
            }
        }
    }

    var statuses: []const git.BranchStatus = &.{};
    const dirty = try app.gpa.alloc(?u32, choices.len);
    @memset(dirty, null);
    const spend = try app.gpa.alloc([]const u8, choices.len);
    @memset(spend, "—");

    // Everything slow, at once. `git status` walks each worktree, the two columns
    // wait on two different hosts, and the token scan reads `~/.claude` — four
    // kinds of waiting with nothing to say to each other.
    {
        var group: Io.Group = .init;
        group.async(app.io, branchStatusTask, .{ repo, &statuses });
        for (choices, 0..) |choice, i| {
            group.async(app.io, dirtyTask, .{ repo, choice.entry.path, &dirty[i] });
        }
        if (opts.tokens) group.async(app.io, tokenTask, .{ app, choices, spend });
        if (!opts.local) {
            if (prs.cached_age == null) group.async(app.io, prTask, .{ app, repo, &prs });
            if (issues.cached_age == null and refs.len > 0) {
                group.async(app.io, issueTask, .{ app, refs, &issues });
            }
        }
        try group.await(app.io);
    }

    if (prs.fetched) cache.putPrs(repo.root, now, prs.list);
    if (issues.fetched) cache.putIssues(repo.root, asked, now, issues.list);
    cache.save(now);

    const rows = try app.gpa.alloc(Row, choices.len);
    for (choices, 0..) |choice, i| {
        rows[i] = try buildRow(app, choice, statuses, dirty[i], prs.list, issues.list, now);
        rows[i].tokens = spend[i];
    }

    try render(app, rows, opts);

    if (!opts.local) {
        if (prs.note) |note| app.ui.hint("{s}", .{note});
        if (issues.note) |note| app.ui.hint("{s}", .{note});
        if (try cacheNote(app.gpa, prs, issues)) |note| app.ui.hint("{s}", .{note});
    }
}

/// The issues the worktrees on screen belong to, in the order the branches give
/// them. Duplicates are left in: `fetchIssueStatuses` folds them itself, and
/// `identifiers` is what the cache is keyed on.
fn issueRefs(app: app_mod.App, choices: []const app_mod.Choice) ![]const linear.Ref {
    var refs: std.ArrayList(linear.Ref) = .empty;
    for (choices) |choice| {
        const branch = choice.entry.branch orelse continue;
        const ref = linear.refFromBranch(branch) orelse continue;
        try refs.append(app.gpa, ref);
    }
    return refs.toOwnedSlice(app.gpa);
}

/// `PE-224` for each distinct ref, uppercased the way Linear stores keys and
/// sorted, so the same set of worktrees always produces the same list.
fn identifiers(app: app_mod.App, refs: []const linear.Ref) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (refs) |ref| {
        const key = try std.ascii.allocUpperString(app.gpa, ref.team);
        const identifier = try std.fmt.allocPrint(app.gpa, "{s}-{d}", .{ key, ref.number });
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen, identifier)) break;
        } else try out.append(app.gpa, identifier);
    }
    const names = try out.toOwnedSlice(app.gpa);
    std.mem.sort([]const u8, names, {}, lessThan);
    return names;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// One column's worth of pull requests, and why it is missing when it is.
const PrColumn = struct {
    list: []const github.PullRequest = &.{},
    note: ?[]const u8 = null,
    /// How old the cached answer is, when that is where these came from.
    cached_age: ?i64 = null,
    /// Came off the network this run, so it is worth storing.
    fetched: bool = false,
};

const IssueColumn = struct {
    list: []const linear.IssueStatus = &.{},
    note: ?[]const u8 = null,
    cached_age: ?i64 = null,
    fetched: bool = false,
};

/// The tasks below run on the thread pool, which is why none of them return an
/// error and none of them touch `app.ui`: a column that cannot be answered
/// reports that in its own result, and the caller decides what to print.
fn branchStatusTask(repo: git.Repo, out: *[]const git.BranchStatus) void {
    // One call for every branch's upstream, drift and tip date.
    out.* = repo.branchStatuses() catch &.{};
}

fn dirtyTask(repo: git.Repo, worktree_path: []const u8, out: *?u32) void {
    out.* = repo.dirtyCount(worktree_path);
}

/// The TOKENS cell for each worktree, in the order given. Reading transcripts is
/// the one part of this dashboard that scales with how much Claude Code has been
/// used rather than with the size of the repo, so `--no-tokens` turns it off.
fn tokenTask(app: app_mod.App, choices: []const app_mod.Choice, cells: [][]const u8) void {
    const cp_root = cp.root(app.gpa, app.environ) catch return;
    const projects = cp.list(app.gpa, app.io, cp_root) catch return;

    var scanner: usage.Scanner = .init(app.gpa, app.io, .open(app.gpa, app.io, app.environ));
    defer scanner.deinit();

    for (choices, 0..) |choice, i| {
        const totals = scanner.worktree(projects, choice.entry.path) catch continue;
        if (totals.empty()) continue;
        cells[i] = std.fmt.allocPrint(app.gpa, "{f}", .{
            ui.count(totals.counts.contextTokens()),
        }) catch continue;
    }
}

fn prTask(app: app_mod.App, repo: git.Repo, out: *PrColumn) void {
    if (github.list(app.gpa, app.io, repo.root)) |list| {
        out.list = list;
        out.fetched = true;
    } else {
        out.note = "PR column skipped — `gh` could not answer. Is it installed and authenticated?";
    }
}

fn issueTask(app: app_mod.App, refs: []const linear.Ref, out: *IssueColumn) void {
    const cfg = config.load(app.gpa, app.io, app.environ) catch {
        out.note = "Linear column skipped — could not read the config.";
        return;
    };
    if (oauth.getToken(app.gpa) == null) {
        out.note = "Linear column needs `lcc auth`.";
        return;
    }
    const token = oauth.ensureFreshToken(app.gpa, app.io, cfg.clientId) catch {
        out.note = "Could not refresh the Linear token — run `lcc auth`.";
        return;
    };
    out.list = linear.fetchIssueStatuses(app.gpa, app.io, token, refs) catch {
        out.note = std.fmt.allocPrint(app.gpa, "Linear lookup failed: {s}", .{
            linear.last_message,
        }) catch "Linear lookup failed.";
        return;
    };
    out.fetched = true;
}

/// Says which columns were answered from the cache and how stale they are. A
/// cache nobody can see is a cache that gets blamed for showing the wrong thing.
fn cacheNote(gpa: std.mem.Allocator, prs: PrColumn, issues: IssueColumn) !?[]const u8 {
    const which: []const u8 = if (prs.cached_age != null and issues.cached_age != null)
        "PR and LINEAR"
    else if (prs.cached_age != null)
        "PR"
    else if (issues.cached_age != null)
        "LINEAR"
    else
        return null;

    // The older of the two is the honest number to show for both.
    const age = @max(prs.cached_age orelse 0, issues.cached_age orelse 0);
    // `ui.age` renders anything under a minute as "now", which does not take an
    // "ago" — and inside a five-minute TTL that is the common case.
    const when: []const u8 = if (age < 60)
        "just now"
    else
        try std.fmt.allocPrint(gpa, "{f} ago", .{ui.age(age)});

    return try std.fmt.allocPrint(gpa, "{s} from cache, asked {s} — `lcc list --refresh` to re-check.", .{
        which,
        when,
    });
}

fn buildRow(
    app: app_mod.App,
    choice: app_mod.Choice,
    statuses: []const git.BranchStatus,
    count: ?u32,
    prs: []const github.PullRequest,
    issues: []const linear.IssueStatus,
    now: i64,
) !Row {
    const branch = if (choice.entry.branch) |b|
        try app.gpa.dupe(u8, b)
    else
        try std.fmt.allocPrint(app.gpa, "{s} (detached)", .{app_mod.shortHead(choice.entry.head)});

    const tree: Tree = if (count) |n|
        if (n == 0) .clean else .dirty
    else
        .missing;
    const status = switch (tree) {
        .clean => try app.gpa.dupe(u8, "clean"),
        .dirty => try std.fmt.allocPrint(app.gpa, "{d} dirty", .{count.?}),
        .missing => try app.gpa.dupe(u8, "missing"),
    };

    const found = if (choice.entry.branch) |b| findStatus(statuses, b) else null;

    var sync: []const u8 = "—";
    var remote_gone = false;
    var age: []const u8 = "—";
    if (found) |s| {
        if (s.committed_at > 0) {
            age = try std.fmt.allocPrint(app.gpa, "{f}", .{ui.age(now - s.committed_at)});
        }
        if (s.gone) {
            sync = "gone";
            remote_gone = true;
        } else if (s.upstream == null) {
            sync = "unpushed";
        } else {
            sync = try std.fmt.allocPrint(app.gpa, "↑{d} ↓{d}", .{ s.ahead, s.behind });
        }
    }

    var pr: []const u8 = "—";
    var pr_state: ?github.State = null;
    if (choice.entry.branch) |b| {
        if (github.forBranch(prs, b)) |found_pr| {
            pr = found_pr.describe(app.gpa);
            pr_state = found_pr.state;
        }
    }

    var issue: []const u8 = "—";
    if (choice.entry.branch) |b| {
        if (linear.statusForBranch(issues, b)) |found_issue| issue = found_issue.state_name;
    }

    return .{
        .choice = choice,
        .branch = branch,
        .tree = tree,
        .status = status,
        .sync = sync,
        .remote_gone = remote_gone,
        .age = age,
        // Filled in by the caller — the token scan is one pass for every row.
        .tokens = "—",
        .pr = pr,
        .pr_state = pr_state,
        .issue = issue,
    };
}

fn findStatus(statuses: []const git.BranchStatus, branch: []const u8) ?git.BranchStatus {
    for (statuses) |status| {
        if (std.mem.eql(u8, status.branch, branch)) return status;
    }
    return null;
}

const Widths = struct {
    branch: usize,
    status: usize,
    sync: usize,
    age: usize,
    tokens: usize,
    pr: usize,
    issue: usize,
};

fn measure(rows: []const Row, opts: Opts) Widths {
    var w: Widths = .{
        .branch = "BRANCH".len,
        .status = "STATUS".len,
        .sync = "SYNC".len,
        .age = "AGE".len,
        .tokens = if (opts.tokens) "TOKENS".len else 0,
        .pr = if (opts.local) 0 else "PR".len,
        .issue = if (opts.local) 0 else "LINEAR".len,
    };
    for (rows) |row| {
        w.branch = @max(w.branch, ui.displayWidth(row.branch));
        w.status = @max(w.status, ui.displayWidth(row.status));
        w.sync = @max(w.sync, ui.displayWidth(row.sync));
        w.age = @max(w.age, ui.displayWidth(row.age));
        if (opts.tokens) w.tokens = @max(w.tokens, ui.displayWidth(row.tokens));
        if (!opts.local) {
            w.pr = @max(w.pr, ui.displayWidth(row.pr));
            w.issue = @max(w.issue, ui.displayWidth(row.issue));
        }
    }
    return w;
}

fn render(app: app_mod.App, rows: []const Row, opts: Opts) !void {
    const w = measure(rows, opts);

    var header: std.ArrayList(u8) = .empty;
    try header.appendSlice(app.gpa, try std.fmt.allocPrint(app.gpa, "{f}  {f}  {f}  {f}", .{
        ui.pad("BRANCH", w.branch),
        ui.pad("STATUS", w.status),
        ui.pad("SYNC", w.sync),
        ui.pad("AGE", w.age),
    }));
    if (opts.tokens) {
        try header.appendSlice(app.gpa, try std.fmt.allocPrint(app.gpa, "  {f}", .{
            ui.pad("TOKENS", w.tokens),
        }));
    }
    if (!opts.local) {
        try header.appendSlice(app.gpa, try std.fmt.allocPrint(app.gpa, "  {f}  {f}", .{
            ui.pad("PR", w.pr),
            ui.pad("LINEAR", w.issue),
        }));
    }
    try header.appendSlice(app.gpa, "  PATH");
    app.ui.hint("{s}", .{header.items});

    for (rows) |row| {
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(app.gpa, try std.fmt.allocPrint(app.gpa, "{f}  {f}  {f}  {f}", .{
            ui.cyan(try std.fmt.allocPrint(app.gpa, "{f}", .{ui.pad(row.branch, w.branch)})),
            paintStatus(row, try pad(app.gpa, row.status, w.status)),
            paintSync(row, try pad(app.gpa, row.sync, w.sync)),
            ui.dim(try pad(app.gpa, row.age, w.age)),
        }));
        if (opts.tokens) {
            try line.appendSlice(app.gpa, try std.fmt.allocPrint(app.gpa, "  {f}", .{
                ui.pad(row.tokens, w.tokens),
            }));
        }
        if (!opts.local) {
            try line.appendSlice(app.gpa, try std.fmt.allocPrint(app.gpa, "  {f}  {f}", .{
                paintPr(row, try pad(app.gpa, row.pr, w.pr)),
                ui.pad(row.issue, w.issue),
            }));
        }
        try line.appendSlice(app.gpa, try std.fmt.allocPrint(app.gpa, "  {f}{f}{f}{f}", .{
            ui.dim(disk.abbreviate(app.gpa, app.environ, row.choice.entry.path)),
            ui.yellow(if (row.choice.entry.locked) "  locked" else ""),
            ui.red(if (row.choice.entry.prunable) "  prunable" else ""),
            ui.dim(if (row.choice.managed) "  lcc" else ""),
        }));
        app.ui.info("{s}", .{line.items});
    }
}

fn paintStatus(row: Row, text: []const u8) ui.Painted {
    return switch (row.tree) {
        .clean => ui.green(text),
        .dirty => ui.yellow(text),
        .missing => ui.red(text),
    };
}

/// Drift is context, not a verdict — only a deleted upstream is worth an alarm,
/// because it means the branch has nowhere left to push.
fn paintSync(row: Row, text: []const u8) ui.Painted {
    return if (row.remote_gone) ui.yellow(text) else ui.dim(text);
}

fn paintPr(row: Row, text: []const u8) ui.Painted {
    const state = row.pr_state orelse return ui.dim(text);
    return switch (state) {
        .open => ui.green(text),
        .merged => ui.dim(text),
        .closed => ui.red(text),
    };
}

/// `ui.pad` renders lazily, which colour wrapping cannot use — the escape has to
/// go around text of a known length.
fn pad(gpa: std.mem.Allocator, text: []const u8, width: usize) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{f}", .{ui.pad(text, width)});
}

test "cacheNote names only the columns that came from the cache" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Nothing cached — nothing to say.
    try std.testing.expect(try cacheNote(arena, .{}, .{}) == null);

    const both = (try cacheNote(arena, .{ .cached_age = 120 }, .{ .cached_age = 200 })).?;
    try std.testing.expect(std.mem.startsWith(u8, both, "PR and LINEAR from cache"));
    // The older of the two is what gets shown, not whichever was checked first.
    try std.testing.expect(std.mem.indexOf(u8, both, "3m ago") != null);

    const pr_only = (try cacheNote(arena, .{ .cached_age = 90 }, .{})).?;
    try std.testing.expect(std.mem.startsWith(u8, pr_only, "PR from cache"));
    try std.testing.expect(std.mem.indexOf(u8, pr_only, "LINEAR") == null);

    const issue_only = (try cacheNote(arena, .{}, .{ .cached_age = 90 })).?;
    try std.testing.expect(std.mem.startsWith(u8, issue_only, "LINEAR from cache"));

    // Under a minute reads as "just now": `ui.age` says "now", which cannot take
    // an "ago" after it.
    const fresh = (try cacheNote(arena, .{ .cached_age = 3 }, .{ .cached_age = 3 })).?;
    try std.testing.expect(std.mem.indexOf(u8, fresh, "asked just now") != null);
    try std.testing.expect(std.mem.indexOf(u8, fresh, "now ago") == null);
}

test "identifiers dedupes, uppercases and sorts what Linear will be asked" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app: app_mod.App = .{
        .gpa = arena,
        .io = std.testing.io,
        .environ = undefined,
        .ui = undefined,
    };

    // Two worktrees on the same issue ask about it once, and a branch carrying
    // the key lowercased must land on the same identifier as one that does not.
    const refs = [_]linear.Ref{
        .{ .team = "pe", .number = 270 },
        .{ .team = "PE", .number = 7 },
        .{ .team = "pe", .number = 270 },
    };
    const out = try identifiers(app, &refs);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("PE-270", out[0]);
    try std.testing.expectEqualStrings("PE-7", out[1]);

    try std.testing.expectEqual(@as(usize, 0), (try identifiers(app, &.{})).len);
}

test "measure sizes every column to its widest cell, header included" {
    const rows = [_]Row{
        .{
            .choice = .{ .entry = .{
                .path = "/x",
                .branch = "feature/pe-256-app-hangs",
                .head = "abc",
                .locked = false,
                .prunable = false,
                .is_main = false,
            }, .managed = true },
            .branch = "feature/pe-256-app-hangs",
            .tree = .dirty,
            .status = "3 dirty",
            .sync = "↑2 ↓0",
            .remote_gone = false,
            .age = "2h",
            .tokens = "62.2M",
            .pr = "#412 open",
            .pr_state = .open,
            .issue = "In Progress",
        },
    };

    const full = measure(&rows, .{});
    try std.testing.expectEqual(@as(usize, "feature/pe-256-app-hangs".len), full.branch);
    try std.testing.expectEqual(@as(usize, "3 dirty".len), full.status);
    // Codepoints, not bytes: the arrows are multi-byte.
    try std.testing.expectEqual(@as(usize, 5), full.sync);
    try std.testing.expectEqual(@as(usize, "AGE".len), full.age);
    try std.testing.expectEqual(@as(usize, "#412 open".len), full.pr);
    try std.testing.expectEqual(@as(usize, "In Progress".len), full.issue);
    try std.testing.expectEqual(@as(usize, "TOKENS".len), full.tokens);

    // --local drops the two network columns entirely.
    const local = measure(&rows, .{ .local = true });
    try std.testing.expectEqual(@as(usize, 0), local.pr);
    try std.testing.expectEqual(@as(usize, 0), local.issue);

    // --no-tokens drops its column, and nothing else moves.
    const quiet = measure(&rows, .{ .tokens = false });
    try std.testing.expectEqual(@as(usize, 0), quiet.tokens);
    try std.testing.expectEqual(full.branch, quiet.branch);
}
