const std = @import("std");
const Io = std.Io;

pub const Event = enum {
    waiting,
    active,
    idle,
    ended,

    pub fn parse(text: []const u8) ?Event {
        return std.meta.stringToEnum(Event, text);
    }
};

const Command = struct {
    type: []const u8 = "command",
    command: []const u8,
    timeout: u32 = 5,
    async: bool = true,
};

const Entry = struct {
    matcher: []const u8 = "",
    hooks: []const Command,
};

const Events = struct {
    Notification: []const Entry,
    SubagentStart: []const Entry,
    UserPromptSubmit: []const Entry,
    PreToolUse: []const Entry,
    Stop: []const Entry,
    SessionEnd: []const Entry,
};

const Settings = struct { hooks: Events };

pub const blocking_matchers = [_][]const u8{
    "permission_prompt",
    "elicitation_dialog",
    "agent_needs_input",
};

fn command(
    gpa: std.mem.Allocator,
    exe: []const u8,
    socket: []const u8,
    session: []const u8,
    event: Event,
) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s} watch-hook --socket {s} --session {s} --event {s}", .{
        exe, socket, session, @tagName(event),
    });
}

pub fn settingsJson(
    gpa: std.mem.Allocator,
    exe: []const u8,
    socket: []const u8,
    session: []const u8,
) ![]u8 {
    const waiting = try command(gpa, exe, socket, session, .waiting);
    const active = try command(gpa, exe, socket, session, .active);
    const idle = try command(gpa, exe, socket, session, .idle);
    const ended = try command(gpa, exe, socket, session, .ended);

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

pub const Payload = struct {
    cwd: []const u8 = "",
    session_id: []const u8 = "",
    hook_event_name: []const u8 = "",
    transcript_path: []const u8 = "",
    permission_mode: []const u8 = "",
};

pub const plan_mode = "plan";

pub fn isPlan(permission_mode: []const u8) bool {
    return std.mem.eql(u8, permission_mode, plan_mode);
}

pub fn parsePayload(gpa: std.mem.Allocator, raw: []const u8) ?Payload {
    return std.json.parseFromSliceLeaky(Payload, gpa, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

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

    const body = try settingsJson(arena, "/opt/homebrew/bin/lcc", "/home/me/.config/lcc/daemon.sock", "s-00000007");

    const Schema = struct {
        hooks: struct {
            Notification: []struct {
                matcher: []const u8,
                hooks: []struct { type: []const u8, command: []const u8, timeout: u32, async: bool },
            },
            SubagentStart: []struct {
                matcher: []const u8,
                hooks: []struct { type: []const u8, command: []const u8, timeout: u32, async: bool },
            },
            UserPromptSubmit: []struct {
                matcher: []const u8,
                hooks: []struct { type: []const u8, command: []const u8, timeout: u32, async: bool },
            },
            PreToolUse: []struct {
                matcher: []const u8,
                hooks: []struct { type: []const u8, command: []const u8, timeout: u32, async: bool },
            },
            Stop: []struct {
                matcher: []const u8,
                hooks: []struct { type: []const u8, command: []const u8, timeout: u32, async: bool },
            },
            SessionEnd: []struct {
                matcher: []const u8,
                hooks: []struct { type: []const u8, command: []const u8, timeout: u32, async: bool },
            },
        },
    };
    const parsed = try std.json.parseFromSliceLeaky(Schema, arena, body, .{});

    try testing.expectEqual(blocking_matchers.len, parsed.hooks.Notification.len);
    for (parsed.hooks.Notification, blocking_matchers) |entry, matcher| {
        try testing.expectEqualStrings(matcher, entry.matcher);
        try testing.expect(std.mem.endsWith(u8, entry.hooks[0].command, "--event waiting"));
    }
    try testing.expectEqual(@as(usize, 1), parsed.hooks.SubagentStart.len);
    try testing.expectEqualStrings("", parsed.hooks.SubagentStart[0].matcher);
    try testing.expect(std.mem.endsWith(u8, parsed.hooks.SubagentStart[0].hooks[0].command, "--event active"));

    try testing.expect(std.mem.endsWith(u8, parsed.hooks.Stop[0].hooks[0].command, "--event idle"));
    try testing.expect(std.mem.endsWith(u8, parsed.hooks.UserPromptSubmit[0].hooks[0].command, "--event active"));
    try testing.expect(std.mem.endsWith(u8, parsed.hooks.PreToolUse[0].hooks[0].command, "--event active"));
    try testing.expect(std.mem.endsWith(u8, parsed.hooks.SessionEnd[0].hooks[0].command, "--event ended"));

    try testing.expect(std.mem.indexOf(u8, body, "\"matcher\": null") == null);
    try testing.expectEqualStrings("", parsed.hooks.Stop[0].matcher);

    try testing.expect(parsed.hooks.Stop[0].hooks[0].async);
    try testing.expect(parsed.hooks.Stop[0].hooks[0].timeout <= 10);
    try testing.expectEqualStrings("command", parsed.hooks.Stop[0].hooks[0].type);

    try testing.expect(std.mem.startsWith(u8, parsed.hooks.Stop[0].hooks[0].command, "/opt/homebrew/bin/lcc "));
    try testing.expect(std.mem.indexOf(u8, parsed.hooks.Stop[0].hooks[0].command, "--socket /home/me/.config/lcc/daemon.sock") != null);
}

test "idle_prompt is not a blocking matcher" {
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

    const raw =
        \\{"session_id":"669f68ae","transcript_path":"/h/.claude/projects/x/t.jsonl",
        \\ "cwd":"/r/.lcc/worktrees/pe-256","prompt_id":"551136fb",
        \\ "permission_mode":"plan","effort":{"level":"xhigh"},
        \\ "hook_event_name":"PreToolUse","tool_name":"Bash",
        \\ "tool_input":{"command":"echo hi","description":"Print hi"},
        \\ "tool_use_id":"toolu_016wh833eFmoMGNzHJyvZ3Ay"}
    ;
    const payload = parsePayload(arena, raw).?;
    try testing.expectEqualStrings("/r/.lcc/worktrees/pe-256", payload.cwd);
    try testing.expectEqualStrings("669f68ae", payload.session_id);
    try testing.expectEqualStrings("PreToolUse", payload.hook_event_name);

    try testing.expectEqualStrings("plan", payload.permission_mode);
    try testing.expect(isPlan(payload.permission_mode));

    try testing.expect(parsePayload(arena, "not json at all") == null);
    try testing.expect(parsePayload(arena, "") == null);

    const sparse = parsePayload(arena, "{}").?;
    try testing.expectEqualStrings("", sparse.cwd);
    try testing.expectEqualStrings("", sparse.permission_mode);
    try testing.expect(!isPlan(sparse.permission_mode));
}

test "the events that report no mode really report none" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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
    for ([_][]const u8{ "default", "acceptEdits", "bypassPermissions", "dontAsk", "auto" }) |mode| {
        try testing.expect(!isPlan(mode));
    }
    try testing.expect(!isPlan("Plan"));
    try testing.expect(!isPlan(""));
}

test "plan mode needs no hook of its own" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try settingsJson(arena, "/opt/homebrew/bin/lcc", "/s.sock", "s-00000001");
    try testing.expect(std.mem.indexOf(u8, body, "permission_mode") == null);
    try testing.expect(std.mem.indexOf(u8, body, "--event plan") == null);
    inline for (@typeInfo(Events).@"struct".fields) |field| {
        try testing.expect(std.mem.indexOf(u8, body, "\"" ++ field.name ++ "\"") != null);
    }
}

test "event names round-trip through the command line" {
    for ([_]Event{ .waiting, .active, .idle, .ended }) |event| {
        try testing.expectEqual(event, Event.parse(@tagName(event)).?);
    }
    try testing.expect(Event.parse("nonsense") == null);
}
