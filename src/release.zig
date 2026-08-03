//! Which release an issue targets, decided as a pure function of gathered facts.
//!
//! This module imports nothing but `std` and `semver.zig` — no git, no Linear, no
//! `Io`, no allocator. Everything that costs a round trip is gathered by the
//! caller and handed over as `Facts`, which is what makes all seven rules table
//! tests rather than something only a live workspace can settle. It is the
//! `Facts`/`buildReport` split in `commands/start.zig`, pushed as far as it goes.
//!
//! The rules, in order:
//!
//!   1. a version said outright
//!   2. the issue is already in a project — never silently reassigned
//!   3. the current branch is `release/X.Y.Z`
//!   4. the branch was cut from one — from the pull request's base, else from the
//!      candidate base HEAD is fewest commits ahead of
//!   5. on trunk: the lowest open release project the board still accumulates for
//!   6. nothing open left: the next minor above what already shipped — proposed,
//!      never taken
//!   7. nobody can tell: ask

const std = @import("std");
const semver = @import("semver.zig");

pub const Version = semver.Version;

pub const Rule = enum {
    explicit,
    issue_project,
    release_branch,
    pr_base,
    nearest_base,
    lowest_open,
    next_minor,
    unresolved,

    /// The rule's number in the list above, so a report can name it the way the
    /// documentation does.
    pub fn number(self: Rule) u8 {
        return switch (self) {
            .explicit => 1,
            .issue_project => 2,
            .release_branch => 3,
            .pr_base, .nearest_base => 4,
            .lowest_open => 5,
            .next_minor => 6,
            .unresolved => 7,
        };
    }

    /// The bracketed half of `→ Project: v2.5.2 (rule 3: release branch)`.
    pub fn describe(self: Rule) []const u8 {
        return switch (self) {
            .explicit => "named outright",
            .issue_project => "already set on the issue",
            .release_branch => "release branch",
            .pr_base => "base of the pull request",
            .nearest_base => "nearest base by commit distance",
            .lowest_open => "lowest open release project",
            .next_minor => "next minor above what shipped",
            .unresolved => "nothing could settle it",
        };
    }
};

pub const Project = struct {
    id: []const u8,
    /// Exactly as Linear spells it — what a human sees and what `--assign` matches.
    name: []const u8,
    version: Version,
};

pub const ReleaseBranch = struct {
    /// `release/2.5.2`, `origin/` already stripped.
    branch: []const u8,
    version: Version,
    /// `git rev-list --count origin/<branch>..HEAD`. Null when the range could not
    /// be resolved, and a null must **lose** the nearest-base contest rather than
    /// win it — an unreachable ref is not the closest one.
    ahead: ?u32 = null,
};

/// Why a version could not be settled without asking.
pub const Reason = enum {
    /// Rule 7 proper: git and Linear both came up empty.
    no_signal,
    /// On trunk's line, but the project board could not be read.
    linear_unavailable,
    /// The issue reports no team, so there is no board to scope a query to.
    no_team,
    /// The open-project window was full, so the lowest is not provable.
    projects_truncated,
    /// Two release branches are equidistant from HEAD.
    ambiguous_base,
    /// No repository, so the release-branch veto cannot be applied — and an
    /// unvetoed "lowest open project" is exactly the wrong answer rule 5 exists
    /// to avoid.
    no_git,
};

pub const Evidence = struct {
    kind: enum { argument, project, branch, pull_request, distance },
    /// `release/2.5.2`, `--assign v2.5.2`, `2 commits ahead of origin/release/2.5.2`.
    text: []const u8,
};

pub const Resolved = struct {
    version: Version,
    rule: Rule,
    evidence: Evidence,
    /// The project already carrying this name, when the board was read and one
    /// exists. Null means either "Linear was not asked" or "asked, and there is
    /// none" — only the second may authorise creating it, which is why the caller
    /// tracks whether it asked.
    project: ?Project = null,
    /// A project already on the issue that this answer disagrees with. Reachable
    /// only through rule 1, because nothing else outranks rule 2 — and this is
    /// what a writer refuses on without an explicit override.
    displaced: ?Project = null,
};

pub const AlreadySet = struct {
    /// Null when the project's name is not a version. Untouchable either way.
    version: ?Version,
    project: ?Project,
    name: []const u8,
};

pub const NeedsConfirmation = struct {
    /// `vA.B+1.0`.
    candidate: Version,
    baseline: Version,
    baseline_from: enum { tag, completed_project, release_branch },
    /// `v2.5.2`, `project v2.5.2`, `origin/release/2.5.2`.
    baseline_evidence: []const u8,
};

pub const NeedsChoice = struct {
    reason: Reason,
    /// Sub-slices of `Facts`, never allocated — which is why `Facts` arrives
    /// sorted and already partitioned.
    open: []const Project = &.{},
    branches: []const ReleaseBranch = &.{},
    /// Where a picker should put the cursor, when one row is better than the rest.
    suggestion: ?Version = null,
};

pub const Outcome = union(enum) {
    /// A version lcc stands behind. Rules 1, 3, 4, 5.
    resolved: Resolved,
    /// Rule 2, carrying no permission to do anything.
    already_set: AlreadySet,
    /// Rule 6: a candidate nobody has agreed to yet.
    needs_confirmation: NeedsConfirmation,
    /// Rule 7, and every case where a rule could have fired but its input was
    /// missing or ambiguous.
    needs_choice: NeedsChoice,
};

/// Everything the rules read, gathered before any of them runs.
///
/// Every version list arrives **semver-ascending**, and every rule is guarded by
/// its own input being present. Both together are what let a caller ask twice:
/// once on facts holding only the issue, and again once git and the project board
/// have been paid for. A rule whose input is missing simply does not fire.
pub const Facts = struct {
    /// `PE-42`, for the wording of a question.
    identifier: []const u8 = "",

    /// Rule 1 — the version said outright, already parsed.
    explicit: ?Version = null,
    /// Rule 2 — the version-named project the issue carries.
    issue_project: ?Project = null,
    /// Rule 2 for a project whose name is not a version. It still fires: an
    /// already-set project is untouchable whether or not lcc can read a version
    /// out of its name.
    issue_project_unversioned: ?[]const u8 = null,

    /// False when no repository was found at all, which is different from a
    /// repository that simply has no release branches.
    git_available: bool = false,
    /// Null for a detached HEAD.
    current_branch: ?[]const u8 = null,
    default_branch: []const u8 = "main",
    /// The base branch of the pull request for the current branch, short name.
    /// Null covers no PR, no `gh`, no auth and no network alike — the fallback
    /// does not care which.
    pr_base: ?[]const u8 = null,
    /// Live `origin/release/X.Y.Z`, each with how far HEAD is ahead of it.
    release_branches: []const ReleaseBranch = &.{},
    /// How far HEAD is ahead of `origin/<default_branch>`. Null when the range
    /// could not be resolved.
    ahead_of_default: ?u32 = null,
    /// Tags that parse as versions, ascending.
    tags: []const Version = &.{},

    /// Linear was asked for the team's release projects and answered.
    projects_asked: bool = false,
    /// Versions trunk is still accumulating for, ascending — `partitionStabilising`
    /// already applied.
    open_projects: []const Project = &.{},
    /// Open projects dropped by that partition, kept because a dropped candidate
    /// is the most likely thing a human disagrees with.
    dropped_projects: []const Project = &.{},
    /// Completed ones, ascending. A baseline for rule 6, nothing else.
    completed_projects: []const Project = &.{},
    /// The open window was full, so the lowest open version is not provable.
    projects_truncated: bool = false,
    /// The issue's team key. Null means there is no board to scope a query to.
    team: ?[]const u8 = null,
};

/// Rules 1 to 4 — everything answerable from the argument, the issue and local
/// refs. Null when the project board is still needed, which is also what facts
/// that have not been fully gathered yet come to.
///
/// Worth calling on its own: rule 2 is the common case in a start-task flow, and
/// it needs neither git nor the project board.
pub fn resolveLocal(facts: Facts) ?Outcome {
    // 1 — said outright. It wins the *report* even over an already-set project,
    // and carries the conflict in `displaced` so a writer can refuse: the prose
    // orders rule 1 first while also saying rule 2 is never overridden, and those
    // two only hold together if the override is reported but not performed.
    if (facts.explicit) |version| {
        return .{ .resolved = .{
            .version = version,
            .rule = .explicit,
            .evidence = .{ .kind = .argument, .text = "named outright" },
            .displaced = facts.issue_project,
        } };
    }

    // 2 — already in a project. Never silently reassigned; moving between releases
    // is a manual cut.
    if (facts.issue_project) |project| {
        return .{ .already_set = .{
            .version = project.version,
            .project = project,
            .name = project.name,
        } };
    }
    if (facts.issue_project_unversioned) |name| {
        return .{ .already_set = .{ .version = null, .project = null, .name = name } };
    }

    // 3 — standing on the release branch itself.
    if (facts.current_branch) |branch| {
        if (semver.fromBranch(branch)) |version| {
            return .{ .resolved = .{
                .version = version,
                .rule = .release_branch,
                .evidence = .{ .kind = .branch, .text = branch },
            } };
        }
        // On trunk there is nothing to measure — trunk *is* the base.
        if (std.mem.eql(u8, branch, facts.default_branch)) return null;
    }

    // 4a — a pull request already answers what this was cut from. A base that is
    // not a release branch means trunk, which is rule 5's business.
    if (facts.pr_base) |base| {
        if (semver.fromBranch(base)) |version| {
            return .{ .resolved = .{
                .version = version,
                .rule = .pr_base,
                .evidence = .{ .kind = .pull_request, .text = base },
            } };
        }
        return null;
    }

    // 4b — no pull request: the candidate base HEAD is fewest commits ahead of.
    return nearestBase(facts);
}

/// The whole ladder. Total, allocation-free, and callable on partial facts.
pub fn resolve(facts: Facts) Outcome {
    if (resolveLocal(facts)) |outcome| return outcome;

    // 5 — on trunk's line: the lowest version the board is still accumulating for.
    if (!facts.git_available) {
        // Without git the release-branch veto cannot be applied, and an unvetoed
        // "lowest open" is the wrong-answer shape rule 5 exists to prevent.
        return .{ .needs_choice = .{
            .reason = .no_git,
            .open = facts.open_projects,
            .suggestion = if (facts.open_projects.len > 0) facts.open_projects[0].version else null,
        } };
    }
    if (facts.team == null) return .{ .needs_choice = .{ .reason = .no_team } };
    if (!facts.projects_asked) return .{ .needs_choice = .{ .reason = .linear_unavailable } };
    if (facts.projects_truncated) {
        return .{ .needs_choice = .{
            .reason = .projects_truncated,
            .open = facts.open_projects,
            .suggestion = if (facts.open_projects.len > 0) facts.open_projects[0].version else null,
        } };
    }
    if (facts.open_projects.len > 0) {
        const lowest = facts.open_projects[0];
        return .{ .resolved = .{
            .version = lowest.version,
            .rule = .lowest_open,
            .evidence = .{ .kind = .project, .text = lowest.name },
            .project = lowest,
        } };
    }

    // 6 — nothing open left. Propose the next minor above whatever shipped most
    // recently, and let a human agree to it.
    if (highestShipped(facts)) |baseline| {
        return .{ .needs_confirmation = .{
            .candidate = semver.nextMinor(baseline.version),
            .baseline = baseline.version,
            .baseline_from = baseline.source,
            .baseline_evidence = baseline.text,
        } };
    }

    // 7 — git and Linear both came up empty.
    return .{ .needs_choice = .{ .reason = .no_signal } };
}

/// The candidate base HEAD is fewest commits ahead of.
///
/// Trunk wins every tie, deliberately: falling through to the project board puts
/// the decision where there is more evidence than a commit count, and it never
/// files work into a release that is already stabilising. A null count loses to
/// everything, because a ref that could not be resolved is not the nearest one.
fn nearestBase(facts: Facts) ?Outcome {
    var best: ?ReleaseBranch = null;
    var tied = false;

    for (facts.release_branches) |candidate| {
        const ahead = candidate.ahead orelse continue;
        if (best) |current| {
            const current_ahead = current.ahead.?;
            if (ahead < current_ahead) {
                best = candidate;
                tied = false;
            } else if (ahead == current_ahead) {
                tied = true;
            }
        } else {
            best = candidate;
        }
    }

    const winner = best orelse return null;

    // Trunk wins outright when it is at least as near, which is also the tie rule.
    if (facts.ahead_of_default) |trunk| {
        if (trunk <= winner.ahead.?) return null;
    }
    if (tied) {
        return .{ .needs_choice = .{
            .reason = .ambiguous_base,
            .branches = facts.release_branches,
        } };
    }
    return .{ .resolved = .{
        .version = winner.version,
        .rule = .nearest_base,
        .evidence = .{ .kind = .distance, .text = winner.branch },
    } };
}

const Baseline = struct {
    version: Version,
    source: @FieldType(NeedsConfirmation, "baseline_from"),
    text: []const u8,
};

/// The highest version that has already been cut, from whichever of the three
/// sources knows about the newest one. All three are consulted because each can
/// be the only one that saw the latest release: a tag exists once it ships, a
/// completed project once the board is tidied, and a release branch as soon as
/// stabilisation starts.
fn highestShipped(facts: Facts) ?Baseline {
    var best: ?Baseline = null;

    if (facts.tags.len > 0) {
        best = .{ .version = facts.tags[facts.tags.len - 1], .source = .tag, .text = "git tag" };
    }
    if (facts.completed_projects.len > 0) {
        const latest = facts.completed_projects[facts.completed_projects.len - 1];
        if (best == null or latest.version.order(best.?.version) == .gt) {
            best = .{ .version = latest.version, .source = .completed_project, .text = latest.name };
        }
    }
    for (facts.release_branches) |branch| {
        if (best == null or branch.version.order(best.?.version) == .gt) {
            best = .{ .version = branch.version, .source = .release_branch, .text = branch.branch };
        }
    }
    return best;
}

/// Splits `open` in place into the versions trunk is still accumulating for and
/// the ones it is not, returning how many of the first kind ended up at the front.
/// Unstable, so the caller sorts each half.
///
/// Two things are dropped, and they are different:
///
///   * a version with a live `origin/release/X.Y.Z` branch — that release is
///     already being stabilised, so trunk is aiming past it;
///   * a version at or below `shipped_ceiling` — a project left open in the
///     backlog long after its release went out has no branch left to veto it and
///     would otherwise win rule 5 outright. The ceiling is built from tags and
///     completed projects, **not** from release branches: a release branch means
///     stabilising, which is the first rule's job, not shipped.
pub fn partitionStabilising(
    open: []Project,
    branches: []const ReleaseBranch,
    shipped_ceiling: ?Version,
) usize {
    var keep: usize = 0;
    for (0..open.len) |i| {
        if (isStabilising(open[i], branches)) continue;
        if (shipped_ceiling) |ceiling| {
            if (open[i].version.order(ceiling) != .gt) continue;
        }
        const held = open[keep];
        open[keep] = open[i];
        open[i] = held;
        keep += 1;
    }
    return keep;
}

fn isStabilising(project: Project, branches: []const ReleaseBranch) bool {
    for (branches) |branch| {
        if (branch.version.order(project.version) == .eq) return true;
    }
    return false;
}

fn v(text: []const u8) Version {
    return semver.parse(text).?;
}

fn proj(id: []const u8, name: []const u8) Project {
    return .{ .id = id, .name = name, .version = v(name) };
}

test "rule 1 wins the report even over a project already set, and states the conflict" {
    const already = proj("p-250", "v2.5.0");
    const outcome = resolve(.{
        .explicit = v("v2.6.0"),
        .issue_project = already,
    });

    try std.testing.expectEqual(Rule.explicit, outcome.resolved.rule);
    try std.testing.expectEqual(@as(usize, 6), outcome.resolved.version.minor);
    // Reported, not performed: a writer refuses on this without an explicit
    // override, which is where "never silently reassign" is actually enforced.
    try std.testing.expectEqualStrings("v2.5.0", outcome.resolved.displaced.?.name);
}

test "rule 2 fires with no git and no board, which is the whole point of staging" {
    const outcome = resolve(.{ .issue_project = proj("p-260", "v2.6.0") });

    try std.testing.expectEqual(@as(usize, 6), outcome.already_set.version.?.minor);
    try std.testing.expectEqualStrings("v2.6.0", outcome.already_set.name);
    // `resolveLocal` answers it too, so the caller can skip paying for git.
    try std.testing.expect(resolveLocal(.{ .issue_project = proj("p-260", "v2.6.0") }) != null);
}

test "a project whose name is not a version is still untouchable" {
    const outcome = resolve(.{ .issue_project_unversioned = "Q3 rewrite" });

    try std.testing.expect(outcome.already_set.version == null);
    try std.testing.expectEqualStrings("Q3 rewrite", outcome.already_set.name);
}

test "rule 3 reads the release off the branch underfoot" {
    const outcome = resolve(.{
        .git_available = true,
        .current_branch = "release/2.5.2",
    });

    try std.testing.expectEqual(Rule.release_branch, outcome.resolved.rule);
    try std.testing.expectEqual(@as(usize, 2), outcome.resolved.version.patch);
    try std.testing.expectEqualStrings("release/2.5.2", outcome.resolved.evidence.text);
}

test "rule 4 takes the pull request's base, and falls through when that base is trunk" {
    const from_pr = resolve(.{
        .git_available = true,
        .current_branch = "feature/pe-42-x",
        .pr_base = "release/2.6.0",
        .projects_asked = true,
        .team = "PE",
    });
    try std.testing.expectEqual(Rule.pr_base, from_pr.resolved.rule);
    try std.testing.expectEqual(@as(usize, 6), from_pr.resolved.version.minor);

    // A pull request based on trunk says the work is aimed at trunk's release, so
    // the board decides — the commit-distance contest is not consulted at all.
    const onto_trunk = resolve(.{
        .git_available = true,
        .current_branch = "feature/pe-42-x",
        .pr_base = "main",
        .projects_asked = true,
        .team = "PE",
        .open_projects = &.{proj("p-270", "v2.7.0")},
    });
    try std.testing.expectEqual(Rule.lowest_open, onto_trunk.resolved.rule);
}

test "the nearest-base contest measures distance, and a null loses to everything" {
    const branches = [_]ReleaseBranch{
        .{ .branch = "release/2.5.2", .version = v("v2.5.2"), .ahead = 7 },
        .{ .branch = "release/2.6.0", .version = v("v2.6.0"), .ahead = 2 },
        // Unreachable: it must not come back as the nearest one just because its
        // count could not be taken.
        .{ .branch = "release/2.4.1", .version = v("v2.4.1"), .ahead = null },
    };
    const outcome = resolve(.{
        .git_available = true,
        .current_branch = "feature/pe-42-x",
        .release_branches = &branches,
        .ahead_of_default = 12,
    });

    try std.testing.expectEqual(Rule.nearest_base, outcome.resolved.rule);
    try std.testing.expectEqualStrings("release/2.6.0", outcome.resolved.evidence.text);

    // A null on its own leaves nothing to measure, so the board decides.
    const unmeasurable = [_]ReleaseBranch{
        .{ .branch = "release/2.4.1", .version = v("v2.4.1"), .ahead = null },
    };
    const fell_through = resolveLocal(.{
        .git_available = true,
        .current_branch = "feature/pe-42-x",
        .release_branches = &unmeasurable,
    });
    try std.testing.expect(fell_through == null);
}

test "trunk wins a tie, and two release branches tying is a question" {
    const branches = [_]ReleaseBranch{
        .{ .branch = "release/2.6.0", .version = v("v2.6.0"), .ahead = 3 },
    };

    // Trunk at the same distance wins: the board has more evidence than a commit
    // count, and this never files work into a release already stabilising.
    const to_board = resolveLocal(.{
        .git_available = true,
        .current_branch = "feature/pe-42-x",
        .release_branches = &branches,
        .ahead_of_default = 3,
    });
    try std.testing.expect(to_board == null);

    // Two releases equidistant is the expensive thing to guess at.
    const tied = [_]ReleaseBranch{
        .{ .branch = "release/2.6.0", .version = v("v2.6.0"), .ahead = 3 },
        .{ .branch = "release/2.5.2", .version = v("v2.5.2"), .ahead = 3 },
    };
    const outcome = resolve(.{
        .git_available = true,
        .current_branch = "feature/pe-42-x",
        .release_branches = &tied,
        .ahead_of_default = 9,
    });
    try std.testing.expectEqual(Reason.ambiguous_base, outcome.needs_choice.reason);
    try std.testing.expectEqual(@as(usize, 2), outcome.needs_choice.branches.len);
}

test "a detached HEAD still gets the contest rather than falling straight to rule 7" {
    const branches = [_]ReleaseBranch{
        .{ .branch = "release/2.6.0", .version = v("v2.6.0"), .ahead = 1 },
    };
    const outcome = resolve(.{
        .git_available = true,
        .current_branch = null,
        .release_branches = &branches,
        .ahead_of_default = 40,
    });
    try std.testing.expectEqual(Rule.nearest_base, outcome.resolved.rule);
}

test "rule 5 takes the lowest open project — the prose's own worked example" {
    // v2.4.1, v2.5.0, v2.5.1 and v2.5.2 are Completed; v2.6.0 is Backlog with no
    // release branch. This is the board the plan was written against, and the one
    // the live workspace turned out to have.
    const completed = [_]Project{
        proj("p-241", "v2.4.1"),
        proj("p-250", "v2.5.0"),
        proj("p-251", "v2.5.1"),
        proj("p-252", "v2.5.2"),
    };
    const open = [_]Project{proj("p-260", "v2.6.0")};

    const outcome = resolve(.{
        .git_available = true,
        .current_branch = "main",
        .projects_asked = true,
        .team = "PE",
        .open_projects = &open,
        .completed_projects = &completed,
    });

    try std.testing.expectEqual(Rule.lowest_open, outcome.resolved.rule);
    try std.testing.expectEqualStrings("v2.6.0", outcome.resolved.project.?.name);
}

test "an open project with a live release branch is vetoed, and a stale one is dropped" {
    var open = [_]Project{
        proj("p-241", "v2.4.1"),
        proj("p-252", "v2.5.2"),
        proj("p-260", "v2.6.0"),
    };
    const branches = [_]ReleaseBranch{
        .{ .branch = "release/2.5.2", .version = v("v2.5.2"), .ahead = 4 },
    };

    // v2.5.2 is stabilising on a branch, and v2.4.1 sits at or below what already
    // shipped — a project forgotten in the backlog long after its release went out.
    const keep = partitionStabilising(&open, &branches, v("v2.4.1"));
    try std.testing.expectEqual(@as(usize, 1), keep);
    try std.testing.expectEqualStrings("v2.6.0", open[0].name);

    // Without a ceiling only the branch veto applies, which is what the prose says
    // on its own — the stale project survives and would win rule 5.
    var again = [_]Project{ proj("p-241", "v2.4.1"), proj("p-260", "v2.6.0") };
    try std.testing.expectEqual(@as(usize, 2), partitionStabilising(&again, &branches, null));
}

test "rule 6 proposes a minor above the highest of the three baselines" {
    const completed = [_]Project{proj("p-250", "v2.5.0")};
    const branches = [_]ReleaseBranch{
        .{ .branch = "release/2.5.2", .version = v("v2.5.2"), .ahead = 1 },
    };
    const tags = [_]Version{ v("v2.4.1"), v("v2.5.1") };

    const outcome = resolve(.{
        .git_available = true,
        .current_branch = "main",
        .projects_asked = true,
        .team = "PE",
        .open_projects = &.{},
        .completed_projects = &completed,
        .release_branches = &branches,
        .tags = &tags,
        // Trunk is nearer than the release branch, so the contest does not fire.
        .ahead_of_default = 0,
    });

    // The release branch knows about the newest cut, so it is the baseline — and
    // the proposal is a minor above it, never a patch.
    try std.testing.expectEqual(@as(usize, 6), outcome.needs_confirmation.candidate.minor);
    try std.testing.expectEqual(@as(usize, 0), outcome.needs_confirmation.candidate.patch);
    try std.testing.expectEqual(@as(usize, 2), outcome.needs_confirmation.baseline.patch);
    try std.testing.expectEqualStrings("release/2.5.2", outcome.needs_confirmation.baseline_evidence);
}

test "rule 6 counts to ten, where a lexical baseline would have said nine" {
    const tags = [_]Version{ v("v2.9.0"), v("v2.10.0") };
    const outcome = resolve(.{
        .git_available = true,
        .current_branch = "main",
        .projects_asked = true,
        .team = "PE",
        .tags = &tags,
    });

    try std.testing.expectEqual(@as(usize, 11), outcome.needs_confirmation.candidate.minor);
    try std.testing.expectEqual(@as(usize, 10), outcome.needs_confirmation.baseline.minor);
}

test "everything a rule needs can be missing, and each absence has its own answer" {
    const base: Facts = .{ .git_available = true, .current_branch = "main", .team = "PE" };

    // Rule 7 proper.
    try std.testing.expectEqual(
        Reason.no_signal,
        resolve(.{ .git_available = true, .current_branch = "main", .team = "PE", .projects_asked = true }).needs_choice.reason,
    );
    // Linear could not be asked, so "nothing open" is not a claim to make.
    try std.testing.expectEqual(Reason.linear_unavailable, resolve(base).needs_choice.reason);
    // No team means no board to scope a query to.
    try std.testing.expectEqual(
        Reason.no_team,
        resolve(.{ .git_available = true, .current_branch = "main" }).needs_choice.reason,
    );
    // No repository: the release-branch veto cannot be applied, so the lowest open
    // project is offered as a suggestion rather than taken as an answer.
    const open = [_]Project{proj("p-260", "v2.6.0")};
    const blind = resolve(.{ .projects_asked = true, .team = "PE", .open_projects = &open });
    try std.testing.expectEqual(Reason.no_git, blind.needs_choice.reason);
    try std.testing.expectEqual(@as(usize, 6), blind.needs_choice.suggestion.?.minor);
    // The window was full, so the lowest of what came back is a different claim.
    const capped = resolve(.{
        .git_available = true,
        .current_branch = "main",
        .projects_asked = true,
        .team = "PE",
        .open_projects = &open,
        .projects_truncated = true,
    });
    try std.testing.expectEqual(Reason.projects_truncated, capped.needs_choice.reason);
}

test "rule numbers and descriptions stay attached to their rule" {
    try std.testing.expectEqual(@as(u8, 4), Rule.pr_base.number());
    try std.testing.expectEqual(@as(u8, 4), Rule.nearest_base.number());
    try std.testing.expectEqual(@as(u8, 7), Rule.unresolved.number());
    try std.testing.expectEqualStrings("release branch", Rule.release_branch.describe());
}
