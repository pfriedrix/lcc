const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const config = @import("../config.zig");
const git = @import("../git.zig");
const github = @import("../github.zig");
const linear = @import("../linear.zig");
const oauth = @import("../oauth.zig");
const release = @import("../release.zig");
const semver = @import("../semver.zig");

pub const Verb = enum { show, state, comment, project };

pub fn resolveVerb(raw: []const u8) ?Verb {
    if (std.ascii.eqlIgnoreCase(raw, "show")) return .show;
    if (std.ascii.eqlIgnoreCase(raw, "state")) return .state;
    if (std.ascii.eqlIgnoreCase(raw, "comment")) return .comment;
    if (std.ascii.eqlIgnoreCase(raw, "project")) return .project;
    return null;
}

pub const Sub = union(enum) {
    show: Show,
    state: SetState,
    comment: AddComment,
    project: SetProject,

    pub const Show = struct {};

    pub const SetState = struct {
        name: ?[]const u8 = null,
        type: ?[]const u8 = null,
    };

    pub const AddComment = struct {
        body: ?[]const u8 = null,
        file: ?[]const u8 = null,
    };

    pub const SetProject = struct {
        assign: ?[]const u8 = null,
        resolve: bool = false,
        fetch: bool = false,
        create: bool = false,
        force: bool = false,
    };

    pub fn empty(verb: Verb) Sub {
        return switch (verb) {
            .show => .{ .show = .{} },
            .state => .{ .state = .{} },
            .comment => .{ .comment = .{} },
            .project => .{ .project = .{} },
        };
    }
};

pub const Opts = struct {
    issue: ?[]const u8 = null,
    json: bool = false,
    sub: Sub = .{ .show = .{} },
};

pub fn run(app: app_mod.App, opts: Opts) !void {
    const raw = opts.issue orelse bail(app, opts.json, "usage", "issue needs an identifier, e.g. `lcc issue show PE-42`.", .{});
    const trimmed = std.mem.trim(u8, raw, " \t");
    const ref = linear.refFromBranch(trimmed) orelse bail(
        app,
        opts.json,
        "bad_identifier",
        "'{s}' is not an issue identifier — expected something like PE-42.",
        .{trimmed},
    );

    const token = try authorize(app, opts);

    switch (opts.sub) {
        .show => return show(app, opts, token, ref, trimmed),
        .state => |sub| return setState(app, opts, sub, token, ref, trimmed),
        .comment => |sub| return comment(app, opts, sub, token, ref, trimmed),
        .project => |sub| return project(app, opts, sub, token, ref, trimmed),
    }
}

fn authorize(app: app_mod.App, opts: Opts) !oauth.Token {
    app.ui.hint("Reading the Linear token from the Keychain...", .{});
    app.ui.flush();
    if (oauth.getToken(app.gpa) == null) {
        bail(app, opts.json, "not_authenticated", "Not authenticated. Run `lcc auth` first.", .{});
    }

    const cfg = try config.load(app.gpa, app.io, app.environ);

    return oauth.ensureFreshToken(app.gpa, app.io, cfg.clientId) catch |err| bail(
        app,
        opts.json,
        "auth_failed",
        "{s}: {s}",
        .{ @errorName(err), oauth.last_detail },
    );
}

fn show(
    app: app_mod.App,
    opts: Opts,
    token: oauth.Token,
    ref: linear.Ref,
    named: []const u8,
) !void {
    if (!opts.json) {
        app.ui.step("Fetching {s}...", .{named});
        app.ui.flush();
    }

    const found = linear.fetchIssueDetail(app.gpa, app.io, token, ref) catch |err| bail(
        app,
        opts.json,
        "linear_failed",
        "Linear request failed ({s}, HTTP {d}): {s}",
        .{ @errorName(err), linear.last_status, linear.last_message },
    );
    const detail = found orelse bail(app, opts.json, "issue_not_found", "No issue {s} in Linear.", .{named});

    const value = buildShowReport(detail);
    if (opts.json) {
        const body = try std.json.Stringify.valueAlloc(app.gpa, value, .{ .whitespace = .indent_2 });
        app.ui.payload("{s}\n", .{body});
        app.ui.flush();
        return;
    }
    renderShow(app, value);
}

fn setState(
    app: app_mod.App,
    opts: Opts,
    sub: Sub.SetState,
    token: oauth.Token,
    ref: linear.Ref,
    named: []const u8,
) !void {
    const wanted = sub.name.?;

    const found = linear.fetchStateContext(app.gpa, app.io, token, ref) catch |err| bail(
        app,
        opts.json,
        "linear_failed",
        "Linear request failed ({s}, HTTP {d}): {s}",
        .{ @errorName(err), linear.last_status, linear.last_message },
    );
    const ctx = found orelse bail(app, opts.json, "issue_not_found", "No issue {s} in Linear.", .{named});

    const target = switch (try linear.resolveState(app.gpa, ctx.states, wanted, sub.type)) {
        .found => |state| state,
        .unknown => bail(
            app,
            opts.json,
            "state_unknown",
            "{s} has no state called '{s}'.{s} It has: {s}.",
            .{
                ctx.team_key,
                wanted,
                if (ctx.truncated) " Its state list was truncated, so there may be more." else "",
                stateNames(app, ctx.states),
            },
        ),
        .ambiguous => |hits| bail(
            app,
            opts.json,
            "state_ambiguous",
            "{d} states in {s} are called '{s}': {s}. Narrow it: lcc issue state {s} \"{s}\" --type <type>",
            .{ hits.len, ctx.team_key, wanted, stateTypes(app, hits), named, wanted },
        ),
    };

    const changed = !std.mem.eql(u8, ctx.current.id, target.id);
    const landed: linear.WorkflowState = if (!changed) ctx.current else blk: {
        const updated = linear.setIssueState(app.gpa, app.io, token, ctx.issue_id, target.id) catch |err| bail(
            app,
            opts.json,
            "linear_failed",
            "Linear refused the state change ({s}, HTTP {d}): {s}",
            .{ @errorName(err), linear.last_status, linear.last_message },
        );
        break :blk updated.state;
    };

    const value: StateReport = .{
        .issue = .{ .id = ctx.issue_id, .identifier = ctx.identifier, .url = ctx.url },
        .changed = changed,
        .from = .{ .id = ctx.current.id, .name = ctx.current.name, .type = ctx.current.type },
        .to = .{ .id = landed.id, .name = landed.name, .type = landed.type },
    };

    if (opts.json) {
        const payload = try std.json.Stringify.valueAlloc(app.gpa, value, .{ .whitespace = .indent_2 });
        app.ui.payload("{s}\n", .{payload});
        app.ui.flush();
        return;
    }
    if (changed) {
        app.ui.success("{s}: {s} → {s}", .{ value.issue.identifier, value.from.name, value.to.name });
    } else {
        app.ui.info("{s} is already {s} — nothing written.", .{ value.issue.identifier, value.to.name });
    }
    app.ui.flush();
}

fn stateNames(app: app_mod.App, states: []const linear.WorkflowState) []const u8 {
    const names = app.gpa.alloc([]const u8, states.len) catch return "";
    for (states, 0..) |state, i| names[i] = state.name;
    return std.mem.join(app.gpa, ", ", names) catch "";
}

fn stateTypes(app: app_mod.App, states: []const linear.WorkflowState) []const u8 {
    const types = app.gpa.alloc([]const u8, states.len) catch return "";
    for (states, 0..) |state, i| types[i] = state.type;
    return std.mem.join(app.gpa, ", ", types) catch "";
}

const ReportState = struct {
    id: []const u8,
    name: []const u8,
    type: []const u8,
};

const StateReport = struct {
    issue: ReportRef,
    changed: bool,
    from: ReportState,
    to: ReportState,
};

fn project(
    app: app_mod.App,
    opts: Opts,
    sub: Sub.SetProject,
    token: oauth.Token,
    ref: linear.Ref,
    named: []const u8,
) !void {
    if (sub.resolve) return resolveProject(app, opts, sub, token, ref, named);

    const wanted = semver.parse(sub.assign.?) orelse bail(
        app,
        opts.json,
        "bad_version",
        "'{s}' is not a release version — expected something like v2.6.0.",
        .{sub.assign.?},
    );
    const name = try semver.render(app.gpa, wanted);

    const found = linear.fetchIssueDetail(app.gpa, app.io, token, ref) catch |err| bail(
        app,
        opts.json,
        "linear_failed",
        "Linear request failed ({s}, HTTP {d}): {s}",
        .{ @errorName(err), linear.last_status, linear.last_message },
    );
    const detail = found orelse bail(app, opts.json, "issue_not_found", "No issue {s} in Linear.", .{named});

    if (detail.project) |current| {
        if (!sub.force and !std.mem.eql(u8, current.name, name)) {
            bail(
                app,
                opts.json,
                "project_conflict",
                "{s} is already in {s}. Moving it to {s} is a release cut — say so: lcc issue project {s} --assign {s} --force",
                .{ named, current.name, name, named, name },
            );
        }
    }

    const team_id = detail.team_id orelse bail(
        app,
        opts.json,
        "linear_failed",
        "{s} reports no team, so there is no board to find {s} on.",
        .{ named, name },
    );

    const board = linear.fetchReleaseProjects(app.gpa, app.io, token, detail.issue.team_key orelse "") catch |err| bail(
        app,
        opts.json,
        "linear_failed",
        "Linear request failed ({s}, HTTP {d}): {s}",
        .{ @errorName(err), linear.last_status, linear.last_message },
    );

    var created = false;
    const target = findProject(board, name) orelse blk: {
        if (!sub.create) {
            bail(
                app,
                opts.json,
                "project_not_found",
                "No project called {s} on {s}. Create it: lcc issue project {s} --assign {s} --create",
                .{ name, detail.issue.team_key orelse "the team", named, name },
            );
        }
        const summary = try std.fmt.allocPrint(
            app.gpa,
            "Release {f} — issues targeting this release. Issues may be cut later and moved to the next project.",
            .{semver.show(wanted)},
        );
        const made = linear.createProject(app.gpa, app.io, token, name, team_id, summary) catch |err| bail(
            app,
            opts.json,
            "linear_failed",
            "Linear refused to create {s} ({s}, HTTP {d}): {s}",
            .{ name, @errorName(err), linear.last_status, linear.last_message },
        );
        created = true;
        break :blk made;
    };

    const changed = if (detail.project) |current| !std.mem.eql(u8, current.id, target.id) else true;
    if (changed) {
        _ = linear.setIssueProject(app.gpa, app.io, token, detail.issue.id, target.id) catch |err| bail(
            app,
            opts.json,
            "linear_failed",
            "Linear refused the project change ({s}, HTTP {d}): {s}",
            .{ @errorName(err), linear.last_status, linear.last_message },
        );
    }

    const value: ProjectReport = .{
        .issue = .{ .id = detail.issue.id, .identifier = detail.issue.identifier, .url = detail.issue.url },
        .project = .{ .id = target.id, .name = target.name },
        .changed = changed,
        .created = created,
    };

    if (opts.json) {
        const payload = try std.json.Stringify.valueAlloc(app.gpa, value, .{ .whitespace = .indent_2 });
        app.ui.payload("{s}\n", .{payload});
        app.ui.flush();
        return;
    }
    if (created) app.ui.success("Created project {s}", .{value.project.name});
    if (changed) {
        app.ui.success("{s} → {s}", .{ value.issue.identifier, value.project.name });
    } else {
        app.ui.info("{s} is already in {s} — nothing written.", .{ value.issue.identifier, value.project.name });
    }
    app.ui.flush();
}

fn resolveProject(
    app: app_mod.App,
    opts: Opts,
    sub: Sub.SetProject,
    token: oauth.Token,
    ref: linear.Ref,
    named: []const u8,
) !void {
    const found = linear.fetchIssueDetail(app.gpa, app.io, token, ref) catch |err| bail(
        app,
        opts.json,
        "linear_failed",
        "Linear request failed ({s}, HTTP {d}): {s}",
        .{ @errorName(err), linear.last_status, linear.last_message },
    );
    const detail = found orelse bail(app, opts.json, "issue_not_found", "No issue {s} in Linear.", .{named});

    var notes: std.ArrayList([]const u8) = .empty;
    var facts: release.Facts = .{ .identifier = named, .team = detail.issue.team_key };

    if (detail.project) |current| {
        if (semver.parse(current.name)) |version| {
            facts.issue_project = .{ .id = current.id, .name = current.name, .version = version };
        } else {
            facts.issue_project_unversioned = current.name;
        }
    }

    var git_facts: ?GitFacts = null;
    const outcome = release.resolveLocal(facts) orelse blk: {
        git_facts = gatherGit(app, sub, &facts, &notes);
        gatherBoard(app, token, &facts, &notes);
        break :blk release.resolve(facts);
    };

    const value = try buildResolveReport(app.gpa, detail, facts, outcome, git_facts, try notes.toOwnedSlice(app.gpa));

    if (opts.json) {
        const payload = try std.json.Stringify.valueAlloc(app.gpa, value, .{ .whitespace = .indent_2 });
        app.ui.payload("{s}\n", .{payload});
        app.ui.flush();
        return;
    }
    renderResolve(app, value);
}

const GitFacts = struct {
    root: []const u8,
    head: ?[]const u8,
    branch: ?[]const u8,
    detached: bool,
    default_branch: []const u8,
    fetched: bool,
    pr_base: ?[]const u8,
    release_branches: []const release.ReleaseBranch,
};

fn gatherGit(
    app: app_mod.App,
    sub: Sub.SetProject,
    facts: *release.Facts,
    notes: *std.ArrayList([]const u8),
) ?GitFacts {
    const repo = app.repo() catch {
        notes.append(app.gpa, "Not inside a git repository, so no branch could be read.") catch {};
        return null;
    };
    facts.git_available = true;

    if (sub.fetch) repo.fetchPrune() catch {
        notes.append(app.gpa, "git fetch failed; the view of origin may be stale.") catch {};
    };

    facts.current_branch = repo.currentBranch() catch null;
    facts.default_branch = repo.defaultBranch() catch "main";

    const head = repo.headSha();

    var branches: std.ArrayList(release.ReleaseBranch) = .empty;
    if (repo.remoteReleaseBranches()) |live| {
        for (live) |remote| {
            const version = semver.fromBranch(remote.branch) orelse {
                notes.append(app.gpa, std.fmt.allocPrint(
                    app.gpa,
                    "{s} is not a three-component version and was ignored.",
                    .{remote.branch},
                ) catch continue) catch {};
                continue;
            };
            branches.append(app.gpa, .{
                .branch = remote.branch,
                .version = version,
                .ahead = if (head) |sha| repo.countAhead(
                    std.fmt.allocPrint(app.gpa, "origin/{s}", .{remote.branch}) catch continue,
                    sha,
                ) else null,
            }) catch {};
        }
    } else |_| {}
    facts.release_branches = branches.items;

    if (head) |sha| {
        const trunk = std.fmt.allocPrint(app.gpa, "origin/{s}", .{facts.default_branch}) catch null;
        if (trunk) |ref| facts.ahead_of_default = repo.countAhead(ref, sha);
    }

    var tags: std.ArrayList(semver.Version) = .empty;
    if (repo.listTags()) |names| {
        for (names) |name| {
            if (semver.parse(name)) |version| tags.append(app.gpa, version) catch {};
        }
    } else |_| {}
    semver.sortAsc(tags.items);
    facts.tags = tags.items;

    var pr_base: ?[]const u8 = null;
    if (facts.current_branch) |branch| {
        if (github.forBranches(app.gpa, app.io, repo.root, &.{branch})) |prs| {
            if (github.forBranch(prs, branch)) |pr| {
                if (pr.base.len > 0) pr_base = pr.base;
            }
        } else {
            notes.append(app.gpa, "gh could not be asked about a pull request; the base was measured instead.") catch {};
        }
    }
    facts.pr_base = pr_base;

    return .{
        .root = repo.root,
        .head = head,
        .branch = facts.current_branch,
        .detached = facts.current_branch == null,
        .default_branch = facts.default_branch,
        .fetched = sub.fetch,
        .pr_base = pr_base,
        .release_branches = branches.items,
    };
}

fn gatherBoard(
    app: app_mod.App,
    token: oauth.Token,
    facts: *release.Facts,
    notes: *std.ArrayList([]const u8),
) void {
    const team = facts.team orelse return;
    const board = linear.fetchReleaseProjects(app.gpa, app.io, token, team) catch {
        notes.append(app.gpa, std.fmt.allocPrint(
            app.gpa,
            "Linear could not be asked for {s}'s release projects: {s}",
            .{ team, linear.last_message },
        ) catch return) catch {};
        return;
    };

    facts.projects_asked = true;
    facts.projects_truncated = board.truncated;

    const completed = versioned(app, board.completed);
    std.mem.sort(release.Project, completed, {}, projectAsc);
    facts.completed_projects = completed;

    var ceiling: ?semver.Version = null;
    if (facts.tags.len > 0) ceiling = facts.tags[facts.tags.len - 1];
    if (completed.len > 0) {
        const latest = completed[completed.len - 1].version;
        ceiling = if (ceiling) |current| semver.max(current, latest) else latest;
    }

    var open = versioned(app, board.open);
    const keep = release.partitionStabilising(open, facts.release_branches, ceiling);
    const dropped = open[keep..];
    open = open[0..keep];
    std.mem.sort(release.Project, open, {}, projectAsc);
    std.mem.sort(release.Project, dropped, {}, projectAsc);
    facts.open_projects = open;
    facts.dropped_projects = dropped;

    for (dropped) |project_dropped| {
        notes.append(app.gpa, std.fmt.allocPrint(
            app.gpa,
            "{s} is open but not a target — it is stabilising on a release branch, or already shipped.",
            .{project_dropped.name},
        ) catch continue) catch {};
    }
}

fn versioned(app: app_mod.App, projects: []const linear.ReleaseProject) []release.Project {
    var out: std.ArrayList(release.Project) = .empty;
    for (projects) |candidate| {
        const version = semver.parse(candidate.name) orelse continue;
        out.append(app.gpa, .{
            .id = candidate.id,
            .name = candidate.name,
            .version = version,
        }) catch {};
    }
    return out.items;
}

fn projectAsc(_: void, a: release.Project, b: release.Project) bool {
    return a.version.order(b.version) == .lt;
}

fn findProject(board: linear.ReleaseProjects, name: []const u8) ?linear.Project {
    for ([_][]const linear.ReleaseProject{ board.open, board.completed }) |half| {
        for (half) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.name, name)) {
                return .{ .id = candidate.id, .name = candidate.name };
            }
        }
    }
    return null;
}

const ProjectReport = struct {
    issue: ReportRef,
    project: ReportProject,
    changed: bool,
    created: bool,
};

const ReportEvidence = struct {
    kind: []const u8,
    text: []const u8,
};

const ReportBaseline = struct {
    version: []const u8,
    source: []const u8,
    evidence: []const u8,
};

const ReportChoice = struct {
    version: []const u8,
    source: []const u8,
};

const ReportReleaseBranch = struct {
    branch: []const u8,
    version: []const u8,
    ahead: ?u32,
};

const ReportGit = struct {
    root: []const u8,
    head: ?[]const u8,
    branch: ?[]const u8,
    detached: bool,
    default_branch: []const u8,
    fetched: bool,
    pr_base: ?[]const u8,
    release_branches: []const ReportReleaseBranch,
};

const ResolveReport = struct {
    issue: ReportRef,
    status: []const u8,
    rule: u8,
    rule_name: []const u8,
    version: ?[]const u8,
    evidence: ?ReportEvidence,
    project: ?ReportProject,
    confirm_before_create: bool,
    baseline: ?ReportBaseline,
    choices: []const ReportChoice,
    conflict: ?ReportProject,
    question: ?[]const u8,
    command: ?[]const u8,
    git: ?ReportGit,
    notes: []const []const u8,
};

fn buildResolveReport(
    gpa: std.mem.Allocator,
    detail: linear.Detail,
    facts: release.Facts,
    outcome: release.Outcome,
    git_facts: ?GitFacts,
    notes: []const []const u8,
) !ResolveReport {
    const named = detail.issue.identifier;

    var value: ResolveReport = .{
        .issue = .{ .id = detail.issue.id, .identifier = named, .url = detail.issue.url },
        .status = "needs_choice",
        .rule = 7,
        .rule_name = "unresolved",
        .version = null,
        .evidence = null,
        .project = null,
        .confirm_before_create = true,
        .baseline = null,
        .choices = &.{},
        .conflict = null,
        .question = null,
        .command = null,
        .git = null,
        .notes = notes,
    };

    if (git_facts) |g| {
        const branches = try gpa.alloc(ReportReleaseBranch, g.release_branches.len);
        for (g.release_branches, 0..) |branch, i| {
            branches[i] = .{
                .branch = branch.branch,
                .version = try semver.render(gpa, branch.version),
                .ahead = branch.ahead,
            };
        }
        value.git = .{
            .root = g.root,
            .head = g.head,
            .branch = g.branch,
            .detached = g.detached,
            .default_branch = g.default_branch,
            .fetched = g.fetched,
            .pr_base = g.pr_base,
            .release_branches = branches,
        };
    }

    switch (outcome) {
        .resolved => |hit| {
            const name = try semver.render(gpa, hit.version);
            value.status = "resolved";
            value.rule = hit.rule.number();
            value.rule_name = @tagName(hit.rule);
            value.version = name;
            value.evidence = .{ .kind = @tagName(hit.evidence.kind), .text = hit.evidence.text };
            value.confirm_before_create = false;
            if (hit.project) |p| value.project = .{ .id = p.id, .name = p.name };
            if (hit.project == null) {
                if (facts.projects_asked) {
                    value.project = findProjectNamed(facts, name);
                }
            }
            if (hit.displaced) |d| value.conflict = .{ .id = d.id, .name = d.name };
            value.command = try std.fmt.allocPrint(
                gpa,
                "lcc issue project {s} --assign {s}{s}",
                .{ named, name, if (value.project == null) " --create" else "" },
            );
        },
        .already_set => |set| {
            value.status = "already_set";
            value.rule = release.Rule.issue_project.number();
            value.rule_name = @tagName(release.Rule.issue_project);
            value.version = if (set.version) |version| try semver.render(gpa, version) else null;
            value.evidence = .{ .kind = "project", .text = "already set on the issue" };
            value.confirm_before_create = false;
            if (set.project) |p| value.project = .{ .id = p.id, .name = p.name };
        },
        .needs_confirmation => |proposal| {
            value.status = "needs_confirmation";
            value.rule = release.Rule.next_minor.number();
            value.rule_name = @tagName(release.Rule.next_minor);
            const candidate = try semver.render(gpa, proposal.candidate);
            value.version = candidate;
            value.evidence = .{ .kind = "distance", .text = "minor bump above what shipped" };
            value.baseline = .{
                .version = try semver.render(gpa, proposal.baseline),
                .source = @tagName(proposal.baseline_from),
                .evidence = proposal.baseline_evidence,
            };
            value.question = try std.fmt.allocPrint(
                gpa,
                "Latest released: {f}. No open release project. Create {s} and assign {s}? [y / other version / skip]",
                .{ semver.show(proposal.baseline), candidate, named },
            );
            value.command = try std.fmt.allocPrint(
                gpa,
                "lcc issue project {s} --assign {s} --create",
                .{ named, candidate },
            );
        },
        .needs_choice => |choice| {
            var rows: std.ArrayList(ReportChoice) = .empty;
            for (choice.open) |p| {
                try rows.append(gpa, .{ .version = p.name, .source = "project" });
            }
            for (choice.branches) |branch| {
                try rows.append(gpa, .{
                    .version = try semver.render(gpa, branch.version),
                    .source = "release_branch",
                });
            }
            value.choices = rows.items;
            value.question = try std.fmt.allocPrint(
                gpa,
                "Which release does {s} target? ({s}) [vX.Y.Z / skip]",
                .{ named, @tagName(choice.reason) },
            );
            value.command = try std.fmt.allocPrint(
                gpa,
                "lcc issue project {s} --assign <vX.Y.Z> [--create]",
                .{named},
            );
        },
    }

    return value;
}

fn findProjectNamed(facts: release.Facts, name: []const u8) ?ReportProject {
    for ([_][]const release.Project{ facts.open_projects, facts.completed_projects, facts.dropped_projects }) |half| {
        for (half) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.name, name)) {
                return .{ .id = candidate.id, .name = candidate.name };
            }
        }
    }
    return null;
}

fn renderResolve(app: app_mod.App, value: ResolveReport) void {
    const rule = std.fmt.allocPrint(app.gpa, "rule {d}: {s}", .{ value.rule, value.rule_name }) catch "";
    if (value.version) |version| {
        if (std.mem.eql(u8, value.status, "already_set")) {
            app.ui.success("{s}: {s} ({s} — not touched)", .{ value.issue.identifier, version, rule });
        } else if (std.mem.eql(u8, value.status, "needs_confirmation")) {
            app.ui.warn("{s} does not exist yet ({s})", .{ version, rule });
        } else {
            app.ui.success("{s}: {s} ({s})", .{ value.issue.identifier, version, rule });
        }
    } else {
        app.ui.warn("No release resolved for {s} ({s})", .{ value.issue.identifier, rule });
    }
    for (value.notes) |note| app.ui.hint("{s}", .{note});
    if (value.question) |question| app.ui.info("{s}", .{question});
    if (value.command) |command| app.ui.hint("{s}", .{command});
    app.ui.flush();
}

const max_body = 1 << 20;

fn comment(
    app: app_mod.App,
    opts: Opts,
    sub: Sub.AddComment,
    token: oauth.Token,
    ref: linear.Ref,
    named: []const u8,
) !void {
    const body = commentBody(app, opts, sub);
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) {
        bail(app, opts.json, "body_empty", "Refusing to post an empty comment to {s}.", .{named});
    }

    const found = linear.fetchIssueDetail(app.gpa, app.io, token, ref) catch |err| bail(
        app,
        opts.json,
        "linear_failed",
        "Linear request failed ({s}, HTTP {d}): {s}",
        .{ @errorName(err), linear.last_status, linear.last_message },
    );
    const detail = found orelse bail(app, opts.json, "issue_not_found", "No issue {s} in Linear.", .{named});

    const posted = linear.addComment(app.gpa, app.io, token, detail.issue.id, body) catch |err| bail(
        app,
        opts.json,
        "linear_failed",
        "Linear refused the comment ({s}, HTTP {d}): {s}",
        .{ @errorName(err), linear.last_status, linear.last_message },
    );

    const value: CommentReport = .{
        .issue = .{
            .id = detail.issue.id,
            .identifier = detail.issue.identifier,
            .url = detail.issue.url,
        },
        .comment = .{
            .id = posted.id,
            .url = posted.url,
            .created_at = posted.created_at,
        },
        .body_bytes = body.len,
    };

    if (opts.json) {
        const payload = try std.json.Stringify.valueAlloc(app.gpa, value, .{ .whitespace = .indent_2 });
        app.ui.payload("{s}\n", .{payload});
        app.ui.flush();
        return;
    }
    app.ui.success("Commented on {s} ({d} bytes)", .{ value.issue.identifier, value.body_bytes });
    app.ui.info("  {s}", .{value.comment.url});
    app.ui.flush();
}

fn commentBody(app: app_mod.App, opts: Opts, sub: Sub.AddComment) []const u8 {
    if (sub.body) |text| return text;
    const raw = sub.file.?;

    const resolved = Io.Dir.cwd().realPathFileAlloc(app.io, raw, app.gpa) catch |err| switch (err) {
        error.FileNotFound => bail(app, opts.json, "body_not_found", "No file at {s}.", .{raw}),
        else => bail(app, opts.json, "body_unreadable", "Cannot read {s}: {s}", .{ raw, @errorName(err) }),
    };
    const info = Io.Dir.cwd().statFile(app.io, resolved, .{}) catch |err|
        bail(app, opts.json, "body_unreadable", "Cannot read {s}: {s}", .{ raw, @errorName(err) });
    if (info.kind != .file) {
        bail(app, opts.json, "body_not_found", "{s} is a {s}, not a file.", .{ raw, @tagName(info.kind) });
    }
    if (info.size > max_body) {
        bail(app, opts.json, "body_too_large", "{s} is {d} bytes; the limit is {d}.", .{ raw, info.size, max_body });
    }

    return Io.Dir.cwd().readFileAlloc(app.io, resolved, app.gpa, .limited(max_body)) catch |err|
        bail(app, opts.json, "body_unreadable", "Cannot read {s}: {s}", .{ raw, @errorName(err) });
}

const ReportRef = struct {
    id: []const u8,
    identifier: []const u8,
    url: []const u8,
};

const CommentReport = struct {
    issue: ReportRef,
    comment: struct {
        id: []const u8,
        url: []const u8,
        created_at: []const u8,
    },
    body_bytes: usize,
};

const ReportIssue = struct {
    id: []const u8,
    identifier: []const u8,
    title: []const u8,
    url: []const u8,
    state: []const u8,
    state_type: []const u8,
    state_id: []const u8,
    team: ?[]const u8,
    team_id: ?[]const u8,
    assignee: ?[]const u8,
    priority: i64,
    branch_name: []const u8,
    updated_at: []const u8,
};

const ReportProject = struct {
    id: []const u8,
    name: []const u8,
};

const ShowReport = struct {
    issue: ReportIssue,
    project: ?ReportProject,
    labels: []const []const u8,
    description: ?[]const u8,
};

fn buildShowReport(detail: linear.Detail) ShowReport {
    return .{
        .issue = .{
            .id = detail.issue.id,
            .identifier = detail.issue.identifier,
            .title = detail.issue.title,
            .url = detail.issue.url,
            .state = detail.issue.state_name,
            .state_type = detail.issue.state_type,
            .state_id = detail.state_id,
            .team = detail.issue.team_key,
            .team_id = detail.team_id,
            .assignee = detail.issue.assignee_name,
            .priority = detail.issue.priority,
            .branch_name = detail.issue.branch_name,
            .updated_at = detail.issue.updated_at,
        },
        .project = if (detail.project) |p| .{ .id = p.id, .name = p.name } else null,
        .labels = detail.labels,
        .description = detail.description,
    };
}

fn renderShow(app: app_mod.App, value: ShowReport) void {
    app.ui.info("{s}  {s}", .{ value.issue.identifier, value.issue.title });
    app.ui.info("  State     {s}", .{value.issue.state});
    if (value.project) |attached| {
        app.ui.info("  Project   {s}", .{attached.name});
    } else {
        app.ui.info("  Project   —", .{});
    }
    if (value.issue.assignee) |assignee| app.ui.info("  Assignee  {s}", .{assignee});
    if (value.labels.len > 0) {
        const joined = std.mem.join(app.gpa, ", ", value.labels) catch return;
        app.ui.info("  Labels    {s}", .{joined});
    }
    app.ui.info("  Branch    {s}", .{value.issue.branch_name});
    app.ui.info("  {s}", .{value.issue.url});
    app.ui.flush();
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

test "resolveVerb takes the subcommand however it is cased, and nothing else" {
    try std.testing.expectEqual(Verb.show, resolveVerb("show").?);
    try std.testing.expectEqual(Verb.show, resolveVerb("SHOW").?);
    try std.testing.expectEqual(Verb.comment, resolveVerb("comment").?);
    try std.testing.expectEqual(Verb.state, resolveVerb("state").?);
    try std.testing.expectEqual(Verb.project, resolveVerb("project").?);
    try std.testing.expect(resolveVerb("") == null);
    try std.testing.expect(resolveVerb("frobnicate") == null);
    try std.testing.expect(resolveVerb("PE-42") == null);
    try std.testing.expect(resolveVerb("--json") == null);
}

test "the state payload reports what landed, and says when nothing was written" {
    const gpa = std.testing.allocator;

    const issue: ReportRef = .{
        .id = "uuid-1",
        .identifier = "PE-250",
        .url = "https://linear.app/x/issue/PE-250/fix",
    };
    const todo: ReportState = .{ .id = "s-todo", .name = "Todo", .type = "unstarted" };
    const progress: ReportState = .{ .id = "s-progress", .name = "In Progress", .type = "started" };

    const moved: StateReport = .{ .issue = issue, .changed = true, .from = todo, .to = progress };
    const body = try std.json.Stringify.valueAlloc(gpa, moved, .{ .whitespace = .indent_2 });
    defer gpa.free(body);

    const Schema = struct {
        issue: struct { id: []const u8, identifier: []const u8, url: []const u8 },
        changed: bool,
        from: struct { id: []const u8, name: []const u8, type: []const u8 },
        to: struct { id: []const u8, name: []const u8, type: []const u8 },
    };

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Schema, arena_state.allocator(), body, .{});

    try std.testing.expect(parsed.changed);
    try std.testing.expectEqualStrings("Todo", parsed.from.name);
    try std.testing.expectEqualStrings("In Progress", parsed.to.name);

    const untouched: StateReport = .{ .issue = issue, .changed = false, .from = progress, .to = progress };
    const idle = try std.json.Stringify.valueAlloc(gpa, untouched, .{ .whitespace = .indent_2 });
    defer gpa.free(idle);
    const same = try std.json.parseFromSliceLeaky(Schema, arena_state.allocator(), idle, .{});
    try std.testing.expect(!same.changed);
    try std.testing.expectEqualStrings(same.from.id, same.to.id);
}

test "an unresolved release comes back as a proposal, not as a failure" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const detail: linear.Detail = .{
        .issue = .{
            .id = "uuid-1",
            .identifier = "PE-283",
            .title = "Something",
            .branch_name = "feature/pe-283-x",
            .state_name = "Backlog",
            .state_type = "backlog",
            .priority = 0,
            .url = "https://linear.app/x/issue/PE-283/x",
            .updated_at = "2026-08-04T00:00:00.000Z",
            .assignee_name = null,
            .team_key = "PE",
        },
        .state_id = "s-backlog",
        .team_id = "team-uuid",
        .project = null,
        .labels = &.{},
        .description = null,
    };

    const outcome: release.Outcome = .{ .needs_confirmation = .{
        .candidate = semver.parse("v2.6.0").?,
        .baseline = semver.parse("v2.5.2").?,
        .baseline_from = .tag,
        .baseline_evidence = "git tag",
    } };

    const value = try buildResolveReport(arena, detail, .{}, outcome, null, &.{});
    const body = try std.json.Stringify.valueAlloc(arena, value, .{ .whitespace = .indent_2 });

    const Schema = struct {
        issue: struct { id: []const u8, identifier: []const u8, url: []const u8 },
        status: []const u8,
        rule: u8,
        rule_name: []const u8,
        version: ?[]const u8,
        evidence: ?struct { kind: []const u8, text: []const u8 },
        project: ?struct { id: []const u8, name: []const u8 },
        confirm_before_create: bool,
        baseline: ?struct { version: []const u8, source: []const u8, evidence: []const u8 },
        choices: []struct { version: []const u8, source: []const u8 },
        conflict: ?struct { id: []const u8, name: []const u8 },
        question: ?[]const u8,
        command: ?[]const u8,
        git: ?struct {
            root: []const u8,
            head: ?[]const u8,
            branch: ?[]const u8,
            detached: bool,
            default_branch: []const u8,
            fetched: bool,
            pr_base: ?[]const u8,
            release_branches: []struct { branch: []const u8, version: []const u8, ahead: ?u32 },
        },
        notes: [][]const u8,
    };

    const parsed = try std.json.parseFromSliceLeaky(Schema, arena, body, .{});

    try std.testing.expectEqualStrings("needs_confirmation", parsed.status);
    try std.testing.expectEqual(@as(u8, 6), parsed.rule);
    try std.testing.expectEqualStrings("v2.6.0", parsed.version.?);
    try std.testing.expectEqualStrings("v2.5.2", parsed.baseline.?.version);
    try std.testing.expectEqualStrings("tag", parsed.baseline.?.source);
    try std.testing.expect(parsed.confirm_before_create);
    try std.testing.expect(std.mem.endsWith(u8, parsed.command.?, "--assign v2.6.0 --create"));
    try std.testing.expect(std.mem.indexOf(u8, parsed.question.?, "v2.5.2") != null);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"git\": null") != null);
}

test "a resolved release names the rule that found it and needs no confirmation" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const detail: linear.Detail = .{
        .issue = .{
            .id = "uuid-1",
            .identifier = "PE-283",
            .title = "Something",
            .branch_name = "feature/pe-283-x",
            .state_name = "Backlog",
            .state_type = "backlog",
            .priority = 0,
            .url = "https://linear.app/x/issue/PE-283/x",
            .updated_at = "2026-08-04T00:00:00.000Z",
            .assignee_name = null,
            .team_key = "PE",
        },
        .state_id = "s-backlog",
        .team_id = "team-uuid",
        .project = null,
        .labels = &.{},
        .description = null,
    };

    const outcome: release.Outcome = .{ .resolved = .{
        .version = semver.parse("v2.7.0").?,
        .rule = .release_branch,
        .evidence = .{ .kind = .branch, .text = "release/2.7.0" },
    } };

    const value = try buildResolveReport(arena, detail, .{}, outcome, null, &.{});

    try std.testing.expectEqualStrings("resolved", value.status);
    try std.testing.expectEqual(@as(u8, 3), value.rule);
    try std.testing.expectEqualStrings("v2.7.0", value.version.?);
    try std.testing.expect(!value.confirm_before_create);
    try std.testing.expect(std.mem.endsWith(u8, value.command.?, "--create"));
}

test "findProject takes a shipped release too, because an explicit name is not a proposal" {
    const board: linear.ReleaseProjects = .{
        .open = &.{
            .{ .id = "p-260", .name = "v2.6.0", .status_type = "backlog", .status_name = "Backlog" },
        },
        .completed = &.{
            .{ .id = "p-252", .name = "v2.5.2", .status_type = "completed", .status_name = "Completed" },
        },
        .truncated = false,
    };

    try std.testing.expectEqualStrings("p-260", findProject(board, "v2.6.0").?.id);
    try std.testing.expectEqualStrings("p-252", findProject(board, "v2.5.2").?.id);
    try std.testing.expect(findProject(board, "v9.9.9") == null);
}

test "the project payload keeps the shape a caller parses" {
    const gpa = std.testing.allocator;

    const value: ProjectReport = .{
        .issue = .{ .id = "uuid-1", .identifier = "PE-283", .url = "https://linear.app/x/issue/PE-283/x" },
        .project = .{ .id = "p-260", .name = "v2.6.0" },
        .changed = true,
        .created = false,
    };

    const body = try std.json.Stringify.valueAlloc(gpa, value, .{ .whitespace = .indent_2 });
    defer gpa.free(body);

    const Schema = struct {
        issue: struct { id: []const u8, identifier: []const u8, url: []const u8 },
        project: struct { id: []const u8, name: []const u8 },
        changed: bool,
        created: bool,
    };

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Schema, arena_state.allocator(), body, .{});

    try std.testing.expectEqualStrings("v2.6.0", parsed.project.name);
    try std.testing.expect(parsed.changed);
    try std.testing.expect(!parsed.created);
}

test "the comment payload keeps the shape a caller parses" {
    const gpa = std.testing.allocator;

    const value: CommentReport = .{
        .issue = .{
            .id = "uuid-1",
            .identifier = "PE-250",
            .url = "https://linear.app/x/issue/PE-250/fix",
        },
        .comment = .{
            .id = "comment-uuid",
            .url = "https://linear.app/x/issue/PE-250/fix#comment-comment-uuid",
            .created_at = "2026-08-04T09:00:00.000Z",
        },
        .body_bytes = 42,
    };

    const body = try std.json.Stringify.valueAlloc(gpa, value, .{ .whitespace = .indent_2 });
    defer gpa.free(body);

    const Schema = struct {
        issue: struct { id: []const u8, identifier: []const u8, url: []const u8 },
        comment: struct { id: []const u8, url: []const u8, created_at: []const u8 },
        body_bytes: usize,
    };

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Schema, arena_state.allocator(), body, .{});

    try std.testing.expectEqualStrings("PE-250", parsed.issue.identifier);
    try std.testing.expectEqualStrings("comment-uuid", parsed.comment.id);
    try std.testing.expectEqual(@as(usize, 42), parsed.body_bytes);
}

test "the show payload keeps the shape a caller parses" {
    const gpa = std.testing.allocator;

    const detail: linear.Detail = .{
        .issue = .{
            .id = "uuid-1",
            .identifier = "PE-250",
            .title = "Fix CLVisit capture",
            .branch_name = "feature/pe-250-fix-clvisit-capture",
            .state_name = "In Progress",
            .state_type = "started",
            .priority = 2,
            .url = "https://linear.app/x/issue/PE-250/fix",
            .updated_at = "2026-07-27T00:00:00.000Z",
            .assignee_name = "Someone",
            .team_key = "PE",
        },
        .state_id = "state-uuid",
        .team_id = "team-uuid",
        .project = .{ .id = "project-uuid", .name = "v2.6.0" },
        .labels = &.{ "type/dev", "source/clickup" },
        .description = "Dedupe the double writes.",
    };

    const body = try std.json.Stringify.valueAlloc(gpa, buildShowReport(detail), .{ .whitespace = .indent_2 });
    defer gpa.free(body);

    const Schema = struct {
        issue: struct {
            id: []const u8,
            identifier: []const u8,
            title: []const u8,
            url: []const u8,
            state: []const u8,
            state_type: []const u8,
            state_id: []const u8,
            team: ?[]const u8,
            team_id: ?[]const u8,
            assignee: ?[]const u8,
            priority: i64,
            branch_name: []const u8,
            updated_at: []const u8,
        },
        project: ?struct { id: []const u8, name: []const u8 },
        labels: [][]const u8,
        description: ?[]const u8,
    };

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Schema, arena_state.allocator(), body, .{});

    try std.testing.expectEqualStrings("PE-250", parsed.issue.identifier);
    try std.testing.expectEqualStrings("state-uuid", parsed.issue.state_id);
    try std.testing.expectEqualStrings("team-uuid", parsed.issue.team_id.?);
    try std.testing.expectEqualStrings("v2.6.0", parsed.project.?.name);
    try std.testing.expectEqualStrings("type/dev", parsed.labels[0]);
}

test "an issue in no project says so, rather than leaving the key out" {
    const gpa = std.testing.allocator;

    const detail: linear.Detail = .{
        .issue = .{
            .id = "uuid-2",
            .identifier = "PE-9",
            .title = "Something in the backlog",
            .branch_name = "feature/pe-9-something",
            .state_name = "Backlog",
            .state_type = "backlog",
            .priority = 0,
            .url = "https://linear.app/x/issue/PE-9/x",
            .updated_at = "2026-07-27T00:00:00.000Z",
            .assignee_name = null,
            .team_key = "PE",
        },
        .state_id = "state-uuid",
        .team_id = "team-uuid",
        .project = null,
        .labels = &.{},
        .description = null,
    };

    const body = try std.json.Stringify.valueAlloc(gpa, buildShowReport(detail), .{ .whitespace = .indent_2 });
    defer gpa.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"project\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"description\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"assignee\": null") != null);
}
