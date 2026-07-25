//! `lcc remove` — drop a worktree, its Xcode build data, and its branch.

const std = @import("std");
const app_mod = @import("../app.zig");
const dd = @import("../derived_data.zig");
const git = @import("../git.zig");
const prompt = @import("../prompt.zig");
const ui = @import("../ui.zig");

pub const Opts = struct {
    force: bool = false,
    yes: bool = false,
    keep_derived_data: bool = false,
    keep_branch: bool = false,
};

pub fn run(app: app_mod.App, opts: Opts) !void {
    const repo = try app.repo();
    const choices = try app_mod.worktreeChoices(app, repo);
    if (choices.len == 0) {
        app.ui.warn("No worktrees to remove (only the main one exists).", .{});
        return;
    }

    const picked = try app_mod.pickWorktree(app, choices, "Pick a worktree to remove:") orelse
        std.process.exit(app_mod.cancelled_exit_code);

    // Match before removing: once the directory is gone the folders still resolve by
    // path, but the user needs to see what is about to go in the confirmation.
    const root = try dd.root(app.gpa, app.io, app.environ);
    const derived: []dd.Entry = if (opts.keep_derived_data)
        &.{}
    else
        try dd.forWorktree(app.gpa, app.io, try dd.list(app.gpa, app.io, root), picked.entry.path);

    if (derived.len > 0) app.ui.step("Measuring Xcode build data ({d})…", .{derived.len});
    app.ui.flush();
    const sized = try dd.withSizes(app.gpa, app.io, derived);

    const disposition: ?git.BranchDisposition = if (picked.entry.branch != null and !opts.keep_branch)
        try repo.branchDisposition(picked.entry.branch.?)
    else
        null;

    if (!opts.yes) {
        const message = try confirmMessage(app, picked, sized, disposition);
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

    try purge(app, sized, root);
    try disposeBranch(app, repo, picked.entry.branch, disposition);
}

fn confirmMessage(
    app: app_mod.App,
    picked: app_mod.Choice,
    sized: []const dd.Sized,
    disposition: ?git.BranchDisposition,
) ![]u8 {
    const label = picked.entry.branch orelse app_mod.shortHead(picked.entry.head);

    var out: std.ArrayList(u8) = .empty;
    const w = app.gpa;
    try out.appendSlice(w, try std.fmt.allocPrint(w, "Remove worktree {s}?\n", .{label}));
    try out.appendSlice(w, try std.fmt.allocPrint(w, "    worktree   {s}\n", .{picked.entry.path}));
    for (sized) |item| {
        try out.appendSlice(w, try std.fmt.allocPrint(w, "    build data {s}  ({f})\n", .{
            item.entry.name, ui.bytes(item.size),
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
            if (d.unmerged == 1) "" else "s",
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
                if (d.unmerged == 1) "" else "s",
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

fn purge(app: app_mod.App, sized: []const dd.Sized, root: []const u8) !void {
    if (sized.len == 0) return;
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
    if (reclaimed > 0) {
        app.ui.success("Reclaimed {f}.", .{
            ui.bold(try std.fmt.allocPrint(app.gpa, "{f}", .{ui.bytes(reclaimed)})),
        });
    }
}
