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

pub const Project = struct {
    id: []const u8,
    name: []const u8,
};

/// Everything a detail read asks for, for the one issue a caller named.
///
/// A type of its own rather than more fields on `Issue`: `active_issues_query` and
/// `issue_statuses_query` do not select a project, labels or a description, so a
/// null on `Issue` would mean "not asked for" in one place and "there is none" in
/// another — one field carrying two answers.
pub const Detail = struct {
    issue: Issue,
    /// The current state's own id, so a caller that goes on to write already knows
    /// whether the write would be a no-op. Empty when the response carried no
    /// state at all, which no id can equal — so a comparison against it decides to
    /// write rather than to skip.
    state_id: []const u8,
    /// The UUID every mutation that names a team needs. Linear refuses the human
    /// key `PE` there, and reading the id off the issue is what keeps the key from
    /// having a path into one.
    team_id: ?[]const u8,
    project: ?Project,
    labels: []const []const u8,
    description: ?[]const u8,
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

/// One read: serialise, post, unwrap. Every caller below did those three lines by
/// hand, which is three places each to get a variable name wrong and find out from
/// a 400 against a live workspace.
///
/// `emit_null_optional_fields` stays at its default here, unlike on a write: in a
/// *filter* a null variable means "do not filter", which is what `$after: null` on
/// the first page of `fetchAllRaw` relies on.
fn query(
    comptime T: type,
    gpa: std.mem.Allocator,
    io: Io,
    token: oauth.Token,
    text: []const u8,
    variables: anytype,
) Error!T {
    return unwrap(T, gpa, try post(gpa, io, token, try queryBody(gpa, text, variables)));
}

/// The request bytes for a read. Split from `query` so the shape `variables` takes
/// is settled by a test rather than by a live workspace refusing it.
fn queryBody(gpa: std.mem.Allocator, text: []const u8, variables: anytype) Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{
        .query = text,
        .variables = variables,
    }, .{}) catch Error.HttpFailed;
}

/// Every Linear mutation payload is `{ success, <the thing it touched> }`, and
/// every mutation names that thing differently. Aliasing the payload to `payload`
/// and the thing to `entity` in the mutation text is what lets one Zig shape read
/// all of them — the trick `github.zig` uses to alias one connection per branch.
fn Mutation(comptime T: type) type {
    return struct {
        payload: struct {
            success: bool,
            entity: ?T = null,
        },
    };
}

/// One write. Three things separate this from `query`, and each of them is a
/// silent failure the hand-rolled version would have to remember not to make:
///
///  * `emit_null_optional_fields` is off. Linear reads `"projectId": null` in a
///    mutation input as *clear the project*, so an optional left at its default
///    erases a field nobody named.
///  * `success` is checked. A refused write arrives as `success: false` *inside*
///    `data` with no `errors[]` beside it, which `unwrap` passes straight through:
///    an unchecked mutation is a no-op that reports itself as a write.
///  * The aliases are required at compile time, so a mutation written without them
///    fails the build instead of failing to parse against a live workspace.
fn mutate(
    comptime T: type,
    gpa: std.mem.Allocator,
    io: Io,
    token: oauth.Token,
    comptime text: []const u8,
    variables: anytype,
) Error!T {
    comptime {
        if (std.mem.indexOf(u8, text, "payload:") == null or
            std.mem.indexOf(u8, text, "entity:") == null)
        {
            @compileError("a mutation must alias its payload to `payload` and its " ++
                "result to `entity`, so `Mutation` can read it — see `mutate`");
        }
    }
    return readMutation(T, gpa, try post(gpa, io, token, try mutationBody(gpa, text, variables)));
}

/// The request bytes for a write. Split from `mutate` so the null-dropping rule is
/// settled by a test rather than by a field being quietly erased in Linear.
fn mutationBody(gpa: std.mem.Allocator, text: []const u8, variables: anytype) Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{
        .query = text,
        .variables = variables,
    }, .{ .emit_null_optional_fields = false }) catch Error.HttpFailed;
}

/// What a write's response means, decided from the bytes alone — so the two
/// answers that carry no `errors[]` to give them away are testable without a
/// network.
fn readMutation(comptime T: type, gpa: std.mem.Allocator, raw: []const u8) Error!T {
    const data = try unwrap(Mutation(T), gpa, raw);
    if (!data.payload.success) {
        last_message = "Linear declined the write (success: false)";
        return Error.GraphQLFailed;
    }
    return data.payload.entity orelse {
        last_message = "Linear reported success but returned nothing";
        return Error.GraphQLFailed;
    };
}

/// Variables for a query that takes none.
///
/// An empty *struct*, and deliberately not the `.{}` that reads naturally in its
/// place: `.{}` is an empty tuple, `Stringify` writes a tuple as a JSON array, and
/// Linear answers `variables in a POST body must be an object if provided`.
const NoVariables = struct {};

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

    const data = try query(OneIssueData, gpa, io, token, issue_query, .{
        .number = ref.number,
        .team = team,
    });
    if (data.issues.nodes.len == 0) return null;
    return fromRaw(data.issues.nodes[0]);
}

/// Everything one issue carries, for a caller that named it. Same filter as
/// `issue_query`, and for the same reason — number plus team key is unique and lets
/// Linear answer from the team's own index — with the longer field list a detail
/// view reads. `$labels` is a variable rather than a round number because the cost
/// note on `issue_statuses_query` applies to sub-connections too.
const issue_detail_query =
    \\query LccIssueDetail($number: Float!, $team: String!, $labels: Int!) {
    \\  issues(
    \\    filter: { number: { eq: $number }, team: { key: { eq: $team } } }
    \\    first: 1
    \\  ) {
    \\    nodes {
    \\      id
    \\      identifier
    \\      title
    \\      description
    \\      branchName
    \\      priority
    \\      url
    \\      updatedAt
    \\      state { id name type }
    \\      assignee { name }
    \\      team { id key }
    \\      project { id name }
    \\      labels(first: $labels) { nodes { name parent { name } } }
    \\    }
    \\  }
    \\}
;

/// The taxonomy this is read for is three label groups plus an optional `area/*`.
/// Twenty is headroom over that, not a guess at a page size.
const max_labels = 20;

const DetailState = struct { id: []const u8, name: []const u8, type: []const u8 };
const DetailTeam = struct { id: []const u8, key: []const u8 };
/// A grouped label answers `name` with its leaf alone — `bug`, not `type/bug` —
/// and names its group through `parent`. Both halves are needed: the group is what
/// tells `type/bug` from an `area/bug`, and a caller dispatching on `type/` has
/// nothing to match without it.
const RawLabel = struct {
    name: []const u8,
    parent: ?Named = null,
};

const LabelConnection = struct { nodes: []RawLabel };

/// The detail query's own wire shape. Separate from `RawIssue` because the two
/// select different fields, and a shared type would have to make every one of them
/// optional to say so.
const RawDetail = struct {
    id: []const u8,
    identifier: []const u8,
    title: []const u8,
    description: ?[]const u8 = null,
    branchName: []const u8,
    priority: i64,
    url: []const u8,
    updatedAt: []const u8,
    state: ?DetailState = null,
    assignee: ?Named = null,
    team: ?DetailTeam = null,
    project: ?Project = null,
    labels: ?LabelConnection = null,
};

const DetailData = struct { issues: struct { nodes: []RawDetail } };

/// A label the way it is written down and talked about — `type/bug` — rather than
/// the way Linear's API splits it. An ungrouped label is its own whole name.
fn labelName(gpa: std.mem.Allocator, label: RawLabel) ![]const u8 {
    const parent = label.parent orelse return label.name;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ parent.name, label.name });
}

/// The issue `PE-256` names, with the project, labels and description `fetchIssue`
/// does not pay for. Null when the team has no such number.
pub fn fetchIssueDetail(
    gpa: std.mem.Allocator,
    io: Io,
    token: oauth.Token,
    ref: Ref,
) Error!?Detail {
    // Linear stores team keys uppercase; `pe-256` on a command line is the same issue.
    const team = try std.ascii.allocUpperString(gpa, ref.team);

    const data = try query(DetailData, gpa, io, token, issue_detail_query, .{
        .number = ref.number,
        .team = team,
        .labels = max_labels,
    });
    if (data.issues.nodes.len == 0) return null;

    const node = data.issues.nodes[0];

    var labels: []const []const u8 = &.{};
    if (node.labels) |connection| {
        const out = try gpa.alloc([]const u8, connection.nodes.len);
        for (connection.nodes, 0..) |label, i| out[i] = try labelName(gpa, label);
        labels = out;
    }

    return .{
        .issue = .{
            .id = node.id,
            .identifier = node.identifier,
            .title = node.title,
            .branch_name = node.branchName,
            .state_name = if (node.state) |s| std.mem.trim(u8, s.name, " \t") else "Unknown",
            .state_type = if (node.state) |s| s.type else "unknown",
            .priority = node.priority,
            .url = node.url,
            .updated_at = node.updatedAt,
            .assignee_name = if (node.assignee) |a| a.name else null,
            .team_key = if (node.team) |t| t.key else null,
        },
        .state_id = if (node.state) |s| s.id else "",
        .team_id = if (node.team) |t| t.id else null,
        .project = node.project,
        .labels = labels,
        .description = node.description,
    };
}

/// The input is a GraphQL object literal naming exactly the fields being written,
/// with a variable for each value — not a serialised struct. A struct with a
/// second, optional field would put `"…": null` on the wire, and Linear reads that
/// as *clear it*. There is no field here that can carry a null, so there is
/// nothing to remember.
const add_comment_mutation =
    \\mutation LccAddComment($issue: String!, $body: String!) {
    \\  payload: commentCreate(input: { issueId: $issue, body: $body }) {
    \\    success
    \\    entity: comment { id url createdAt }
    \\  }
    \\}
;

pub const Comment = struct {
    id: []const u8,
    url: []const u8,
    created_at: []const u8,
};

const RawComment = struct {
    id: []const u8,
    url: []const u8,
    createdAt: []const u8,
};

/// A comment on an issue.
///
/// Not idempotent, and cannot be: calling it twice posts two comments. lcc has no
/// way to tell a retry from a second thought, and deduping on the body would
/// silently swallow a deliberate repeat.
pub fn addComment(
    gpa: std.mem.Allocator,
    io: Io,
    token: oauth.Token,
    issue_id: []const u8,
    body: []const u8,
) Error!Comment {
    const raw = try mutate(RawComment, gpa, io, token, add_comment_mutation, .{
        .issue = issue_id,
        .body = body,
    });
    return .{ .id = raw.id, .url = raw.url, .created_at = raw.createdAt };
}

pub const WorkflowState = struct {
    id: []const u8,
    name: []const u8,
    /// Linear's `statusType`: `backlog`, `unstarted`, `started`, `completed`,
    /// `canceled`. Reported, and used to *narrow* a match — never to make one.
    /// See `resolveState`.
    type: []const u8,
    /// Where the state sits on the board, so a list of them reads in the order a
    /// human sees rather than the order the API happened to answer in.
    position: f64,
};

/// The issue and every state its team offers, in one request. The two are
/// otherwise two round trips — the id to write to, then the ids that may be
/// written — and there is no moment between them where the answer changes.
const issue_state_context_query =
    \\query LccIssueStateContext($number: Float!, $team: String!, $states: Int!) {
    \\  issues(
    \\    filter: { number: { eq: $number }, team: { key: { eq: $team } } }
    \\    first: 1
    \\  ) {
    \\    nodes {
    \\      id
    \\      identifier
    \\      url
    \\      state { id name type position }
    \\      team {
    \\        id
    \\        key
    \\        states(first: $states) {
    \\          nodes { id name type position }
    \\          pageInfo { hasNextPage }
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

/// A team's workflow is five to eight states in practice and unusable past a
/// couple of dozen. Fifty is the ceiling that keeps a runaway workspace from
/// pricing this request like a full scan — and `hasNextPage` is what turns passing
/// it into something reported rather than silently answered as "no such state".
const max_team_states = 50;

const StateConnection = struct {
    nodes: []WorkflowState,
    pageInfo: PageInfo,
};

const ContextTeam = struct {
    id: []const u8,
    key: []const u8,
    states: ?StateConnection = null,
};

const RawStateContext = struct {
    id: []const u8,
    identifier: []const u8,
    url: []const u8,
    state: ?WorkflowState = null,
    team: ?ContextTeam = null,
};

const StateContextData = struct { issues: struct { nodes: []RawStateContext } };

pub const StateContext = struct {
    issue_id: []const u8,
    identifier: []const u8,
    url: []const u8,
    current: WorkflowState,
    team_key: []const u8,
    team_id: []const u8,
    /// In board order, so a message listing them reads the way the board does.
    states: []const WorkflowState,
    /// The team has more states than `max_team_states`. "No such state" is then a
    /// claim this cannot honestly make.
    truncated: bool,
};

/// Linear hands state names back with trailing whitespace often enough that
/// `fromRaw` has trimmed them since the first version. Doing it once here means
/// every name that leaves this module is already the one a human typed.
fn trimNames(states: []WorkflowState) void {
    for (states) |*state| state.name = std.mem.trim(u8, state.name, " \t");
}

/// Where a status type sits on a board, left to right. Linear's own column order,
/// and the missing half of sorting: `position` is assigned *within* a type, so
/// ordering on it alone interleaves the groups — a real PE board came back as
/// `… In Progress, Done, Canceled, Duplicate, In Review, In Build, In Production`.
fn typeRank(state_type: []const u8) u8 {
    const order = [_][]const u8{ "backlog", "unstarted", "started", "completed", "canceled" };
    for (order, 0..) |candidate, i| {
        if (fold.eql(candidate, state_type)) return @intCast(i);
    }
    // An unknown type sorts last rather than first: whatever it is, it is not one
    // of the five the workflow is built from.
    return order.len;
}

fn boardOrder(_: void, a: WorkflowState, b: WorkflowState) bool {
    const left = typeRank(a.type);
    const right = typeRank(b.type);
    if (left != right) return left < right;
    return a.position < b.position;
}

pub fn fetchStateContext(
    gpa: std.mem.Allocator,
    io: Io,
    token: oauth.Token,
    ref: Ref,
) Error!?StateContext {
    const team = try std.ascii.allocUpperString(gpa, ref.team);

    const data = try query(StateContextData, gpa, io, token, issue_state_context_query, .{
        .number = ref.number,
        .team = team,
        .states = max_team_states,
    });
    if (data.issues.nodes.len == 0) return null;

    const node = data.issues.nodes[0];
    const node_team = node.team orelse return Error.GraphQLFailed;
    const connection = node_team.states orelse return Error.GraphQLFailed;

    trimNames(connection.nodes);
    std.mem.sort(WorkflowState, connection.nodes, {}, boardOrder);

    var current = node.state orelse return Error.GraphQLFailed;
    current.name = std.mem.trim(u8, current.name, " \t");

    return .{
        .issue_id = node.id,
        .identifier = node.identifier,
        .url = node.url,
        .current = current,
        .team_key = node_team.key,
        .team_id = node_team.id,
        .states = connection.nodes,
        .truncated = connection.pageInfo.hasNextPage,
    };
}

pub const StateMatch = union(enum) {
    found: WorkflowState,
    /// No state on this team carries that name. The caller already holds the full
    /// list, so it can say what does exist rather than only what does not.
    unknown,
    /// Two states share the name — Linear permits it across groups. Naming one is
    /// then not an instruction, and guessing is how work lands in the wrong group.
    ambiguous: []const WorkflowState,
};

/// The state `wanted` names, matched on the name alone.
///
/// Nothing here searches on `type`, and that is the design rather than an
/// omission: matching on the type is what let `Canceled` resolve to `Duplicate`,
/// because a status type has as many holders as the board has columns in that
/// group. `want_type` filters an already-matching set and does nothing else — it
/// may narrow a name that matched, and it can never find one that did not.
pub fn resolveState(
    gpa: std.mem.Allocator,
    states: []const WorkflowState,
    wanted: []const u8,
    want_type: ?[]const u8,
) std.mem.Allocator.Error!StateMatch {
    const needle = std.mem.trim(u8, wanted, " \t");

    var hits: std.ArrayList(WorkflowState) = .empty;
    for (states) |state| {
        if (!fold.eql(std.mem.trim(u8, state.name, " \t"), needle)) continue;
        if (want_type) |wanted_type| {
            if (!fold.eql(std.mem.trim(u8, state.type, " \t"), wanted_type)) continue;
        }
        try hits.append(gpa, state);
    }

    return switch (hits.items.len) {
        0 => .unknown,
        1 => .{ .found = hits.items[0] },
        else => .{ .ambiguous = try hits.toOwnedSlice(gpa) },
    };
}

const set_state_mutation =
    \\mutation LccSetState($id: String!, $state: String!) {
    \\  payload: issueUpdate(id: $id, input: { stateId: $state }) {
    \\    success
    \\    entity: issue { id identifier state { id name type position } }
    \\  }
    \\}
;

pub const UpdatedIssue = struct {
    id: []const u8,
    identifier: []const u8,
    state: WorkflowState,
};

const RawUpdatedIssue = struct {
    id: []const u8,
    identifier: []const u8,
    state: ?WorkflowState = null,
};

/// Move an issue to a state, by the state's own id.
///
/// The mutation re-selects the state out of its own response rather than echoing
/// what was asked for, so the report says what Linear ended up with. That is the
/// "after a save, always check the status you got back" rule, enforced instead of
/// written down.
pub fn setIssueState(
    gpa: std.mem.Allocator,
    io: Io,
    token: oauth.Token,
    issue_id: []const u8,
    state_id: []const u8,
) Error!UpdatedIssue {
    const raw = try mutate(RawUpdatedIssue, gpa, io, token, set_state_mutation, .{
        .id = issue_id,
        .state = state_id,
    });
    var state = raw.state orelse return Error.GraphQLFailed;
    state.name = std.mem.trim(u8, state.name, " \t");
    return .{ .id = raw.id, .identifier = raw.identifier, .state = state };
}

/// The team's release projects, split into the ones still open and the ones
/// already shipped.
///
/// Reached through the **root** `projects` connection with an `accessibleTeams`
/// filter, deliberately not through `teams(filter:).projects`: that traversal came
/// back empty on a workspace whose issues are demonstrably in projects, while the
/// same projects list fine here and report `teams: [PE]` themselves.
///
/// Both halves are narrowed before they are capped, which is what makes a small
/// `first` defensible at all under the cost note above: `startsWith: "v"` and the
/// status filter mean the rows that *could* come back are release projects, not
/// the team's whole board.
const release_projects_query =
    \\query LccReleaseProjects($team: String!, $open: Int!, $done: Int!) {
    \\  open: projects(
    \\    filter: {
    \\      name: { startsWith: "v" }
    \\      accessibleTeams: { some: { key: { eq: $team } } }
    \\      status: { type: { nin: ["completed", "canceled"] } }
    \\    }
    \\    first: $open
    \\  ) { nodes { id name status { name type } } pageInfo { hasNextPage } }
    \\  done: projects(
    \\    filter: {
    \\      name: { startsWith: "v" }
    \\      accessibleTeams: { some: { key: { eq: $team } } }
    \\      status: { type: { eq: "completed" } }
    \\    }
    \\    first: $done
    \\  ) { nodes { id name status { name type } } }
    \\}
;

/// The open half has to be able to hold *every* unshipped release project, or
/// "the lowest open version" is not a provable answer — Linear cannot order a
/// project connection by name, so the window is the whole population or nothing.
/// Twenty unshipped releases at once is a board problem the resolver must not
/// paper over, and `hasNextPage` is what turns hitting this into something said
/// out loud rather than answered wrongly.
const max_open_projects = 20;

/// The shipped half is read for the *highest* version alone, and only as one of
/// three baselines the next-minor rule takes the maximum of — the other two being
/// git tags and live release branches, both exact. Ten survives releases completed
/// out of order.
const max_done_projects = 10;

pub const ReleaseProject = struct {
    id: []const u8,
    name: []const u8,
    /// `backlog`, `planned`, `started`, `paused`, `completed`, `canceled` — the
    /// status *type*, which is stable, rather than what the column is called.
    status_type: []const u8,
    /// What the column is called on this board, for a human line.
    status_name: []const u8,
};

pub const ReleaseProjects = struct {
    /// Everything neither completed nor cancelled, whatever its version.
    open: []const ReleaseProject,
    completed: []const ReleaseProject,
    /// The open window was full, so the lowest open version is not provable.
    truncated: bool,
};

const ProjectStatus = struct { name: []const u8, type: []const u8 };

const RawProject = struct {
    id: []const u8,
    name: []const u8,
    status: ?ProjectStatus = null,
};

const ProjectHalf = struct {
    nodes: []RawProject,
    pageInfo: ?PageInfo = null,
};

const ReleaseProjectsData = struct {
    open: ProjectHalf,
    done: ProjectHalf,
};

fn projectsFromRaw(gpa: std.mem.Allocator, nodes: []const RawProject) ![]ReleaseProject {
    const out = try gpa.alloc(ReleaseProject, nodes.len);
    for (nodes, 0..) |node, i| {
        out[i] = .{
            .id = node.id,
            .name = std.mem.trim(u8, node.name, " \t"),
            .status_type = if (node.status) |s| s.type else "unknown",
            .status_name = if (node.status) |s| s.name else "Unknown",
        };
    }
    return out;
}

pub fn fetchReleaseProjects(
    gpa: std.mem.Allocator,
    io: Io,
    token: oauth.Token,
    team_key: []const u8,
) Error!ReleaseProjects {
    const team = try std.ascii.allocUpperString(gpa, team_key);

    const data = try query(ReleaseProjectsData, gpa, io, token, release_projects_query, .{
        .team = team,
        .open = max_open_projects,
        .done = max_done_projects,
    });

    return .{
        .open = try projectsFromRaw(gpa, data.open.nodes),
        .completed = try projectsFromRaw(gpa, data.done.nodes),
        .truncated = if (data.open.pageInfo) |page| page.hasNextPage else false,
    };
}

const set_project_mutation =
    \\mutation LccSetProject($id: String!, $project: String!) {
    \\  payload: issueUpdate(id: $id, input: { projectId: $project }) {
    \\    success
    \\    entity: issue { id identifier project { id name } }
    \\  }
    \\}
;

const RawProjectAssignment = struct {
    id: []const u8,
    identifier: []const u8,
    project: ?Project = null,
};

/// Put an issue in a project, by the project's own id.
pub fn setIssueProject(
    gpa: std.mem.Allocator,
    io: Io,
    token: oauth.Token,
    issue_id: []const u8,
    project_id: []const u8,
) Error!Project {
    const raw = try mutate(RawProjectAssignment, gpa, io, token, set_project_mutation, .{
        .id = issue_id,
        .project = project_id,
    });
    return raw.project orelse Error.GraphQLFailed;
}

/// `teamIds` is where the UUID goes, and there is exactly one source for it: the
/// team read off the issue being assigned. No function here takes a team *key*, so
/// there is no path by which `PE` reaches an argument that wants a UUID — the
/// mistake is unreachable rather than documented.
///
/// The icon and the project lead are deliberately not set. `ProjectCreateInput`
/// does accept both, but on a mutation that only fires when a project is missing
/// they buy a wider request in exchange for decoration; the Linear UI is where a
/// release board gets dressed.
const create_project_mutation =
    \\mutation LccCreateProject($name: String!, $team: String!, $description: String!) {
    \\  payload: projectCreate(input: {
    \\    name: $name,
    \\    teamIds: [$team],
    \\    description: $description
    \\  }) {
    \\    success
    \\    entity: project { id name }
    \\  }
    \\}
;

pub fn createProject(
    gpa: std.mem.Allocator,
    io: Io,
    token: oauth.Token,
    name: []const u8,
    team_id: []const u8,
    description: []const u8,
) Error!Project {
    return mutate(Project, gpa, io, token, create_project_mutation, .{
        .name = name,
        .team = team_id,
        .description = description,
    });
}

fn fetchAllRaw(gpa: std.mem.Allocator, io: Io, token: oauth.Token) Error![]RawIssue {
    var collected: std.ArrayList(RawIssue) = .empty;
    var after: ?[]const u8 = null;

    var page: usize = 0;
    while (page < max_pages) : (page += 1) {
        const data = try query(Data, gpa, io, token, active_issues_query, .{ .after = after });

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
    const data = try query(struct { viewer: Me }, gpa, io, token, "query { viewer { name email } }", NoVariables{});
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

    const data = try query(StatusData, gpa, io, token, issue_statuses_query, .{
        .numbers = numbers.items,
        .teams = teams.items,
        .limit = limit,
    });

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

test "a read with no variables sends an object, because an array is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "query { viewer { name email } }";

    const body = try queryBody(arena, text, NoVariables{});
    try std.testing.expect(std.mem.indexOf(u8, body, "\"variables\":{}") != null);

    // The literal that reads naturally in `NoVariables{}`'s place, and is wrong:
    // `.{}` is an empty tuple, which `Stringify` writes as `[]`. Linear answers
    // that with `variables in a POST body must be an object if provided`, so the
    // difference is a 400 rather than something a type checker would catch.
    const tuple = try queryBody(arena, text, .{});
    try std.testing.expect(std.mem.indexOf(u8, tuple, "\"variables\":[]") != null);

    // A null variable still travels on a read, and has to: `$after: null` is how
    // `fetchAllRaw` asks for the first page. This is the half of the
    // `emit_null_optional_fields` question that a write answers the other way.
    const paged = try queryBody(arena, text, .{ .after = @as(?[]const u8, null) });
    try std.testing.expect(std.mem.indexOf(u8, paged, "\"after\":null") != null);
}

test "a write Linear declined is a failure, not a silent no-op" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Entity = struct { id: []const u8 };

    // No `errors[]` anywhere. `unwrap` alone hands this back as a success, and the
    // caller reports a change that never happened.
    const declined = "{\"data\":{\"payload\":{\"success\":false,\"entity\":null}}}";
    try std.testing.expectError(Error.GraphQLFailed, readMutation(Entity, arena, declined));
    try std.testing.expect(std.mem.indexOf(u8, last_message, "success: false") != null);

    // Success with nothing in it: the write may well have landed, but nothing came
    // back to report, and echoing the request as if it were the response is how a
    // report stops being evidence.
    const hollow = "{\"data\":{\"payload\":{\"success\":true,\"entity\":null}}}";
    try std.testing.expectError(Error.GraphQLFailed, readMutation(Entity, arena, hollow));

    const good = "{\"data\":{\"payload\":{\"success\":true,\"entity\":{\"id\":\"uuid-1\"}}}}";
    try std.testing.expectEqualStrings("uuid-1", (try readMutation(Entity, arena, good)).id);

    // Errors still win over `success`, and still carry their own message.
    const errored =
        \\{"data":null,"errors":[{"message":"Entity not found: Issue"}]}
    ;
    try std.testing.expectError(Error.GraphQLFailed, readMutation(Entity, arena, errored));
    try std.testing.expectEqualStrings("Entity not found: Issue", last_message);
}

test "a write drops the fields it was not asked to change, and escapes the ones it was" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "mutation { payload: x { success entity: y { id } } }";

    // The trap: at `Stringify`'s default, `.project = null` reaches Linear as
    // `"project": null`, which it reads as *clear the project* — an erasure nobody
    // asked for, from a request that only meant to set a state.
    const body = try mutationBody(arena, text, .{
        .id = "uuid-1",
        .state = "state-1",
        .project = @as(?[]const u8, null),
    });
    try std.testing.expect(std.mem.indexOf(u8, body, "\"state\":\"state-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "project") == null);

    // A plan comment is the most escape-hostile thing lcc will ever send: quotes, a
    // backslash and the newlines of a markdown document, all inside one GraphQL
    // string variable.
    const comment = try mutationBody(arena, text, .{ .body = "He said \"go\"\n- a\\b" });
    try std.testing.expect(std.mem.indexOf(u8, comment, "\\\"go\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, comment, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, comment, "a\\\\b") != null);
}

test "every mutation carries the aliases its reader needs and names its input fields" {
    for ([_][]const u8{
        add_comment_mutation,
        set_state_mutation,
        set_project_mutation,
        create_project_mutation,
    }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, text, "payload:") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "entity:") != null);
        // Inputs are object literals with one variable per field, so no optional
        // ever reaches the wire and the `null means clear it` trap has no carrier.
        try std.testing.expect(std.mem.indexOf(u8, text, "input: {") != null);
    }
    // Every `first` on a read is a variable or a literal 1 — never a round number,
    // because Linear prices a request on what it could return.
    try std.testing.expect(std.mem.indexOf(u8, issue_detail_query, "first: $labels") != null);
    try std.testing.expect(std.mem.indexOf(u8, issue_statuses_query, "first: $limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, issue_state_context_query, "first: $states") != null);
    try std.testing.expect(std.mem.indexOf(u8, release_projects_query, "first: $open") != null);
    try std.testing.expect(std.mem.indexOf(u8, release_projects_query, "first: $done") != null);

    // The state write re-reads the state out of its own response, so the report is
    // evidence rather than an echo of what was asked for.
    try std.testing.expect(std.mem.indexOf(u8, set_state_mutation, "state { id name type") != null);

    // Both halves of the project board are narrowed *before* they are capped —
    // without these two filters a small `first` would be a guess rather than a
    // ceiling, which is the cost mistake this whole convention exists to avoid.
    try std.testing.expect(std.mem.indexOf(u8, release_projects_query, "startsWith: \"v\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, release_projects_query, "accessibleTeams") != null);

    // `Project.state` does not exist — it is `status { name type }`. Asking for the
    // field the prose assumed would 400 the whole query.
    try std.testing.expect(std.mem.indexOf(u8, release_projects_query, "status { name type }") != null);

    // Creating a project takes the team's UUID and nothing else could reach it:
    // no function here accepts a team key, so `PE` has no path into `teamIds`.
    try std.testing.expect(std.mem.indexOf(u8, create_project_mutation, "teamIds: [$team]") != null);
}

test "states list in board order, which position alone does not give" {
    // Positions as a real PE board returned them: numbered within each status
    // type, so `In Review` at 0 sorts ahead of `In Progress` at 2 on position
    // alone, and `Done` at 0 lands in the middle of the started column.
    var board = [_]WorkflowState{
        .{ .id = "s-done", .name = "Done", .type = "completed", .position = 0 },
        .{ .id = "s-review", .name = "In Review", .type = "started", .position = 1 },
        .{ .id = "s-backlog", .name = "Backlog", .type = "backlog", .position = 0 },
        .{ .id = "s-progress", .name = "In Progress", .type = "started", .position = 0 },
        .{ .id = "s-canceled", .name = "Canceled", .type = "canceled", .position = 0 },
        .{ .id = "s-todo", .name = "Todo", .type = "unstarted", .position = 0 },
        .{ .id = "s-build", .name = "In Build", .type = "started", .position = 2 },
    };
    std.mem.sort(WorkflowState, &board, {}, boardOrder);

    const expected = [_][]const u8{
        "Backlog", "Todo", "In Progress", "In Review", "In Build", "Done", "Canceled",
    };
    for (expected, board) |want, got| try std.testing.expectEqualStrings(want, got.name);

    // A type nobody recognises sorts last rather than first — whatever it is, it
    // is not one of the five a workflow is built from.
    try std.testing.expect(typeRank("something-new") > typeRank("canceled"));
}

test "a state resolves on its name, so a shared status type cannot answer for it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A real PE board: two states share the `canceled` type, which is the whole
    // collision. Asking for `Canceled` must not be answerable by `Duplicate`.
    const board = [_]WorkflowState{
        .{ .id = "s-backlog", .name = "Backlog", .type = "backlog", .position = 0 },
        .{ .id = "s-progress", .name = "In Progress", .type = "started", .position = 1 },
        .{ .id = "s-canceled", .name = "Canceled", .type = "canceled", .position = 2 },
        .{ .id = "s-duplicate", .name = "Duplicate", .type = "canceled", .position = 3 },
    };

    try std.testing.expectEqualStrings(
        "s-canceled",
        (try resolveState(arena, &board, "Canceled", null)).found.id,
    );
    // Case and stray whitespace are how a name arrives from a command line.
    try std.testing.expectEqualStrings(
        "s-progress",
        (try resolveState(arena, &board, "  in progress ", null)).found.id,
    );
    // A type that matches nothing narrows the match to nothing. It may only
    // narrow: it can never reach a state the name did not already find.
    try std.testing.expectEqual(StateMatch.unknown, try resolveState(arena, &board, "Canceled", "completed"));
    try std.testing.expectEqual(StateMatch.unknown, try resolveState(arena, &board, "In Reviewing", null));
    // A status type is not a name. `started` is the type of `In Progress`, and
    // naming it reaches nothing — which is the half that stopped `Canceled` from
    // being answerable by `Duplicate`.
    try std.testing.expectEqual(StateMatch.unknown, try resolveState(arena, &board, "started", null));

    // A board that really does carry the same name twice: refuse, and hand back
    // both, because guessing is how work lands in the wrong group.
    const collided = [_]WorkflowState{
        .{ .id = "s-done-a", .name = "Done", .type = "completed", .position = 4 },
        .{ .id = "s-done-b", .name = "Done", .type = "canceled", .position = 5 },
    };
    const ambiguous = try resolveState(arena, &collided, "Done", null);
    try std.testing.expectEqual(@as(usize, 2), ambiguous.ambiguous.len);
    // …and `--type` is the escape that is deterministic, because `(name, type)` is
    // the pair that is unique. A picker would not be: it needs a human.
    try std.testing.expectEqualStrings(
        "s-done-a",
        (try resolveState(arena, &collided, "Done", "completed")).found.id,
    );
}

test "a grouped label is named with its group, because that is what callers match" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Linear answers `name` with the leaf alone, so a caller dispatching a pipeline
    // on `type/` sees `bug` and matches nothing. The group is not decoration.
    try std.testing.expectEqualStrings(
        "type/bug",
        try labelName(arena, .{ .name = "bug", .parent = .{ .name = "type" } }),
    );
    // An ungrouped label is already whole.
    try std.testing.expectEqualStrings(
        "needs-design",
        try labelName(arena, .{ .name = "needs-design", .parent = null }),
    );
}

test "unwrap reads a 200 that carries errors as a failure, in Linear's own words" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Viewer = struct { viewer: struct { name: []const u8 } };

    // GraphQL answers 200 and puts the refusal in the body, so the HTTP status
    // check in `post` waves this through. The message is the one Linear really
    // sends when a team key reaches an argument that wanted a UUID.
    const refused =
        \\{"data":null,"errors":[{"message":"Argument Validation Error - teamId must be a UUID"}]}
    ;
    try std.testing.expectError(Error.GraphQLFailed, unwrap(Viewer, arena, refused));
    try std.testing.expectEqualStrings(
        "Argument Validation Error - teamId must be a UUID",
        last_message,
    );

    // No data and nothing said about why.
    try std.testing.expectError(Error.GraphQLFailed, unwrap(Viewer, arena, "{\"data\":null}"));
    try std.testing.expectEqualStrings("Linear API returned no data", last_message);

    // An empty `errors` array is not an error. The `errs.len > 0` guard is what
    // says so, and this is what keeps it from being dropped as redundant.
    const empty_errors = "{\"data\":{\"viewer\":{\"name\":\"x\"}},\"errors\":[]}";
    try std.testing.expectEqualStrings("x", (try unwrap(Viewer, arena, empty_errors)).viewer.name);

    // A body that is not JSON at all — a proxy's error page rather than an API
    // response — comes back with its first bytes quoted, so the failure names
    // what actually arrived instead of only that parsing did not work.
    try std.testing.expectError(Error.GraphQLFailed, unwrap(Viewer, arena, "<html>502 Bad Gateway</html>"));
    try std.testing.expect(std.mem.indexOf(u8, last_message, "502") != null);
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
