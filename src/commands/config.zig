const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const config = @import("../config.zig");
const mcp = @import("../mcp.zig");
const mcp_roster = @import("../mcp_roster.zig");
const prompt = @import("../prompt.zig");
const term = @import("../term.zig");
const ui = @import("../ui.zig");

pub const Opts = struct {
    key: ?[]const u8 = null,
    value: ?[]const u8 = null,
    json: bool = false,
};

pub const Error = error{ UnknownKey, BadValue } || std.mem.Allocator.Error;

const Kind = enum { text, boolean, list, choice };

const Key = struct {
    name: []const u8,
    kind: Kind,
    label: []const u8,
    choices: []const []const u8 = &.{},
};

pub const keys = [_]Key{
    .{ .name = "watchByDefault", .kind = .boolean, .label = "Sessions outlive the terminal" },
    .{ .name = "planMode", .kind = .boolean, .label = "Start in plan mode" },
    .{ .name = "planModel", .kind = .text, .label = "Model for planning sessions" },
    .{ .name = "planTaskCommand", .kind = .text, .label = "Opening prompt when planning" },
    .{ .name = "postPlanModel", .kind = .text, .label = "Model to return to after a plan" },
    .{ .name = "resumeSessions", .kind = .boolean, .label = "Resume last session on open" },
    .{ .name = "allIssues", .kind = .boolean, .label = "Offer every assigned issue" },
    .{ .name = "showTokens", .kind = .boolean, .label = "Token column in list" },
    .{ .name = "listNetwork", .kind = .choice, .label = "PR and Linear columns", .choices = &.{ "refresh", "cached", "local" } },
    .{ .name = "keepBranch", .kind = .boolean, .label = "Removing keeps the branch" },
    .{ .name = "keepDerivedData", .kind = .boolean, .label = "Removing keeps build data" },
    .{ .name = "keepXcode", .kind = .boolean, .label = "Removing leaves Xcode alone" },
    .{ .name = "xcodeApp", .kind = .text, .label = "Xcode to open worktrees in" },
    .{ .name = "worktreeTemplate", .kind = .text, .label = "Worktree path" },
    .{ .name = "startTaskCommand", .kind = .text, .label = "Opening prompt" },
    .{ .name = "activeStates", .kind = .list, .label = "Linear states offered" },
    .{ .name = "linkPatterns", .kind = .list, .label = "Files linked into a worktree" },
    .{ .name = "linkExclude", .kind = .list, .label = "Files never linked" },
    .{ .name = "mcpCarry", .kind = .list, .label = "MCP servers carried" },
    .{ .name = "mcpDisable", .kind = .list, .label = "MCP servers switched off" },
};

fn find(name: []const u8) ?Key {
    for (keys) |key| {
        if (std.mem.eql(u8, key.name, name)) return key;
    }
    return null;
}

pub fn run(app: app_mod.App, opts: Opts) !void {
    const key_name = opts.key orelse {
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
            .planMode = cfg.planMode,
            .planModel = cfg.planModel,
            .planTaskCommand = cfg.planTaskCommand,
            .postPlanModel = cfg.postPlanModel,
            .resumeSessions = cfg.resumeSessions,
            .showTokens = cfg.showTokens,
            .listNetwork = @tagName(cfg.listNetwork),
            .allIssues = cfg.allIssues,
            .keepBranch = cfg.keepBranch,
            .keepDerivedData = cfg.keepDerivedData,
            .keepXcode = cfg.keepXcode,
            .xcodeApp = cfg.xcodeApp,
            .worktreeTemplate = cfg.worktreeTemplate,
            .startTaskCommand = cfg.startTaskCommand,
            .activeStates = cfg.activeStates,
            .linkPatterns = cfg.linkPatterns,
            .linkExclude = cfg.linkExclude,
            .mcpCarry = cfg.mcpCarry,
            .mcpDisable = cfg.mcpDisable,
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

fn display(app: app_mod.App, cfg: config.Config, key: Key) ![]const u8 {
    const raw = try render(app, cfg, key);
    if (key.kind != .boolean) return raw;
    return if (std.mem.eql(u8, raw, "true")) "on" else "off";
}

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
            screen.eraseFrame();
            screen.out.writeAll(term.csi ++ "?25h") catch {};
            screen.out.flush() catch {};
            terminal.restore();

            const answered = try ask(app, key, cfg, &patch);

            terminal.* = try term.Terminal.enterRaw();
            screen.out.writeAll(term.csi ++ "?25l") catch {};
            screen.reset();

            if (!answered) return;
        },
    }
    config.save(app.gpa, app.io, app.environ, patch) catch {};
}

const servers_hint = "repo rows travel with the worktree; unchecking a global one switches it off";

fn ask(app: app_mod.App, key: Key, cfg: config.Config, patch: *config.Patch) !bool {
    if (std.mem.eql(u8, key.name, "mcpCarry") or std.mem.eql(u8, key.name, "mcpDisable")) {
        if (try serverRows(app, cfg)) |rows| {
            const items = try app.gpa.alloc(prompt.Item, rows.len);
            const width = nameWidth(rows);
            for (rows, items) |row, *item| item.* = .{
                .label = try std.fmt.allocPrint(app.gpa, "{f}  {s}", .{
                    ui.pad(row.name, width),
                    @tagName(row.origin),
                }),
                .checked = row.checked,
            };
            const picked = try prompt.checkbox(app.gpa, app.io, "MCP servers", servers_hint, items) orelse return false;
            const outcome = try serverOutcome(app.gpa, rows, picked);
            patch.mcpCarry = outcome.carry;
            patch.mcpDisable = outcome.disable;
            return true;
        }
    }

    const current = try render(app, cfg, key);
    const shown = if (placeholder(current)) "" else current;
    const typed = try prompt.input(app.gpa, app.io, key.name, shown) orelse return false;
    if (key.kind == .text) {
        applyText(patch, key.name, typed);
    } else {
        applyList(patch, key.name, try splitList(app.gpa, typed));
    }
    return true;
}

fn serverRows(app: app_mod.App, cfg: config.Config) !?[]const ServerRow {
    const local = try mcp.known(app.gpa, app.io, app.environ);
    const root = if (app.repo()) |repo| repo.root else |_| null;
    const now = app_mod.nowSeconds(app.io);

    const roster = mcp_roster.cached(app.gpa, app.io, app.environ, now) orelse probe: {
        app.ui.step("Asking Claude Code which MCP servers it loads…", .{});
        app.ui.flush();
        break :probe mcp_roster.refresh(app.gpa, app.io, app.environ, root, now) catch &.{};
    };

    const rows = try serverRowsFrom(app.gpa, local, roster, cfg.mcpCarry, cfg.mcpDisable);
    return if (rows.len == 0) null else rows;
}

fn nameWidth(rows: []const ServerRow) usize {
    var width: usize = 0;
    for (rows) |row| width = @max(width, ui.displayWidth(row.name));
    return width;
}

pub const Origin = enum { repo, global };

pub const ServerRow = struct {
    name: []const u8,
    origin: Origin,
    checked: bool,
};

pub const ServerChoice = struct {
    carry: ?config.McpCarry,
    disable: []const []const u8,
};

pub fn serverRowsFrom(
    gpa: std.mem.Allocator,
    local: []const []const u8,
    roster: []const []const u8,
    carry: ?[]const []const u8,
    disable: []const []const u8,
) ![]const ServerRow {
    var repo_names: std.ArrayList([]const u8) = .empty;
    try repo_names.appendSlice(gpa, local);
    for (carry orelse &.{}) |name| {
        if (!mcp.containsFold(repo_names.items, name)) try repo_names.append(gpa, name);
    }

    var rows: std.ArrayList(ServerRow) = .empty;
    for (repo_names.items) |name| {
        try rows.append(gpa, .{
            .name = name,
            .origin = .repo,
            .checked = carriedNow(carry, name),
        });
    }

    for (roster) |name| {
        if (mcp.containsFold(repo_names.items, name)) continue;
        try rows.append(gpa, .{
            .name = name,
            .origin = .global,
            .checked = !mcp.containsFold(disable, name),
        });
    }
    for (disable) |name| {
        if (mcp.containsFold(repo_names.items, name)) continue;
        if (containsRow(rows.items, name)) continue;
        try rows.append(gpa, .{ .name = name, .origin = .global, .checked = false });
    }

    return rows.toOwnedSlice(gpa);
}

fn containsRow(rows: []const ServerRow, wanted: []const u8) bool {
    for (rows) |row| {
        if (std.ascii.eqlIgnoreCase(row.name, wanted)) return true;
    }
    return false;
}

pub fn carriedNow(current: ?[]const []const u8, name: []const u8) bool {
    const allow = current orelse return true;
    return mcp.containsFold(allow, name);
}

pub fn serverOutcome(
    gpa: std.mem.Allocator,
    rows: []const ServerRow,
    picked: []const usize,
) !ServerChoice {
    var kept: std.ArrayList([]const u8) = .empty;
    var denied: std.ArrayList([]const u8) = .empty;
    var repo_total: usize = 0;

    var chosen = try gpa.alloc(bool, rows.len);
    @memset(chosen, false);
    for (picked) |index| chosen[index] = true;

    for (rows, chosen) |row, on| {
        switch (row.origin) {
            .repo => {
                repo_total += 1;
                if (on) try kept.append(gpa, row.name);
            },
            .global => if (!on) try denied.append(gpa, row.name),
        }
    }

    const carry: ?config.McpCarry = if (repo_total == 0)
        null
    else if (kept.items.len == repo_total)
        .all
    else
        .{ .only = try kept.toOwnedSlice(gpa) };

    return .{ .carry = carry, .disable = try denied.toOwnedSlice(gpa) };
}

fn placeholder(text: []const u8) bool {
    inline for (.{ "(none)", "(all)", "(ask)" }) |shown| {
        if (std.mem.eql(u8, text, shown)) return true;
    }
    return false;
}

fn applyBool(patch: *config.Patch, name: []const u8, on: bool) void {
    if (std.mem.eql(u8, name, "watchByDefault")) patch.watchByDefault = on;
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
    if (std.mem.eql(u8, name, "xcodeApp")) patch.xcodeApp = raw;
    if (std.mem.eql(u8, name, "planModel")) patch.planModel = raw;
    if (std.mem.eql(u8, name, "planTaskCommand")) patch.planTaskCommand = raw;
    if (std.mem.eql(u8, name, "postPlanModel")) patch.postPlanModel = raw;
}

fn applyList(patch: *config.Patch, name: []const u8, items: []const []const u8) void {
    if (std.mem.eql(u8, name, "activeStates")) patch.activeStates = items;
    if (std.mem.eql(u8, name, "linkPatterns")) patch.linkPatterns = items;
    if (std.mem.eql(u8, name, "linkExclude")) patch.linkExclude = items;
    if (std.mem.eql(u8, name, "mcpCarry")) patch.mcpCarry = mcpCarryFrom(items);
    if (std.mem.eql(u8, name, "mcpDisable")) patch.mcpDisable = items;
}

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
        return if (cfg.startTaskCommand.len == 0) "(none)" else cfg.startTaskCommand;
    }
    if (std.mem.eql(u8, key.name, "xcodeApp")) {
        return if (cfg.xcodeApp.len == 0) "(ask)" else cfg.xcodeApp;
    }
    if (std.mem.eql(u8, key.name, "planModel")) {
        return if (cfg.planModel.len == 0) "(session)" else cfg.planModel;
    }
    if (std.mem.eql(u8, key.name, "planTaskCommand")) {
        return if (cfg.planTaskCommand.len == 0) "(startTaskCommand)" else cfg.planTaskCommand;
    }
    if (std.mem.eql(u8, key.name, "postPlanModel")) {
        return if (cfg.postPlanModel.len == 0) "(stay)" else cfg.postPlanModel;
    }
    if (std.mem.eql(u8, key.name, "activeStates")) return std.mem.join(app.gpa, ", ", cfg.activeStates);
    if (std.mem.eql(u8, key.name, "linkPatterns")) return std.mem.join(app.gpa, ", ", cfg.linkPatterns);
    if (std.mem.eql(u8, key.name, "linkExclude")) return std.mem.join(app.gpa, ", ", cfg.linkExclude);
    if (std.mem.eql(u8, key.name, "mcpCarry")) {
        const carry = cfg.mcpCarry orelse return "(all)";
        if (carry.len == 0) return "(none)";
        return std.mem.join(app.gpa, ", ", carry);
    }
    if (std.mem.eql(u8, key.name, "mcpDisable")) {
        if (cfg.mcpDisable.len == 0) return "(none)";
        return std.mem.join(app.gpa, ", ", cfg.mcpDisable);
    }
    return "";
}

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
        try testing.expect(ui.displayWidth(key.label) <= 32);
        for (keys[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, key.name, other.name));
        }
    }
    try testing.expect(find("watchByDefault") != null);
    try testing.expect(find("nonsense") == null);

    for (keys) |key| {
        if (key.kind == .choice) try testing.expect(key.choices.len > 1);
    }
}

test "the destructive flags are deliberately not settings" {
    try testing.expect(find("yes") == null);
    try testing.expect(find("force") == null);
    try testing.expect(find("json") == null);
}

test "mcpCarry keeps the three states its words describe" {
    const gpa = testing.allocator;
    try testing.expect(mcpCarryFrom(&.{}) == .all);
    try testing.expect(mcpCarryFrom(&.{"all"}) == .all);
    try testing.expect(mcpCarryFrom(&.{"ALL"}) == .all);
    try testing.expectEqual(@as(usize, 0), mcpCarryFrom(&.{"none"}).only.len);

    const named = mcpCarryFrom(&.{ "linear-server", "xcode" });
    try testing.expectEqual(@as(usize, 2), named.only.len);
    try testing.expectEqualStrings("linear-server", named.only[0]);
    try testing.expectEqual(@as(usize, 2), mcpCarryFrom(&.{ "all", "xcode" }).only.len);
    _ = gpa;
}

fn pickAll(gpa: std.mem.Allocator, rows: []const ServerRow) ![]usize {
    const out = try gpa.alloc(usize, rows.len);
    for (out, 0..) |*slot, i| slot.* = i;
    return out;
}

test "the list is what Claude Code loads, split by who governs each row" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const local: []const []const u8 = &.{ "linear-server", "xcode" };
    const roster: []const []const u8 = &.{ "linear-server", "xcode", "context7", "claude.ai Notion", "plugin:figma:figma" };

    const rows = try serverRowsFrom(arena, local, roster, null, &.{});
    try testing.expectEqual(@as(usize, 5), rows.len);
    try testing.expectEqual(Origin.repo, rows[0].origin);
    try testing.expectEqual(Origin.repo, rows[1].origin);
    try testing.expectEqual(Origin.global, rows[2].origin);
    try testing.expectEqualStrings("context7", rows[2].name);
    try testing.expectEqualStrings("claude.ai Notion", rows[3].name);
    for (rows) |row| try testing.expect(row.checked);
}

test "a row starts checked exactly when that server reaches the session today" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try serverRowsFrom(
        arena,
        &.{ "linear-server", "xcode" },
        &.{ "context7", "claude.ai Notion" },
        &.{"linear-server"},
        &.{"claude.ai Notion"},
    );
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expect(rows[0].checked);
    try testing.expect(!rows[1].checked);
    try testing.expect(rows[2].checked);
    try testing.expect(!rows[3].checked);
}

test "a name the roster no longer knows still gets a row, so a setting is never lost" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try serverRowsFrom(arena, &.{}, &.{"context7"}, &.{"figma"}, &.{"pencil"});
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("figma", rows[0].name);
    try testing.expectEqual(Origin.repo, rows[0].origin);
    try testing.expectEqualStrings("pencil", rows[2].name);
    try testing.expect(!rows[2].checked);

    try testing.expectEqual(@as(usize, 0), (try serverRowsFrom(arena, &.{}, &.{}, null, &.{})).len);
}

test "a roster that names a repo server does not list it twice under two rules" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try serverRowsFrom(arena, &.{"xcode"}, &.{ "XCODE", "context7" }, null, &.{});
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("xcode", rows[0].name);
    try testing.expectEqual(Origin.repo, rows[0].origin);
    try testing.expectEqualStrings("context7", rows[1].name);
}

test "every box checked carries everything and denies nothing" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try serverRowsFrom(arena, &.{ "linear-server", "xcode" }, &.{ "context7", "pencil" }, null, &.{});
    const outcome = try serverOutcome(arena, rows, try pickAll(arena, rows));
    try testing.expect(outcome.carry.? == .all);
    try testing.expectEqual(@as(usize, 0), outcome.disable.len);
}

test "unchecking sends a repo row to mcpCarry and a global row to mcpDisable" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try serverRowsFrom(arena, &.{ "linear-server", "xcode" }, &.{ "context7", "pencil" }, null, &.{});
    const outcome = try serverOutcome(arena, rows, &.{ 0, 2 });

    try testing.expectEqual(@as(usize, 1), outcome.carry.?.only.len);
    try testing.expectEqualStrings("linear-server", outcome.carry.?.only[0]);
    try testing.expectEqual(@as(usize, 1), outcome.disable.len);
    try testing.expectEqualStrings("pencil", outcome.disable[0]);
}

test "a machine with no repo servers leaves mcpCarry alone rather than rewriting it to all" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try serverRowsFrom(arena, &.{}, &.{ "context7", "pencil" }, null, &.{});
    try testing.expectEqual(@as(usize, 2), rows.len);

    const outcome = try serverOutcome(arena, rows, &.{0});
    try testing.expect(outcome.carry == null);
    try testing.expectEqual(@as(usize, 1), outcome.disable.len);
    try testing.expectEqualStrings("pencil", outcome.disable[0]);
}

test "a box starts checked exactly when the server is carried today" {
    try testing.expect(carriedNow(null, "anything"));
    try testing.expect(carriedNow(&.{ "linear-server", "xcode" }, "XCODE"));
    try testing.expect(!carriedNow(&.{ "linear-server", "xcode" }, "sentry"));
    try testing.expect(!carriedNow(&.{}, "xcode"));
}

test "listNetwork parses its three states and nothing else" {
    try testing.expectEqual(config.ListNetwork.refresh, config.ListNetwork.parse("refresh").?);
    try testing.expectEqual(config.ListNetwork.cached, config.ListNetwork.parse("cached").?);
    try testing.expectEqual(config.ListNetwork.local, config.ListNetwork.parse(" local ").?);
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
    try testing.expectEqualStrings("In Progress", states[1]);
    try testing.expectEqualStrings("In Review", states[2]);

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

    try testing.expect((try config.load(arena, io, &environ)).watchByDefault);

    try config.save(arena, io, &environ, .{ .watchByDefault = false });
    try testing.expect(!(try config.load(arena, io, &environ)).watchByDefault);

    try config.save(arena, io, &environ, .{ .startTaskCommand = "/start-task {identifier}" });
    const cfg = try config.load(arena, io, &environ);
    try testing.expect(!cfg.watchByDefault);
    try testing.expectEqualStrings("/start-task {identifier}", cfg.startTaskCommand);
}
