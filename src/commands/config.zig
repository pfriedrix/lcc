//! `lcc config` — every setting, browsable, and each one addressable by name.
//!
//! Two shapes for the same table. Bare, it opens a list you move through and
//! change in place; that is the one to reach for when you do not remember what
//! a setting is called, which is most of the time. Named — `lcc config <key>
//! [<value>]` — it reads or writes exactly one and never touches raw mode,
//! which is the only form a script, a slash command or a tool call can use.
//!
//! Both drive the same `keys` table, so a setting cannot exist in one and be
//! missing from the other. That was the problem with `lcc setup`: a hand-written
//! walk through five settings in a fixed order, which every later setting was
//! simply absent from.

const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const config = @import("../config.zig");
const prompt = @import("../prompt.zig");
const term = @import("../term.zig");
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
    /// What you type: the key as it appears in the JSON file.
    name: []const u8,
    kind: Kind,
    /// What you read. Short enough to sit beside its value in a list and say
    /// what the setting *does*, so nothing needs a line of explanation under
    /// it — a settings list that has to describe itself is one whose names are
    /// wrong.
    label: []const u8,
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
    .{ .name = "watchByDefault", .kind = .boolean, .label = "Sessions outlive the terminal" },
    .{ .name = "planMode", .kind = .boolean, .label = "Start in plan mode" },
    .{ .name = "statusBar", .kind = .boolean, .label = "Status bar while attached" },
    .{ .name = "resumeSessions", .kind = .boolean, .label = "Resume last session on open" },
    .{ .name = "allIssues", .kind = .boolean, .label = "Offer every assigned issue" },
    .{ .name = "showTokens", .kind = .boolean, .label = "Token column in list" },
    .{ .name = "listNetwork", .kind = .choice, .label = "PR and Linear columns", .choices = &.{ "refresh", "cached", "local" } },
    .{ .name = "keepBranch", .kind = .boolean, .label = "Removing keeps the branch" },
    .{ .name = "keepDerivedData", .kind = .boolean, .label = "Removing keeps build data" },
    .{ .name = "keepXcode", .kind = .boolean, .label = "Removing leaves Xcode alone" },
    .{ .name = "worktreeTemplate", .kind = .text, .label = "Worktree path" },
    .{ .name = "startTaskCommand", .kind = .text, .label = "Opening prompt" },
    .{ .name = "activeStates", .kind = .list, .label = "Linear states offered" },
    .{ .name = "linkPatterns", .kind = .list, .label = "Files linked into a worktree" },
    .{ .name = "linkExclude", .kind = .list, .label = "Files never linked" },
    .{ .name = "mcpCarry", .kind = .list, .label = "MCP servers carried" },
};

fn find(name: []const u8) ?Key {
    for (keys) |key| {
        if (std.mem.eql(u8, key.name, name)) return key;
    }
    return null;
}

pub fn run(app: app_mod.App, opts: Opts) !void {
    const key_name = opts.key orelse {
        // A terminal gets the browser; anything else gets the plain listing,
        // because a picker reached from a tool call fails with NotATerminal
        // after doing nothing useful.
        if (!opts.json and (Io.File.stdout().isTty(app.io) catch false)) return browse(app);
        return list(app, opts);
    };

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
            applyBool(&patch, key.name, on);
        },
        .choice => {
            const chosen = config.ListNetwork.parse(raw) orelse {
                app.ui.fail("'{s}' is not one of: {s}", .{ raw, try std.mem.join(app.gpa, ", ", key.choices) });
                std.process.exit(1);
            };
            if (std.mem.eql(u8, key.name, "listNetwork")) patch.listNetwork = chosen;
        },
        .text => applyText(&patch, key.name, raw),
        .list => applyList(&patch, key.name, try splitList(app.gpa, raw)),
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

/// The interactive form: the whole table, moved through and changed in place.
///
/// Every change is written as it is made rather than collected behind a save
/// step. The file is six lines of JSON and the alternative is a modal state
/// where what is on screen and what is on disk disagree.
fn browse(app: app_mod.App) !void {
    var terminal = try term.Terminal.enterRaw();
    defer terminal.restore();

    var out_buffer: [32 * 1024]u8 = undefined;
    var out_writer: Io.File.Writer = .init(.stdout(), app.io, &out_buffer);
    var screen: term.Screen = .{ .out = &out_writer.interface };
    const out = screen.out;

    out.writeAll(term.csi ++ "?25l") catch {};
    defer {
        screen.eraseFrame();
        out.writeAll(term.csi ++ "?25h") catch {};
        out.flush() catch {};
    }

    const p = ui.palette();
    var cursor: usize = 0;
    var key_buf: [8]u8 = undefined;
    var last_cols: u16 = 0;

    var width: usize = 0;
    for (keys) |key| width = @max(width, ui.displayWidth(key.label));

    while (true) {
        const dims = terminal.size();
        if (dims.cols != last_cols) {
            screen.reset();
            last_cols = dims.cols;
        }
        const cfg = try config.load(app.gpa, app.io, app.environ);

        screen.eraseFrame();
        var lines: usize = 0;

        out.print("{s}lcc{s}\n\n", .{ p.bold, p.reset }) catch {};
        lines += 2;

        for (keys, 0..) |key, i| {
            const selected = i == cursor;
            out.print("{s}{s}{f}{s}  {s}{s}{s}\n", .{
                if (selected) p.cyan else "",
                if (selected) "❯ " else "  ",
                ui.pad(key.label, width),
                p.reset,
                if (selected) p.bold else p.dim,
                term.truncate(try display(app, cfg, key), dims.cols -| (width + 6)),
                p.reset,
            }) catch {};
            lines += 1;
        }

        // Navigation, not explanation. The settings say what they do; this says
        // what the keys do, and nothing else earns a line here.
        out.print("\n  {s}↑↓ · enter · q{s}\n", .{ p.dim, p.reset }) catch {};
        lines += 2;

        screen.lines = lines;
        out.flush() catch {};

        switch (term.readKey(terminal, &key_buf)) {
            .cancel => return,
            .up => cursor = if (cursor == 0) keys.len - 1 else cursor - 1,
            .down => cursor = if (cursor + 1 >= keys.len) 0 else cursor + 1,
            .space, .enter => try change(app, &screen, &terminal, keys[cursor], cfg),
            .text => |t| {
                // By key position, so a Cyrillic layout still navigates.
                if (term.layoutKey(t)) |key| switch (key) {
                    'q' => return,
                    'j' => cursor = if (cursor + 1 >= keys.len) 0 else cursor + 1,
                    'k' => cursor = if (cursor == 0) keys.len - 1 else cursor - 1,
                    else => {},
                };
            },
            else => {},
        }
    }
}

/// The value as a switch reads it. `on`/`off` rather than `true`/`false`,
/// because this is a list of toggles; the named form keeps the literal the file
/// holds, since that is what you would type back at it.
fn display(app: app_mod.App, cfg: config.Config, key: Key) ![]const u8 {
    const raw = try render(app, cfg, key);
    if (key.kind != .boolean) return raw;
    return if (std.mem.eql(u8, raw, "true")) "on" else "off";
}

/// Apply one change to the highlighted setting.
///
/// A boolean toggles and a choice cycles, both in place — an editor for two or
/// three values would be more machinery than the values are worth. Text and
/// lists need a real line editor, which means handing the terminal to
/// `prompt.input` and taking it back afterwards.
fn change(
    app: app_mod.App,
    screen: *term.Screen,
    terminal: *term.Terminal,
    key: Key,
    cfg: config.Config,
) !void {
    var patch: config.Patch = .{};
    switch (key.kind) {
        .boolean => {
            const now = std.mem.eql(u8, try render(app, cfg, key), "true");
            applyBool(&patch, key.name, !now);
        },
        .choice => {
            const current = @tagName(cfg.listNetwork);
            var at: usize = 0;
            for (key.choices, 0..) |choice, i| {
                if (std.mem.eql(u8, choice, current)) at = i;
            }
            const next = key.choices[(at + 1) % key.choices.len];
            if (std.mem.eql(u8, key.name, "listNetwork")) {
                patch.listNetwork = config.ListNetwork.parse(next).?;
            }
        },
        .text, .list => {
            // `prompt.input` owns the terminal for its lifetime, so this one is
            // given back and taken again around it — the same handover
            // `lcc watch` performs around an attached session.
            screen.eraseFrame();
            screen.out.writeAll(term.csi ++ "?25h") catch {};
            screen.out.flush() catch {};
            terminal.restore();

            const current = try render(app, cfg, key);
            const shown = if (std.mem.eql(u8, current, "(none)") or std.mem.eql(u8, current, "(all)"))
                ""
            else
                current;
            const typed = try prompt.input(app.gpa, app.io, key.name, shown);

            terminal.* = try term.Terminal.enterRaw();
            screen.out.writeAll(term.csi ++ "?25l") catch {};
            screen.reset();

            const raw = typed orelse return;
            if (key.kind == .text) {
                applyText(&patch, key.name, raw);
            } else {
                applyList(&patch, key.name, try splitList(app.gpa, raw));
            }
        },
    }
    config.save(app.gpa, app.io, app.environ, patch) catch {};
}

fn applyBool(patch: *config.Patch, name: []const u8, on: bool) void {
    if (std.mem.eql(u8, name, "watchByDefault")) patch.watchByDefault = on;
    if (std.mem.eql(u8, name, "statusBar")) patch.statusBar = on;
    if (std.mem.eql(u8, name, "planMode")) patch.planMode = on;
    if (std.mem.eql(u8, name, "resumeSessions")) patch.resumeSessions = on;
    if (std.mem.eql(u8, name, "showTokens")) patch.showTokens = on;
    if (std.mem.eql(u8, name, "allIssues")) patch.allIssues = on;
    if (std.mem.eql(u8, name, "keepBranch")) patch.keepBranch = on;
    if (std.mem.eql(u8, name, "keepDerivedData")) patch.keepDerivedData = on;
    if (std.mem.eql(u8, name, "keepXcode")) patch.keepXcode = on;
}

fn applyText(patch: *config.Patch, name: []const u8, raw: []const u8) void {
    if (std.mem.eql(u8, name, "worktreeTemplate")) patch.worktreeTemplate = raw;
    if (std.mem.eql(u8, name, "startTaskCommand")) patch.startTaskCommand = raw;
}

fn applyList(patch: *config.Patch, name: []const u8, items: []const []const u8) void {
    if (std.mem.eql(u8, name, "activeStates")) patch.activeStates = items;
    if (std.mem.eql(u8, name, "linkPatterns")) patch.linkPatterns = items;
    if (std.mem.eql(u8, name, "linkExclude")) patch.linkExclude = items;
    if (std.mem.eql(u8, name, "mcpCarry")) patch.mcpCarry = mcpCarryFrom(items);
}

/// `mcpCarry` has three states, not two, and the words for them predate this
/// command: "all" carries every local server, "none" carries none, a list
/// carries those. Empty means "all" because the key's absence is what carries
/// everything — the distinction `config.McpCarry` exists to keep.
///
/// Taken literally, a typed "none" would otherwise become a list holding one
/// server called `none`, and the session would silently get no MCP servers for
/// a reason nobody could see.
pub fn mcpCarryFrom(items: []const []const u8) config.McpCarry {
    if (items.len == 0) return .all;
    if (items.len == 1) {
        if (std.ascii.eqlIgnoreCase(items[0], "all")) return .all;
        if (std.ascii.eqlIgnoreCase(items[0], "none")) return .{ .only = &.{} };
    }
    return .{ .only = items };
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

test "every key is unique and carries a label short enough to sit in a list" {
    for (keys, 0..) |key, i| {
        try testing.expect(key.label.len > 0);
        // Short enough to sit beside its value rather than wrap. There is no
        // second line and no description under it to fall back on — the name
        // is the whole explanation.
        try testing.expect(ui.displayWidth(key.label) <= 32);
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

test "mcpCarry keeps the three states its words describe" {
    const gpa = testing.allocator;
    try testing.expect(mcpCarryFrom(&.{}) == .all);
    try testing.expect(mcpCarryFrom(&.{"all"}) == .all);
    try testing.expect(mcpCarryFrom(&.{"ALL"}) == .all);
    // "none" is empty, not a server called none — which is what a literal
    // reading would produce, and it would fail silently.
    try testing.expectEqual(@as(usize, 0), mcpCarryFrom(&.{"none"}).only.len);

    const named = mcpCarryFrom(&.{ "linear-server", "xcode" });
    try testing.expectEqual(@as(usize, 2), named.only.len);
    try testing.expectEqualStrings("linear-server", named.only[0]);
    // A server genuinely called "all" alongside others is still a list.
    try testing.expectEqual(@as(usize, 2), mcpCarryFrom(&.{ "all", "xcode" }).only.len);
    _ = gpa;
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
