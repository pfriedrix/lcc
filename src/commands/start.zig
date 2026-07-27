//! `lcc` / `lcc start` — pick an issue, bootstrap a worktree, launch Claude.

const std = @import("std");
const app_mod = @import("../app.zig");
const claude = @import("../claude.zig");
const config = @import("../config.zig");
const git = @import("../git.zig");
const link = @import("../link.zig");
const linear = @import("../linear.zig");
const oauth = @import("../oauth.zig");
const prompt = @import("../prompt.zig");
const ui = @import("../ui.zig");

const priority_label = [_][]const u8{ "   ", "U  ", "H  ", "M  ", "L  " };

pub fn run(app: app_mod.App, all: bool) !void {
    if (oauth.getToken(app.gpa) == null) {
        app.ui.fail("Not authenticated. Run `lcc auth` first.", .{});
        std.process.exit(1);
    }

    const cfg = try config.load(app.gpa, app.io, app.environ);
    const repo = try app.repo();

    const fetch_label = if (all)
        try app.gpa.dupe(u8, "all states")
    else
        try std.mem.join(app.gpa, ", ", cfg.activeStates);
    app.ui.step("Fetching Linear issues ({s})...", .{fetch_label});
    app.ui.flush();

    const token = oauth.ensureFreshToken(app.gpa, app.io, cfg.clientId) catch |err| {
        app.ui.fail("{s}: {s}", .{ @errorName(err), oauth.last_detail });
        std.process.exit(1);
    };

    const result = linear.fetchActiveIssues(app.gpa, app.io, token, cfg.activeStates, all) catch |err| {
        app.ui.fail("Linear request failed ({s}, HTTP {d}): {s}", .{
            @errorName(err), linear.last_status, linear.last_message,
        });
        std.process.exit(1);
    };

    if (!all and result.skipped.len > 0) {
        var skipped_total: u32 = 0;
        for (result.skipped) |s| skipped_total += s.count;

        var breakdown: std.ArrayList(u8) = .empty;
        for (result.skipped, 0..) |s, i| {
            if (i > 0) try breakdown.appendSlice(app.gpa, ", ");
            try breakdown.appendSlice(
                app.gpa,
                try std.fmt.allocPrint(app.gpa, "{s} ({d})", .{ s.name, s.count }),
            );
        }
        app.ui.hint(
            "Filtered out {d} of {d} assigned issues — not in activeStates: {s}",
            .{ skipped_total, result.total, breakdown.items },
        );
        app.ui.hint(
            "To include them, edit ~/.config/lcc/config.json → activeStates, or run `lcc --all`.",
            .{},
        );
    }

    if (result.matched.len == 0) {
        if (all) {
            app.ui.warn("No active issues assigned to you (excluding Completed/Canceled).", .{});
        } else {
            app.ui.warn("No issues assigned to you in: {s}.", .{fetch_label});
        }
        return;
    }

    const selected = try pickIssue(app, result.matched) orelse
        std.process.exit(app_mod.cancelled_exit_code);

    const branch = try git.rewriteBranchName(app.gpa, selected.branch_name, "feature");
    app.ui.hint("Selected {s} — branch {s}", .{ selected.identifier, branch });

    const worktree_path = try git.renderWorktreePath(app.gpa, cfg.worktreeTemplate, repo.root, branch);

    const strategy = repo.resolveStrategy(branch);
    var base: []const u8 = undefined;
    if (strategy == .new) {
        const def = try repo.defaultBranch();
        const cur = try repo.currentBranch();
        if (cur == null or std.mem.eql(u8, cur.?, def)) {
            base = def;
        } else {
            app.ui.flush();
            const message = try std.fmt.allocPrint(app.gpa, "Base new branch on current '{s}'?", .{cur.?});
            const use_current = try prompt.confirm(app.gpa, app.io, message, true) orelse
                std.process.exit(app_mod.cancelled_exit_code);
            if (use_current) {
                base = cur.?;
            } else {
                base = try pickBaseBranch(app, repo) orelse
                    std.process.exit(app_mod.cancelled_exit_code);
            }
        }
        app.ui.step("Creating worktree at {f} (base: {f})", .{ ui.dim(worktree_path), ui.bold(base) });
    } else {
        base = try repo.defaultBranch();
        app.ui.step("Creating worktree at {f}", .{ui.dim(worktree_path)});
    }
    app.ui.flush();

    const wt = repo.createWorktree(branch, worktree_path, base) catch |err| {
        if (err == git.Error.WorktreePathExists) {
            app.ui.fail(
                "Worktree path already exists: {s}\nRemove it first with: git worktree remove {s}  (or delete the directory).",
                .{ worktree_path, worktree_path },
            );
            std.process.exit(1);
        }
        return err;
    };

    const summary = switch (wt.created) {
        .new => try std.fmt.allocPrint(app.gpa, "created from {s}", .{base}),
        .reused_local => try app.gpa.dupe(u8, "reused local branch"),
        .tracking_remote => try std.fmt.allocPrint(app.gpa, "tracking origin/{s}", .{branch}),
    };
    app.ui.success("Worktree {s}: {s}", .{ summary, wt.path });

    const to_link = try link.findFiles(app.gpa, app.io, repo.root, cfg.linkPatterns, cfg.linkExclude);
    if (to_link.len == 0) {
        app.ui.hint("Nothing matched linkPatterns in the repo — skipping symlinks.", .{});
    } else {
        const linked = try link.linkFiles(app.gpa, app.io, to_link, worktree_path);
        for (linked) |r| {
            switch (r.status) {
                .linked => app.ui.success("Linked {s}", .{r.rel}),
                .skipped_exists => app.ui.hint("Skipped {s} (already exists in worktree)", .{r.rel}),
            }
        }
    }

    app.ui.info("", .{});
    app.ui.info("{f} in {f}", .{ ui.bold("Launching Claude Code"), ui.dim(worktree_path) });
    app.ui.hint("Linear: {s}", .{selected.url});
    app.ui.info("", .{});
    app.ui.flush();

    var extra: std.ArrayList([]const u8) = .empty;
    const trimmed_command = std.mem.trim(u8, cfg.startTaskCommand, " \t");
    if (trimmed_command.len > 0) {
        try extra.append(app.gpa, try expandCommand(app.gpa, cfg.startTaskCommand, selected, branch));
    }

    const code = try claude.launch(app.gpa, app.io, worktree_path, extra.items);
    std.process.exit(code);
}

fn pickIssue(app: app_mod.App, issues: []const linear.Issue) !?linear.Issue {
    const items = try app.gpa.alloc(prompt.Item, issues.len);
    for (issues, 0..) |issue, i| {
        const prio_index: usize = if (issue.priority >= 0 and issue.priority <= 4)
            @intCast(issue.priority)
        else
            0;
        items[i] = .{
            .label = try std.fmt.allocPrint(app.gpa, "{f} {s} {f} {s}", .{
                ui.pad(issue.identifier, 8),
                priority_label[prio_index],
                ui.pad(issue.state_name, 20),
                issue.title,
            }),
            .haystack = try std.fmt.allocPrint(app.gpa, "{s} {s} {s} {s} {s} {s}", .{
                issue.identifier,
                issue.title,
                issue.branch_name,
                issue.state_name,
                issue.assignee_name orelse "",
                issue.team_key orelse "",
            }),
            .description = try std.fmt.allocPrint(app.gpa, "{s} — {s}", .{
                issue.branch_name, issue.url,
            }),
        };
    }

    app.ui.flush();
    const message = try std.fmt.allocPrint(
        app.gpa,
        "Pick a Linear issue ({d} total, type to search):",
        .{issues.len},
    );
    const index = try prompt.search(app.gpa, app.io, message, items) orelse return null;
    return issues[index];
}

fn pickBaseBranch(app: app_mod.App, repo: git.Repo) !?[]const u8 {
    const branches = try repo.listBranches();
    const items = try app.gpa.alloc(prompt.Item, branches.len);
    for (branches, 0..) |branch, i| {
        items[i] = .{ .label = branch, .haystack = branch };
    }
    app.ui.flush();
    const index = try prompt.search(app.gpa, app.io, "Pick base branch:", items) orelse return null;
    return branches[index];
}

fn expandCommand(
    gpa: std.mem.Allocator,
    template: []const u8,
    issue: linear.Issue,
    branch: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, template, i, '}')) |close| {
                const key = template[i + 1 .. close];
                const value: ?[]const u8 =
                    if (std.mem.eql(u8, key, "identifier")) issue.identifier
                    else if (std.mem.eql(u8, key, "branch")) branch
                    else if (std.mem.eql(u8, key, "url")) issue.url
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
