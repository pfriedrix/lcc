//! `lcc list` — a dashboard of the worktrees in the current repo. Working-tree
//! state, drift from the upstream, and how the work is tracked, in one screen.
//!
//! Everything local comes from two git calls plus one `git status` per worktree.
//! The PR and Linear columns are one batched request each, and both degrade to a
//! dash when they cannot be answered — an unauthenticated shell still gets the
//! rest of the table.

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
const ui = @import("../ui.zig");
const usage = @import("../usage.zig");

pub const Opts = struct {
    /// Skip the two network columns.
    local: bool = false,
    /// Show what each worktree has spent on Claude Code. On by default: the
    /// question "how much has this task cost" comes up every time the dashboard
    /// does. Off is for when reading the transcripts is not worth the wait.
    tokens: bool = true,
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

    // One call for every branch's upstream, drift and tip date.
    const statuses: []const git.BranchStatus = repo.branchStatuses() catch &.{};
    const now = app_mod.nowSeconds(app.io);

    const remote: Remote = if (opts.local)
        .{}
    else
        try fetchRemote(app, repo, choices);

    const spend = try tokenColumn(app, choices, opts);

    const rows = try app.gpa.alloc(Row, choices.len);
    for (choices, 0..) |choice, i| {
        rows[i] = try buildRow(app, repo, choice, statuses, remote, now);
        rows[i].tokens = spend[i];
    }

    try render(app, rows, opts);

    if (!opts.local) {
        if (remote.pr_note) |note| app.ui.hint("{s}", .{note});
        if (remote.issue_note) |note| app.ui.hint("{s}", .{note});
    }
}

/// The TOKENS cell for each worktree, in the order given. Reading transcripts is
/// the one part of this dashboard that scales with how much Claude Code has been
/// used rather than with the size of the repo, so `--no-tokens` turns it off.
fn tokenColumn(app: app_mod.App, choices: []const app_mod.Choice, opts: Opts) ![]const []const u8 {
    const cells = try app.gpa.alloc([]const u8, choices.len);
    @memset(cells, "—");
    if (!opts.tokens) return cells;

    const cp_root = try cp.root(app.gpa, app.environ);
    const projects = try cp.list(app.gpa, app.io, cp_root);

    var scanner: usage.Scanner = .init(app.gpa, app.io);
    defer scanner.deinit();

    for (choices, 0..) |choice, i| {
        const totals = try scanner.worktree(projects, choice.entry.path);
        if (totals.empty()) continue;
        cells[i] = try std.fmt.allocPrint(app.gpa, "{f}", .{
            ui.count(totals.counts.contextTokens()),
        });
    }
    return cells;
}

/// What the two network lookups produced, plus why a column is missing.
const Remote = struct {
    prs: []const github.PullRequest = &.{},
    issues: []const linear.IssueStatus = &.{},
    pr_note: ?[]const u8 = null,
    issue_note: ?[]const u8 = null,
};

fn fetchRemote(app: app_mod.App, repo: git.Repo, choices: []const app_mod.Choice) !Remote {
    var remote: Remote = .{};

    if (github.list(app.gpa, app.io, repo.root)) |prs| {
        remote.prs = prs;
    } else {
        remote.pr_note = "PR column skipped — `gh` could not answer. Is it installed and authenticated?";
    }

    // Only ask Linear about branches that actually name an issue.
    var refs: std.ArrayList(linear.Ref) = .empty;
    for (choices) |choice| {
        const branch = choice.entry.branch orelse continue;
        const ref = linear.refFromBranch(branch) orelse continue;
        try refs.append(app.gpa, ref);
    }
    if (refs.items.len == 0) return remote;

    const cfg = try config.load(app.gpa, app.io, app.environ);
    if (oauth.getToken(app.gpa) == null) {
        remote.issue_note = "Linear column needs `lcc auth`.";
        return remote;
    }
    const token = oauth.ensureFreshToken(app.gpa, app.io, cfg.clientId) catch {
        remote.issue_note = "Could not refresh the Linear token — run `lcc auth`.";
        return remote;
    };
    remote.issues = linear.fetchIssueStatuses(app.gpa, app.io, token, refs.items) catch {
        remote.issue_note = try std.fmt.allocPrint(app.gpa, "Linear lookup failed: {s}", .{
            linear.last_message,
        });
        return remote;
    };
    return remote;
}

fn buildRow(
    app: app_mod.App,
    repo: git.Repo,
    choice: app_mod.Choice,
    statuses: []const git.BranchStatus,
    remote: Remote,
    now: i64,
) !Row {
    const branch = if (choice.entry.branch) |b|
        try app.gpa.dupe(u8, b)
    else
        try std.fmt.allocPrint(app.gpa, "{s} (detached)", .{app_mod.shortHead(choice.entry.head)});

    const count = repo.dirtyCount(choice.entry.path);
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
        if (github.forBranch(remote.prs, b)) |found_pr| {
            pr = found_pr.describe(app.gpa);
            pr_state = found_pr.state;
        }
    }

    var issue: []const u8 = "—";
    if (choice.entry.branch) |b| {
        if (linear.statusForBranch(remote.issues, b)) |found_issue| issue = found_issue.state_name;
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
