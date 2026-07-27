//! Pull-request state for the dashboard, read through the `gh` CLI.
//!
//! `gh` is treated as optional: it may be absent, unauthenticated, or pointed at
//! a repo with no remote. Any of those yields an empty list rather than an error —
//! one missing column must never fail `lcc list`.

const std = @import("std");
const Io = std.Io;
const exec = @import("exec.zig");

pub const State = enum {
    open,
    merged,
    closed,

    /// Lower sorts first: an open PR is the one worth showing when a branch has
    /// several, and a merged one beats an abandoned one.
    fn rank(self: State) u8 {
        return switch (self) {
            .open => 0,
            .merged => 1,
            .closed => 2,
        };
    }
};

pub const PullRequest = struct {
    number: u32,
    branch: []const u8,
    state: State,
    draft: bool,

    /// `#412 open`, `#412 draft`, `#398 merged`.
    pub fn describe(self: PullRequest, gpa: std.mem.Allocator) []const u8 {
        const label = if (self.draft and self.state == .open) "draft" else @tagName(self.state);
        return std.fmt.allocPrint(gpa, "#{d} {s}", .{ self.number, label }) catch label;
    }
};

const RawPr = struct {
    number: u32,
    headRefName: []const u8,
    state: []const u8,
    isDraft: bool = false,
};

/// Every pull request in the repo, open or not. Null — not an empty slice — when
/// `gh` could not answer at all, so a repo with no PRs is not reported as a
/// missing or unauthenticated `gh`.
pub fn list(gpa: std.mem.Allocator, io: Io, repo_root: []const u8) ?[]const PullRequest {
    const raw = exec.capture(gpa, io, &.{
        "gh",      "pr",   "list",
        "--state", "all",
        "--json",  "number,headRefName,state,isDraft",
        "--limit", "200",
    }, repo_root) catch return null;

    const parsed = std.json.parseFromSliceLeaky([]RawPr, gpa, raw, .{
        .ignore_unknown_fields = true,
    }) catch return null;

    const out = gpa.alloc(PullRequest, parsed.len) catch return null;
    for (parsed, 0..) |pr, i| {
        out[i] = .{
            .number = pr.number,
            .branch = pr.headRefName,
            .state = parseState(pr.state),
            .draft = pr.isDraft,
        };
    }
    return out;
}

fn parseState(raw: []const u8) State {
    if (std.ascii.eqlIgnoreCase(raw, "MERGED")) return .merged;
    if (std.ascii.eqlIgnoreCase(raw, "CLOSED")) return .closed;
    return .open;
}

/// The pull request worth showing for `branch`: open beats merged beats closed,
/// and the highest number wins within a state (the most recent attempt).
pub fn forBranch(prs: []const PullRequest, branch: []const u8) ?PullRequest {
    var best: ?PullRequest = null;
    for (prs) |pr| {
        if (!std.mem.eql(u8, pr.branch, branch)) continue;
        const current = best orelse {
            best = pr;
            continue;
        };
        if (pr.state.rank() < current.state.rank() or
            (pr.state.rank() == current.state.rank() and pr.number > current.number))
        {
            best = pr;
        }
    }
    return best;
}

test "forBranch prefers open, then merged, then the newest attempt" {
    const prs = [_]PullRequest{
        .{ .number = 10, .branch = "feature/x", .state = .closed, .draft = false },
        .{ .number = 11, .branch = "feature/x", .state = .merged, .draft = false },
        .{ .number = 12, .branch = "feature/y", .state = .open, .draft = false },
        .{ .number = 13, .branch = "feature/x", .state = .open, .draft = true },
    };

    try std.testing.expectEqual(@as(u32, 13), forBranch(&prs, "feature/x").?.number);
    try std.testing.expectEqual(@as(u32, 12), forBranch(&prs, "feature/y").?.number);
    try std.testing.expect(forBranch(&prs, "feature/z") == null);

    const closed_only = [_]PullRequest{
        .{ .number = 1, .branch = "b", .state = .closed, .draft = false },
        .{ .number = 4, .branch = "b", .state = .closed, .draft = false },
    };
    try std.testing.expectEqual(@as(u32, 4), forBranch(&closed_only, "b").?.number);
}

test "describe labels a draft distinctly from an open PR" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const open: PullRequest = .{ .number = 412, .branch = "b", .state = .open, .draft = false };
    const draft: PullRequest = .{ .number = 413, .branch = "b", .state = .open, .draft = true };
    const merged: PullRequest = .{ .number = 398, .branch = "b", .state = .merged, .draft = true };

    try std.testing.expectEqualStrings("#412 open", open.describe(arena));
    try std.testing.expectEqualStrings("#413 draft", draft.describe(arena));
    // gh keeps isDraft set on a PR that was merged out of draft; state wins.
    try std.testing.expectEqualStrings("#398 merged", merged.describe(arena));
}

test "parseState maps gh's uppercase names" {
    try std.testing.expectEqual(State.merged, parseState("MERGED"));
    try std.testing.expectEqual(State.closed, parseState("CLOSED"));
    try std.testing.expectEqual(State.open, parseState("OPEN"));
    // Anything unrecognised reads as open — the state that shows the most detail.
    try std.testing.expectEqual(State.open, parseState("SOMETHING_NEW"));
}
