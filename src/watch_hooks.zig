//! How a session tells lcc what it is doing — Claude Code's own hooks, not a
//! reading of its screen.
//!
//! The first design here scraped the pty: strip ANSI, match a spinner glyph and
//! "esc to interrupt", guess. That needed a pattern table, fixtures pinned to a
//! release, and a drift detector to notice when a new Claude Code silently
//! invalidated all of it. None of it is necessary. Claude Code reports its own
//! state through hooks, exactly and by contract:
//!
//!   Notification/permission_prompt → blocked on a decision   → waiting
//!   Notification/agent_needs_input → blocked on a decision   → waiting
//!   UserPromptSubmit, PreToolUse   → a turn is in flight     → active
//!   SubagentStart                  → so is work it handed
//!                                    to a subagent           → active
//!   Stop                           → the turn finished       → idle
//!   SessionEnd                     → the session is over     → exited
//!
//! **The matcher does the discrimination, not lcc.** Each entry hard-codes the
//! state it means into its own command line, so nothing here has to parse a
//! notification's payload to work out which kind it was. A field lcc never
//! reads is a field that cannot be renamed out from under it.
//!
//! `permission_mode` is the one exception, and it is one because Claude Code
//! offers no way to make it the rule: matchers select on a notification's type
//! and on tool names, never on the mode, so plan mode cannot be baked into a
//! command line the way every other state above is. It is read out of the
//! payload instead — from `PreToolUse`, `UserPromptSubmit` and `Stop`, the
//! three of these events that carry it.
//!
//! What keeps that from becoming the fragility the rule exists to avoid: an
//! absent or empty value is a **no-op**, never a clear. A renamed or dropped
//! field freezes the last mode reported rather than silently deciding every
//! session has left plan mode, and a value this build has never heard of reads
//! as "not plan" — the direction `Session.parsedStatus` already fails in.
//!
//! Installed through `claude --settings <file>`, which loads *additional*
//! settings and merges hook entries rather than replacing them. So lcc writes
//! nothing to `~/.claude/settings.json`, nothing into the repo, and the hooks
//! exist only for sessions lcc launched.

const std = @import("std");
const Io = std.Io;

/// What a hook reports. Deliberately smaller than the set of hook events: these
/// are the transitions a dashboard can act on, and nothing else is worth a
/// process spawn on every turn.
pub const Event = enum {
    /// Blocked on a human decision. The one that means "go here now".
    waiting,
    /// A turn is in flight.
    active,
    /// The turn finished. Not blocked — come back whenever.
    idle,
    /// The session ended on its own.
    ended,

    pub fn parse(text: []const u8) ?Event {
        return std.meta.stringToEnum(Event, text);
    }
};

/// `type` and `async` are Claude Code's field names, not ours.
const Command = struct {
    type: []const u8 = "command",
    command: []const u8,
    /// Seconds. Short on purpose: a wedged handler must not become a wedged
    /// session, and everything this does is one connect and one write.
    timeout: u32 = 5,
    /// Never block a turn on lcc's bookkeeping. A status that arrives late is
    /// a cosmetic problem; a turn that waits for it is not.
    @"async": bool = true,
};

const Entry = struct {
    /// Empty string, never null, for "every notification of this event".
    ///
    /// Measured, not assumed: a `"matcher": null` parses as valid JSON and is
    /// accepted without complaint, and then the whole entry is silently
    /// dropped — Claude Code registers no hook and reports no error. An empty
    /// string registers. Nothing in lcc's own schema test could catch that,
    /// because the schema was lcc's.
    matcher: []const u8 = "",
    hooks: []const Command,
};

const Events = struct {
    Notification: []const Entry,
    /// Claude Code fires this for every agent a workflow or a `Task` spawns,
    /// and its matcher is the agent type — so an empty one is all of them.
    ///
    /// It is here because of what a session looks like without it. The main
    /// agent hands work to subagents and its own turn ends, so `Stop` fires and
    /// the row reads `idle` — "finished, come back whenever" — while a dynamic
    /// workflow grinds away underneath it for twenty minutes. The one thing the
    /// dashboard exists to answer is "where is the work", and `idle` was the
    /// wrong answer to it.
    ///
    /// `active`, not `waiting`, and the distinction is the whole point of the
    /// colour. `waiting` has to keep meaning "a person is blocking this one";
    /// a session whose subagents are busy is blocking on nobody, and painting
    /// it the same yellow would put two states that call for opposite
    /// responses under one signal. The same reasoning keeps `idle_prompt` out
    /// of `blocking_matchers` below.
    SubagentStart: []const Entry,
    UserPromptSubmit: []const Entry,
    PreToolUse: []const Entry,
    Stop: []const Entry,
    SessionEnd: []const Entry,
};

const Settings = struct { hooks: Events };

/// The notification matchers that mean a human is actually blocking the
/// session, as opposed to being merely informed.
///
/// `idle_prompt` is deliberately absent: it is a nudge after a quiet spell, not
/// a question, and mapping it to `waiting` would light up every finished
/// session as if it needed attention — which is exactly the signal this feature
/// exists to make trustworthy.
pub const blocking_matchers = [_][]const u8{
    "permission_prompt",
    "elicitation_dialog",
    "agent_needs_input",
};

fn command(gpa: std.mem.Allocator, exe: []const u8, socket: []const u8, event: Event) ![]const u8 {
    // Absolute paths on both: a hook runs with the session's environment, and
    // the daemon may have been started from a shell whose PATH no longer
    // resembles this one.
    return std.fmt.allocPrint(gpa, "{s} watch-hook --socket {s} --event {s}", .{
        exe, socket, @tagName(event),
    });
}

/// The settings file handed to `claude --settings`.
///
/// `exe` must be the resolved binary, never `argv[0]`: `lcc` on PATH is a
/// symlink into `zig-out/bin`, and a hook that re-resolved it would run
/// whichever build the symlink happens to point at rather than the one that
/// started the daemon.
pub fn settingsJson(
    gpa: std.mem.Allocator,
    exe: []const u8,
    socket: []const u8,
) ![]u8 {
    const waiting = try command(gpa, exe, socket, .waiting);
    const active = try command(gpa, exe, socket, .active);
    const idle = try command(gpa, exe, socket, .idle);
    const ended = try command(gpa, exe, socket, .ended);

    var blocking: std.ArrayList(Entry) = .empty;
    for (blocking_matchers) |matcher| {
        try blocking.append(gpa, .{
            .matcher = matcher,
            .hooks = try gpa.dupe(Command, &.{.{ .command = waiting }}),
        });
    }

    return std.json.Stringify.valueAlloc(gpa, Settings{ .hooks = .{
        .Notification = blocking.items,
        .SubagentStart = &.{.{ .hooks = &.{.{ .command = active }} }},
        .UserPromptSubmit = &.{.{ .hooks = &.{.{ .command = active }} }},
        .PreToolUse = &.{.{ .hooks = &.{.{ .command = active }} }},
        .Stop = &.{.{ .hooks = &.{.{ .command = idle }} }},
        .SessionEnd = &.{.{ .hooks = &.{.{ .command = ended }} }},
    } }, .{ .whitespace = .indent_2 });
}

/// The fields lcc reads out of the JSON a hook receives on stdin.
///
/// `cwd` is the whole point: it is the worktree, which is the key the daemon
/// already has a session under. Everything else is defaulted, so a Claude Code
/// that adds or drops a field cannot turn a status update into a failure.
pub const Payload = struct {
    cwd: []const u8 = "",
    session_id: []const u8 = "",
    hook_event_name: []const u8 = "",
    transcript_path: []const u8 = "",
    /// Claude Code's own permission mode. Empty on the events that do not carry
    /// it — `Notification`, `SubagentStart`, `SessionEnd` — which is why the
    /// daemon holds the last one rather than re-deriving it per event.
    permission_mode: []const u8 = "",
};

/// The one mode lcc distinguishes.
///
/// The others (`default`, `acceptEdits`, `bypassPermissions`, `dontAsk`,
/// `auto`) all present as the lifecycle status. Plan mode is worth a row of its
/// own because it ends: `lcc start` launches in it and approving the plan
/// leaves it, so the marker appearing and going away is the signal. A badge
/// that every session wore for its whole life would not be.
pub const plan_mode = "plan";

/// Whether a reported mode means the session is still planning.
pub fn isPlan(permission_mode: []const u8) bool {
    return std.mem.eql(u8, permission_mode, plan_mode);
}

pub fn parsePayload(gpa: std.mem.Allocator, raw: []const u8) ?Payload {
    return std.json.parseFromSliceLeaky(Payload, gpa, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

/// What the handler sends on to the daemon.
pub const Report = struct {
    cwd: []const u8,
    session_id: []const u8,
    event: []const u8,
    permission_mode: []const u8 = "",
};

const testing = std.testing;

test "the settings name every event and bake the state into each command" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try settingsJson(arena, "/opt/homebrew/bin/lcc", "/home/me/.config/lcc/daemon.sock");

    // Declared independently, and unknown fields rejected, so a rename here
    // fails in this test rather than as a session that silently never reports.
    const Schema = struct {
        hooks: struct {
            Notification: []struct {
                matcher: []const u8,
                hooks: []struct { type: []const u8, command: []const u8, timeout: u32, @"async": bool },
            },
            SubagentStart: []struct {
                matcher: []const u8,
                hooks: []struct { type: []const u8, command: []const u8, timeout: u32, @"async": bool },
            },
            UserPromptSubmit: []struct {
                matcher: []const u8,
                hooks: []struct { type: []const u8, command: []const u8, timeout: u32, @"async": bool },
            },
            PreToolUse: []struct {
                matcher: []const u8,
                hooks: []struct { type: []const u8, command: []const u8, timeout: u32, @"async": bool },
            },
            Stop: []struct {
                matcher: []const u8,
                hooks: []struct { type: []const u8, command: []const u8, timeout: u32, @"async": bool },
            },
            SessionEnd: []struct {
                matcher: []const u8,
                hooks: []struct { type: []const u8, command: []const u8, timeout: u32, @"async": bool },
            },
        },
    };
    const parsed = try std.json.parseFromSliceLeaky(Schema, arena, body, .{});

    // One entry per blocking matcher, each carrying `--event waiting`.
    try testing.expectEqual(blocking_matchers.len, parsed.hooks.Notification.len);
    for (parsed.hooks.Notification, blocking_matchers) |entry, matcher| {
        try testing.expectEqualStrings(matcher, entry.matcher);
        try testing.expect(std.mem.endsWith(u8, entry.hooks[0].command, "--event waiting"));
    }
    // A subagent starting is the session working, so `active` — never
    // `waiting`, which has to go on meaning that a person is blocking it. An
    // empty matcher, so it counts for every agent type rather than for
    // whichever ones were named the day this was written.
    try testing.expectEqual(@as(usize, 1), parsed.hooks.SubagentStart.len);
    try testing.expectEqualStrings("", parsed.hooks.SubagentStart[0].matcher);
    try testing.expect(std.mem.endsWith(u8, parsed.hooks.SubagentStart[0].hooks[0].command, "--event active"));

    try testing.expect(std.mem.endsWith(u8, parsed.hooks.Stop[0].hooks[0].command, "--event idle"));
    try testing.expect(std.mem.endsWith(u8, parsed.hooks.UserPromptSubmit[0].hooks[0].command, "--event active"));
    try testing.expect(std.mem.endsWith(u8, parsed.hooks.PreToolUse[0].hooks[0].command, "--event active"));
    try testing.expect(std.mem.endsWith(u8, parsed.hooks.SessionEnd[0].hooks[0].command, "--event ended"));

    // An unmatched entry carries an empty matcher, not null: null is accepted
    // as JSON and then silently registers nothing. Asserted on the wire rather
    // than trusted from the struct, since the struct is what got it wrong.
    try testing.expect(std.mem.indexOf(u8, body, "\"matcher\": null") == null);
    try testing.expectEqualStrings("", parsed.hooks.Stop[0].matcher);

    // Never block a turn, and never wait long. A hook that stalls a session is
    // worse than a status that never arrives.
    try testing.expect(parsed.hooks.Stop[0].hooks[0].@"async");
    try testing.expect(parsed.hooks.Stop[0].hooks[0].timeout <= 10);
    try testing.expectEqualStrings("command", parsed.hooks.Stop[0].hooks[0].type);

    // The resolved binary, not a bare name a PATH lookup could resolve
    // differently inside a session.
    try testing.expect(std.mem.startsWith(u8, parsed.hooks.Stop[0].hooks[0].command, "/opt/homebrew/bin/lcc "));
    try testing.expect(std.mem.indexOf(u8, parsed.hooks.Stop[0].hooks[0].command, "--socket /home/me/.config/lcc/daemon.sock") != null);
}

test "idle_prompt is not a blocking matcher" {
    // The distinction the whole dashboard rests on. `waiting` has to mean "this
    // one needs you now"; if a quiet-spell nudge produced it, every finished
    // session would claim attention and the colour would stop meaning anything.
    for (blocking_matchers) |matcher| {
        try testing.expect(!std.mem.eql(u8, matcher, "idle_prompt"));
    }
    try testing.expectEqual(@as(usize, 3), blocking_matchers.len);
}

test "a hook payload yields the worktree, and a broken one yields nothing" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Captured verbatim from Claude Code 2.1.223, only the paths shortened.
    // Written out rather than reduced to the four fields lcc reads, because
    // what this has to prove is that the *real* shape parses — including
    // `effort` and `tool_input`, which are nested objects rather than the
    // scalar unknowns a hand-written fixture would have contained.
    const raw =
        \\{"session_id":"669f68ae","transcript_path":"/h/.claude/projects/x/t.jsonl",
        \\ "cwd":"/r/.lcc/worktrees/pe-256","prompt_id":"551136fb",
        \\ "permission_mode":"plan","effort":{"level":"xhigh"},
        \\ "hook_event_name":"PreToolUse","tool_name":"Bash",
        \\ "tool_input":{"command":"echo hi","description":"Print hi"},
        \\ "tool_use_id":"toolu_016wh833eFmoMGNzHJyvZ3Ay"}
    ;
    const payload = parsePayload(arena, raw).?;
    // cwd is the worktree, which is the key the daemon already files sessions
    // under — no correlation table, no session-id mapping to keep in sync.
    try testing.expectEqualStrings("/r/.lcc/worktrees/pe-256", payload.cwd);
    try testing.expectEqualStrings("669f68ae", payload.session_id);
    try testing.expectEqualStrings("PreToolUse", payload.hook_event_name);

    // The one field read out of the payload rather than baked into a matcher,
    // because Claude Code offers no matcher that selects on it. See the header.
    try testing.expectEqualStrings("plan", payload.permission_mode);
    try testing.expect(isPlan(payload.permission_mode));

    // Malformed input is a dropped update, never a crash in a hook that runs on
    // every turn of every session.
    try testing.expect(parsePayload(arena, "not json at all") == null);
    try testing.expect(parsePayload(arena, "") == null);

    // A payload missing everything still parses: every field is defaulted, so a
    // Claude Code that drops a key costs one update rather than all of them.
    const sparse = parsePayload(arena, "{}").?;
    try testing.expectEqualStrings("", sparse.cwd);
    // And an absent mode reads as absent, not as "left plan mode". The daemon
    // holds the last one it was told; a renamed field must cost the update
    // rather than silently clearing every session's plan marker.
    try testing.expectEqualStrings("", sparse.permission_mode);
    try testing.expect(!isPlan(sparse.permission_mode));
}

test "the events that report no mode really report none" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Half the events lcc registers carry no `permission_mode` — measured, and
    // the reason `watch_session.Session` holds the last one rather than reading
    // it per event. This payload is a `Notification`, which is *also* the one
    // event whose absent mode would do the most damage if read as a clear: it
    // fires on the permission prompt at the end of a plan, so a session would
    // drop its plan marker at the exact moment the marker was earned.
    const raw =
        \\{"session_id":"abc123","transcript_path":"/h/.claude/projects/x/t.jsonl",
        \\ "cwd":"/r/.lcc/worktrees/pe-256","hook_event_name":"Notification",
        \\ "notification_type":"permission_prompt",
        \\ "message":"Claude needs your permission"}
    ;
    const payload = parsePayload(arena, raw).?;
    try testing.expectEqualStrings("/r/.lcc/worktrees/pe-256", payload.cwd);
    try testing.expectEqualStrings("", payload.permission_mode);
}

test "plan is the only mode lcc distinguishes" {
    try testing.expect(isPlan("plan"));
    // The other five Claude Code reports all mean the same thing to a row: the
    // lifecycle status, unchanged. Plan mode earns a marker because it *ends* —
    // one that every session wore for its whole life would say nothing.
    for ([_][]const u8{ "default", "acceptEdits", "bypassPermissions", "dontAsk", "auto" }) |mode| {
        try testing.expect(!isPlan(mode));
    }
    // Case matters, and a near miss is not a match: reading `Plan` as plan mode
    // would be a guess, and guessing is what the hook design exists to avoid.
    try testing.expect(!isPlan("Plan"));
    try testing.expect(!isPlan(""));
}

test "plan mode needs no hook of its own" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The mode rides on events lcc already registers, so the settings file is
    // byte-for-byte what it was. Pinned because the obvious "fix" for a future
    // bug here is to add a hook — and there is no hook event that reports a
    // mode change, so one would fire on something else and mean nothing.
    const body = try settingsJson(arena, "/opt/homebrew/bin/lcc", "/s.sock");
    try testing.expect(std.mem.indexOf(u8, body, "permission_mode") == null);
    try testing.expect(std.mem.indexOf(u8, body, "--event plan") == null);
    inline for (@typeInfo(Events).@"struct".fields) |field| {
        try testing.expect(std.mem.indexOf(u8, body, "\"" ++ field.name ++ "\"") != null);
    }
}

test "event names round-trip through the command line" {
    // The handler receives `--event <name>` and has to map it back. A rename on
    // one side only would leave every hook reporting nothing.
    for ([_]Event{ .waiting, .active, .idle, .ended }) |event| {
        try testing.expectEqual(event, Event.parse(@tagName(event)).?);
    }
    try testing.expect(Event.parse("nonsense") == null);
}
