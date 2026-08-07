const std = @import("std");
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

const Removal = struct {
    choice: app_mod.Choice,
    attached: Attached = .{},
    disposition: ?git.BranchDisposition = null,
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

    const selected = try selectWorktrees(app, choices);
    if (selected.len == 0) {
        app.ui.hint("Nothing selected.", .{});
        return;
    }

    const dd_root = try dd.root(app.gpa, app.io, app.environ);
    const cp_root = try cp.root(app.gpa, app.environ);
    const removals = try prepareRemovals(app, repo, selected, opts, dd_root, cp_root);
    const actionable = try withoutUnsavedWork(app, removals, opts);
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

fn selectWorktrees(app: app_mod.App, choices: []const app_mod.Choice) ![]const app_mod.Choice {
    const items = try app.gpa.alloc(prompt.Item, choices.len);
    for (choices, 0..) |choice, i| {
        items[i] = .{ .label = try app_mod.worktreeLabel(app.gpa, choice) };
    }

    app.ui.flush();
    const chosen = try prompt.checkbox(
        app.gpa,
        app.io,
        "Select worktrees to remove (space toggles, enter confirms):",
        items,
        false,
    ) orelse std.process.exit(app_mod.cancelled_exit_code);
    return choicesAt(app.gpa, choices, chosen);
}

fn choicesAt(
    gpa: std.mem.Allocator,
    choices: []const app_mod.Choice,
    indices: []const usize,
) ![]const app_mod.Choice {
    const subset = try gpa.alloc(app_mod.Choice, indices.len);
    for (indices, 0..) |index, i| subset[i] = choices[index];
    return subset;
}

fn prepareRemovals(
    app: app_mod.App,
    repo: git.Repo,
    selected: []const app_mod.Choice,
    opts: Opts,
    dd_root: []const u8,
    cp_root: []const u8,
) ![]Removal {
    const removals = try app.gpa.alloc(Removal, selected.len);
    for (selected, 0..) |choice, i| {
        removals[i] = .{
            .choice = choice,
            .disposition = if (choice.entry.branch != null and !opts.keep_branch)
                try repo.branchDisposition(choice.entry.branch.?)
            else
                null,
        };
    }

    if (!opts.local and !opts.keep_branch) {
        var asked: std.ArrayList([]const u8) = .empty;
        for (removals) |removal| {
            const disposition = removal.disposition orelse continue;
            if (disposition.reason == .unmerged) try asked.append(app.gpa, disposition.branch);
        }
        if (asked.items.len > 0) {
            if (pullRequests(app, repo, asked.items)) |prs| {
                for (removals) |*removal| {
                    const disposition = removal.disposition orelse continue;
                    const number = github.mergedFor(prs, disposition.branch) orelse continue;
                    removal.disposition = disposition.withMergedPr(number);
                }
            }
        }
    }

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

    const derived = try app.gpa.alloc([]dd.Entry, removals.len);
    const sessions = try app.gpa.alloc([]cp.Entry, removals.len);
    const in_xcode = try app.gpa.alloc(xcode.Open, removals.len);
    var paths: std.ArrayList([]const u8) = .empty;

    for (removals, 0..) |removal, i| {
        const path = removal.choice.entry.path;
        derived[i] = try dd.forWorktree(app.gpa, app.io, dd_all, path);
        sessions[i] = try cp.forWorktree(app.gpa, app.io, cp_all, path);
        in_xcode[i] = try held.inside(app.gpa, app.io, path);
        for (derived[i]) |entry| try paths.append(app.gpa, entry.path);
        for (sessions[i]) |entry| try paths.append(app.gpa, entry.path);
    }

    if (paths.items.len > 0) {
        app.ui.step("Measuring build data and sessions ({d})…", .{paths.items.len});
        app.ui.flush();
    }
    const sizes = try disk.usage(app.gpa, app.io, paths.items);

    var scanner: usage.Scanner = .init(app.gpa, app.io, .open(app.gpa, app.io, app.environ));
    defer scanner.deinit();

    var at: usize = 0;
    for (removals, 0..) |*removal, i| {
        const dd_sized = try app.gpa.alloc(dd.Sized, derived[i].len);
        for (derived[i], 0..) |entry, j| {
            dd_sized[j] = .{ .entry = entry, .size = sizes[at] };
            at += 1;
        }

        const cp_sized = try app.gpa.alloc(cp.Sized, sessions[i].len);
        for (sessions[i], 0..) |entry, j| {
            cp_sized[j] = .{ .entry = entry, .size = sizes[at] };
            at += 1;
        }
        removal.attached = .{
            .derived = dd_sized,
            .sessions = cp_sized,
            .spent = try scanner.worktree(cp_all, removal.choice.entry.path),
            .xcode = in_xcode[i],
        };
    }
    return removals;
}

fn confirmRemovalsMessage(app: app_mod.App, removals: []const Removal, opts: Opts) ![]u8 {
    if (removals.len == 1) {
        const removal = removals[0];
        return confirmMessage(app, removal.choice, removal.attached, removal.disposition, opts);
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(app.gpa, try std.fmt.allocPrint(app.gpa, "Remove {d} worktrees?\n", .{removals.len}));
    for (removals) |removal| {
        const label = removal.choice.entry.branch orelse app_mod.shortHead(removal.choice.entry.head);
        try out.appendSlice(app.gpa, try std.fmt.allocPrint(app.gpa, "\n  {s}\n", .{label}));
        try appendConfirmationDetails(
            app,
            &out,
            removal.choice,
            removal.attached,
            removal.disposition,
            opts,
        );
    }
    return out.toOwnedSlice(app.gpa);
}

fn withoutUnsavedWork(app: app_mod.App, removals: []const Removal, opts: Opts) ![]const Removal {
    if (opts.force) return removals;

    var actionable: std.ArrayList(Removal) = .empty;
    for (removals) |removal| {
        if (removal.attached.xcode.unsaved.len == 0) {
            try actionable.append(app.gpa, removal);
            continue;
        }

        const entry = removal.choice.entry;
        const label = entry.branch orelse app_mod.shortHead(entry.head);
        app.ui.warn("Kept {f} — Xcode has unsaved changes in it", .{ui.cyan(label)});
        for (removal.attached.xcode.unsaved) |doc| app.ui.hint("  {s}", .{doc.path});
        app.ui.hint("  Save them there, or rerun with: lcc remove --force", .{});
    }
    return actionable.toOwnedSlice(app.gpa);
}

fn removeSelected(
    app: app_mod.App,
    repo: git.Repo,
    removals: []const Removal,
    opts: Opts,
    dd_root: []const u8,
    cp_root: []const u8,
) !void {
    var removed: usize = 0;
    var kept_sessions: usize = 0;
    var reclaimed: u64 = 0;

    for (removals) |removal| {
        const entry = removal.choice.entry;
        const label = entry.branch orelse app_mod.shortHead(entry.head);

        if (removal.attached.xcode.unsaved.len > 0 and !opts.force) {
            app.ui.warn("Kept {f} — Xcode has unsaved changes in it", .{ui.cyan(label)});
            for (removal.attached.xcode.unsaved) |doc| app.ui.hint("  {s}", .{doc.path});
            app.ui.hint("  Save them there, or rerun with: lcc remove --force", .{});
            continue;
        }

        const closed = closeXcode(app, removal.attached.xcode);
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
        reclaimed += try purgeDerived(app, removal.attached.derived, dd_root);
        if (opts.sessions) {
            reclaimed += try purgeSessions(app, removal.attached.sessions, cp_root);
        } else {
            kept_sessions += removal.attached.sessions.len;
        }

        try disposeBranch(app, repo, entry.branch, removal.disposition);
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
    if (removals.len > 1) {
        app.ui.success("Removed {d} of {d} selected worktrees.", .{ removed, removals.len });
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

fn confirmMessage(
    app: app_mod.App,
    picked: app_mod.Choice,
    attached: Attached,
    disposition: ?git.BranchDisposition,
    opts: Opts,
) ![]u8 {
    const label = picked.entry.branch orelse app_mod.shortHead(picked.entry.head);

    var out: std.ArrayList(u8) = .empty;
    const w = app.gpa;
    try out.appendSlice(w, try std.fmt.allocPrint(w, "Remove worktree {s}?\n", .{label}));
    try appendConfirmationDetails(app, &out, picked, attached, disposition, opts);
    return out.toOwnedSlice(w);
}

fn appendConfirmationDetails(
    app: app_mod.App,
    out: *std.ArrayList(u8),
    picked: app_mod.Choice,
    attached: Attached,
    disposition: ?git.BranchDisposition,
    opts: Opts,
) !void {
    const w = app.gpa;
    try out.appendSlice(w, try std.fmt.allocPrint(w, "    worktree   {s}\n", .{picked.entry.path}));
    for (attached.xcode.workspaces) |doc| {
        try out.appendSlice(w, try std.fmt.allocPrint(w, "    xcode      {s}  (open — will be closed)\n", .{
            doc.name(),
        }));
    }
    for (attached.xcode.unsaved) |doc| {
        try out.appendSlice(w, try std.fmt.allocPrint(w, "    unsaved    {s}  (in Xcode — the changes go too)\n", .{
            doc.name(),
        }));
    }
    for (attached.derived) |item| {
        try out.appendSlice(w, try std.fmt.allocPrint(w, "    build data {s}  ({f})\n", .{
            item.entry.name, ui.bytes(item.size),
        }));
    }
    for (attached.sessions) |item| {
        try out.appendSlice(w, try std.fmt.allocPrint(w, "    sessions   {s}  ({d} session{s}, {f}){s}\n", .{
            item.entry.name,
            item.entry.sessions,
            plural(item.entry.sessions),
            ui.bytes(item.size),
            if (opts.sessions) "" else "  — kept, use --sessions",
        }));
    }
    if (!attached.spent.empty()) {
        try out.appendSlice(w, try std.fmt.allocPrint(w, "    spent      {f}\n", .{
            usage.brief(attached.spent, app_mod.nowSeconds(app.io)),
        }));
    }
    if (disposition) |d| {
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

const Row = struct {
    worktree: ?git.WorktreeEntry,
    branch: []const u8,
    disposition: git.BranchDisposition,
    attached: Attached = .{},

    fn reason(self: Row, gpa: std.mem.Allocator) []const u8 {
        return switch (self.disposition.reason) {
            .merged => "merged",
            .merged_pr => std.fmt.allocPrint(gpa, "merged #{d}", .{self.disposition.pr}) catch "merged",
            .upstream_gone => "remote gone",
            else => "safe",
        };
    }
};

fn runMerged(app: app_mod.App, repo: git.Repo, opts: Opts) !void {
    if (!opts.local) refresh(app, repo);

    app.ui.step("Checking which branches are already merged…", .{});
    app.ui.flush();

    const worktrees = try repo.listWorktrees();

    var checked_out: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (worktrees) |entry| {
        if (entry.branch) |branch| try checked_out.put(app.gpa, branch, {});
    }

    var candidates: std.ArrayList(Row) = .empty;
    for (worktrees) |entry| {
        if (entry.is_main) continue;
        const branch = entry.branch orelse continue;
        try candidates.append(app.gpa, .{
            .worktree = entry,
            .branch = branch,
            .disposition = try repo.branchDisposition(branch),
        });
    }

    for (try repo.branchStatuses()) |status| {
        if (checked_out.contains(status.branch)) continue;
        try candidates.append(app.gpa, .{
            .worktree = null,
            .branch = status.branch,
            .disposition = try repo.branchDisposition(status.branch),
        });
    }

    if (!opts.local) try consultGitHub(app, repo, candidates.items);

    var rows: std.ArrayList(Row) = .empty;
    for (candidates.items) |row| {
        if (row.disposition.safe) try rows.append(app.gpa, row);
    }

    if (rows.items.len == 0) {
        app.ui.success("Nothing merged to clean up.", .{});
        return;
    }

    const dd_root = try dd.root(app.gpa, app.io, app.environ);
    const cp_root = try cp.root(app.gpa, app.environ);
    try attach(app, rows.items, opts, dd_root, cp_root);

    const picked: []const Row = if (opts.yes) rows.items else try selectRows(app, rows.items, opts);
    if (picked.len == 0) {
        app.ui.hint("Nothing selected.", .{});
        return;
    }

    var reclaimed: u64 = 0;
    var worktrees_gone: usize = 0;
    var branches_gone: usize = 0;

    for (picked) |row| {
        if (row.worktree) |entry| {
            if (row.attached.xcode.unsaved.len > 0 and !opts.force) {
                app.ui.warn("Kept {f} — Xcode has unsaved changes in it", .{ui.cyan(row.branch)});
                app.ui.hint("  Save them there, or rerun with: lcc remove --merged --force", .{});
                continue;
            }
            const closed = closeXcode(app, row.attached.xcode);

            repo.removeWorktree(entry.path, opts.force) catch {
                app.ui.warn("Kept {f} — {s}", .{ ui.cyan(row.branch), git.last_error });
                app.ui.hint("  Retry with: lcc remove --merged --force", .{});
                noteReopen(app, closed);
                continue;
            };
            worktrees_gone += 1;
            app.ui.success("Removed worktree {f}", .{ui.cyan(row.branch)});

            reclaimed += try purgeDerived(app, row.attached.derived, dd_root);
            if (opts.sessions) {
                reclaimed += try purgeSessions(app, row.attached.sessions, cp_root);
            }
        }

        if (opts.keep_branch) continue;
        const forced = repo.deleteVerified(row.disposition) catch {
            app.ui.warn("Could not delete branch {s} — {s}", .{ row.branch, git.last_error });
            app.ui.hint("  Delete manually with: git branch -D {s}", .{row.branch});
            continue;
        };
        branches_gone += 1;
        app.ui.success("Deleted branch {f}", .{ui.cyan(row.branch)});
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
        if (row.disposition.reason != .unmerged) continue;
        for (asked.items) |seen| {
            if (std.mem.eql(u8, seen, row.branch)) break;
        } else try asked.append(app.gpa, row.branch);
    }
    if (asked.items.len == 0) return;

    const prs = pullRequests(app, repo, asked.items) orelse return;
    for (rows) |*row| {
        const number = github.mergedFor(prs, row.branch) orelse continue;
        row.disposition = row.disposition.withMergedPr(number);
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
        const entry = row.worktree orelse {
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
            .spent = if (row.worktree) |entry| try scanner.worktree(cp_all, entry.path) else .{},
            .xcode = in_xcode[i],
        };
    }
}

fn rowLabel(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    row: Row,
    branch_width: usize,
    reason_width: usize,
    opts: Opts,
) ![]const u8 {
    const size = row.attached.reclaimable(opts.sessions);
    const reclaim = if (size == 0)
        try gpa.dupe(u8, "—")
    else
        try std.fmt.allocPrint(gpa, "{f}", .{ui.bytes(size)});

    const spent = if (row.attached.spent.empty())
        try gpa.dupe(u8, "—")
    else
        try std.fmt.allocPrint(gpa, "{f}", .{
            ui.count(row.attached.spent.counts.contextTokens()),
        });

    const where = if (row.worktree) |entry|
        disk.abbreviate(gpa, environ, entry.path)
    else
        "branch only — no worktree left";

    const note = if (row.attached.xcode.unsaved.len > 0)
        "  — unsaved in Xcode"
    else if (row.attached.xcode.workspaces.len > 0)
        "  — open in Xcode"
    else
        "";

    return std.fmt.allocPrint(gpa, "{f}  {f}  {f}  {f}  {s}{s}", .{
        ui.pad(row.branch, branch_width),
        ui.pad(row.reason(gpa), reason_width),
        ui.pad(reclaim, 8),
        ui.pad(spent, 7),
        where,
        note,
    });
}

fn selectRows(app: app_mod.App, rows: []const Row, opts: Opts) ![]const Row {
    var branch_width: usize = 0;
    var reason_width: usize = 0;
    for (rows) |row| {
        branch_width = @max(branch_width, ui.displayWidth(row.branch));
        reason_width = @max(reason_width, ui.displayWidth(row.reason(app.gpa)));
    }

    const items = try app.gpa.alloc(prompt.Item, rows.len);
    for (rows, 0..) |row, i| {
        items[i] = .{
            .label = try rowLabel(app.gpa, app.environ, row, branch_width, reason_width, opts),
        };
    }

    app.ui.flush();
    const chosen = try prompt.checkbox(
        app.gpa,
        app.io,
        "Select what to remove (space toggles, enter confirms):",
        items,
        true,
    ) orelse std.process.exit(app_mod.cancelled_exit_code);

    const subset = try app.gpa.alloc(Row, chosen.len);
    for (chosen, 0..) |index, i| subset[i] = rows[index];
    return subset;
}

fn plural(n: anytype) []const u8 {
    return if (n == 1) "" else "s";
}

test "worktree multi-selection preserves zero one and many choices" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const choices = [_]app_mod.Choice{
        .{ .entry = .{
            .path = "/tmp/one",
            .branch = "feature/one",
            .head = "11111111",
            .locked = false,
            .prunable = false,
            .is_main = false,
        }, .managed = true },
        .{ .entry = .{
            .path = "/tmp/two",
            .branch = "feature/two",
            .head = "22222222",
            .locked = false,
            .prunable = false,
            .is_main = false,
        }, .managed = true },
        .{ .entry = .{
            .path = "/tmp/detached",
            .branch = null,
            .head = "33333333",
            .locked = false,
            .prunable = false,
            .is_main = false,
        }, .managed = false },
    };

    const none = try choicesAt(arena, &choices, &.{});
    try std.testing.expectEqual(@as(usize, 0), none.len);

    const one = try choicesAt(arena, &choices, &.{1});
    try std.testing.expectEqualStrings("feature/two", one[0].entry.branch.?);

    const many = try choicesAt(arena, &choices, &.{ 0, 2 });
    try std.testing.expectEqual(@as(usize, 2), many.len);
    try std.testing.expectEqualStrings("/tmp/one", many[0].entry.path);
    try std.testing.expectEqualStrings("/tmp/detached", many[1].entry.path);
    try std.testing.expect(many[1].entry.branch == null);
}

test "a bulk row shows what it frees and what it spent" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", "/Users/me");

    const worktree: git.WorktreeEntry = .{
        .path = "/Users/me/Projects/App/.lcc/worktrees/pe-101",
        .branch = "feature/pe-101-shipped",
        .head = "abc",
        .locked = false,
        .prunable = false,
        .is_main = false,
    };
    const row: Row = .{
        .worktree = worktree,
        .branch = "feature/pe-101-shipped",
        .disposition = .{ .branch = "feature/pe-101-shipped", .safe = true, .reason = .merged, .unmerged = 0 },
        .attached = .{
            .derived = &.{},
            .sessions = &.{},
            .spent = .{
                .counts = .{ .messages = 190, .cache_read = 52_600_000 },
                .sessions = 1,
            },
        },
    };

    const label = try rowLabel(arena, &environ, row, 22, 11, .{});
    try std.testing.expect(std.mem.indexOf(u8, label, "53M") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "—") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "~/Projects/App/.lcc/worktrees/pe-101") != null);

    var orphan = row;
    orphan.worktree = null;
    orphan.attached = .{};
    const orphan_label = try rowLabel(arena, &environ, orphan, 22, 11, .{});
    try std.testing.expect(std.mem.indexOf(u8, orphan_label, "53M") == null);
    try std.testing.expect(std.mem.indexOf(u8, orphan_label, "branch only") != null);

    var by_pr = row;
    by_pr.disposition = (git.BranchDisposition{
        .branch = "feature/pe-101-shipped",
        .safe = false,
        .reason = .unmerged,
        .unmerged = 3,
    }).withMergedPr(412);
    const pr_label = try rowLabel(arena, &environ, by_pr, 22, 11, .{});
    try std.testing.expect(std.mem.indexOf(u8, pr_label, "merged #412") != null);

    const doc: xcode.Document = .{
        .app = "/Applications/Xcode.app",
        .path = "/Users/me/Projects/App/.lcc/worktrees/pe-101/App.xcodeproj",
        .resolved = "/Users/me/Projects/App/.lcc/worktrees/pe-101/App.xcodeproj",
    };

    var opened = row;
    opened.attached.xcode = .{ .workspaces = &.{doc} };
    const open_label = try rowLabel(arena, &environ, opened, 22, 11, .{});
    try std.testing.expect(std.mem.indexOf(u8, open_label, "open in Xcode") != null);

    var dirty = row;
    dirty.attached.xcode = .{ .workspaces = &.{doc}, .unsaved = &.{doc} };
    const dirty_label = try rowLabel(arena, &environ, dirty, 22, 11, .{});
    try std.testing.expect(std.mem.indexOf(u8, dirty_label, "unsaved in Xcode") != null);
}
