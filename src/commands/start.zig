const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const claude = @import("../claude.zig");
const config = @import("../config.zig");
const disk = @import("../disk.zig");
const git = @import("../git.zig");
const link = @import("../link.zig");
const linear = @import("../linear.zig");
const mcp = @import("../mcp.zig");
const oauth = @import("../oauth.zig");
const prompt = @import("../prompt.zig");
const repos = @import("../repos.zig");
const ui = @import("../ui.zig");
const usage = @import("../usage.zig");
const watch_client = @import("../watch_client.zig");
const watch_cmd = @import("watch.zig");

const priority_label = [_][]const u8{ "   ", "U  ", "H  ", "M  ", "L  " };

pub const Opts = struct {
    all: bool = false,
    issue: ?[]const u8 = null,
    json: bool = false,
    base: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    plan: ?[]const u8 = null,
    plan_mode: bool = true,
    watch: bool = true,
    no_attach: bool = false,
    cancel_returns: bool = false,
};

fn cancel(opts: Opts) error{Cancelled} {
    if (opts.cancel_returns) return error.Cancelled;
    std.process.exit(app_mod.cancelled_exit_code);
}

pub fn run(app: app_mod.App, opts: Opts) !void {
    if (opts.json and opts.issue == null) {
        bail(app, opts.json, "usage", "--json needs an issue to resolve, e.g. `lcc start PE-256 --json`.", .{});
    }
    if (opts.json and opts.all) {
        bail(app, opts.json, "usage", "--all only affects the picker, which --json does not use.", .{});
    }
    const plan_path: ?[]const u8 = if (opts.plan) |raw| blk: {
        const resolved = Io.Dir.cwd().realPathFileAlloc(app.io, raw, app.gpa) catch |err| switch (err) {
            error.FileNotFound => bail(app, opts.json, "plan_not_found", "No plan file at {s}.", .{raw}),
            else => bail(app, opts.json, "plan_unreadable", "Cannot read plan at {s}: {s}", .{ raw, @errorName(err) }),
        };
        const info = Io.Dir.cwd().statFile(app.io, resolved, .{}) catch |err|
            bail(app, opts.json, "plan_unreadable", "Cannot read plan at {s}: {s}", .{ raw, @errorName(err) });
        if (info.kind != .file) {
            bail(app, opts.json, "plan_not_found", "{s} is a {s}, not a plan file.", .{ raw, @tagName(info.kind) });
        }
        break :blk resolved;
    } else null;
    app.ui.hint("Reading the Linear token from the Keychain...", .{});
    app.ui.flush();
    if (oauth.getToken(app.gpa) == null) {
        bail(app, opts.json, "not_authenticated", "Not authenticated. Run `lcc auth` first.", .{});
    }

    const cfg = try config.load(app.gpa, app.io, app.environ);

    const plan_mode = plan_path == null and opts.plan_mode;

    if (plan_path != null and !templateCarriesPlan(cfg.startTaskCommand)) {
        bail(
            app,
            opts.json,
            "usage",
            "--plan needs {{plan}} in startTaskCommand — nothing else carries it to the agent. Add it with `lcc setup`.",
            .{},
        );
    }

    const token = oauth.ensureFreshToken(app.gpa, app.io, cfg.clientId) catch |err| {
        bail(app, opts.json, "auth_failed", "{s}: {s}", .{ @errorName(err), oauth.last_detail });
    };

    const selected = if (opts.issue) |raw|
        try fetchNamed(app, opts, token, raw)
    else
        try pickFromActive(app, opts, cfg, token) orelse return;

    const suggested = try git.rewriteBranchName(app.gpa, selected.branch_name, "feature");
    if (!opts.json) app.ui.hint("Selected {s} — branch {s}", .{ selected.identifier, suggested });

    var repo = try resolveRepo(app, opts, selected.identifier);
    repo.stdout_reserved = opts.json;

    const wt = try bootstrap(app, opts, cfg, repo, suggested);

    const learned = try repos.remember(
        app.gpa,
        repos.load(app.gpa, app.io, app.environ),
        selected.identifier,
        repo.root,
    );
    repos.save(app.gpa, app.io, app.environ, learned) catch {};

    const claude_carried = if (wt.is_main_checkout)
        null
    else
        try mcp.carry(app.gpa, app.io, app.environ, repo.root);
    const carried: ?McpFact =
        if (claude_carried) |value| .{ .path = value.path, .names = value.names } else null;

    const trimmed_command = std.mem.trim(u8, cfg.startTaskCommand, " \t");
    const expanded = if (trimmed_command.len > 0)
        try expandCommand(app.gpa, cfg.startTaskCommand, selected, wt.branch, plan_path)
    else
        null;

    const initial_prompt: ?[]const u8 = if (expanded) |e| e.text else null;

    if (opts.json) {
        try report(app, repo, selected, suggested, wt, carried, initial_prompt);
        return;
    }

    const launch_label = if (plan_mode)
        "Launching Claude Code in plan mode"
    else
        "Launching Claude Code";
    app.ui.info("", .{});
    app.ui.info("{f} in {f}", .{ ui.bold(launch_label), ui.dim(wt.path) });
    app.ui.hint("Linear: {s}", .{selected.url});
    if (plan_path) |path| app.ui.hint("Plan: {s}", .{path});
    const spent = usage.forWorktree(app.gpa, app.io, app.environ, wt.path);
    if (!spent.empty()) {
        app.ui.hint("Spent here: {f}", .{usage.brief(spent, app_mod.nowSeconds(app.io))});
    }
    if (carried) |c| {
        app.ui.hint("MCP: carrying {d} local server(s) from {s} — {s}", .{
            c.names.len,
            std.fs.path.basename(repo.root),
            try std.mem.join(app.gpa, ", ", c.names),
        });
    }
    app.ui.info("", .{});
    app.ui.flush();

    const args = try launchArgs(
        app.gpa,
        if (claude_carried) |c| c.path else null,
        initial_prompt,
        plan_mode,
    );

    if (opts.watch) {
        if (watch_client.startSession(app, .{
            .worktree = wt.path,
            .branch = wt.branch,
            .issue = selected.identifier,
            .repo_root = repo.root,
            .program = try claude.resolvePath(app.gpa, app.io),
            .argv = args,
        })) |started| {
            if (opts.no_attach) {
                app.ui.success("Session {s} running in the background.", .{started.id});
                app.ui.hint("It survives this terminal closing — `lcc open` shows it.", .{});
                return;
            }
            app.ui.flush();
            return watch_cmd.run(app, .{});
        } else |err| {
            app.ui.warn("Could not start this in the background ({s}) — running in this terminal instead.", .{@errorName(err)});
            app.ui.hint("The session will not survive this terminal closing.", .{});
        }
    }

    const code = try claude.launch(app.gpa, app.io, wt.path, args);
    std.process.exit(code);
}

fn fetchNamed(
    app: app_mod.App,
    opts: Opts,
    token: oauth.Token,
    raw: []const u8,
) !linear.Issue {
    const trimmed = std.mem.trim(u8, raw, " \t");
    const ref = linear.refFromBranch(trimmed) orelse bail(
        app,
        opts.json,
        "bad_identifier",
        "'{s}' is not an issue identifier — expected something like PE-256.",
        .{trimmed},
    );

    if (!opts.json) {
        app.ui.step("Fetching {s}...", .{trimmed});
        app.ui.flush();
    }

    const found = linear.fetchIssue(app.gpa, app.io, token, ref) catch |err| bail(
        app,
        opts.json,
        "linear_failed",
        "Linear request failed ({s}, HTTP {d}): {s}",
        .{ @errorName(err), linear.last_status, linear.last_message },
    );
    return found orelse bail(app, opts.json, "issue_not_found", "No issue {s} in Linear.", .{trimmed});
}

fn pickFromActive(
    app: app_mod.App,
    opts: Opts,
    cfg: config.Config,
    token: oauth.Token,
) !?linear.Issue {
    const fetch_label = if (opts.all)
        try app.gpa.dupe(u8, "all states")
    else
        try std.mem.join(app.gpa, ", ", cfg.activeStates);
    app.ui.step("Fetching Linear issues ({s})...", .{fetch_label});
    app.ui.flush();

    const result = linear.fetchActiveIssues(app.gpa, app.io, token, cfg.activeStates, opts.all) catch |err| bail(
        app,
        opts.json,
        "linear_failed",
        "Linear request failed ({s}, HTTP {d}): {s}",
        .{ @errorName(err), linear.last_status, linear.last_message },
    );

    if (!opts.all and result.skipped.len > 0) {
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
            "To include them, edit ~/.config/lcc/config.json → activeStates, or run `lcc start --all`.",
            .{},
        );
    }

    if (result.matched.len == 0) {
        if (opts.all) {
            app.ui.warn("No active issues assigned to you (excluding Completed/Canceled).", .{});
        } else {
            app.ui.warn("No issues assigned to you in: {s}.", .{fetch_label});
        }
        return null;
    }

    return try pickIssue(app, result.matched) orelse
        return cancel(opts);
}

const MatchedBy = enum { branch, issue };

const Bootstrapped = struct {
    branch: []const u8,
    path: []const u8,
    status: enum { created, existing },
    matched_by: ?MatchedBy,
    created: ?git.Strategy,
    base: ?[]const u8,
    is_main_checkout: bool,
    linked: []const []const u8,
    skipped: []const []const u8,
};

const Match = struct {
    entry: git.WorktreeEntry,
    by: MatchedBy,
};

fn findWorktree(entries: []const git.WorktreeEntry, branch: []const u8) ?Match {
    if (git.worktreeForBranch(entries, branch)) |entry| return .{ .entry = entry, .by = .branch };
    for (entries) |entry| {
        const name = entry.branch orelse continue;
        if (linear.sameIssue(name, branch)) return .{ .entry = entry, .by = .issue };
    }
    return null;
}

fn newestBranchForIssue(statuses: []const git.BranchStatus, suggested: []const u8) ?[]const u8 {
    var best: ?git.BranchStatus = null;
    for (statuses) |status| {
        if (std.mem.eql(u8, status.branch, suggested)) continue;
        if (!linear.sameIssue(status.branch, suggested)) continue;
        if (best == null or status.committed_at > best.?.committed_at) best = status;
    }
    return if (best) |status| status.branch else null;
}

fn bootstrap(
    app: app_mod.App,
    opts: Opts,
    cfg: config.Config,
    repo: git.Repo,
    suggested: []const u8,
) !Bootstrapped {
    var branch = suggested;
    var path: []const u8 = undefined;
    var status: @FieldType(Bootstrapped, "status") = .created;
    var matched_by: ?MatchedBy = null;
    var created: ?git.Strategy = null;
    var base: ?[]const u8 = null;
    var is_main_checkout = false;

    const entries = try repo.listWorktrees();
    if (findWorktree(entries, suggested)) |match| {
        branch = match.entry.branch.?;
        path = match.entry.path;
        status = .existing;
        matched_by = match.by;
        is_main_checkout = match.entry.is_main;
        if (!opts.json) {
            if (match.by == .issue) {
                app.ui.warn(
                    "The issue was renamed in Linear — its work is on {s}, while Linear now suggests {s}.",
                    .{ branch, suggested },
                );
            }
            if (match.entry.is_main) {
                app.ui.warn("{s} is checked out in the main checkout — working there, not in a worktree.", .{branch});
            } else {
                app.ui.success("Worktree already exists: {s}", .{match.entry.path});
            }
        }
    } else {
        if (repo.resolveStrategy(branch) == .new) {
            if (newestBranchForIssue(try repo.branchStatuses(), branch)) |existing| {
                if (!opts.json) app.ui.warn(
                    "The issue was renamed in Linear — its branch is {s}, while Linear now suggests {s}.",
                    .{ existing, branch },
                );
                branch = existing;
            }
        }

        path = try git.renderWorktreePath(app.gpa, cfg.worktreeTemplate, repo.root, branch);
        base = try resolveBase(app, opts, repo, branch);

        if (!opts.json) {
            if (repo.resolveStrategy(branch) == .new) {
                app.ui.step("Creating worktree at {f} (base: {f})", .{ ui.dim(path), ui.bold(base.?) });
            } else {
                app.ui.step("Creating worktree at {f}", .{ui.dim(path)});
            }
            app.ui.flush();
        }

        const wt = repo.createWorktree(branch, path, base.?) catch |err| switch (err) {
            git.Error.WorktreePathExists => bail(
                app,
                opts.json,
                "worktree_path_exists",
                "Worktree path already exists but no worktree is registered there: {s}\nRemove it first with: git worktree remove {s}  (or delete the directory).",
                .{ path, path },
            ),
            git.Error.GitFailed => if (git.last_error.len > 0)
                bail(app, opts.json, "git_failed", "git worktree add failed: {s}", .{git.last_error})
            else
                bail(app, opts.json, "git_failed", "git worktree add failed.", .{}),
            else => return err,
        };
        created = wt.created;

        if (!opts.json) {
            const summary = switch (wt.created) {
                .new => try std.fmt.allocPrint(app.gpa, "created from {s}", .{base.?}),
                .reused_local => try app.gpa.dupe(u8, "reused local branch"),
                .tracking_remote => try std.fmt.allocPrint(app.gpa, "tracking origin/{s}", .{branch}),
            };
            app.ui.success("Worktree {s}: {s}", .{ summary, wt.path });
        }
    }

    var linked: std.ArrayList([]const u8) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;

    const to_link = try link.findFiles(app.gpa, app.io, repo.root, cfg.linkPatterns, cfg.linkExclude);
    if (to_link.len == 0) {
        if (!opts.json) app.ui.hint("Nothing matched linkPatterns in the repo — skipping symlinks.", .{});
    } else {
        for (try link.linkFiles(app.gpa, app.io, to_link, path)) |r| {
            switch (r.status) {
                .linked => {
                    try linked.append(app.gpa, r.rel);
                    if (!opts.json) app.ui.success("Linked {s}", .{r.rel});
                },
                .skipped_exists => {
                    try skipped.append(app.gpa, r.rel);
                    if (!opts.json) app.ui.hint("Skipped {s} (already exists in worktree)", .{r.rel});
                },
            }
        }
    }
    return .{
        .branch = branch,
        .path = path,
        .status = status,
        .matched_by = matched_by,
        .created = created,
        .base = base,
        .is_main_checkout = is_main_checkout,
        .linked = try linked.toOwnedSlice(app.gpa),
        .skipped = try skipped.toOwnedSlice(app.gpa),
    };
}

fn resolveRepo(app: app_mod.App, opts: Opts, identifier: []const u8) !git.Repo {
    if (opts.repo) |given| return app.repoAt(given) catch bail(
        app,
        opts.json,
        "bad_repo",
        "--repo {s} is not inside a git repository.",
        .{given},
    );

    const state = repos.load(app.gpa, app.io, app.environ);

    if (repos.recall(state, identifier)) |remembered| {
        if (app.repoAt(remembered)) |found| {
            if (!opts.json) app.ui.hint("{s} lives in {f}", .{
                identifier,
                ui.bold(std.fs.path.basename(found.root)),
            });
            return found;
        } else |_| {}
    }

    const here: ?[]const u8 = if (app.repo()) |found| found.root else |_| null;
    const known = try repos.candidates(app.gpa, app.io, state, here, here);

    const started = try repos.withIssueBranch(app.gpa, app.io, known, identifier);
    if (started.len == 1) {
        const found = try app.repoAt(started[0]);
        if (!opts.json and (here == null or !std.mem.eql(u8, found.root, here.?))) {
            app.ui.hint("{s} already has a branch in {f}", .{
                identifier,
                ui.bold(std.fs.path.basename(found.root)),
            });
        }
        return found;
    }

    if (opts.json) bail(
        app,
        opts.json,
        "repo_unconfirmed",
        "Nothing says which repository {s} belongs to: no answer remembered for it, and " ++
            "no branch for it in any repository lcc knows{s}. --json will not fall back to the " ++
            "current directory — re-run with --repo <path>, or once interactively to answer it.",
        .{ identifier, if (here) |root| root else "" },
    );

    const offer = if (started.len > 1) started else known;
    if (offer.len == 0) return error.NotAGitRepository;
    return app.repoAt(try pickRepo(app, opts, identifier, offer));
}

fn pickRepo(app: app_mod.App, opts: Opts, identifier: []const u8, roots: []const []const u8) ![]const u8 {
    const items = try app.gpa.alloc(prompt.Item, roots.len);
    for (roots, 0..) |root, i| {
        items[i] = .{
            .label = try std.fmt.allocPrint(app.gpa, "{f}  {f}", .{
                ui.pad(std.fs.path.basename(root), 28),
                ui.dim(root),
            }),
            .haystack = root,
            .description = root,
        };
    }

    app.ui.flush();
    const message = try std.fmt.allocPrint(
        app.gpa,
        "Which repository does {s} live in? (asked once — lcc remembers)",
        .{identifier},
    );
    const index = try prompt.search(app.gpa, app.io, message, items) orelse
        return cancel(opts);
    return roots[index];
}

fn resolveBase(app: app_mod.App, opts: Opts, repo: git.Repo, branch: []const u8) ![]const u8 {
    if (opts.base) |explicit| return explicit;

    const def = try repo.defaultBranch();
    if (repo.resolveStrategy(branch) != .new) return def;

    const cur = try repo.currentBranch();
    if (cur == null or std.mem.eql(u8, cur.?, def)) return def;

    if (opts.json) return def;

    app.ui.flush();
    const message = try std.fmt.allocPrint(app.gpa, "Base new branch on current '{s}'?", .{cur.?});
    const use_current = try prompt.confirm(app.gpa, app.io, message, true) orelse
        return cancel(opts);
    if (use_current) return cur.?;

    return try pickBaseBranch(app, repo) orelse
        return cancel(opts);
}

const Report = struct {
    issue: ReportIssue,
    branch: ReportBranch,
    worktree: ReportWorktree,
    repo: ReportRepo,
    links: ReportLinks,
    start_task_command: ?[]const u8,
    mcp: ?ReportMcp,
};

const McpFact = struct {
    path: []const u8,
    names: []const []const u8,
};

const ReportIssue = struct {
    id: []const u8,
    identifier: []const u8,
    title: []const u8,
    url: []const u8,
    state: []const u8,
    state_type: []const u8,
    team: ?[]const u8,
    assignee: ?[]const u8,
};

const ReportBranch = struct {
    name: []const u8,
    suggested: []const u8,
    renamed: bool,
    upstream: ?[]const u8,
    pushed: bool,
    ahead: u32,
    behind: u32,
    current: bool,
};

const ReportWorktree = struct {
    path: []const u8,
    status: []const u8,
    matched_by: ?[]const u8,
    created: ?[]const u8,
    base: ?[]const u8,
    is_main_checkout: bool,
    is_cwd: bool,
};

const ReportRepo = struct {
    root: []const u8,
    default_branch: []const u8,
};

const ReportLinks = struct {
    linked: []const []const u8,
    skipped: []const []const u8,
};

const ReportMcp = struct {
    config: []const u8,
    servers: []const []const u8,
};

const Facts = struct {
    current_branch: ?[]const u8,
    branch_status: ?git.BranchStatus,
    repo_root: []const u8,
    default_branch: []const u8,
    is_cwd: bool,
    start_task_command: ?[]const u8,
    carried: ?McpFact,
};

fn buildReport(
    issue: linear.Issue,
    suggested: []const u8,
    wt: Bootstrapped,
    facts: Facts,
) Report {
    return .{
        .issue = .{
            .id = issue.id,
            .identifier = issue.identifier,
            .title = issue.title,
            .url = issue.url,
            .state = issue.state_name,
            .state_type = issue.state_type,
            .team = issue.team_key,
            .assignee = issue.assignee_name,
        },
        .branch = .{
            .name = wt.branch,
            .suggested = suggested,
            .renamed = !std.mem.eql(u8, wt.branch, suggested),
            .upstream = if (facts.branch_status) |s| s.upstream else null,
            .pushed = if (facts.branch_status) |s| s.upstream != null else false,
            .ahead = if (facts.branch_status) |s| s.ahead else 0,
            .behind = if (facts.branch_status) |s| s.behind else 0,
            .current = if (facts.current_branch) |c| std.mem.eql(u8, c, wt.branch) else false,
        },
        .worktree = .{
            .path = wt.path,
            .status = @tagName(wt.status),
            .matched_by = if (wt.matched_by) |m| @tagName(m) else null,
            .created = if (wt.created) |c| @tagName(c) else null,
            .base = wt.base,
            .is_main_checkout = wt.is_main_checkout,
            .is_cwd = facts.is_cwd,
        },
        .repo = .{
            .root = facts.repo_root,
            .default_branch = facts.default_branch,
        },
        .links = .{
            .linked = wt.linked,
            .skipped = wt.skipped,
        },
        .start_task_command = facts.start_task_command,
        .mcp = if (facts.carried) |c|
            .{ .config = c.path, .servers = c.names }
        else
            null,
    };
}

fn report(
    app: app_mod.App,
    repo: git.Repo,
    issue: linear.Issue,
    suggested: []const u8,
    wt: Bootstrapped,
    carried: ?McpFact,
    start_task_command: ?[]const u8,
) !void {
    var branch_status: ?git.BranchStatus = null;
    for (try repo.branchStatuses()) |status| {
        if (!std.mem.eql(u8, status.branch, wt.branch)) continue;
        branch_status = status;
        break;
    }

    const value = buildReport(issue, suggested, wt, .{
        .current_branch = try repo.currentBranch(),
        .branch_status = branch_status,
        .repo_root = repo.root,
        .default_branch = try repo.defaultBranch(),
        .is_cwd = isCwd(app, wt.path),
        .start_task_command = start_task_command,
        .carried = carried,
    });

    const body = try std.json.Stringify.valueAlloc(app.gpa, value, .{ .whitespace = .indent_2 });
    app.ui.payload("{s}\n", .{body});
    app.ui.flush();
}

fn isCwd(app: app_mod.App, path: []const u8) bool {
    const here = Io.Dir.cwd().realPathFileAlloc(app.io, ".", app.gpa) catch return false;
    const there = disk.realPath(app.gpa, app.io, path);
    return std.mem.eql(u8, here, there) or disk.isInside(app.gpa, there, here);
}

fn bail(
    app: app_mod.App,
    json: bool,
    code: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) noreturn {
    const message = std.fmt.allocPrint(app.gpa, fmt, args) catch "";
    if (json) {
        const body = std.json.Stringify.valueAlloc(app.gpa, .{
            .@"error" = .{ .code = code, .message = message },
        }, .{ .whitespace = .indent_2 }) catch "{\"error\":{\"code\":\"internal\"}}";
        app.ui.payload("{s}\n", .{body});
    }
    app.ui.fail("{s}", .{message});
    app.ui.flush();
    std.process.exit(1);
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

test "findWorktree prefers the exact branch, then the issue behind it" {
    const entries = [_]git.WorktreeEntry{
        .{ .path = "/r", .branch = "main", .head = "a", .locked = false, .prunable = false, .is_main = true },
        .{
            .path = "/wt/old",
            .branch = "feature/pe-250-fix-clvisit-handling-dedupe-arrivaldeparture-double-writes",
            .head = "b",
            .locked = false,
            .prunable = false,
            .is_main = false,
        },
        .{ .path = "/wt/other", .branch = "feature/pe-9-unrelated", .head = "c", .locked = false, .prunable = false, .is_main = false },
    };

    const renamed = findWorktree(&entries, "feature/pe-250-fix-clvisit-capture-dropped-visits").?;
    try std.testing.expectEqualStrings("/wt/old", renamed.entry.path);
    try std.testing.expectEqual(MatchedBy.issue, renamed.by);

    const exact = findWorktree(&entries, "feature/pe-250-fix-clvisit-handling-dedupe-arrivaldeparture-double-writes").?;
    try std.testing.expectEqualStrings("/wt/old", exact.entry.path);
    try std.testing.expectEqual(MatchedBy.branch, exact.by);

    const both = entries ++ [_]git.WorktreeEntry{.{
        .path = "/wt/new",
        .branch = "feature/pe-250-fix-clvisit-capture-dropped-visits",
        .head = "d",
        .locked = false,
        .prunable = false,
        .is_main = false,
    }};
    const preferred = findWorktree(&both, "feature/pe-250-fix-clvisit-capture-dropped-visits").?;
    try std.testing.expectEqualStrings("/wt/new", preferred.entry.path);
    try std.testing.expectEqual(MatchedBy.branch, preferred.by);

    try std.testing.expect(findWorktree(&entries, "feature/pe-251-nothing-here") == null);
    try std.testing.expect(findWorktree(entries[0..1], "feature/pe-250-x") == null);
}

test "newestBranchForIssue reuses the renamed branch, and only the right issue's" {
    const statuses = [_]git.BranchStatus{
        .{ .branch = "main", .upstream = null, .ahead = 0, .behind = 0, .gone = false, .committed_at = 900 },
        .{ .branch = "feature/pe-250-first-name", .upstream = null, .ahead = 0, .behind = 0, .gone = false, .committed_at = 100 },
        .{ .branch = "feature/pe-250-second-name", .upstream = null, .ahead = 0, .behind = 0, .gone = false, .committed_at = 200 },
        .{ .branch = "feature/pe-25-different-issue", .upstream = null, .ahead = 0, .behind = 0, .gone = false, .committed_at = 999 },
    };

    const found = newestBranchForIssue(&statuses, "feature/pe-250-what-linear-suggests-now").?;
    try std.testing.expectEqualStrings("feature/pe-250-second-name", found);

    try std.testing.expect(newestBranchForIssue(&statuses, "feature/pe-9-nothing-here") == null);
    try std.testing.expect(newestBranchForIssue(&statuses, "feature/pe-25-different-issue") == null);
}

test "the --json payload keeps the shape a caller parses" {
    const gpa = std.testing.allocator;

    const issue: linear.Issue = .{
        .id = "uuid-1",
        .identifier = "PE-250",
        .title = "Fix CLVisit capture",
        .branch_name = "feature/pe-250-fix-clvisit-capture-dropped-visits",
        .state_name = "In Progress",
        .state_type = "started",
        .priority = 2,
        .url = "https://linear.app/x/issue/PE-250/fix",
        .updated_at = "2026-07-27T00:00:00.000Z",
        .assignee_name = "Someone",
        .team_key = "PE",
    };
    const wt: Bootstrapped = .{
        .branch = "feature/pe-250-fix-clvisit-handling-dedupe",
        .path = "/wt/old",
        .status = .existing,
        .matched_by = .issue,
        .created = null,
        .base = null,
        .is_main_checkout = false,
        .linked = &.{".env"},
        .skipped = &.{".claude/settings.local.json"},
    };

    const value = buildReport(issue, issue.branch_name, wt, .{
        .current_branch = "feature/pe-250-fix-clvisit-handling-dedupe",
        .branch_status = .{
            .branch = "feature/pe-250-fix-clvisit-handling-dedupe",
            .upstream = null,
            .ahead = 3,
            .behind = 1,
            .gone = false,
            .committed_at = 0,
        },
        .repo_root = "/r",
        .default_branch = "main",
        .is_cwd = true,
        .start_task_command = "/start-task PE-250",
        .carried = .{ .path = "/cfg/mcp/-r.json", .names = &.{ "linear-server", "xcode" } },
    });

    const body = try std.json.Stringify.valueAlloc(gpa, value, .{ .whitespace = .indent_2 });
    defer gpa.free(body);

    const Schema = struct {
        issue: struct {
            id: []const u8,
            identifier: []const u8,
            title: []const u8,
            url: []const u8,
            state: []const u8,
            state_type: []const u8,
            team: ?[]const u8,
            assignee: ?[]const u8,
        },
        branch: struct {
            name: []const u8,
            suggested: []const u8,
            renamed: bool,
            upstream: ?[]const u8,
            pushed: bool,
            ahead: u32,
            behind: u32,
            current: bool,
        },
        worktree: struct {
            path: []const u8,
            status: []const u8,
            matched_by: ?[]const u8,
            created: ?[]const u8,
            base: ?[]const u8,
            is_main_checkout: bool,
            is_cwd: bool,
        },
        repo: struct { root: []const u8, default_branch: []const u8 },
        links: struct { linked: [][]const u8, skipped: [][]const u8 },
        start_task_command: ?[]const u8,
        mcp: ?struct { config: []const u8, servers: [][]const u8 },
    };

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Schema, arena_state.allocator(), body, .{});

    try std.testing.expectEqualStrings("PE-250", parsed.issue.identifier);
    try std.testing.expectEqualStrings("feature/pe-250-fix-clvisit-handling-dedupe", parsed.branch.name);
    try std.testing.expectEqualStrings(issue.branch_name, parsed.branch.suggested);
    try std.testing.expect(parsed.branch.renamed);
    try std.testing.expect(!parsed.branch.pushed);
    try std.testing.expect(parsed.branch.current);
    try std.testing.expectEqual(@as(u32, 3), parsed.branch.ahead);
    try std.testing.expectEqualStrings("existing", parsed.worktree.status);
    try std.testing.expectEqualStrings("issue", parsed.worktree.matched_by.?);
    try std.testing.expect(parsed.worktree.created == null);
    try std.testing.expect(parsed.worktree.is_cwd);
    try std.testing.expectEqualStrings(".env", parsed.links.linked[0]);
    try std.testing.expectEqualStrings("/start-task PE-250", parsed.start_task_command.?);
    try std.testing.expectEqualStrings("/cfg/mcp/-r.json", parsed.mcp.?.config);
    try std.testing.expectEqualStrings("linear-server", parsed.mcp.?.servers[0]);
}

test "a created worktree reports no match and its base" {
    const gpa = std.testing.allocator;

    const issue: linear.Issue = .{
        .id = "uuid-2",
        .identifier = "PE-9",
        .title = "New work",
        .branch_name = "feature/pe-9-new-work",
        .state_name = "Todo",
        .state_type = "unstarted",
        .priority = 0,
        .url = "https://linear.app/x/issue/PE-9/new-work",
        .updated_at = "2026-07-27T00:00:00.000Z",
        .assignee_name = null,
        .team_key = "PE",
    };
    const wt: Bootstrapped = .{
        .branch = "feature/pe-9-new-work",
        .path = "/wt/pe-9",
        .status = .created,
        .matched_by = null,
        .created = .new,
        .base = "main",
        .is_main_checkout = false,
        .linked = &.{},
        .skipped = &.{},
    };

    const value = buildReport(issue, issue.branch_name, wt, .{
        .current_branch = "main",
        .branch_status = null,
        .repo_root = "/r",
        .default_branch = "main",
        .is_cwd = false,
        .start_task_command = null,
        .carried = null,
    });

    try std.testing.expect(!value.branch.renamed);
    try std.testing.expect(!value.branch.pushed);
    try std.testing.expect(value.branch.upstream == null);
    try std.testing.expect(!value.branch.current);
    try std.testing.expectEqualStrings("created", value.worktree.status);
    try std.testing.expect(value.worktree.matched_by == null);
    try std.testing.expectEqualStrings("new", value.worktree.created.?);
    try std.testing.expectEqualStrings("main", value.worktree.base.?);
    try std.testing.expect(value.start_task_command == null);

    const body = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"matched_by\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"upstream\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"start_task_command\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"mcp\":null") != null);
}

fn launchArgs(
    gpa: std.mem.Allocator,
    mcp_config: ?[]const u8,
    initial_prompt: ?[]const u8,
    plan_mode: bool,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (plan_mode) try out.appendSlice(gpa, &.{ "--permission-mode", "plan" });
    if (mcp_config) |path| try out.appendSlice(gpa, &.{ "--mcp-config", path });
    if (initial_prompt) |value| {
        try out.append(gpa, "--");
        try out.append(gpa, value);
    }
    return out.toOwnedSlice(gpa);
}

pub const Expanded = struct {
    text: []u8,
    used_plan: bool,
};

const Placeholder = enum { identifier, branch, url, plan };

const Recognized = struct {
    key: Placeholder,
    end: usize,
};

fn placeholderAt(template: []const u8, i: usize) ?Recognized {
    if (template[i] != '{') return null;
    const close = std.mem.indexOfScalarPos(u8, template, i, '}') orelse return null;
    const key = std.meta.stringToEnum(Placeholder, template[i + 1 .. close]) orelse return null;
    return .{ .key = key, .end = close + 1 };
}

pub fn templateCarriesPlan(template: []const u8) bool {
    var i: usize = 0;
    while (i < template.len) {
        if (placeholderAt(template, i)) |found| {
            if (found.key == .plan) return true;
            i = found.end;
            continue;
        }
        i += 1;
    }
    return false;
}

pub fn expandCommand(
    gpa: std.mem.Allocator,
    template: []const u8,
    issue: linear.Issue,
    branch: []const u8,
    plan_path: ?[]const u8,
) !Expanded {
    var out: std.ArrayList(u8) = .empty;
    var used_plan = false;
    var i: usize = 0;
    while (i < template.len) {
        if (placeholderAt(template, i)) |found| {
            const value: []const u8 = switch (found.key) {
                .identifier => issue.identifier,
                .branch => branch,
                .url => issue.url,
                .plan => blk: {
                    used_plan = true;
                    break :blk plan_path orelse "";
                },
            };
            try out.appendSlice(gpa, value);
            i = found.end;
            continue;
        }
        try out.append(gpa, template[i]);
        i += 1;
    }
    return .{ .text = try out.toOwnedSlice(gpa), .used_plan = used_plan };
}

test "expandCommand fills the placeholders and leaves anything else alone" {
    const gpa = std.testing.allocator;
    const issue: linear.Issue = .{
        .id = "uuid-1",
        .identifier = "PE-250",
        .title = "Fix CLVisit capture",
        .branch_name = "feature/pe-250-suggested",
        .state_name = "In Progress",
        .state_type = "started",
        .priority = 2,
        .url = "https://linear.app/x/issue/PE-250/fix",
        .updated_at = "2026-07-27T00:00:00.000Z",
        .assignee_name = "Someone",
        .team_key = "PE",
    };

    const cases = [_]struct {
        template: []const u8,
        plan: ?[]const u8,
        want: []const u8,
        want_used_plan: bool = false,
    }{
        .{ .template = "/start-task {identifier}", .plan = null, .want = "/start-task PE-250" },
        .{ .template = "{branch} {url}", .plan = null, .want = "feature/pe-250-actual https://linear.app/x/issue/PE-250/fix" },
        .{
            .template = "/start-task {identifier} --plan {plan}",
            .plan = "/Users/me/.claude/plans/x.md",
            .want = "/start-task PE-250 --plan /Users/me/.claude/plans/x.md",
            .want_used_plan = true,
        },
        .{ .template = "read {plan} then go", .plan = null, .want = "read  then go", .want_used_plan = true },
        .{
            .template = "/start-task {identifier}",
            .plan = "/Users/me/.claude/plans/x.md",
            .want = "/start-task PE-250",
            .want_used_plan = false,
        },
        .{ .template = "{nope} {identifier}", .plan = null, .want = "{nope} PE-250" },
        .{ .template = "{unclosed", .plan = null, .want = "{unclosed" },
    };

    for (cases) |case| {
        const got = try expandCommand(gpa, case.template, issue, "feature/pe-250-actual", case.plan);
        defer gpa.free(got.text);
        try std.testing.expectEqualStrings(case.want, got.text);
        try std.testing.expectEqual(case.want_used_plan, got.used_plan);
    }
}

test "launchArgs always separates the prompt from the options with --" {
    const gpa = std.testing.allocator;

    const opens_with_dash = "--- \n- step one";

    const carried = try launchArgs(gpa, "/cfg/mcp.json", opens_with_dash, false);
    defer gpa.free(carried);
    try std.testing.expectEqual(@as(usize, 4), carried.len);
    try std.testing.expectEqualStrings("--mcp-config", carried[0]);
    try std.testing.expectEqualStrings("/cfg/mcp.json", carried[1]);
    try std.testing.expectEqualStrings("--", carried[2]);
    try std.testing.expectEqualStrings(opens_with_dash, carried[3]);

    const bare = try launchArgs(gpa, null, opens_with_dash, false);
    defer gpa.free(bare);
    try std.testing.expectEqual(@as(usize, 2), bare.len);
    try std.testing.expectEqualStrings("--", bare[0]);
    try std.testing.expectEqualStrings(opens_with_dash, bare[1]);

    const empty = try launchArgs(gpa, null, null, false);
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const only_mcp = try launchArgs(gpa, "/cfg/mcp.json", null, false);
    defer gpa.free(only_mcp);
    try std.testing.expectEqual(@as(usize, 2), only_mcp.len);
}

test "launchArgs opens in plan mode, and the mode stays ahead of the separator" {
    const gpa = std.testing.allocator;

    const planning = try launchArgs(gpa, null, "/start-task PE-250", true);
    defer gpa.free(planning);
    try std.testing.expectEqual(@as(usize, 4), planning.len);
    try std.testing.expectEqualStrings("--permission-mode", planning[0]);
    try std.testing.expectEqualStrings("plan", planning[1]);
    try std.testing.expectEqualStrings("--", planning[2]);
    try std.testing.expectEqualStrings("/start-task PE-250", planning[3]);

    const with_mcp = try launchArgs(gpa, "/cfg/mcp.json", "/start-task PE-250", true);
    defer gpa.free(with_mcp);
    try std.testing.expectEqual(@as(usize, 6), with_mcp.len);
    try std.testing.expectEqualStrings("--permission-mode", with_mcp[0]);
    try std.testing.expectEqualStrings("plan", with_mcp[1]);
    try std.testing.expectEqualStrings("--mcp-config", with_mcp[2]);
    try std.testing.expectEqualStrings("--", with_mcp[4]);

    const no_prompt = try launchArgs(gpa, null, null, true);
    defer gpa.free(no_prompt);
    try std.testing.expectEqual(@as(usize, 2), no_prompt.len);
    try std.testing.expectEqualStrings("--permission-mode", no_prompt[0]);
    try std.testing.expectEqualStrings("plan", no_prompt[1]);
}
