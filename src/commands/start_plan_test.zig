const std = @import("std");
const linear = @import("../linear.zig");
const start = @import("start.zig");

pub const issue_fixture: linear.Issue = .{
    .id = "uuid-1",
    .identifier = "PE-250",
    .title = "Fix background refresh",
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

fn argAfter(args: []const []const u8, flag: []const u8) ?[]const u8 {
    if (args.len == 0) return null;
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) return args[i + 1];
    }
    return null;
}

test "the planning model rides the sessions that are there to plan, and no others" {
    const gpa = std.testing.allocator;

    const planning = try start.launchArgs(gpa, null, "/start-task PE-250", true, "fable");
    defer gpa.free(planning);

    const chosen = argAfter(planning, "--model");
    if (chosen == null or !std.mem.eql(u8, chosen.?, "fable")) {
        std.debug.print(
            \\
            \\a plan-mode launch went out on the session model:
            \\  planModel: "fable"
            \\  --model:   {s}
            \\  cost:      the whole point of the setting is silently lost — planning runs on
            \\             whatever the terminal happened to start with, and nothing says so
            \\
        , .{chosen orelse "(absent)"});
        return error.PlanModelMissing;
    }

    if (!std.mem.eql(u8, planning[planning.len - 2], "--")) {
        std.debug.print(
            \\
            \\the model landed past the separator:
            \\  argv tail: "{s}" "{s}"
            \\  cost:      everything after -- is the prompt, so claude reads --model as text
            \\             and starts on the default model with a mangled opening message
            \\
        , .{ planning[planning.len - 2], planning[planning.len - 1] });
        return error.PlanModelAfterSeparator;
    }

    const carried = try start.launchArgs(gpa, null, "/start-task PE-250", false, "fable");
    defer gpa.free(carried);
    if (argAfter(carried, "--model")) |leaked| {
        std.debug.print(
            \\
            \\a session started from an existing plan took the planning model:
            \\  --model: {s}
            \\  cost:    --plan exists so the pipeline runs spec onward here — the model meant
            \\           for one plan ends up paying for code, review and test as well
            \\
        , .{leaked});
        return error.PlanModelLeaked;
    }

    const unset = try start.launchArgs(gpa, null, null, true, "");
    defer gpa.free(unset);
    if (argAfter(unset, "--model")) |empty| {
        std.debug.print(
            \\
            \\an unset planModel still reached the command line:
            \\  --model: "{s}"
            \\  cost:    claude is handed an empty model name and refuses to start, so the
            \\           default config stops working at all
            \\
        , .{empty});
        return error.PlanModelEmpty;
    }
}

test "a plan-mode session gets its own opening prompt, and a carried plan never does" {
    const planning = "/plan {identifier}";
    const pipeline = "/lwp:start-task {identifier} {plan}";

    const opens_planning = start.openingTemplate(planning, pipeline, true);
    if (!std.mem.eql(u8, opens_planning, planning)) {
        std.debug.print(
            \\
            \\a plan-mode session opened on the pipeline prompt:
            \\  chose: "{s}"
            \\  cost:  the pipeline runs spec onward in the session that was only meant to
            \\         plan, so the planning model pays for the whole task after all
            \\
        , .{opens_planning});
        return error.PlanPromptIgnored;
    }

    const carried = start.openingTemplate(planning, pipeline, false);
    if (!std.mem.eql(u8, carried, pipeline)) {
        std.debug.print(
            \\
            \\a session started from an existing plan opened on the planning prompt:
            \\  chose: "{s}"
            \\  cost:  {{plan}} is only in the pipeline template, so the approved plan is
            \\         dropped and the second session re-plans what was just approved
            \\
        , .{carried});
        return error.CarriedPlanPromptLost;
    }

    const unset = start.openingTemplate("", pipeline, true);
    if (!std.mem.eql(u8, unset, pipeline)) {
        std.debug.print(
            \\
            \\an unset planTaskCommand changed what a plan-mode session opens with:
            \\  chose: "{s}"
            \\  cost:  every existing config silently stops sending its opening prompt
            \\
        , .{unset});
        return error.PlanPromptRegressed;
    }
}

test "the hand-back is composed only when there is a model to hand back to" {
    const gpa = std.testing.allocator;
    const command = "/lwp:start-task PE-250";

    const full = try start.postPlanInput(gpa, "opus[1m]", command);
    defer if (full) |v| gpa.free(v);
    if (full == null or !std.mem.eql(u8, full.?, "/model opus[1m]\r" ++ command ++ "\r")) {
        std.debug.print(
            \\
            \\the post-plan hand-back came out wrong:
            \\  got:  "{s}"
            \\  cost: the session stays on the planning model for spec onward, which is the
            \\        one thing this whole path exists to prevent
            \\
        , .{full orelse "(null)"});
        return error.HandbackMiscomposed;
    }

    const off = try start.postPlanInput(gpa, "", command);
    defer if (off) |v| gpa.free(v);
    if (off != null) {
        std.debug.print(
            \\
            \\an unset postPlanModel still produced input to inject:
            \\  got:  "{s}"
            \\  cost: every session that never asked for this starts typing into itself
            \\
        , .{off.?});
        return error.HandbackNotOptIn;
    }

    const bare = try start.postPlanInput(gpa, "opus[1m]", "");
    defer if (bare) |v| gpa.free(v);
    if (bare == null or !std.mem.eql(u8, bare.?, "/model opus[1m]\r")) {
        std.debug.print(
            \\
            \\an empty opening command did not reduce to the model switch alone:
            \\  got:  "{s}"
            \\  cost: a bare carriage return is submitted to the agent as an empty turn
            \\
        , .{bare orelse "(null)"});
        return error.HandbackTrailingReturn;
    }
}
