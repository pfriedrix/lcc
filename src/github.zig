//! Pull-request state for the dashboard, read through the `gh` CLI.
//!
//! `gh` is treated as optional: it may be absent, unauthenticated, or pointed at
//! a repo with no remote. Any of those yields an empty list rather than an error —
//! one missing column must never fail `lcc list`.
//!
//! Asked branch by branch rather than as "every pull request in this repo". The
//! flat listing is one request only until a repo passes a hundred PRs, after
//! which GitHub pages and `gh` pays a second round trip — and it was already
//! answering with two hundred rows to fill six cells. One aliased connection per
//! branch is a single request whose size tracks the worktrees on screen instead
//! of the repo's history, and it stops silently missing the branch whose PR is
//! older than the last two hundred.

const std = @import("std");
const Io = std.Io;
const exec = @import("exec.zig");

/// Pull requests fetched per branch, newest first. A branch has one, occasionally
/// a second after a botched first attempt; ten is headroom, and `forBranch`
/// decides which of them the column shows.
const per_branch = 10;

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

/// One aliased `pullRequests` connection per branch, so the whole column is one
/// request. The keys are positional (`b0`, `b1`, …) and never read back: each node
/// carries its own `headRefName`, which is what `forBranch` matches on.
const Alias = struct {
    nodes: []const RawPr = &.{},
};

const Envelope = struct {
    data: ?struct {
        /// Null when the repo could not be resolved — a remote `gh` cannot see.
        repository: ?std.json.ArrayHashMap(Alias) = null,
    } = null,
    errors: ?[]const struct { message: []const u8 = "" } = null,
};

/// The pull requests of `branches`, whatever state they are in. Null — not an
/// empty slice — when `gh` could not answer at all, so a branch with no pull
/// request is not reported as a missing or unauthenticated `gh`.
///
/// The filter is `headRefName` on the connection rather than a lookup of the ref
/// itself, and that distinction is the whole reason this can replace asking for
/// every pull request in the repo: a merged PR outlives the branch it came from,
/// so `ref(qualifiedName:)` goes null the moment the remote branch is deleted
/// while the connection still answers.
pub fn forBranches(
    gpa: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    branches: []const []const u8,
) ?[]const PullRequest {
    // Nothing to ask about is not a failure: a repo whose worktrees are all
    // detached has no branch to match a pull request against, and no round trip
    // would turn that into an answer.
    if (branches.len == 0) return &.{};

    const query = buildQuery(gpa, branches) catch return null;
    const query_field = std.fmt.allocPrint(gpa, "query={s}", .{query}) catch return null;
    const raw = exec.capture(gpa, io, &.{
        "gh", "api", "graphql",
        // `-F` substitutes gh's `:owner`/`:repo` placeholders for the current
        // repo's; `-f` does not. The query itself has to go through `-f`, so gh
        // does not try to read it as a typed value.
        "-F", "owner=:owner",
        "-F", "name=:repo",
        "-f", query_field,
    }, repo_root) catch return null;

    const envelope = std.json.parseFromSliceLeaky(Envelope, gpa, raw, .{
        .ignore_unknown_fields = true,
        // `std.json.ArrayHashMap` has nowhere to put its keys without this.
        .allocate = .alloc_always,
    }) catch return null;

    if (envelope.errors) |errs| {
        if (errs.len > 0) return null;
    }
    const data = envelope.data orelse return null;
    const repository = data.repository orelse return null;

    var out: std.ArrayList(PullRequest) = .empty;
    for (repository.map.values()) |alias| {
        for (alias.nodes) |pr| {
            out.append(gpa, .{
                .number = pr.number,
                .branch = pr.headRefName,
                .state = parseState(pr.state),
                .draft = pr.isDraft,
            }) catch return null;
        }
    }
    return out.toOwnedSlice(gpa) catch null;
}

fn buildQuery(gpa: std.mem.Allocator, branches: []const []const u8) ![]const u8 {
    var q: std.ArrayList(u8) = .empty;
    try q.appendSlice(gpa, "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){");
    for (branches, 0..) |branch, i| {
        // A GraphQL string literal is a JSON string, and a git branch name may
        // legally contain a quote — so let the JSON encoder produce the literal
        // rather than wrapping it in quotes and hoping.
        const literal = try std.json.Stringify.valueAlloc(gpa, branch, .{});
        try q.appendSlice(gpa, try std.fmt.allocPrint(
            gpa,
            "b{d}:pullRequests(headRefName:{s},first:{d},orderBy:{{field:CREATED_AT,direction:DESC}})" ++
                "{{nodes{{number state isDraft headRefName}}}}",
            .{ i, literal, per_branch },
        ));
    }
    try q.appendSlice(gpa, "}}");
    return q.toOwnedSlice(gpa);
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

test "buildQuery aliases one connection per branch and quotes them as JSON" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const q = try buildQuery(arena, &.{ "feature/a", "release/2.4.1" });

    // One alias per branch, numbered positionally, and both branch names present
    // as GraphQL string literals.
    try std.testing.expect(std.mem.indexOf(u8, q, "b0:pullRequests(headRefName:\"feature/a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "b1:pullRequests(headRefName:\"release/2.4.1\"") != null);
    // Every node carries the ref, which is what `forBranch` matches on — the alias
    // names are never read back.
    try std.testing.expect(std.mem.indexOf(u8, q, "headRefName }") != null or
        std.mem.indexOf(u8, q, "state isDraft headRefName") != null);
    try std.testing.expect(std.mem.endsWith(u8, q, "}}"));

    // A quote is legal in a git branch name and must not end the literal early.
    const nasty = try buildQuery(arena, &.{"feature/say-\"hi\""});
    try std.testing.expect(std.mem.indexOf(u8, nasty, "\\\"hi\\\"") != null);
}

test "forBranches asks nothing when there is no branch to ask about" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An empty result, not null: a repo of detached worktrees has no head ref to
    // match, which is an answer rather than a failure to reach `gh`.
    const out = forBranches(arena, std.testing.io, ".", &.{});
    try std.testing.expect(out != null);
    try std.testing.expectEqual(@as(usize, 0), out.?.len);
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
