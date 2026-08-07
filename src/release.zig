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
    name: []const u8,
    version: Version,
};

pub const ReleaseBranch = struct {
    branch: []const u8,
    version: Version,
    ahead: ?u32 = null,
};

pub const Reason = enum {
    no_signal,
    linear_unavailable,
    no_team,
    projects_truncated,
    ambiguous_base,
    no_git,
};

pub const Evidence = struct {
    kind: enum { argument, project, branch, pull_request, distance },
    text: []const u8,
};

pub const Resolved = struct {
    version: Version,
    rule: Rule,
    evidence: Evidence,
    project: ?Project = null,
    displaced: ?Project = null,
};

pub const AlreadySet = struct {
    version: ?Version,
    project: ?Project,
    name: []const u8,
};

pub const NeedsConfirmation = struct {
    candidate: Version,
    baseline: Version,
    baseline_from: enum { tag, completed_project, release_branch },
    baseline_evidence: []const u8,
};

pub const NeedsChoice = struct {
    reason: Reason,
    open: []const Project = &.{},
    branches: []const ReleaseBranch = &.{},
    suggestion: ?Version = null,
};

pub const Outcome = union(enum) {
    resolved: Resolved,
    already_set: AlreadySet,
    needs_confirmation: NeedsConfirmation,
    needs_choice: NeedsChoice,
};

pub const Facts = struct {
    identifier: []const u8 = "",

    explicit: ?Version = null,
    issue_project: ?Project = null,
    issue_project_unversioned: ?[]const u8 = null,

    git_available: bool = false,
    current_branch: ?[]const u8 = null,
    default_branch: []const u8 = "main",
    pr_base: ?[]const u8 = null,
    release_branches: []const ReleaseBranch = &.{},
    ahead_of_default: ?u32 = null,
    tags: []const Version = &.{},

    projects_asked: bool = false,
    open_projects: []const Project = &.{},
    dropped_projects: []const Project = &.{},
    completed_projects: []const Project = &.{},
    projects_truncated: bool = false,
    team: ?[]const u8 = null,
};

pub fn resolveLocal(facts: Facts) ?Outcome {
    if (facts.explicit) |version| {
        return .{ .resolved = .{
            .version = version,
            .rule = .explicit,
            .evidence = .{ .kind = .argument, .text = "named outright" },
            .displaced = facts.issue_project,
        } };
    }

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

    if (facts.current_branch) |branch| {
        if (semver.fromBranch(branch)) |version| {
            return .{ .resolved = .{
                .version = version,
                .rule = .release_branch,
                .evidence = .{ .kind = .branch, .text = branch },
            } };
        }
        if (std.mem.eql(u8, branch, facts.default_branch)) return null;
    }

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

    return nearestBase(facts);
}

pub fn resolve(facts: Facts) Outcome {
    if (resolveLocal(facts)) |outcome| return outcome;

    if (!facts.git_available) {
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

    if (highestShipped(facts)) |baseline| {
        return .{ .needs_confirmation = .{
            .candidate = semver.nextMinor(baseline.version),
            .baseline = baseline.version,
            .baseline_from = baseline.source,
            .baseline_evidence = baseline.text,
        } };
    }

    return .{ .needs_choice = .{ .reason = .no_signal } };
}

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
    try std.testing.expectEqualStrings("v2.5.0", outcome.resolved.displaced.?.name);
}

test "rule 2 fires with no git and no board, which is the whole point of staging" {
    const outcome = resolve(.{ .issue_project = proj("p-260", "v2.6.0") });

    try std.testing.expectEqual(@as(usize, 6), outcome.already_set.version.?.minor);
    try std.testing.expectEqualStrings("v2.6.0", outcome.already_set.name);
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

    const to_board = resolveLocal(.{
        .git_available = true,
        .current_branch = "feature/pe-42-x",
        .release_branches = &branches,
        .ahead_of_default = 3,
    });
    try std.testing.expect(to_board == null);

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

    const keep = partitionStabilising(&open, &branches, v("v2.4.1"));
    try std.testing.expectEqual(@as(usize, 1), keep);
    try std.testing.expectEqualStrings("v2.6.0", open[0].name);

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
        .ahead_of_default = 0,
    });

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

    try std.testing.expectEqual(
        Reason.no_signal,
        resolve(.{ .git_available = true, .current_branch = "main", .team = "PE", .projects_asked = true }).needs_choice.reason,
    );
    try std.testing.expectEqual(Reason.linear_unavailable, resolve(base).needs_choice.reason);
    try std.testing.expectEqual(
        Reason.no_team,
        resolve(.{ .git_available = true, .current_branch = "main" }).needs_choice.reason,
    );
    const open = [_]Project{proj("p-260", "v2.6.0")};
    const blind = resolve(.{ .projects_asked = true, .team = "PE", .open_projects = &open });
    try std.testing.expectEqual(Reason.no_git, blind.needs_choice.reason);
    try std.testing.expectEqual(@as(usize, 6), blind.needs_choice.suggestion.?.minor);
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
