const std = @import("std");
const linear = @import("../linear.zig");
const start = @import("start.zig");

pub const issue_fixture: linear.Issue = .{
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

test "the plan-channel test home reaches start.expandCommand" {
    const gpa = std.testing.allocator;
    const got = try start.expandCommand(gpa, "{identifier}", issue_fixture, "feature/pe-250-actual", null);
    defer gpa.free(got.text);
    try std.testing.expectEqualStrings("PE-250", got.text);
}

const branch = "feature/pe-250-actual";

const plan_path = "/tmp/lcc-plan-fixture.md";

fn yn(b: bool) []const u8 {
    return if (b) "true" else "false";
}

fn expectCarries(template: []const u8, want: bool) !void {
    const got = start.templateCarriesPlan(template);
    if (got != want) {
        std.debug.print(
            \\
            \\templateCarriesPlan misread the template:
            \\  template: "{s}"
            \\  answered: {s}
            \\  expected: {s}
            \\  cost:     {s}
            \\
        , .{
            template,
            yn(got),
            yn(want),
            if (want)
                "a launch whose template does carry the plan is refused"
            else
                "--plan is accepted for a template that carries nothing to the agent",
        });
        return error.PlanChannelMisread;
    }
}

test "AC-1: templateCarriesPlan answers true for a {plan} placeholder embedded anywhere in the template" {
    try expectCarries("/start-task {identifier} --plan {plan}", true);
    try expectCarries("/start-task {plan} {identifier}", true);
    try expectCarries("{plan}", true);
}

test "AC-2: templateCarriesPlan answers false when there is no {plan} placeholder, including prose that merely says plan" {
    try expectCarries("/start-task {identifier}", false);
    try expectCarries("/start-task {identifier} --note read the plan before coding", false);
}

test "AC-3: templateCarriesPlan answers false for an empty template and for one that is only spaces and tabs" {
    try expectCarries("", false);
    try expectCarries("   \t  \t", false);
}

test "AC-4: templateCarriesPlan answers false for an unclosed brace and for an unknown key" {
    try expectCarries("/start-task {identifier} --plan {plan", false);
    try expectCarries("/start-task {identifier} {nope}", false);
}

test "AC-5: templateCarriesPlan agrees with expandCommand's used_plan on every template in the table" {
    const gpa = std.testing.allocator;

    const Case = struct { name: []const u8, template: []const u8 };
    const table = [_]Case{
        .{ .name = "{plan} present", .template = "/start-task {identifier} --plan {plan}" },
        .{ .name = "{plan} absent", .template = "/start-task {identifier}" },
        .{ .name = "empty template", .template = "" },
        .{ .name = "unclosed brace", .template = "/start-task {identifier} --plan {plan" },
        .{ .name = "unknown key", .template = "/start-task {nope}" },
        .{ .name = "{plan} twice", .template = "/start-task --plan {plan} --replan {plan}" },
        .{ .name = "{plan} adjacent to another placeholder", .template = "{identifier}{plan}" },
    };

    for (table) |case| {
        const early = start.templateCarriesPlan(case.template);
        const expanded = start.expandCommand(gpa, case.template, issue_fixture, branch, plan_path) catch |err| {
            std.debug.print(
                \\
                \\expandCommand failed on table entry "{s}" (template: "{s}") with {s},
                \\so the two scans cannot be compared for that entry.
                \\
            , .{ case.name, case.template, @errorName(err) });
            return err;
        };
        defer gpa.free(expanded.text);

        if (early != expanded.used_plan) {
            std.debug.print(
                \\
                \\the two scans of one syntax drifted apart on table entry "{s}":
                \\  template:            "{s}"
                \\  templateCarriesPlan: {s}
                \\  expandCommand.used_plan: {s}
                \\  cost: {s}
                \\
            , .{
                case.name,
                case.template,
                yn(early),
                yn(expanded.used_plan),
                if (early)
                    "the worktree is cut anyway and the late refusal still fires — the bug survives its own fix"
                else
                    "a launch the expander would have carried is refused before anything is created",
            });
            return error.PlanChannelDrift;
        }
    }
}
