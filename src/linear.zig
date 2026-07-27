//! GraphQL against api.linear.app over std.http.Client, plus the state
//! filtering and ordering that `issues.ts` did on top of the SDK.

const std = @import("std");
const Io = std.Io;
const fold = @import("fold.zig");
const oauth = @import("oauth.zig");

pub const endpoint = "https://api.linear.app/graphql";

const active_issues_query =
    \\query LccIssues($after: String) {
    \\  issues(
    \\    filter: { state: { type: { nin: ["completed", "canceled"] } } }
    \\    first: 250
    \\    after: $after
    \\  ) {
    \\    nodes {
    \\      id
    \\      identifier
    \\      title
    \\      branchName
    \\      priority
    \\      url
    \\      updatedAt
    \\      state { name type }
    \\      assignee { name }
    \\      team { key }
    \\    }
    \\    pageInfo { hasNextPage endCursor }
    \\  }
    \\}
;

const State = struct { name: []const u8, type: []const u8 };
const Named = struct { name: []const u8 };
const Team = struct { key: []const u8 };

const RawIssue = struct {
    id: []const u8,
    identifier: []const u8,
    title: []const u8,
    branchName: []const u8,
    priority: i64,
    url: []const u8,
    updatedAt: []const u8,
    state: ?State = null,
    assignee: ?Named = null,
    team: ?Team = null,
};

const PageInfo = struct {
    hasNextPage: bool,
    endCursor: ?[]const u8 = null,
};

const IssueConnection = struct {
    nodes: []RawIssue,
    pageInfo: PageInfo,
};

const Data = struct { issues: IssueConnection };
const GraphQLError = struct { message: []const u8 };

const Envelope = struct {
    data: ?Data = null,
    errors: ?[]GraphQLError = null,
};

pub const Issue = struct {
    id: []const u8,
    identifier: []const u8,
    title: []const u8,
    branch_name: []const u8,
    state_name: []const u8,
    state_type: []const u8,
    priority: i64,
    url: []const u8,
    /// ISO 8601 as Linear returns it. Compared lexicographically, which is
    /// exact for a fixed-format UTC timestamp and avoids parsing dates.
    updated_at: []const u8,
    assignee_name: ?[]const u8,
    team_key: ?[]const u8,
};

pub const StateCount = struct {
    name: []const u8,
    count: u32,
};

pub const Error = error{
    HttpFailed,
    BadStatus,
    GraphQLFailed,
} || std.mem.Allocator.Error;

pub var last_status: u16 = 0;
pub var last_message: []const u8 = "";

const max_pages = 10; // 250 x 10 = 2500 issues; safety cap to avoid runaway loops

pub const FetchResult = struct {
    matched: []Issue,
    skipped: []StateCount,
    total: usize,
};

fn authHeader(gpa: std.mem.Allocator, token: oauth.Token) ![]u8 {
    // Personal API tokens go in raw, OAuth access tokens as a bearer — the two
    // modes the Linear SDK exposes as `apiKey` and `accessToken`.
    if (token.is_pat orelse false) return gpa.dupe(u8, token.access_token);
    return std.fmt.allocPrint(gpa, "Bearer {s}", .{token.access_token});
}

/// One GraphQL round trip. `body` is the already-serialised request; the raw
/// response body comes back, with `last_status`/`last_message` set either way.
fn post(gpa: std.mem.Allocator, io: Io, token: oauth.Token, body: []const u8) Error![]const u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const auth = try authHeader(gpa, token);
    var response: Io.Writer.Allocating = .init(gpa);

    const res = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = body,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth },
            .user_agent = .{ .override = "lcc/0.1.0" },
        },
        .response_writer = &response.writer,
    }) catch |err| {
        last_message = @errorName(err);
        return Error.HttpFailed;
    };

    const raw = response.written();
    last_status = @intFromEnum(res.status);
    if (last_status < 200 or last_status >= 300) {
        last_message = try gpa.dupe(u8, raw[0..@min(raw.len, 400)]);
        return Error.BadStatus;
    }
    return raw;
}

/// Parses a GraphQL envelope, turning both transport-level `errors` and a
/// missing `data` into `GraphQLFailed` with the message worth showing.
fn unwrap(comptime T: type, gpa: std.mem.Allocator, raw: []const u8) Error!T {
    const Wrapper = struct {
        data: ?T = null,
        errors: ?[]GraphQLError = null,
    };
    const envelope = std.json.parseFromSliceLeaky(Wrapper, gpa, raw, .{
        .ignore_unknown_fields = true,
    }) catch {
        last_message = try gpa.dupe(u8, raw[0..@min(raw.len, 400)]);
        return Error.GraphQLFailed;
    };
    if (envelope.errors) |errs| {
        if (errs.len > 0) {
            last_message = errs[0].message;
            return Error.GraphQLFailed;
        }
    }
    return envelope.data orelse {
        last_message = "Linear API returned no data";
        return Error.GraphQLFailed;
    };
}

fn fromRaw(issue: RawIssue) Issue {
    return .{
        .id = issue.id,
        .identifier = issue.identifier,
        .title = issue.title,
        .branch_name = issue.branchName,
        .state_name = if (issue.state) |s| std.mem.trim(u8, s.name, " \t") else "Unknown",
        .state_type = if (issue.state) |s| s.type else "unknown",
        .priority = issue.priority,
        .url = issue.url,
        .updated_at = issue.updatedAt,
        .assignee_name = if (issue.assignee) |a| a.name else null,
        .team_key = if (issue.team) |t| t.key else null,
    };
}

/// Everything `Issue` carries, for the one issue a caller named. Filtering on the
/// number and the team key both narrows it to a unique row and lets Linear answer
/// from the team's index — the cost note on `issue_statuses_query` applies here
/// too, which is why `first` is 1 rather than a round number.
const issue_query =
    \\query LccIssue($number: Float!, $team: String!) {
    \\  issues(
    \\    filter: { number: { eq: $number }, team: { key: { eq: $team } } }
    \\    first: 1
    \\  ) {
    \\    nodes {
    \\      id
    \\      identifier
    \\      title
    \\      branchName
    \\      priority
    \\      url
    \\      updatedAt
    \\      state { name type }
    \\      assignee { name }
    \\      team { key }
    \\    }
    \\  }
    \\}
;

const OneIssueData = struct { issues: struct { nodes: []RawIssue } };

/// The issue `PE-256` names. Neither the assignee nor the `activeStates` filter
/// applies: naming an issue outright is a more specific answer than either, so a
/// backlog issue or one assigned to somebody else still resolves. Null when the
/// team has no such number.
pub fn fetchIssue(
    gpa: std.mem.Allocator,
    io: Io,
    token: oauth.Token,
    ref: Ref,
) Error!?Issue {
    // Linear stores team keys uppercase; `pe-256` on a command line is the same issue.
    const team = try std.ascii.allocUpperString(gpa, ref.team);

    const body = std.json.Stringify.valueAlloc(gpa, .{
        .query = issue_query,
        .variables = .{ .number = ref.number, .team = team },
    }, .{}) catch return Error.HttpFailed;

    const raw = try post(gpa, io, token, body);
    const data = try unwrap(OneIssueData, gpa, raw);
    if (data.issues.nodes.len == 0) return null;
    return fromRaw(data.issues.nodes[0]);
}

fn fetchAllRaw(gpa: std.mem.Allocator, io: Io, token: oauth.Token) Error![]RawIssue {
    var collected: std.ArrayList(RawIssue) = .empty;
    var after: ?[]const u8 = null;

    var page: usize = 0;
    while (page < max_pages) : (page += 1) {
        const body = std.json.Stringify.valueAlloc(gpa, .{
            .query = active_issues_query,
            .variables = .{ .after = after },
        }, .{}) catch return Error.HttpFailed;

        const raw = try post(gpa, io, token, body);
        const data = try unwrap(Data, gpa, raw);

        try collected.appendSlice(gpa, data.issues.nodes);

        if (!data.issues.pageInfo.hasNextPage) break;
        after = data.issues.pageInfo.endCursor orelse break;
    }

    return collected.toOwnedSlice(gpa);
}

const SortContext = struct {
    order: []const []const u8,

    fn stateRank(self: SortContext, name: []const u8) usize {
        for (self.order, 0..) |candidate, i| {
            if (fold.eql(candidate, name)) return i;
        }
        return 99;
    }

    /// Preserve the order from `activeStates` (so Todo before In Progress, etc.),
    /// then most recently updated first within each state.
    fn lessThan(self: SortContext, a: Issue, b: Issue) bool {
        const ai = self.stateRank(a.state_name);
        const bi = self.stateRank(b.state_name);
        if (ai != bi) return ai < bi;
        return std.mem.order(u8, a.updated_at, b.updated_at) == .gt;
    }
};

pub fn fetchActiveIssues(
    gpa: std.mem.Allocator,
    io: Io,
    token: oauth.Token,
    active_states: []const []const u8,
    include_all: bool,
) Error!FetchResult {
    const raw = try fetchAllRaw(gpa, io, token);

    var matched: std.ArrayList(Issue) = .empty;
    var skipped: std.StringArrayHashMapUnmanaged(u32) = .empty;

    for (raw) |issue| {
        const state_name = if (issue.state) |s| std.mem.trim(u8, s.name, " \t") else "Unknown";

        var wanted = include_all;
        if (!wanted) {
            for (active_states) |candidate| {
                if (fold.eql(candidate, state_name)) {
                    wanted = true;
                    break;
                }
            }
        }
        if (!wanted) {
            const entry = try skipped.getOrPut(gpa, state_name);
            entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
            continue;
        }

        try matched.append(gpa, fromRaw(issue));
    }

    const issues = try matched.toOwnedSlice(gpa);
    std.mem.sort(Issue, issues, SortContext{ .order = active_states }, SortContext.lessThan);

    // Most-skipped state first, matching the TypeScript breakdown line.
    const counts = try gpa.alloc(StateCount, skipped.count());
    for (skipped.keys(), skipped.values(), 0..) |name, count, i| {
        counts[i] = .{ .name = name, .count = count };
    }
    std.mem.sort(StateCount, counts, {}, countDesc);

    return .{ .matched = issues, .skipped = counts, .total = raw.len };
}

fn countDesc(_: void, a: StateCount, b: StateCount) bool {
    return a.count > b.count;
}

pub const Me = struct {
    name: []const u8,
    email: []const u8,
};

/// `client.viewer` — used by `lcc auth` to confirm who the token belongs to.
pub fn viewer(gpa: std.mem.Allocator, io: Io, token: oauth.Token) Error!Me {
    const body = std.json.Stringify.valueAlloc(gpa, .{
        .query = "query { viewer { name email } }",
    }, .{}) catch return Error.HttpFailed;

    const raw = try post(gpa, io, token, body);
    const data = try unwrap(struct { viewer: Me }, gpa, raw);
    return data.viewer;
}

/// Both halves of the filter matter for speed as well as correctness: numbers are
/// only unique within a team, and filtering on the team key too lets Linear answer
/// from the team's own index instead of every issue the token can see.
///
/// `first` is a variable, and the field list is as short as the caller needs, because
/// Linear prices a request on how much it *could* return: asking for a fixed 100 rows
/// of every field made a five-branch lookup swing between a third of a second and a
/// minute.
const issue_statuses_query =
    \\query LccIssueStatuses($numbers: [Float!], $teams: [String!], $limit: Int) {
    \\  issues(
    \\    filter: { number: { in: $numbers }, team: { key: { in: $teams } } }
    \\    first: $limit
    \\  ) {
    \\    nodes {
    \\      identifier
    \\      state { name type }
    \\    }
    \\  }
    \\}
;

const RawStatus = struct {
    identifier: []const u8,
    state: ?State = null,
};

const StatusConnection = struct { nodes: []RawStatus };
const StatusData = struct { issues: StatusConnection };

pub const IssueStatus = struct {
    identifier: []const u8,
    state_name: []const u8,
    state_type: []const u8,
};

/// `PE-224` as it appears inside a branch name.
pub const Ref = struct {
    team: []const u8,
    number: u32,
};

/// Longest team key lcc will believe. Linear's own keys are a handful of letters;
/// the cap is what keeps `checkout-3` from being read as issue 3 of team CHECKOUT.
const max_team_key = 8;

/// The issue a branch belongs to, read out of names like `feature/pe-224-do-thing`.
/// Only the shape is checked here — whether `PE-224` is a real issue is settled by
/// matching the identifiers Linear returns, so a false positive costs nothing.
pub fn refFromBranch(branch: []const u8) ?Ref {
    var i: usize = 0;
    while (i < branch.len) {
        // The key has to start a word, so `feature/pe-224` matches and `2pe-3` does not.
        if (i > 0 and std.ascii.isAlphanumeric(branch[i - 1])) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < branch.len and std.ascii.isAlphabetic(branch[end])) end += 1;
        if (end > i and end - i <= max_team_key and end < branch.len and branch[end] == '-') {
            var digits = end + 1;
            while (digits < branch.len and std.ascii.isDigit(branch[digits])) digits += 1;
            if (digits > end + 1) {
                const number = std.fmt.parseInt(u32, branch[end + 1 .. digits], 10) catch {
                    i = digits;
                    continue;
                };
                return .{ .team = branch[i..end], .number = number };
            }
        }
        i = if (end > i) end + 1 else i + 1;
    }
    return null;
}

/// State and title for the issues a set of branches names, in one request.
/// Team keys and numbers are sent as independent sets, so the response can hold
/// issues no branch asked about — callers settle it with `statusForBranch`.
pub fn fetchIssueStatuses(
    gpa: std.mem.Allocator,
    io: Io,
    token: oauth.Token,
    refs: []const Ref,
) Error![]IssueStatus {
    if (refs.len == 0) return &.{};

    var numbers: std.ArrayList(u32) = .empty;
    var teams: std.ArrayList([]const u8) = .empty;
    for (refs) |ref| {
        for (numbers.items) |seen| {
            if (seen == ref.number) break;
        } else try numbers.append(gpa, ref.number);

        // Linear stores keys uppercase; branch names carry them lowercased.
        const key = try std.ascii.allocUpperString(gpa, ref.team);
        for (teams.items) |seen| {
            if (std.mem.eql(u8, seen, key)) break;
        } else try teams.append(gpa, key);
    }

    // A number can exist in every team asked about, so that product is the ceiling
    // on rows; anything more would be paying for rows that cannot come back.
    const limit = numbers.items.len * teams.items.len;

    const body = std.json.Stringify.valueAlloc(gpa, .{
        .query = issue_statuses_query,
        .variables = .{
            .numbers = numbers.items,
            .teams = teams.items,
            .limit = limit,
        },
    }, .{}) catch return Error.HttpFailed;

    const raw = try post(gpa, io, token, body);
    const data = try unwrap(StatusData, gpa, raw);

    const out = try gpa.alloc(IssueStatus, data.issues.nodes.len);
    for (data.issues.nodes, 0..) |node, i| {
        out[i] = .{
            .identifier = node.identifier,
            .state_name = if (node.state) |s| std.mem.trim(u8, s.name, " \t") else "Unknown",
            .state_type = if (node.state) |s| s.type else "unknown",
        };
    }
    return out;
}

/// Whether two branch names belong to the same issue. Linear derives `branchName`
/// from the title, so renaming an issue renames the branch it suggests — but the
/// work stays on the branch that was cut from the old name. The `PE-224` part is
/// the half that cannot drift.
///
/// A name with no issue ref in it never matches, not even another one like it:
/// `master` and `release/2.4.1` are not the same issue, they are no issue at all.
pub fn sameIssue(a: []const u8, b: []const u8) bool {
    const left = refFromBranch(a) orelse return false;
    const right = refFromBranch(b) orelse return false;
    return left.number == right.number and fold.eql(left.team, right.team);
}

/// The issue whose identifier matches `PE-224` for this branch, case-insensitively.
pub fn statusForBranch(statuses: []const IssueStatus, branch: []const u8) ?IssueStatus {
    const ref = refFromBranch(branch) orelse return null;
    for (statuses) |status| {
        const dash = std.mem.lastIndexOfScalar(u8, status.identifier, '-') orelse continue;
        if (!fold.eql(status.identifier[0..dash], ref.team)) continue;
        const number = std.fmt.parseInt(u32, status.identifier[dash + 1 ..], 10) catch continue;
        if (number == ref.number) return status;
    }
    return null;
}

test "refFromBranch finds the issue key wherever it sits" {
    const feature = refFromBranch("feature/pe-224-implement-history-empty-states").?;
    try std.testing.expectEqualStrings("pe", feature.team);
    try std.testing.expectEqual(@as(u32, 224), feature.number);

    const bare = refFromBranch("PE-42").?;
    try std.testing.expectEqualStrings("PE", bare.team);
    try std.testing.expectEqual(@as(u32, 42), bare.number);

    const nested = refFromBranch("pfriedrix/eng-7-thing").?;
    try std.testing.expectEqualStrings("eng", nested.team);
    try std.testing.expectEqual(@as(u32, 7), nested.number);

    // The key can sit after another dashed segment.
    const later = refFromBranch("feature/abc-pe-224-thing").?;
    try std.testing.expectEqualStrings("pe", later.team);
    try std.testing.expectEqual(@as(u32, 224), later.number);

    try std.testing.expect(refFromBranch("master") == null);
    try std.testing.expect(refFromBranch("release/2.4.1") == null);
    // The key has to start a word.
    try std.testing.expect(refFromBranch("2pe-3") == null);
    // And be short enough to be a team key, so ordinary words are not mistaken
    // for one: `typewriter-2` is a branch name, not issue 2 of team TYPEWRITER.
    try std.testing.expect(refFromBranch("typewriter-2") == null);
}

test "sameIssue survives a renamed issue and refuses branches with no issue" {
    // The case from a real repo: PE-250's title changed, so Linear suggests a new
    // branch name while the work sits on the one cut from the old title.
    try std.testing.expect(sameIssue(
        "feature/pe-250-fix-clvisit-handling-dedupe-arrivaldeparture-double-writes",
        "feature/pe-250-fix-clvisit-capture-dropped-visits-lost-headless-writes-no",
    ));
    // Case differs between Linear's key and the branch name.
    try std.testing.expect(sameIssue("feature/PE-250-a", "feature/pe-250-b"));

    try std.testing.expect(!sameIssue("feature/pe-250-a", "feature/pe-251-a"));
    // Same number, different team.
    try std.testing.expect(!sameIssue("feature/pe-250-a", "feature/eng-250-a"));
    // No ref at all is not an issue, so it matches nothing — including itself.
    try std.testing.expect(!sameIssue("master", "master"));
    try std.testing.expect(!sameIssue("release/2.4.1", "feature/pe-250-a"));
}

test "statusForBranch matches on team and number, not position" {
    const statuses = [_]IssueStatus{
        .{ .identifier = "ENG-224", .state_name = "Todo", .state_type = "unstarted" },
        .{ .identifier = "PE-224", .state_name = "In Review", .state_type = "started" },
    };

    const hit = statusForBranch(&statuses, "feature/pe-224-thing").?;
    try std.testing.expectEqualStrings("In Review", hit.state_name);

    try std.testing.expect(statusForBranch(&statuses, "feature/pe-999-thing") == null);
    try std.testing.expect(statusForBranch(&statuses, "master") == null);
}
