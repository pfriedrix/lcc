//! Reading and writing one Linear issue, named by its identifier.
//!
//! `lcc start --json` resolves an issue too, but it is not a read-only probe: it
//! cuts a branch and a worktree on the way, and a caller that only wanted to look
//! has to undo them. This is the command that only looks.
//!
//! Nothing here needs a repository. `show` answers the same from anywhere, which
//! is what lets a caller ask about an issue before deciding where its code lives.

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

/// The subcommand `raw` names, case-insensitively — the shape `open.resolveTarget`
/// uses. Null is "not one of ours", which the caller turns into a message naming
/// the ones that are.
pub fn resolveVerb(raw: []const u8) ?Verb {
    if (std.ascii.eqlIgnoreCase(raw, "show")) return .show;
    if (std.ascii.eqlIgnoreCase(raw, "state")) return .state;
    if (std.ascii.eqlIgnoreCase(raw, "comment")) return .comment;
    if (std.ascii.eqlIgnoreCase(raw, "project")) return .project;
    return null;
}

/// The flags a verb takes, and only those. A union rather than one flat struct
/// carrying every flag: an option a verb has no use for should not be a thing that
/// parses and is then ignored.
pub const Sub = union(enum) {
    show: Show,
    state: SetState,
    comment: AddComment,
    project: SetProject,

    pub const Show = struct {};

    pub const SetState = struct {
        /// The state as it is written on the board — resolved against that team's
        /// own workflow states, never against a status type.
        name: ?[]const u8 = null,
        /// `--type` — narrows a name two states share, by Linear's `statusType`.
        /// It may only narrow: a type that matches no name is still no such state.
        type: ?[]const u8 = null,
    };

    pub const AddComment = struct {
        /// `-m` — the body outright.
        body: ?[]const u8 = null,
        /// `-f` — the body read off disk. Mutually exclusive with `body`.
        file: ?[]const u8 = null,
    };

    pub const SetProject = struct {
        /// `--assign vX.Y.Z` — the version said outright. There is no inference
        /// here and no resolver: a command that writes to Linear names what it is
        /// writing.
        assign: ?[]const u8 = null,
        /// `--resolve` — work out which release this issue targets and say so.
        /// Read-only, always exits 0. Mutually exclusive with `--assign`.
        resolve: bool = false,
        /// `--fetch` — refresh the view of `origin` first. Off by default because
        /// this runs on a hot path, and a stale view degrades to a conservative
        /// answer rather than a wrong one.
        fetch: bool = false,
        /// Create the project when it does not exist. The flag **is** the consent,
        /// moved out of a prompt so a non-interactive caller can give it.
        create: bool = false,
        /// Reassign an issue that is already in a project. Moving between releases
        /// is a deliberate "cut", so it does not happen by accident.
        force: bool = false,
    };

    /// The defaults for `verb`, so the parser has somewhere to put its flags.
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
    /// `PE-42`, exactly as typed. Parsed into a `linear.Ref` inside `run`, so a bad
    /// identifier is one refusal in one place however many subcommands there are.
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

/// The Keychain read, the config, and a token that has not expired.
///
/// The hint comes before the read, not after: the Keychain grants access to a
/// binary by its code signature, so a freshly built lcc can block here on a system
/// dialog asking for the login password. Announced, that is a wait with a reason;
/// unannounced, it is a process sitting silently with no output and no child.
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
        // The full board, in its own order, so "no such state" says what there is
        // instead of only what there is not. When the state list was capped, that
        // is a different claim and the message makes it.
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
        // Refused in both modes, not just the machine one: two modes disagreeing
        // about which state an issue landed in is worse than either refusing. The
        // escape is `--type`, because `(name, type)` is the pair that is unique —
        // and it is the same string in both modes, so a caller can retry without
        // a human.
        .ambiguous => |hits| bail(
            app,
            opts.json,
            "state_ambiguous",
            "{d} states in {s} are called '{s}': {s}. Narrow it: lcc issue state {s} \"{s}\" --type <type>",
            .{ hits.len, ctx.team_key, wanted, stateTypes(app, hits), named, wanted },
        ),
    };

    // Linear's GitHub integration moves an issue on a branch push, so arriving to
    // find it already there is the normal case, not a race. Writing anyway would
    // bump `updatedAt` and put a state change in the activity feed nobody made.
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

/// The types that tell two same-named states apart, which is the only thing a
/// caller can use to narrow them.
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
    /// False when the issue was already there. The write is skipped, not faked —
    /// `from` and `to` are then the same value.
    changed: bool,
    from: ReportState,
    /// What Linear ended up with, re-read out of the mutation's own payload rather
    /// than echoed back from the request.
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
    // Normalised, so `2.6.0` and `v2.6.0` name the same project and a created one
    // is always spelled the way the board spells it.
    const name = try semver.render(app.gpa, wanted);

    const found = linear.fetchIssueDetail(app.gpa, app.io, token, ref) catch |err| bail(
        app,
        opts.json,
        "linear_failed",
        "Linear request failed ({s}, HTTP {d}): {s}",
        .{ @errorName(err), linear.last_status, linear.last_message },
    );
    const detail = found orelse bail(app, opts.json, "issue_not_found", "No issue {s} in Linear.", .{named});

    // Moving an issue between releases is a deliberate cut, and this is where that
    // is enforced rather than merely written down. The refusal names the flag, so
    // a caller that meant it can say so without going and reading the docs.
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

    // Already in the right project: reported, not rewritten, for the same reason
    // `state` skips a no-op — an activity-feed entry nobody made is noise.
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

/// Which release this issue targets, worked out rather than named.
///
/// Read-only and **always exits 0**, even when only a human can settle it: an
/// unresolved case comes back as a proposal with the whole computation already
/// done, so the caller's question is a formatting job rather than a re-derivation.
/// The write is `--assign`, which infers nothing.
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

    // Rule 2 is the common case in a start-task flow, and it needs neither git nor
    // the project board. Asking here is what keeps those two off the hot path.
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

/// The git half of `Facts`, kept for the report so a reader can see what the rule
/// was decided against. Null when there is no repository here at all.
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

    // Every count is measured from a resolved sha rather than the literal `HEAD`:
    // the counts run in the main checkout, so `HEAD` there would be a different
    // commit whenever the user is standing in a linked worktree.
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
        // Tags are noisy — `build-4471` lives beside `v2.6.0` — so the ones that
        // are not versions are skipped silently rather than noted one by one.
        for (names) |name| {
            if (semver.parse(name)) |version| tags.append(app.gpa, version) catch {};
        }
    } else |_| {}
    semver.sortAsc(tags.items);
    facts.tags = tags.items;

    // The base rides on a request lcc already makes for this branch, so there is
    // no second process and no second network hop. `gh` is optional throughout:
    // its absence costs a note, and the commit-distance contest still answers.
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

    // Everything already cut, from the two sources that mean *shipped* — tags and
    // completed projects. A live release branch means stabilising, which is the
    // veto's job below, not this ceiling's.
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

/// The projects whose names really are versions. A `v2.6.0-rc1` on the board is
/// invisible to the resolver rather than standing in for the release.
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

/// The project called `name`, looked for in both halves of the board.
///
/// A completed project is a legitimate target for an explicit `--assign`: dropping
/// shipped releases is about what the *resolver* may propose, not about what a
/// human may name outright.
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
    /// Whether this run attached it. False when the issue was already there.
    changed: bool,
    /// Whether this run had to create the project first.
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

/// What `--resolve` promises.
///
/// Every status exits 0 — an unresolved case is an answer, not a failure, and the
/// point of moving this into lcc is that the computation survives the human gate
/// instead of being defeated by it. `question` and `command` are pre-worded so the
/// caller quotes rather than re-derives them.
const ResolveReport = struct {
    issue: ReportRef,
    /// `resolved`, `already_set`, `needs_confirmation` or `needs_choice`.
    status: []const u8,
    rule: u8,
    rule_name: []const u8,
    /// The version. Present for `resolved`, for `already_set` unless the project's
    /// name is not a version, and for `needs_confirmation` as the candidate.
    version: ?[]const u8,
    evidence: ?ReportEvidence,
    /// The Linear project carrying that name, when one exists.
    project: ?ReportProject,
    /// Whether a human has to agree before the project is created — false for the
    /// rules that read a version off a fact, true for the one that infers it.
    confirm_before_create: bool,
    baseline: ?ReportBaseline,
    choices: []const ReportChoice,
    /// A project already on the issue that this answer disagrees with. Non-null
    /// means `--assign` will refuse without `--force`.
    conflict: ?ReportProject,
    question: ?[]const u8,
    command: ?[]const u8,
    /// Null when the answer never needed git — not an empty object, because "not
    /// gathered" and "gathered and empty" are different facts.
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
            // Rules 1 and 3 to 5 read a version off a fact, so a project created
            // for one needs no further agreement.
            value.confirm_before_create = false;
            if (hit.project) |p| value.project = .{ .id = p.id, .name = p.name };
            if (hit.project == null) {
                // Only the board having been read makes "there is none" a claim
                // worth acting on, so say which of the two nulls this is.
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

/// A markdown plan is the largest thing anyone reasonably comments with. A
/// megabyte is headroom over that; past it the caller has pointed at the wrong
/// file, and saying so beats sending it.
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

    // The issue's own UUID is what `commentCreate` writes against, and the read
    // that fetches it is also what proves the issue exists before anything is sent.
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

/// The comment body, from `-m` outright or from a file.
///
/// The path is resolved before it is read, and the ways that can fail are kept
/// apart: `realPathFileAlloc` resolves anything that exists, directories included,
/// so "no such file" is a claim to make once it is true rather than a catch-all.
/// Told a file is missing when it is sitting there unreadable, you go looking for
/// the wrong thing.
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

/// The three fields a write's report needs to identify what it wrote to. A subset
/// of `ReportIssue` rather than the whole of it, because a write should not have
/// to have read the description in order to report itself.
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
    /// Bytes as sent, so a caller that fed a file can tell a truncated read from a
    /// whole one without re-stat-ing it.
    body_bytes: usize,
};

/// Shared by every subcommand, and field-for-field the `issue` block of
/// `lcc start --json` where the two overlap, plus the ids a write needs and the
/// fields only a detail read pays for. A caller parses one shape, not two.
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

/// What `show --json` promises. A declared type rather than a literal inside the
/// printer, because it is a contract another program parses — the test at the
/// bottom of this file is what keeps the field names from drifting.
const ShowReport = struct {
    issue: ReportIssue,
    /// Null is "in no project", which for an issue past Todo is the invariant a
    /// caller is checking for.
    project: ?ReportProject,
    /// Every label, flat. Which one picks a pipeline is the caller's taxonomy, and
    /// grouping them here would be lcc taking a view on one it does not own.
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
    // Stated even when there is none: an issue past Todo with no project is
    // invisible on the release board, and a line that disappears when it is
    // missing is the one a reader stops looking for.
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

/// The exits a caller has to be able to react to, in the shape it asked for. JSON
/// goes to stdout and the human line to stderr, so both readers get served.
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
    // An identifier in the verb's place is a missing subcommand, not a verb.
    try std.testing.expect(resolveVerb("PE-42") == null);
    // Nor is a flag: `lcc issue --json PE-42` names no subcommand at all.
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

    // Already there: Linear's GitHub integration moves an issue on a branch push,
    // so this is the normal case. The write is skipped rather than faked, and
    // `from` and `to` are the same value — which is how a caller tells a no-op
    // from a move without comparing names itself.
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

    // Rule 6: nothing open left, so lcc proposes a minor above what shipped and
    // hands the question over already worded.
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
    // The one rule that infers rather than reads: creating this project needs a
    // human to agree first, and the flag that says so is in the command.
    try std.testing.expect(parsed.confirm_before_create);
    try std.testing.expect(std.mem.endsWith(u8, parsed.command.?, "--assign v2.6.0 --create"));
    // Already worded, so the caller's hard gate is a formatting job.
    try std.testing.expect(std.mem.indexOf(u8, parsed.question.?, "v2.5.2") != null);

    // `git: null` is the staging contract: rule 2 and this path never paid for it,
    // and an empty object would claim it was gathered and came back bare.
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
    // Rule 3 read the version off a branch that exists, so there is nothing left
    // for a human to agree to — only rule 6 infers.
    try std.testing.expect(!value.confirm_before_create);
    // The board was never asked, so no project was found, and the command says so
    // by carrying `--create`.
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
    // Dropping shipped releases governs what the resolver may *propose*. A human
    // naming one outright — backfilling an issue onto a release that already went
    // out — is a different act, and refusing it here would be lcc overruling them.
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
        /// Separate from `changed` on purpose: a caller has to be able to tell an
        /// issue being filed into an existing release from one that brought a new
        /// release board into existence.
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
    // The comment's own URL, not the issue's: a caller that reports "commented"
    // should be able to link to the comment it made.
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

    // The shape the caller relies on, spelled out independently of `ShowReport`.
    // Parsing rejects unknown fields, so renaming, dropping *or* adding one fails
    // here rather than in whatever is reading the JSON.
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
    // The two ids a write needs, so setting a state or creating a project never
    // has to send the human key `PE` where Linear wants a UUID.
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

    // A missing project is the invariant violation a caller is looking for, so the
    // key is present and null rather than absent — an absent key reads as "lcc did
    // not check", which is a different answer.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"project\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"description\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"assignee\": null") != null);
}
