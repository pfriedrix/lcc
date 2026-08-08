const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const cp = @import("../claude_projects.zig");
const dd = @import("../derived_data.zig");
const disk = @import("../disk.zig");
const git = @import("../git.zig");
const github = @import("../github.zig");
const prompt = @import("../prompt.zig");
const rc = @import("../remote_cache.zig");
const ui = @import("../ui.zig");
const usage = @import("../usage.zig");
const xcode = @import("../xcode.zig");

pub const Opts = struct {
    force: bool = false,
    yes: bool = false,
    keep_derived_data: bool = false,
    keep_branch: bool = false,
    keep_xcode: bool = false,
    local: bool = false,
    sessions: bool = false,
    merged: bool = false,
};

const Attached = struct {
    derived: []dd.Sized = &.{},
    sessions: []cp.Sized = &.{},
    xcode: xcode.Open = .{},
    spent: usage.Totals = .{},

    fn reclaimable(self: Attached, sessions_go: bool) u64 {
        var total: u64 = 0;
        for (self.derived) |item| total += item.size;
        if (sessions_go) {
            for (self.sessions) |item| total += item.size;
        }
        return total;
    }
};

const Row = struct {
    choice: ?app_mod.Choice = null,
    branch: ?[]const u8 = null,
    disposition: ?git.BranchDisposition = null,
    attached: Attached = .{},
    dirty: ?u32 = null,
    committed_at: i64 = 0,

    fn entry(self: Row) ?git.WorktreeEntry {
        const choice = self.choice orelse return null;
        return choice.entry;
    }

    fn label(self: Row, gpa: std.mem.Allocator) ![]const u8 {
        if (self.branch) |branch| return branch;
        const found = self.entry() orelse return "—";
        return std.fmt.allocPrint(gpa, "{s} (detached)", .{app_mod.shortHead(found.head)});
    }
};

pub fn run(app: app_mod.App, opts: Opts) !void {
    const repo = try app.repo();
    if (opts.merged) return runMerged(app, repo, opts);

    if (!opts.local and !opts.keep_branch) refresh(app, repo);

    const choices = try app_mod.worktreeChoices(app, repo);
    if (choices.len == 0) {
        app.ui.warn("No worktrees to remove (only the main one exists).", .{});
        return;
    }

    const rows = try app.gpa.alloc(Row, choices.len);
    for (choices, 0..) |choice, i| {
        rows[i] = .{ .choice = choice, .branch = choice.entry.branch };
    }

    if (!opts.keep_branch) {
        try judge(app, repo, rows);
        if (!opts.local) try consultGitHub(app, repo, rows);
    }
    try inspect(app, repo, rows);

    const dd_root = try dd.root(app.gpa, app.io, app.environ);
    const cp_root = try cp.root(app.gpa, app.environ);
    try attach(app, rows, opts, dd_root, cp_root);

    const selected = try select(
        app,
        rows,
        opts,
        "Select worktrees to remove (space toggles, enter confirms):",
        false,
    );
    if (selected.len == 0) {
        app.ui.hint("Nothing selected.", .{});
        return;
    }

    const actionable = try withoutUnsavedWork(app, selected, opts);
    if (actionable.len == 0) return;

    if (!opts.yes) {
        const message = try confirmRemovalsMessage(app, actionable, opts);
        const answer = try prompt.confirm(app.gpa, app.io, message, false) orelse
            std.process.exit(app_mod.cancelled_exit_code);
        if (!answer) {
            app.ui.hint("Aborted.", .{});
            return;
        }
    }

    try removeSelected(app, repo, actionable, opts, dd_root, cp_root);
}

fn branchStatusTask(repo: git.Repo, out: *[]const git.BranchStatus) void {
    out.* = repo.branchStatuses() catch &.{};
}

fn dirtyTask(repo: git.Repo, worktree_path: []const u8, out: *?u32) void {
    out.* = repo.dirtyCount(worktree_path);
}

fn dispositionTask(repo: git.Repo, branch: []const u8, out: *?git.BranchDisposition) void {
    out.* = repo.branchDisposition(branch) catch null;
}

fn judge(app: app_mod.App, repo: git.Repo, rows: []Row) !void {
    var group: Io.Group = .init;
    for (rows) |*row| {
        const branch = row.branch orelse continue;
        group.async(app.io, dispositionTask, .{ repo, branch, &row.disposition });
    }
    try group.await(app.io);
}

fn inspect(app: app_mod.App, repo: git.Repo, rows: []Row) !void {
    var statuses: []const git.BranchStatus = &.{};
    {
        var group: Io.Group = .init;
        group.async(app.io, branchStatusTask, .{ repo, &statuses });
        for (rows) |*row| {
            const found = row.entry() orelse continue;
            group.async(app.io, dirtyTask, .{ repo, found.path, &row.dirty });
        }
        try group.await(app.io);
    }

    for (rows) |*row| {
        const branch = row.branch orelse continue;
        for (statuses) |status| {
            if (!std.mem.eql(u8, status.branch, branch)) continue;
            row.committed_at = status.committed_at;
            break;
        }
    }
}

const headers = .{
    .branch = "BRANCH",
    .merge = "MERGE",
    .status = "STATUS",
    .age = "AGE",
    .frees = "FREES",
    .spent = "SPENT",
    .where = "PATH",
};

const Cells = struct {
    branch: []const u8,
    merge: []const u8,
    status: []const u8,
    age: []const u8,
    frees: []const u8,
    spent: []const u8,
    where: []const u8,
    note: []const u8,
};

const Widths = struct {
    branch: usize = headers.branch.len,
    merge: usize = headers.merge.len,
    status: usize = headers.status.len,
    age: usize = headers.age.len,
    frees: usize = headers.frees.len,
    spent: usize = headers.spent.len,
};

fn measure(cells: []const Cells) Widths {
    var w: Widths = .{};
    for (cells) |cell| {
        w.branch = @max(w.branch, ui.displayWidth(cell.branch));
        w.merge = @max(w.merge, ui.displayWidth(cell.merge));
        w.status = @max(w.status, ui.displayWidth(cell.status));
        w.age = @max(w.age, ui.displayWidth(cell.age));
        w.frees = @max(w.frees, ui.displayWidth(cell.frees));
        w.spent = @max(w.spent, ui.displayWidth(cell.spent));
    }
    return w;
}

fn headerLine(gpa: std.mem.Allocator, w: Widths) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{f}  {f}  {f}  {f}  {f}  {f}  {s}", .{
        ui.pad(headers.branch, w.branch),
        ui.pad(headers.merge, w.merge),
        ui.pad(headers.status, w.status),
        ui.pad(headers.age, w.age),
        ui.pad(headers.frees, w.frees),
        ui.pad(headers.spent, w.spent),
        headers.where,
    });
}

fn rowLine(gpa: std.mem.Allocator, cell: Cells, w: Widths) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{f}  {f}  {f}  {f}  {f}  {f}  {s}{s}", .{
        ui.pad(cell.branch, w.branch),
        ui.pad(cell.merge, w.merge),
        ui.pad(cell.status, w.status),
        ui.pad(cell.age, w.age),
        ui.pad(cell.frees, w.frees),
        ui.pad(cell.spent, w.spent),
        cell.where,
        cell.note,
    });
}

fn cellsFor(app: app_mod.App, row: Row, opts: Opts, now: i64) !Cells {
    return .{
        .branch = try row.label(app.gpa),
        .merge = try mergeCell(app.gpa, row.disposition),
        .status = try statusCell(app.gpa, row),
        .age = try ageCell(app.gpa, row.committed_at, now),
        .frees = try sizeCell(app.gpa, row.attached.reclaimable(opts.sessions)),
        .spent = try spentCell(app.gpa, row.attached.spent),
        .where = if (row.entry()) |found|
            disk.abbreviate(app.gpa, app.environ, found.path)
        else
            "branch only — no worktree left",
        .note = try noteCell(app.gpa, row),
    };
}

fn mergeCell(gpa: std.mem.Allocator, disposition: ?git.BranchDisposition) ![]const u8 {
    const d = disposition orelse return "—";
    return switch (d.reason) {
        .merged => "merged",
        .merged_pr => try std.fmt.allocPrint(gpa, "merged #{d}", .{d.pr}),
        .upstream_gone => "remote gone",
        .default_branch => "default branch",
        .unmerged => if (d.unmerged == 0)
            "unmerged"
        else
            try std.fmt.allocPrint(gpa, "{d} unmerged", .{d.unmerged}),
    };
}

fn statusCell(gpa: std.mem.Allocator, row: Row) ![]const u8 {
    if (row.entry() == null) return "—";
    const count = row.dirty orelse return "missing";
    if (count == 0) return "clean";
    return std.fmt.allocPrint(gpa, "{d} dirty", .{count});
}

fn ageCell(gpa: std.mem.Allocator, committed_at: i64, now: i64) ![]const u8 {
    if (committed_at <= 0) return "—";
    return std.fmt.allocPrint(gpa, "{f}", .{ui.age(now - committed_at)});
}

fn sizeCell(gpa: std.mem.Allocator, size: u64) ![]const u8 {
    if (size == 0) return "—";
    return std.fmt.allocPrint(gpa, "{f}", .{ui.bytes(size)});
}

fn spentCell(gpa: std.mem.Allocator, spent: usage.Totals) ![]const u8 {
    if (spent.empty()) return "—";
    return std.fmt.allocPrint(gpa, "{f}", .{ui.count(spent.counts.contextTokens())});
}

fn noteCell(gpa: std.mem.Allocator, row: Row) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (row.choice) |choice| {
        if (choice.entry.locked) try out.appendSlice(gpa, "  locked");
        if (choice.entry.prunable) try out.appendSlice(gpa, "  prunable");
        if (choice.managed) try out.appendSlice(gpa, "  lcc");
    }
    if (row.attached.xcode.unsaved.len > 0) {
        try out.appendSlice(gpa, "  — unsaved in Xcode");
    } else if (row.attached.xcode.workspaces.len > 0) {
        try out.appendSlice(gpa, "  — open in Xcode");
    }
    return out.toOwnedSlice(gpa);
}

fn select(
    app: app_mod.App,
    rows: []const Row,
    opts: Opts,
    message: []const u8,
    checked_default: bool,
) ![]const Row {
    const now = app_mod.nowSeconds(app.io);
    const cells = try app.gpa.alloc(Cells, rows.len);
    for (rows, 0..) |row, i| cells[i] = try cellsFor(app, row, opts, now);
    const w = measure(cells);

    const items = try app.gpa.alloc(prompt.Item, rows.len);
    for (cells, 0..) |cell, i| items[i] = .{ .label = try rowLine(app.gpa, cell, w) };

    app.ui.flush();
    const chosen = try prompt.checkbox(
        app.gpa,
        app.io,
        message,
        try headerLine(app.gpa, w),
        items,
        checked_default,
    ) orelse std.process.exit(app_mod.cancelled_exit_code);
    return rowsAt(app.gpa, rows, chosen);
}

fn rowsAt(gpa: std.mem.Allocator, rows: []const Row, indices: []const usize) ![]const Row {
    const subset = try gpa.alloc(Row, indices.len);
    for (indices, 0..) |index, i| subset[i] = rows[index];
    return subset;
}

fn confirmRemovalsMessage(app: app_mod.App, rows: []const Row, opts: Opts) ![]u8 {
    if (rows.len == 1) return confirmMessage(app, rows[0], opts);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(app.gpa, try std.fmt.allocPrint(app.gpa, "Remove {d} worktrees?\n", .{rows.len}));
    for (rows) |row| {
        try out.appendSlice(app.gpa, try std.fmt.allocPrint(app.gpa, "\n  {s}\n", .{
            try row.label(app.gpa),
        }));
        try appendConfirmationDetails(app, &out, row, opts);
    }
    return out.toOwnedSlice(app.gpa);
}

fn withoutUnsavedWork(app: app_mod.App, rows: []const Row, opts: Opts) ![]const Row {
    if (opts.force) return rows;

    var actionable: std.ArrayList(Row) = .empty;
    for (rows) |row| {
        if (row.attached.xcode.unsaved.len == 0) {
            try actionable.append(app.gpa, row);
            continue;
        }

        app.ui.warn("Kept {f} — Xcode has unsaved changes in it", .{
            ui.cyan(try row.label(app.gpa)),
        });
        for (row.attached.xcode.unsaved) |doc| app.ui.hint("  {s}", .{doc.path});
        app.ui.hint("  Save them there, or rerun with: lcc remove --force", .{});
    }
    return actionable.toOwnedSlice(app.gpa);
}

fn removeSelected(
    app: app_mod.App,
    repo: git.Repo,
    rows: []const Row,
    opts: Opts,
    dd_root: []const u8,
    cp_root: []const u8,
) !void {
    var removed: usize = 0;
    var kept_sessions: usize = 0;
    var reclaimed: u64 = 0;

    for (rows) |row| {
        const entry = row.entry() orelse continue;
        const label = try row.label(app.gpa);

        if (row.attached.xcode.unsaved.len > 0 and !opts.force) {
            app.ui.warn("Kept {f} — Xcode has unsaved changes in it", .{ui.cyan(label)});
            for (row.attached.xcode.unsaved) |doc| app.ui.hint("  {s}", .{doc.path});
            app.ui.hint("  Save them there, or rerun with: lcc remove --force", .{});
            continue;
        }

        const closed = closeXcode(app, row.attached.xcode);
        const gone = remove: {
            repo.removeWorktree(entry.path, opts.force) catch {
                if (opts.force) {
                    app.ui.warn("Kept {f} — {s}", .{ ui.cyan(label), git.last_error });
                    noteReopen(app, closed);
                    break :remove false;
                }

                app.ui.warn("Could not remove {f} — {s}", .{ ui.cyan(label), git.last_error });
                app.ui.flush();
                const message = try std.fmt.allocPrint(
                    app.gpa,
                    "{s} has uncommitted changes or is locked. Force remove?",
                    .{label},
                );
                const forced = try prompt.confirm(app.gpa, app.io, message, false) orelse
                    std.process.exit(app_mod.cancelled_exit_code);
                if (!forced) {
                    app.ui.hint("Kept {s}.", .{label});
                    noteReopen(app, closed);
                    break :remove false;
                }
                repo.removeWorktree(entry.path, true) catch {
                    app.ui.warn("Kept {f} — {s}", .{ ui.cyan(label), git.last_error });
                    noteReopen(app, closed);
                    break :remove false;
                };
            };
            break :remove true;
        };
        if (!gone) continue;

        removed += 1;
        app.ui.success("Removed worktree {f}", .{ui.cyan(label)});
        reclaimed += try purgeDerived(app, row.attached.derived, dd_root);
        if (opts.sessions) {
            reclaimed += try purgeSessions(app, row.attached.sessions, cp_root);
        } else {
            kept_sessions += row.attached.sessions.len;
        }

        try disposeBranch(app, repo, entry.branch, row.disposition);
    }

    if (kept_sessions > 0) {
        app.ui.hint("Kept {d} session transcript folder{s} — delete with: lcc remove --sessions", .{
            kept_sessions, plural(kept_sessions),
        });
    }
    if (reclaimed > 0) {
        app.ui.success("Reclaimed {f}.", .{
            ui.bold(try std.fmt.allocPrint(app.gpa, "{f}", .{ui.bytes(reclaimed)})),
        });
    }
    if (rows.len > 1) {
        app.ui.success("Removed {d} of {d} selected worktrees.", .{ removed, rows.len });
    }
}

const automation_hint =
    "Allow it under System Settings → Privacy & Security → Automation, or use --keep-xcode.";

fn closeXcode(app: app_mod.App, held: xcode.Open) bool {
    if (held.workspaces.len == 0) return false;

    xcode.closeDocuments(app.gpa, app.io, held.workspaces) catch {
        app.ui.warn("Could not close {s} in Xcode — {s}", .{
            held.workspaces[0].name(),
            xcode.last_error,
        });
        app.ui.hint("  {s}", .{automation_hint});
        return false;
    };
    for (held.workspaces) |doc| {
        app.ui.success("Closed {f} in Xcode", .{ui.cyan(doc.name())});
    }
    return true;
}

fn noteReopen(app: app_mod.App, closed: bool) void {
    if (!closed) return;
    app.ui.hint("  Its Xcode window is closed — reopen with: lcc open xcode", .{});
}

fn refresh(app: app_mod.App, repo: git.Repo) void {
    app.ui.step("Fetching…", .{});
    app.ui.flush();
    repo.fetchPrune() catch {
        app.ui.warn("Could not fetch — deciding from the refs already here.", .{});
    };
}

fn pullRequests(
    app: app_mod.App,
    repo: git.Repo,
    branches: []const []const u8,
) ?[]const github.PullRequest {
    const now = app_mod.nowSeconds(app.io);
    var cache: rc.Cache = .open(app.gpa, app.io, app.environ);
    if (cache.prs(repo.root, branches, now)) |hit| return hit.list;

    app.ui.step("Asking GitHub about {d} branch{s}…", .{ branches.len, plural(branches.len) });
    app.ui.flush();
    const list = github.forBranches(app.gpa, app.io, repo.root, branches) orelse {
        app.ui.warn("Could not reach GitHub — judging by local refs alone.", .{});
        return null;
    };
    cache.putPrs(repo.root, branches, now, list);
    cache.save(now);
    return list;
}

fn confirmMessage(app: app_mod.App, row: Row, opts: Opts) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = app.gpa;
    try out.appendSlice(w, try std.fmt.allocPrint(w, "Remove worktree {s}?\n", .{
        try row.label(w),
    }));
    try appendConfirmationDetails(app, &out, row, opts);
    return out.toOwnedSlice(w);
}

fn appendConfirmationDetails(
    app: app_mod.App,
    out: *std.ArrayList(u8),
    row: Row,
    opts: Opts,
) !void {
    const w = app.gpa;
    if (row.entry()) |entry| {
        try out.appendSlice(w, try std.fmt.allocPrint(w, "    worktree   {s}\n", .{entry.path}));
    }
    if (row.dirty) |count| {
        if (count > 0) {
            try out.appendSlice(w, try std.fmt.allocPrint(
                w,
                "    changes    {d} uncommitted  (lost if the removal is forced)\n",
                .{count},
            ));
        }
    }
    for (row.attached.xcode.workspaces) |doc| {
        try out.appendSlice(w, try std.fmt.allocPrint(w, "    xcode      {s}  (open — will be closed)\n", .{
            doc.name(),
        }));
    }
    for (row.attached.xcode.unsaved) |doc| {
        try out.appendSlice(w, try std.fmt.allocPrint(w, "    unsaved    {s}  (in Xcode — the changes go too)\n", .{
            doc.name(),
        }));
    }
    for (row.attached.derived) |item| {
        try out.appendSlice(w, try std.fmt.allocPrint(w, "    build data {s}  ({f})\n", .{
            item.entry.name, ui.bytes(item.size),
        }));
    }
    for (row.attached.sessions) |item| {
        try out.appendSlice(w, try std.fmt.allocPrint(w, "    sessions   {s}  ({d} session{s}, {f}){s}\n", .{
            item.entry.name,
            item.entry.sessions,
            plural(item.entry.sessions),
            ui.bytes(item.size),
            if (opts.sessions) "" else "  — kept, use --sessions",
        }));
    }
    if (!row.attached.spent.empty()) {
        try out.appendSlice(w, try std.fmt.allocPrint(w, "    spent      {f}\n", .{
            usage.brief(row.attached.spent, app_mod.nowSeconds(app.io)),
        }));
    }
    if (row.disposition) |d| {
        try out.appendSlice(w, try std.fmt.allocPrint(w, "    branch     {s}  {s}\n", .{
            d.branch, try describeDisposition(w, d),
        }));
    }
}

fn describeDisposition(gpa: std.mem.Allocator, d: git.BranchDisposition) ![]const u8 {
    return switch (d.reason) {
        .merged => "(merged — will be deleted)",
        .merged_pr => try std.fmt.allocPrint(gpa, "(PR #{d} merged — will be deleted)", .{d.pr}),
        .upstream_gone => "(pushed, remote branch gone — will be deleted)",
        .default_branch => "(default branch — kept)",
        .unmerged => try std.fmt.allocPrint(gpa, "({d} unmerged commit{s} — kept)", .{
            d.unmerged,
            plural(d.unmerged),
        }),
    };
}

fn disposeBranch(
    app: app_mod.App,
    repo: git.Repo,
    branch_name: ?[]const u8,
    disposition: ?git.BranchDisposition,
) !void {
    const branch = branch_name orelse return;
    const d = disposition orelse {
        app.ui.hint("Branch left intact. Delete with: git branch -D {s}", .{branch});
        return;
    };

    if (!d.safe) {
        const detail = switch (d.reason) {
            .default_branch => try app.gpa.dupe(u8, "is the default branch"),
            else => try std.fmt.allocPrint(app.gpa, "has {d} unmerged commit{s}", .{
                d.unmerged,
                plural(d.unmerged),
            }),
        };
        app.ui.warn("Branch {f} {s} — kept.", .{ ui.cyan(branch), detail });
        app.ui.hint("  Delete anyway with: git branch -D {s}", .{branch});
        return;
    }

    const forced = repo.deleteVerified(d) catch {
        app.ui.warn("Could not delete branch {s} — {s}", .{ branch, git.last_error });
        app.ui.hint("  Delete manually with: git branch -D {s}", .{branch});
        return;
    };
    app.ui.success("Deleted branch {f}", .{ui.cyan(branch)});
    if (forced) app.ui.hint("  git's own check could not see the merge — used -D.", .{});
}

fn purgeDerived(app: app_mod.App, sized: []const dd.Sized, root: []const u8) !u64 {
    var reclaimed: u64 = 0;
    for (sized) |item| {
        dd.remove(app.gpa, app.io, item.entry, root) catch |err| {
            app.ui.warn("Could not remove {s}: {s}", .{ item.entry.name, @errorName(err) });
            continue;
        };
        reclaimed += item.size;
        app.ui.success("Removed build data {f} {f}", .{
            ui.dim(item.entry.name),
            ui.yellow(try std.fmt.allocPrint(app.gpa, "({f})", .{ui.bytes(item.size)})),
        });
    }
    return reclaimed;
}

fn purgeSessions(app: app_mod.App, sized: []const cp.Sized, root: []const u8) !u64 {
    var reclaimed: u64 = 0;
    for (sized) |item| {
        cp.remove(app.gpa, app.io, item.entry, root) catch |err| {
            app.ui.warn("Could not remove {s}: {s}", .{ item.entry.name, @errorName(err) });
            continue;
        };
        reclaimed += item.size;
        app.ui.success("Removed sessions {f} {f}", .{
            ui.dim(item.entry.name),
            ui.yellow(try std.fmt.allocPrint(app.gpa, "({f})", .{ui.bytes(item.size)})),
        });
    }
    return reclaimed;
}

fn runMerged(app: app_mod.App, repo: git.Repo, opts: Opts) !void {
    if (!opts.local) refresh(app, repo);

    app.ui.step("Checking which branches are already merged…", .{});
    app.ui.flush();

    const worktrees = try repo.listWorktrees();

    var checked_out: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (worktrees) |entry| {
        if (entry.branch) |branch| try checked_out.put(app.gpa, branch, {});
    }

    const prefix = try app_mod.managedPrefix(app, repo);

    var candidates: std.ArrayList(Row) = .empty;
    for (worktrees) |entry| {
        if (entry.is_main) continue;
        const branch = entry.branch orelse continue;
        try candidates.append(app.gpa, .{
            .choice = .{ .entry = entry, .managed = app_mod.isManaged(prefix, entry.path) },
            .branch = branch,
        });
    }

    for (try repo.branchStatuses()) |status| {
        if (checked_out.contains(status.branch)) continue;
        try candidates.append(app.gpa, .{ .branch = status.branch });
    }

    try judge(app, repo, candidates.items);
    if (!opts.local) try consultGitHub(app, repo, candidates.items);

    var rows: std.ArrayList(Row) = .empty;
    for (candidates.items) |row| {
        const d = row.disposition orelse continue;
        if (d.safe) try rows.append(app.gpa, row);
    }

    if (rows.items.len == 0) {
        app.ui.success("Nothing merged to clean up.", .{});
        return;
    }

    try inspect(app, repo, rows.items);

    const dd_root = try dd.root(app.gpa, app.io, app.environ);
    const cp_root = try cp.root(app.gpa, app.environ);
    try attach(app, rows.items, opts, dd_root, cp_root);

    const picked: []const Row = if (opts.yes) rows.items else try select(
        app,
        rows.items,
        opts,
        "Select what to remove (space toggles, enter confirms):",
        true,
    );
    if (picked.len == 0) {
        app.ui.hint("Nothing selected.", .{});
        return;
    }

    var reclaimed: u64 = 0;
    var worktrees_gone: usize = 0;
    var branches_gone: usize = 0;

    for (picked) |row| {
        const branch = row.branch orelse continue;
        if (row.entry()) |entry| {
            if (row.attached.xcode.unsaved.len > 0 and !opts.force) {
                app.ui.warn("Kept {f} — Xcode has unsaved changes in it", .{ui.cyan(branch)});
                app.ui.hint("  Save them there, or rerun with: lcc remove --merged --force", .{});
                continue;
            }
            const closed = closeXcode(app, row.attached.xcode);

            repo.removeWorktree(entry.path, opts.force) catch {
                app.ui.warn("Kept {f} — {s}", .{ ui.cyan(branch), git.last_error });
                app.ui.hint("  Retry with: lcc remove --merged --force", .{});
                noteReopen(app, closed);
                continue;
            };
            worktrees_gone += 1;
            app.ui.success("Removed worktree {f}", .{ui.cyan(branch)});

            reclaimed += try purgeDerived(app, row.attached.derived, dd_root);
            if (opts.sessions) {
                reclaimed += try purgeSessions(app, row.attached.sessions, cp_root);
            }
        }

        if (opts.keep_branch) continue;
        const disposition = row.disposition orelse continue;
        const forced = repo.deleteVerified(disposition) catch {
            app.ui.warn("Could not delete branch {s} — {s}", .{ branch, git.last_error });
            app.ui.hint("  Delete manually with: git branch -D {s}", .{branch});
            continue;
        };
        branches_gone += 1;
        app.ui.success("Deleted branch {f}", .{ui.cyan(branch)});
        if (forced) app.ui.hint("  git's own check could not see the merge — used -D.", .{});
    }

    app.ui.info("", .{});
    app.ui.success("{d} worktree{s}, {d} branch{s}, {f} reclaimed.", .{
        worktrees_gone,
        plural(worktrees_gone),
        branches_gone,
        if (branches_gone == 1) "" else "es",
        ui.bold(try std.fmt.allocPrint(app.gpa, "{f}", .{ui.bytes(reclaimed)})),
    });
    if (!opts.sessions) {
        app.ui.hint("Session transcripts were kept. Add --sessions to delete them too.", .{});
    }
}

fn consultGitHub(app: app_mod.App, repo: git.Repo, rows: []Row) !void {
    var asked: std.ArrayList([]const u8) = .empty;
    for (rows) |row| {
        const d = row.disposition orelse continue;
        if (d.reason != .unmerged) continue;
        for (asked.items) |seen| {
            if (std.mem.eql(u8, seen, d.branch)) break;
        } else try asked.append(app.gpa, d.branch);
    }
    if (asked.items.len == 0) return;

    const prs = pullRequests(app, repo, asked.items) orelse return;
    for (rows) |*row| {
        const d = row.disposition orelse continue;
        const number = github.mergedFor(prs, d.branch) orelse continue;
        row.disposition = d.withMergedPr(number);
    }
}

fn attach(
    app: app_mod.App,
    rows: []Row,
    opts: Opts,
    dd_root: []const u8,
    cp_root: []const u8,
) !void {
    const dd_all: []dd.Entry = if (opts.keep_derived_data)
        &.{}
    else
        try dd.list(app.gpa, app.io, dd_root);
    const cp_all = try cp.list(app.gpa, app.io, cp_root);

    const held: xcode.Open = if (opts.keep_xcode) .{} else try xcode.openDocuments(app.gpa, app.io);
    if (held.unanswered) {
        app.ui.warn("Could not ask Xcode what it has open — it may be holding some of these.", .{});
        app.ui.hint("  {s}", .{automation_hint});
    }

    var paths: std.ArrayList([]const u8) = .empty;
    const derived = try app.gpa.alloc([]dd.Entry, rows.len);
    const sessions = try app.gpa.alloc([]cp.Entry, rows.len);
    const in_xcode = try app.gpa.alloc(xcode.Open, rows.len);

    for (rows, 0..) |row, i| {
        const entry = row.entry() orelse {
            derived[i] = &.{};
            sessions[i] = &.{};
            in_xcode[i] = .{};
            continue;
        };
        derived[i] = try dd.forWorktree(app.gpa, app.io, dd_all, entry.path);
        sessions[i] = try cp.forWorktree(app.gpa, app.io, cp_all, entry.path);
        in_xcode[i] = try held.inside(app.gpa, app.io, entry.path);
        for (derived[i]) |e| try paths.append(app.gpa, e.path);
        for (sessions[i]) |e| try paths.append(app.gpa, e.path);
    }

    if (paths.items.len > 0) {
        app.ui.step("Measuring build data and sessions ({d})…", .{paths.items.len});
        app.ui.flush();
    }
    const sizes = try disk.usage(app.gpa, app.io, paths.items);

    var scanner: usage.Scanner = .init(app.gpa, app.io, .open(app.gpa, app.io, app.environ));
    defer scanner.deinit();

    var at: usize = 0;
    for (rows, 0..) |*row, i| {
        const dd_sized = try app.gpa.alloc(dd.Sized, derived[i].len);
        for (derived[i], 0..) |e, j| {
            dd_sized[j] = .{ .entry = e, .size = sizes[at] };
            at += 1;
        }
        const cp_sized = try app.gpa.alloc(cp.Sized, sessions[i].len);
        for (sessions[i], 0..) |e, j| {
            cp_sized[j] = .{ .entry = e, .size = sizes[at] };
            at += 1;
        }
        row.attached = .{
            .derived = dd_sized,
            .sessions = cp_sized,
            .spent = if (row.entry()) |entry| try scanner.worktree(cp_all, entry.path) else .{},
            .xcode = in_xcode[i],
        };
    }
}

fn plural(n: anytype) []const u8 {
    return if (n == 1) "" else "s";
}

fn testRow(path: []const u8, branch: ?[]const u8, head: []const u8) Row {
    return .{
        .choice = .{ .entry = .{
            .path = path,
            .branch = branch,
            .head = head,
            .locked = false,
            .prunable = false,
            .is_main = false,
        }, .managed = true },
        .branch = branch,
    };
}

test "multi-selection preserves zero one and many picks" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = [_]Row{
        testRow("/tmp/one", "feature/one", "11111111"),
        testRow("/tmp/two", "feature/two", "22222222"),
        testRow("/tmp/detached", null, "33333333"),
    };

    const none = try rowsAt(arena, &rows, &.{});
    try std.testing.expectEqual(@as(usize, 0), none.len);

    const one = try rowsAt(arena, &rows, &.{1});
    try std.testing.expectEqualStrings("feature/two", one[0].branch.?);

    const many = try rowsAt(arena, &rows, &.{ 0, 2 });
    try std.testing.expectEqual(@as(usize, 2), many.len);
    try std.testing.expectEqualStrings("/tmp/one", many[0].entry().?.path);
    try std.testing.expectEqualStrings("/tmp/detached", many[1].entry().?.path);
    try std.testing.expect(many[1].branch == null);
}

test "a row says whether its work landed before it is ticked, not after" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", "/Users/me");

    const app: app_mod.App = .{
        .gpa = arena,
        .io = undefined,
        .environ = &environ,
        .ui = undefined,
    };

    const now: i64 = 1_800_000_000;
    var row = testRow(
        "/Users/me/Projects/App/.lcc/worktrees/pe-256",
        "feature/pe-256-app-hangs",
        "abc",
    );
    row.disposition = .{
        .branch = "feature/pe-256-app-hangs",
        .safe = false,
        .reason = .unmerged,
        .unmerged = 3,
    };
    row.dirty = 2;
    row.committed_at = now - 7200;

    const unmerged = try cellsFor(app, row, .{}, now);
    try std.testing.expectEqualStrings("3 unmerged", unmerged.merge);
    try std.testing.expectEqualStrings("2 dirty", unmerged.status);
    try std.testing.expectEqualStrings("2h", unmerged.age);

    var landed = row;
    landed.disposition = row.disposition.?.withMergedPr(412);
    landed.dirty = 0;
    const merged = try cellsFor(app, landed, .{}, now);
    try std.testing.expectEqualStrings("merged #412", merged.merge);
    try std.testing.expectEqualStrings("clean", merged.status);

    var untracked = row;
    untracked.disposition = null;
    untracked.dirty = null;
    untracked.committed_at = 0;
    const unknown = try cellsFor(app, untracked, .{}, now);
    try std.testing.expectEqualStrings("—", unknown.merge);
    try std.testing.expectEqualStrings("missing", unknown.status);
    try std.testing.expectEqualStrings("—", unknown.age);
}

test "a row shows what it frees and what it spent" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", "/Users/me");

    const app: app_mod.App = .{
        .gpa = arena,
        .io = undefined,
        .environ = &environ,
        .ui = undefined,
    };

    const now: i64 = 1_800_000_000;
    var row = testRow(
        "/Users/me/Projects/App/.lcc/worktrees/pe-101",
        "feature/pe-101-shipped",
        "abc",
    );
    row.disposition = .{
        .branch = "feature/pe-101-shipped",
        .safe = true,
        .reason = .merged,
        .unmerged = 0,
    };
    row.dirty = 0;

    var derived = [_]dd.Sized{.{
        .entry = .{
            .name = "App-abc",
            .path = "/dd/App-abc",
            .workspace_path = "/Users/me/x",
        },
        .size = 1_200_000_000,
    }};
    var sessions = [_]cp.Sized{.{
        .entry = .{
            .name = "-Users-me-x",
            .path = "/cp/-Users-me-x",
            .cwd = "/Users/me/x",
            .sessions = 3,
        },
        .size = 40_000_000,
    }};
    row.attached = .{
        .derived = &derived,
        .sessions = &sessions,
        .spent = .{
            .counts = .{ .messages = 190, .cache_read = 52_600_000 },
            .sessions = 1,
        },
    };

    const kept = try cellsFor(app, row, .{}, now);
    try std.testing.expectEqualStrings("1.1 GB", kept.frees);
    try std.testing.expectEqualStrings("53M", kept.spent);
    try std.testing.expectEqualStrings("~/Projects/App/.lcc/worktrees/pe-101", kept.where);
    try std.testing.expectEqualStrings("  lcc", kept.note);

    const with_sessions = try cellsFor(app, row, .{ .sessions = true }, now);
    try std.testing.expectEqualStrings("1.2 GB", with_sessions.frees);

    var orphan: Row = .{ .branch = "feature/pe-103-squashed" };
    orphan.disposition = .{
        .branch = "feature/pe-103-squashed",
        .safe = true,
        .reason = .upstream_gone,
        .unmerged = 1,
    };
    const gone = try cellsFor(app, orphan, .{}, now);
    try std.testing.expectEqualStrings("remote gone", gone.merge);
    try std.testing.expectEqualStrings("—", gone.status);
    try std.testing.expectEqualStrings("—", gone.frees);
    try std.testing.expectEqualStrings("branch only — no worktree left", gone.where);
}

test "an open Xcode window is named on the row that would close it" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", "/Users/me");

    const app: app_mod.App = .{
        .gpa = arena,
        .io = undefined,
        .environ = &environ,
        .ui = undefined,
    };

    const doc: xcode.Document = .{
        .app = "/Applications/Xcode.app",
        .path = "/Users/me/Projects/App/.lcc/worktrees/pe-101/App.xcodeproj",
        .resolved = "/Users/me/Projects/App/.lcc/worktrees/pe-101/App.xcodeproj",
    };

    var row = testRow("/Users/me/Projects/App/.lcc/worktrees/pe-101", "feature/pe-101", "abc");

    row.attached.xcode = .{ .workspaces = &.{doc} };
    const opened = try cellsFor(app, row, .{}, 0);
    try std.testing.expectEqualStrings("  lcc  — open in Xcode", opened.note);

    row.attached.xcode = .{ .workspaces = &.{doc}, .unsaved = &.{doc} };
    const dirty = try cellsFor(app, row, .{}, 0);
    try std.testing.expectEqualStrings("  lcc  — unsaved in Xcode", dirty.note);
}

test "every column is as wide as its widest cell, header included" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cells = [_]Cells{
        .{
            .branch = "feature/pe-256-app-hangs",
            .merge = "merged #412",
            .status = "clean",
            .age = "2h",
            .frees = "1.2 GB",
            .spent = "53M",
            .where = "~/Projects/App/.lcc/worktrees/pe-256",
            .note = "",
        },
    };

    const w = measure(&cells);
    try std.testing.expectEqual(@as(usize, "feature/pe-256-app-hangs".len), w.branch);
    try std.testing.expectEqual(@as(usize, "merged #412".len), w.merge);
    try std.testing.expectEqual(@as(usize, "STATUS".len), w.status);
    try std.testing.expectEqual(@as(usize, "AGE".len), w.age);
    try std.testing.expectEqual(@as(usize, "1.2 GB".len), w.frees);
    try std.testing.expectEqual(@as(usize, "SPENT".len), w.spent);

    const header = try headerLine(arena, w);
    const line = try rowLine(arena, cells[0], w);
    try std.testing.expectEqual(
        std.mem.indexOf(u8, header, "STATUS").?,
        std.mem.indexOf(u8, line, "clean").?,
    );
    try std.testing.expectEqual(
        std.mem.indexOf(u8, header, "PATH").?,
        std.mem.indexOf(u8, line, "~/Projects").?,
    );
}
