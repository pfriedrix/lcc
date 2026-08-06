//! `lcc config` — read and write `~/.config/lcc/config.json` without a prompt.
//!
//! `lcc setup` already configures lcc, but it is interactive: it puts the
//! terminal in raw mode and fails outright with `NotATerminal` when there is no
//! tty. That makes it unreachable from a script, from a slash command, and from
//! a tool call — which is exactly where "turn watch off for this machine"
//! wants to be said. This is the same settings, named and one at a time.

const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const config = @import("../config.zig");
const ui = @import("../ui.zig");

pub const Opts = struct {
    key: ?[]const u8 = null,
    value: ?[]const u8 = null,
    json: bool = false,
};

pub const Error = error{ UnknownKey, BadValue } || std.mem.Allocator.Error;

/// What a key holds, which decides how it parses and how it prints.
const Kind = enum { text, boolean, list, choice };

const Key = struct {
    name: []const u8,
    kind: Kind,
    /// Shown by a bare `lcc config`, so the list is self-explaining rather than
    /// a set of names you have to look up elsewhere.
    doc: []const u8,
    /// For `.choice`, so a wrong value can be answered with the right ones
    /// instead of just "no".
    choices: []const []const u8 = &.{},
};

/// Every key `lcc config` will touch.
///
/// `clientId` is deliberately absent: it belongs to the OAuth setup and has its
/// own command (`lcc auth setup --client-id`), where the surrounding text can
/// say what it is for.
/// Deliberately absent: `--yes` and `--force`. A stored setting that
/// pre-approves a destructive operation removes the one confirmation standing
/// between a mistyped command and a deleted worktree, and it does so invisibly,
/// months after anyone typed it. `--json` is absent for a duller reason: it is
/// a property of one invocation, never a preference.
pub const keys = [_]Key{
    .{ .name = "watchByDefault", .kind = .boolean, .doc = "hand new sessions to the daemon instead of this terminal" },
    .{ .name = "statusBar", .kind = .boolean, .doc = "reserve the bottom row of an attached session for lcc" },
    .{ .name = "planMode", .kind = .boolean, .doc = "open new sessions in plan mode (--plan overrides regardless)" },
    .{ .name = "resumeSessions", .kind = .boolean, .doc = "`lcc open` resumes the last session rather than starting fresh" },
    .{ .name = "showTokens", .kind = .boolean, .doc = "the TOKENS column in `lcc list` — off skips reading transcripts" },
    .{
        .name = "listNetwork",
        .kind = .choice,
        .doc = "the PR and Linear columns in `lcc list`",
        .choices = &.{ "refresh", "cached", "local" },
    },
    .{ .name = "allIssues", .kind = .boolean, .doc = "offer every assigned issue, not just activeStates" },
    .{ .name = "keepBranch", .kind = .boolean, .doc = "`lcc remove` leaves the git branch in place" },
    .{ .name = "keepDerivedData", .kind = .boolean, .doc = "`lcc remove` leaves Xcode build data in place" },
    .{ .name = "keepXcode", .kind = .boolean, .doc = "`lcc remove` does not ask Xcode to close the worktree" },
    .{ .name = "worktreeTemplate", .kind = .text, .doc = "where worktrees are created" },
    .{ .name = "startTaskCommand", .kind = .text, .doc = "the prompt a new session opens with" },
    .{ .name = "activeStates", .kind = .list, .doc = "Linear states the picker offers" },
    .{ .name = "linkPatterns", .kind = .list, .doc = "files symlinked into every worktree" },
    .{ .name = "linkExclude", .kind = .list, .doc = "what linkPatterns must not match" },
    .{ .name = "mcpCarry", .kind = .list, .doc = "local MCP servers worth carrying (empty carries all)" },
};

fn find(name: []const u8) ?Key {
    for (keys) |key| {
        if (std.mem.eql(u8, key.name, name)) return key;
    }
    return null;
}

pub fn run(app: app_mod.App, opts: Opts) !void {
    const key_name = opts.key orelse return list(app, opts);

    const key = find(key_name) orelse {
        app.ui.fail("Unknown setting '{s}'. `lcc config` lists them.", .{key_name});
        std.process.exit(1);
    };

    if (opts.value) |raw| return set(app, opts, key, raw);
    return get(app, opts, key);
}

fn list(app: app_mod.App, opts: Opts) !void {
    const cfg = try config.load(app.gpa, app.io, app.environ);

    if (opts.json) {
        const body = try std.json.Stringify.valueAlloc(app.gpa, .{
            .watchByDefault = cfg.watchByDefault,
            .statusBar = cfg.statusBar,
            .planMode = cfg.planMode,
            .resumeSessions = cfg.resumeSessions,
            .showTokens = cfg.showTokens,
            .listNetwork = @tagName(cfg.listNetwork),
            .allIssues = cfg.allIssues,
            .keepBranch = cfg.keepBranch,
            .keepDerivedData = cfg.keepDerivedData,
            .keepXcode = cfg.keepXcode,
            .worktreeTemplate = cfg.worktreeTemplate,
            .startTaskCommand = cfg.startTaskCommand,
            .activeStates = cfg.activeStates,
            .linkPatterns = cfg.linkPatterns,
            .linkExclude = cfg.linkExclude,
            .mcpCarry = cfg.mcpCarry,
        }, .{ .whitespace = .indent_2 });
        app.ui.payload("{s}\n", .{body});
        app.ui.flush();
        return;
    }

    var width: usize = 0;
    for (keys) |key| width = @max(width, key.name.len);
    for (keys) |key| {
        app.ui.info("{f}  {s}", .{ ui.pad(key.name, width), try render(app, cfg, key) });
        if (key.kind == .choice) {
            app.ui.hint("{f}  {s} — one of: {s}", .{
                ui.pad("", width),
                key.doc,
                try std.mem.join(app.gpa, ", ", key.choices),
            });
        } else {
            app.ui.hint("{f}  {s}", .{ ui.pad("", width), key.doc });
        }
    }
    app.ui.info("", .{});
    app.ui.hint("Change one with: lcc config <setting> <value>", .{});
}

fn get(app: app_mod.App, opts: Opts, key: Key) !void {
    const cfg = try config.load(app.gpa, app.io, app.environ);
    const text = try render(app, cfg, key);
    if (opts.json) {
        const body = try std.json.Stringify.valueAlloc(app.gpa, .{
            .key = key.name,
            .value = text,
        }, .{ .whitespace = .indent_2 });
        app.ui.payload("{s}\n", .{body});
        app.ui.flush();
        return;
    }
    // Bare, so `lcc config worktreeTemplate` can be read by a shell without
    // anything to strip off it.
    app.ui.info("{s}", .{text});
}

fn set(app: app_mod.App, opts: Opts, key: Key, raw: []const u8) !void {
    var patch: config.Patch = .{};
    switch (key.kind) {
        .boolean => {
            const on = parseBool(raw) orelse {
                app.ui.fail("'{s}' is not true or false.", .{raw});
                std.process.exit(1);
            };
            if (std.mem.eql(u8, key.name, "watchByDefault")) patch.watchByDefault = on;
            if (std.mem.eql(u8, key.name, "statusBar")) patch.statusBar = on;
            if (std.mem.eql(u8, key.name, "planMode")) patch.planMode = on;
            if (std.mem.eql(u8, key.name, "resumeSessions")) patch.resumeSessions = on;
            if (std.mem.eql(u8, key.name, "showTokens")) patch.showTokens = on;
            if (std.mem.eql(u8, key.name, "allIssues")) patch.allIssues = on;
            if (std.mem.eql(u8, key.name, "keepBranch")) patch.keepBranch = on;
            if (std.mem.eql(u8, key.name, "keepDerivedData")) patch.keepDerivedData = on;
            if (std.mem.eql(u8, key.name, "keepXcode")) patch.keepXcode = on;
        },
        .choice => {
            const chosen = config.ListNetwork.parse(raw) orelse {
                app.ui.fail("'{s}' is not one of: {s}", .{ raw, try std.mem.join(app.gpa, ", ", key.choices) });
                std.process.exit(1);
            };
            if (std.mem.eql(u8, key.name, "listNetwork")) patch.listNetwork = chosen;
        },
        .text => {
            if (std.mem.eql(u8, key.name, "worktreeTemplate")) patch.worktreeTemplate = raw;
            if (std.mem.eql(u8, key.name, "startTaskCommand")) patch.startTaskCommand = raw;
        },
        .list => {
            const items = try splitList(app.gpa, raw);
            if (std.mem.eql(u8, key.name, "activeStates")) patch.activeStates = items;
            if (std.mem.eql(u8, key.name, "linkPatterns")) patch.linkPatterns = items;
            if (std.mem.eql(u8, key.name, "linkExclude")) patch.linkExclude = items;
            // Empty means "carry all", which is the absence of the key rather
            // than an empty array — the distinction `McpCarry` exists to keep.
            if (std.mem.eql(u8, key.name, "mcpCarry")) {
                patch.mcpCarry = if (items.len == 0) .all else .{ .only = items };
            }
        },
    }

    try config.save(app.gpa, app.io, app.environ, patch);

    const cfg = try config.load(app.gpa, app.io, app.environ);
    const text = try render(app, cfg, key);
    if (opts.json) {
        const body = try std.json.Stringify.valueAlloc(app.gpa, .{
            .key = key.name,
            .value = text,
        }, .{ .whitespace = .indent_2 });
        app.ui.payload("{s}\n", .{body});
        app.ui.flush();
        return;
    }
    app.ui.success("{s} = {s}", .{ key.name, text });
}

fn render(app: app_mod.App, cfg: config.Config, key: Key) ![]const u8 {
    const yes_no = struct {
        fn of(on: bool) []const u8 {
            return if (on) "true" else "false";
        }
    }.of;

    if (std.mem.eql(u8, key.name, "watchByDefault")) return yes_no(cfg.watchByDefault);
    if (std.mem.eql(u8, key.name, "statusBar")) return yes_no(cfg.statusBar);
    if (std.mem.eql(u8, key.name, "planMode")) return yes_no(cfg.planMode);
    if (std.mem.eql(u8, key.name, "resumeSessions")) return yes_no(cfg.resumeSessions);
    if (std.mem.eql(u8, key.name, "showTokens")) return yes_no(cfg.showTokens);
    if (std.mem.eql(u8, key.name, "allIssues")) return yes_no(cfg.allIssues);
    if (std.mem.eql(u8, key.name, "keepBranch")) return yes_no(cfg.keepBranch);
    if (std.mem.eql(u8, key.name, "keepDerivedData")) return yes_no(cfg.keepDerivedData);
    if (std.mem.eql(u8, key.name, "keepXcode")) return yes_no(cfg.keepXcode);
    if (std.mem.eql(u8, key.name, "listNetwork")) return @tagName(cfg.listNetwork);
    if (std.mem.eql(u8, key.name, "worktreeTemplate")) return cfg.worktreeTemplate;
    if (std.mem.eql(u8, key.name, "startTaskCommand")) {
        // An empty template is the default and means "open with no prompt";
        // printing nothing would read as a bug.
        return if (cfg.startTaskCommand.len == 0) "(none)" else cfg.startTaskCommand;
    }
    if (std.mem.eql(u8, key.name, "activeStates")) return std.mem.join(app.gpa, ", ", cfg.activeStates);
    if (std.mem.eql(u8, key.name, "linkPatterns")) return std.mem.join(app.gpa, ", ", cfg.linkPatterns);
    if (std.mem.eql(u8, key.name, "linkExclude")) return std.mem.join(app.gpa, ", ", cfg.linkExclude);
    if (std.mem.eql(u8, key.name, "mcpCarry")) {
        const carry = cfg.mcpCarry orelse return "(all)";
        if (carry.len == 0) return "(none)";
        return std.mem.join(app.gpa, ", ", carry);
    }
    return "";
}

/// Generous about what counts as a yes: this is typed by hand, and refusing
/// `on` or `1` would be pedantry rather than safety.
pub fn parseBool(raw: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, raw, " \t");
    inline for (.{ "true", "yes", "on", "1" }) |yes| {
        if (std.ascii.eqlIgnoreCase(trimmed, yes)) return true;
    }
    inline for (.{ "false", "no", "off", "0" }) |no| {
        if (std.ascii.eqlIgnoreCase(trimmed, no)) return false;
    }
    return null;
}

/// Comma-separated, trimmed, empties dropped. An empty string is an empty list
/// rather than a list containing nothing-in-particular.
pub fn splitList(gpa: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        try out.append(gpa, trimmed);
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "every key is unique and documented" {
    // A bare `lcc config` is the only place these names are discoverable, so an
    // undocumented one is a setting nobody will find.
    for (keys, 0..) |key, i| {
        try testing.expect(key.doc.len > 0);
        for (keys[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, key.name, other.name));
        }
    }
    try testing.expect(find("watchByDefault") != null);
    try testing.expect(find("nonsense") == null);

    // Every choice key offers its options, or a wrong value can only be
    // answered with "no" rather than with the right answer.
    for (keys) |key| {
        if (key.kind == .choice) try testing.expect(key.choices.len > 1);
    }
}

test "the destructive flags are deliberately not settings" {
    // A stored `yes` or `force` removes the one confirmation between a mistyped
    // command and a deleted worktree — invisibly, months after it was typed.
    // Asserted rather than left to a comment, because the obvious next commit
    // is someone adding them for symmetry.
    try testing.expect(find("yes") == null);
    try testing.expect(find("force") == null);
    try testing.expect(find("json") == null);
}

test "listNetwork parses its three states and nothing else" {
    try testing.expectEqual(config.ListNetwork.refresh, config.ListNetwork.parse("refresh").?);
    try testing.expectEqual(config.ListNetwork.cached, config.ListNetwork.parse("cached").?);
    try testing.expectEqual(config.ListNetwork.local, config.ListNetwork.parse(" local ").?);
    // Two booleans would have let someone ask for both "skip the network" and
    // "ignore the cache"; one setting cannot express that at all.
    try testing.expect(config.ListNetwork.parse("both") == null);
    try testing.expect(config.ListNetwork.parse("") == null);
}

test "a boolean accepts what people actually type" {
    for ([_][]const u8{ "true", "TRUE", "yes", "on", "1", " true " }) |raw| {
        try testing.expectEqual(true, parseBool(raw).?);
    }
    for ([_][]const u8{ "false", "FALSE", "no", "off", "0" }) |raw| {
        try testing.expectEqual(false, parseBool(raw).?);
    }
    // Anything else is refused rather than guessed — silently reading "maybe"
    // as false would turn watch mode off without saying so.
    try testing.expect(parseBool("maybe") == null);
    try testing.expect(parseBool("") == null);
    try testing.expect(parseBool("2") == null);
}

test "a list splits on commas and drops the gaps" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const states = try splitList(arena, "Todo, In Progress ,In Review");
    try testing.expectEqual(@as(usize, 3), states.len);
    try testing.expectEqualStrings("Todo", states[0]);
    // Trimmed, because typing a space after a comma is the normal thing to do
    // and " In Progress" would never match a Linear state.
    try testing.expectEqualStrings("In Progress", states[1]);
    try testing.expectEqualStrings("In Review", states[2]);

    // Empty is an empty list, not a list holding one empty string — which for
    // `linkPatterns` would be a pattern matching everything.
    try testing.expectEqual(@as(usize, 0), (try splitList(arena, "")).len);
    try testing.expectEqual(@as(usize, 0), (try splitList(arena, " , , ")).len);
}

test "watchByDefault round-trips through the file" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", home);

    // On when nothing has been said.
    try testing.expect((try config.load(arena, io, &environ)).watchByDefault);

    try config.save(arena, io, &environ, .{ .watchByDefault = false });
    try testing.expect(!(try config.load(arena, io, &environ)).watchByDefault);

    // And back, without disturbing anything else that was stored.
    try config.save(arena, io, &environ, .{ .startTaskCommand = "/start-task {identifier}" });
    const cfg = try config.load(arena, io, &environ);
    try testing.expect(!cfg.watchByDefault);
    try testing.expectEqualStrings("/start-task {identifier}", cfg.startTaskCommand);
}
