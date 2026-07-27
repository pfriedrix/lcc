//! `lcc remove` — drop a worktree, its Xcode build data, and its branch.
//! `--merged` does the same in bulk for everything whose work is already safe.

const std = @import("std");
const app_mod = @import("../app.zig");
const cp = @import("../claude_projects.zig");
const dd = @import("../derived_data.zig");
const disk = @import("../disk.zig");
const git = @import("../git.zig");
const prompt = @import("../prompt.zig");
const ui = @import("../ui.zig");

pub const Opts = struct {
    force: bool = false,
    yes: bool = false,
    keep_derived_data: bool = false,
    keep_branch: bool = false,
    /// Delete the Claude Code session transcripts too. Off by default: build
    /// data regenerates on the next build, a transcript never comes back.
    sessions: bool = false,
    /// Bulk mode — every worktree and branch whose commits already survive.
    merged: bool = false,
};

/// Everything lcc found attached to one worktree, measured in a single `du`.
const Attached = struct {
    derived: []dd.Sized = &.{},
    sessions: []cp.Sized = &.{},

    fn reclaimable(self: Attached, sessions_go: bool) u64 {
        var total: u64 = 0;
        for (self.derived) |item| total += item.size;
        if (sessions_go) {
            for (self.sessions) |item| total += item.size;
        }
        return total;
    }
};

pub fn run(app: app_mod.App, opts: Opts) !void {
    const repo = try app.repo();
    if (opts.merged) return runMerged(app, repo, opts);

    const choices = try app_mod.worktreeChoices(app, repo);
    if (choices.len == 0) {
        app.ui.warn("No worktrees to remove (only the main one exists).", .{});
        return;
    }

    const picked = try app_mod.pickWorktree(app, choices, "Pick a worktree to remove:") orelse
        std.process.exit(app_mod.cancelled_exit_code);

    // Match before removing: once the directory is gone the folders still resolve by
    // path, but the user needs to see what is about to go in the confirmation.
    const dd_root = try dd.root(app.gpa, app.io, app.environ);
    const cp_root = try cp.root(app.gpa, app.environ);

    const derived: []dd.Entry = if (opts.keep_derived_data)
        &.{}
    else
        try dd.forWorktree(app.gpa, app.io, try dd.list(app.gpa, app.io, dd_root), picked.entry.path);
    // Matched even when they are being kept — "not silently" means the row shows up.
    const sessions = try cp.forWorktree(
        app.gpa,
        app.io,
        try cp.list(app.gpa, app.io, cp_root),
        picked.entry.path,
    );

    if (derived.len + sessions.len > 0) {
        app.ui.step("Measuring what the worktree left behind ({d})…", .{derived.len + sessions.len});
        app.ui.flush();
    }
    const attached: Attached = .{
        .derived = try dd.withSizes(app.gpa, app.io, derived),
        .sessions = try cp.withSizes(app.gpa, app.io, sessions),
    };

    const disposition: ?git.BranchDisposition = if (picked.entry.branch != null and !opts.keep_branch)
        try repo.branchDisposition(picked.entry.branch.?)
    else
        null;

    if (!opts.yes) {
        const message = try confirmMessage(app, picked, attached, disposition, opts);
        const answer = try prompt.confirm(app.gpa, app.io, message, false) orelse
            std.process.exit(app_mod.cancelled_exit_code);
        if (!answer) {
            app.ui.hint("Aborted.", .{});
            return;
        }
    }

    repo.removeWorktree(picked.entry.path, opts.force) catch |err| {
        if (opts.force) return err;
        app.ui.warn("{s}", .{git.last_error});
        app.ui.flush();
        const forced = try prompt.confirm(
            app.gpa,
            app.io,
            "Worktree has uncommitted changes or is locked. Force remove?",
            false,
        ) orelse std.process.exit(app_mod.cancelled_exit_code);
        if (!forced) {
            app.ui.hint("Aborted.", .{});
            return;
        }
        try repo.removeWorktree(picked.entry.path, true);
    };

    app.ui.success("Removed worktree {f}", .{
        ui.cyan(picked.entry.branch orelse app_mod.shortHead(picked.entry.head)),
    });

    var reclaimed: u64 = 0;
    reclaimed += try purgeDerived(app, attached.derived, dd_root);
    if (opts.sessions) {
        reclaimed += try purgeSessions(app, attached.sessions, cp_root);
    } else if (attached.sessions.len > 0) {
        app.ui.hint("Kept {d} session transcript folder{s} — delete with: lcc remove --sessions", .{
            attached.sessions.len, plural(attached.sessions.len),
        });
    }
    if (reclaimed > 0) {
        app.ui.success("Reclaimed {f}.", .{
            ui.bold(try std.fmt.allocPrint(app.gpa, "{f}", .{ui.bytes(reclaimed)})),
        });
    }

    try disposeBranch(app, repo, picked.entry.branch, disposition);
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
    try out.appendSlice(w, try std.fmt.allocPrint(w, "    worktree   {s}\n", .{picked.entry.path}));
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
    if (disposition) |d| {
        try out.appendSlice(w, try std.fmt.allocPrint(w, "    branch     {s}  {s}\n", .{
            d.branch, try describeDisposition(w, d),
        }));
    }
    return out.toOwnedSlice(w);
}

fn describeDisposition(gpa: std.mem.Allocator, d: git.BranchDisposition) ![]const u8 {
    return switch (d.reason) {
        .merged => "(merged — will be deleted)",
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
    const branch = branch_name orelse return; // Detached worktree — no branch to speak of.
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

    // A gone upstream means `-d` refuses even though the work is safely merged.
    repo.deleteBranch(branch, d.reason == .upstream_gone) catch {
        app.ui.warn("Could not delete branch {s}", .{branch});
        app.ui.hint("  Delete manually with: git branch -D {s}", .{branch});
        return;
    };
    app.ui.success("Deleted branch {f}", .{ui.cyan(branch)});
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

/// One candidate for bulk removal: a worktree whose branch is safely merged, or
/// a branch that outlived its worktree.
const Row = struct {
    /// Null when only the branch is left.
    worktree: ?git.WorktreeEntry,
    branch: []const u8,
    disposition: git.BranchDisposition,
    attached: Attached = .{},

    fn reason(self: Row) []const u8 {
        return switch (self.disposition.reason) {
            .merged => "merged",
            .upstream_gone => "remote gone",
            else => "safe",
        };
    }
};

fn runMerged(app: app_mod.App, repo: git.Repo, opts: Opts) !void {
    app.ui.step("Checking which branches are already merged…", .{});
    app.ui.flush();

    const worktrees = try repo.listWorktrees();

    // A branch checked out anywhere — including the main worktree — is off limits:
    // git refuses to delete it, and lcc must not pretend otherwise.
    var checked_out: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (worktrees) |entry| {
        if (entry.branch) |branch| try checked_out.put(app.gpa, branch, {});
    }

    var rows: std.ArrayList(Row) = .empty;
    for (worktrees) |entry| {
        if (entry.is_main) continue;
        // Detached: no branch, so nothing tells us the commits survived.
        const branch = entry.branch orelse continue;
        const disposition = try repo.branchDisposition(branch);
        if (!disposition.safe) continue;
        try rows.append(app.gpa, .{
            .worktree = entry,
            .branch = branch,
            .disposition = disposition,
        });
    }

    for (try repo.branchStatuses()) |status| {
        if (checked_out.contains(status.branch)) continue;
        const disposition = try repo.branchDisposition(status.branch);
        if (!disposition.safe) continue;
        try rows.append(app.gpa, .{
            .worktree = null,
            .branch = status.branch,
            .disposition = disposition,
        });
    }

    if (rows.items.len == 0) {
        app.ui.success("Nothing merged to clean up.", .{});
        return;
    }

    // `dd.root` shells out to `defaults`, so resolve both once and pass them down.
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
            repo.removeWorktree(entry.path, opts.force) catch {
                app.ui.warn("Kept {f} — {s}", .{ ui.cyan(row.branch), git.last_error });
                app.ui.hint("  Retry with: lcc remove --merged --force", .{});
                continue;
            };
            worktrees_gone += 1;
            app.ui.success("Removed worktree {f}", .{ui.cyan(row.branch)});

            reclaimed += try purgeDerived(app, row.attached.derived, dd_root);
            if (opts.sessions) reclaimed += try purgeSessions(app, row.attached.sessions, cp_root);
        }

        if (opts.keep_branch) continue;
        repo.deleteBranch(row.branch, row.disposition.reason == .upstream_gone) catch {
            app.ui.warn("Could not delete branch {s}", .{row.branch});
            app.ui.hint("  Delete manually with: git branch -D {s}", .{row.branch});
            continue;
        };
        branches_gone += 1;
        app.ui.success("Deleted branch {f}", .{ui.cyan(row.branch)});
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

/// Matches build data and session folders to every row, then sizes them all with
/// a single `du` — one child process for the whole batch rather than one per row.
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

    var paths: std.ArrayList([]const u8) = .empty;
    const derived = try app.gpa.alloc([]dd.Entry, rows.len);
    const sessions = try app.gpa.alloc([]cp.Entry, rows.len);

    for (rows, 0..) |row, i| {
        const entry = row.worktree orelse {
            derived[i] = &.{};
            sessions[i] = &.{};
            continue;
        };
        derived[i] = try dd.forWorktree(app.gpa, app.io, dd_all, entry.path);
        sessions[i] = try cp.forWorktree(app.gpa, app.io, cp_all, entry.path);
        for (derived[i]) |e| try paths.append(app.gpa, e.path);
        for (sessions[i]) |e| try paths.append(app.gpa, e.path);
    }

    if (paths.items.len > 0) {
        app.ui.step("Measuring build data and sessions ({d})…", .{paths.items.len});
        app.ui.flush();
    }
    const sizes = try disk.usage(app.gpa, app.io, paths.items);

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
        row.attached = .{ .derived = dd_sized, .sessions = cp_sized };
    }
}

fn selectRows(app: app_mod.App, rows: []const Row, opts: Opts) ![]const Row {
    var branch_width: usize = 0;
    var reason_width: usize = 0;
    for (rows) |row| {
        branch_width = @max(branch_width, ui.displayWidth(row.branch));
        reason_width = @max(reason_width, row.reason().len);
    }

    const items = try app.gpa.alloc(prompt.Item, rows.len);
    for (rows, 0..) |row, i| {
        const size = row.attached.reclaimable(opts.sessions);
        const reclaim = if (size == 0)
            try app.gpa.dupe(u8, "—")
        else
            try std.fmt.allocPrint(app.gpa, "{f}", .{ui.bytes(size)});

        items[i] = .{
            .label = try std.fmt.allocPrint(app.gpa, "{f}  {f}  {f}  {s}", .{
                ui.pad(row.branch, branch_width),
                ui.pad(row.reason(), reason_width),
                ui.pad(reclaim, 8),
                if (row.worktree) |entry|
                    disk.abbreviate(app.gpa, app.environ, entry.path)
                else
                    "branch only — no worktree left",
            }),
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
