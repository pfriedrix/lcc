//! GraphQL against api.linear.app over std.http.Client, plus the state
//! filtering and ordering that `issues.ts` did on top of the SDK.

const std = @import("std");
const Io = std.Io;
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

fn fetchAllRaw(gpa: std.mem.Allocator, io: Io, token: oauth.Token) Error![]RawIssue {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const auth = try authHeader(gpa, token);

    var collected: std.ArrayList(RawIssue) = .empty;
    var after: ?[]const u8 = null;

    var page: usize = 0;
    while (page < max_pages) : (page += 1) {
        const body = std.json.Stringify.valueAlloc(gpa, .{
            .query = active_issues_query,
            .variables = .{ .after = after },
        }, .{}) catch return Error.HttpFailed;

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

        const envelope = std.json.parseFromSliceLeaky(Envelope, gpa, raw, .{
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
        const data = envelope.data orelse {
            last_message = "Linear API returned no data";
            return Error.GraphQLFailed;
        };

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
            if (std.ascii.eqlIgnoreCase(candidate, name)) return i;
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
                if (std.ascii.eqlIgnoreCase(candidate, state_name)) {
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

        try matched.append(gpa, .{
            .id = issue.id,
            .identifier = issue.identifier,
            .title = issue.title,
            .branch_name = issue.branchName,
            .state_name = state_name,
            .state_type = if (issue.state) |s| s.type else "unknown",
            .priority = issue.priority,
            .url = issue.url,
            .updated_at = issue.updatedAt,
            .assignee_name = if (issue.assignee) |a| a.name else null,
            .team_key = if (issue.team) |t| t.key else null,
        });
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

const Viewer = struct {
    data: ?struct {
        viewer: struct {
            name: []const u8,
            email: []const u8,
        },
    } = null,
};

pub const Me = struct {
    name: []const u8,
    email: []const u8,
};

/// `client.viewer` — used by `lcc auth` to confirm who the token belongs to.
pub fn viewer(gpa: std.mem.Allocator, io: Io, token: oauth.Token) Error!Me {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const auth = try authHeader(gpa, token);
    const body = std.json.Stringify.valueAlloc(gpa, .{
        .query = "query { viewer { name email } }",
    }, .{}) catch return Error.HttpFailed;

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

    const parsed = std.json.parseFromSliceLeaky(Viewer, gpa, raw, .{
        .ignore_unknown_fields = true,
    }) catch {
        last_message = try gpa.dupe(u8, raw[0..@min(raw.len, 400)]);
        return Error.GraphQLFailed;
    };
    const data = parsed.data orelse {
        last_message = try gpa.dupe(u8, raw[0..@min(raw.len, 400)]);
        return Error.GraphQLFailed;
    };
    return .{ .name = data.viewer.name, .email = data.viewer.email };
}
