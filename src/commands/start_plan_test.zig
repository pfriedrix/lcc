//! Test home for `lcc start`'s plan channel — the rules deciding whether a `--plan`
//! path can reach the agent at all.
//!
//! `start.zig` keeps its tests in-source, next to what they cover. This file exists
//! because the plan-channel tests are authored by an agent that may not touch a
//! production file, and Zig collects tests only from files the test root imports
//! (`main.zig`'s `test` block says so). An out-of-file home is the only shape those
//! two rules leave, so the seam it needs is `pub`.

const std = @import("std");
const linear = @import("../linear.zig");
const start = @import("start.zig");

/// The issue every plan-channel case expands a template against. Nothing here is ever
/// what a case is about — only the template is — so it is fixed once rather than
/// restated per case.
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
