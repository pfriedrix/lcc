const std = @import("std");
const Io = std.Io;
const exec = @import("exec.zig");

const per_branch = 10;

pub const State = enum {
    open,
    merged,
    closed,

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
    base: []const u8 = "",
    state: State,
    draft: bool,

    pub fn describe(self: PullRequest, gpa: std.mem.Allocator) []const u8 {
        const label = if (self.draft and self.state == .open) "draft" else @tagName(self.state);
        return std.fmt.allocPrint(gpa, "#{d} {s}", .{ self.number, label }) catch label;
    }
};

const RawPr = struct {
    number: u32,
    headRefName: []const u8,
    baseRefName: []const u8 = "",
    state: []const u8,
    isDraft: bool = false,
};

const Alias = struct {
    nodes: []const RawPr = &.{},
};

const Envelope = struct {
    data: ?struct {
        repository: ?std.json.ArrayHashMap(Alias) = null,
    } = null,
    errors: ?[]const struct { message: []const u8 = "" } = null,
};

pub fn forBranches(
    gpa: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    branches: []const []const u8,
) ?[]const PullRequest {
    if (branches.len == 0) return &.{};

    const query = buildQuery(gpa, branches) catch return null;
    const query_field = std.fmt.allocPrint(gpa, "query={s}", .{query}) catch return null;
    const raw = exec.capture(gpa, io, &.{
        "gh",         "api",          "graphql",
        "-F",         "owner=:owner", "-F",
        "name=:repo", "-f",           query_field,
    }, repo_root) catch return null;

    const envelope = std.json.parseFromSliceLeaky(Envelope, gpa, raw, .{
        .ignore_unknown_fields = true,
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
                .base = pr.baseRefName,
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
        const literal = try std.json.Stringify.valueAlloc(gpa, branch, .{});
        try q.appendSlice(gpa, try std.fmt.allocPrint(
            gpa,
            "b{d}:pullRequests(headRefName:{s},first:{d},orderBy:{{field:CREATED_AT,direction:DESC}})" ++
                "{{nodes{{number state isDraft headRefName baseRefName}}}}",
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

pub fn mergedFor(prs: []const PullRequest, branch: []const u8) ?u32 {
    const pr = forBranch(prs, branch) orelse return null;
    return if (pr.state == .merged) pr.number else null;
}

test "buildQuery aliases one connection per branch and quotes them as JSON" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const q = try buildQuery(arena, &.{ "feature/a", "release/2.4.1" });

    try std.testing.expect(std.mem.indexOf(u8, q, "b0:pullRequests(headRefName:\"feature/a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "b1:pullRequests(headRefName:\"release/2.4.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "headRefName }") != null or
        std.mem.indexOf(u8, q, "state isDraft headRefName") != null);
    try std.testing.expect(std.mem.endsWith(u8, q, "}}"));

    const nasty = try buildQuery(arena, &.{"feature/say-\"hi\""});
    try std.testing.expect(std.mem.indexOf(u8, nasty, "\\\"hi\\\"") != null);
}

test "forBranches asks nothing when there is no branch to ask about" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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

test "mergedFor answers only for a branch whose newest word is a merge" {
    const prs = [_]PullRequest{
        .{ .number = 398, .branch = "feature/shipped", .state = .merged, .draft = false },
        .{ .number = 400, .branch = "feature/abandoned", .state = .closed, .draft = false },
        .{ .number = 401, .branch = "feature/again", .state = .merged, .draft = false },
        .{ .number = 402, .branch = "feature/again", .state = .open, .draft = false },
    };

    try std.testing.expectEqual(@as(?u32, 398), mergedFor(&prs, "feature/shipped"));
    try std.testing.expectEqual(@as(?u32, null), mergedFor(&prs, "feature/abandoned"));
    try std.testing.expectEqual(@as(?u32, null), mergedFor(&prs, "feature/again"));
    try std.testing.expectEqual(@as(?u32, null), mergedFor(&prs, "feature/unknown"));
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
    try std.testing.expectEqualStrings("#398 merged", merged.describe(arena));
}

test "parseState maps gh's uppercase names" {
    try std.testing.expectEqual(State.merged, parseState("MERGED"));
    try std.testing.expectEqual(State.closed, parseState("CLOSED"));
    try std.testing.expectEqual(State.open, parseState("OPEN"));
    try std.testing.expectEqual(State.open, parseState("SOMETHING_NEW"));
}
