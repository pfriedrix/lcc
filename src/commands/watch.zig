const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const config = @import("../config.zig");
const exec = @import("../exec.zig");
const sessions = @import("../sessions.zig");
const ui = @import("../ui.zig");
const watch_client = @import("../watch_client.zig");
const term = @import("../term.zig");
const watch_attach = @import("../watch_attach.zig");
const watch_hooks = @import("../watch_hooks.zig");
const claude = @import("../claude.zig");
const claude_projects = @import("../claude_projects.zig");
const linear = @import("../linear.zig");
const mcp = @import("../mcp.zig");
const start_cmd = @import("start.zig");
const watch_table = @import("../watch_table.zig");
const wire = @import("../wire.zig");

pub const Opts = struct {
    json: bool = false,
    stop_all: bool = false,
    force: bool = false,
};

pub const HookOpts = struct {
    socket: ?[]const u8 = null,
    event: ?[]const u8 = null,
};

pub const Row = struct {
    id: []const u8,
    issue: ?[]const u8,
    branch: []const u8,
    worktree: []const u8,
    status: []const u8,
    pid: i32,
    started_at: i64,
    last_activity_at: i64,
    exit_code: ?i32,
    stale: bool,
};

pub fn run(app: app_mod.App, opts: Opts) anyerror!void {
    if (opts.stop_all) return stopAll(app, opts);
    if (!opts.json and Io.File.stdout().isTty(app.io) catch false) {
        return dashboard(app);
    }
    if (!opts.json and !(Io.File.stdout().isTty(app.io) catch false)) {
        app.ui.hint("Not a terminal — use `lcc open --json`.", .{});
    }
    return snapshotOnce(app, opts);
}

fn stopAll(app: app_mod.App, opts: Opts) !void {
    var conn = (watch_client.connectExisting(app, .control) catch null) orelse {
        app.ui.info("No background sessions are running.", .{});
        return;
    };
    defer conn.close(app.io);

    try conn.sendControl(app.gpa, .stop, wire.Stop{ .force = opts.force });
    if (opts.force) {
        app.ui.success("Killed every background session.", .{});
    } else {
        app.ui.success("Asked every background session to finish.", .{});
    }
}

fn snapshotOnce(app: app_mod.App, opts: Opts) !void {
    const live = watch_client.snapshot(app) catch null;
    const now = app_mod.nowSeconds(app.io);
    const outdated = outdatedDaemon(app, app.gpa, exec.selfModified(app.gpa, app.io));

    if (live) |list| {
        const rows = try app.gpa.alloc(Row, list.len);
        for (list, 0..) |s, i| rows[i] = toRow(s, false);
        return emit(app, opts, rows, true, outdated, now);
    }

    const state = sessions.load(app.gpa, app.io, app.environ);
    const resolved = try sessions.resolved(app.gpa, app.io, state, now);
    const rows = try app.gpa.alloc(Row, resolved.len);
    for (resolved, 0..) |r, i| {
        var row = toRow(r.session, r.stale);
        row.status = @tagName(r.status);
        rows[i] = row;
    }
    return emit(app, opts, rows, false, outdated, now);
}

fn outdatedDaemon(app: app_mod.App, arena: std.mem.Allocator, built: ?i64) bool {
    return sessions.daemonOutdated(sessions.load(arena, app.io, app.environ), built);
}

const outdated_warning = "These sessions are running an older build of lcc than this one.";
const outdated_hint = "They end on their own 30 minutes after the last one finishes. `lcc open --stop-all` is immediate, but ends them now.";

fn toRow(s: sessions.Session, stale: bool) Row {
    return .{
        .id = s.id,
        .issue = s.issue,
        .branch = s.branch,
        .worktree = s.worktree,
        .status = s.status,
        .pid = s.pid,
        .started_at = s.started_at,
        .last_activity_at = s.last_activity_at,
        .exit_code = s.exit_code,
        .stale = stale,
    };
}

pub fn snapshotJson(gpa: std.mem.Allocator, rows: []const Row, live: bool, outdated: bool) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{
        .sessions_live = live,
        .outdated_build = outdated,
        .sessions = rows,
    }, .{ .whitespace = .indent_2 });
}

fn emit(app: app_mod.App, opts: Opts, rows: []const Row, live: bool, outdated: bool, now: i64) !void {
    if (opts.json) {
        const body = try snapshotJson(app.gpa, rows, live, outdated);
        app.ui.payload("{s}\n", .{body});
        app.ui.flush();
        return;
    }

    if (rows.len == 0) {
        app.ui.info("No watched sessions.", .{});
        app.ui.hint("Start one with: lcc start PE-256", .{});
        return;
    }

    if (!live) app.ui.warn("Nothing is running these sessions — showing the last recorded state.", .{});
    if (live and outdated) {
        app.ui.warn("{s}", .{outdated_warning});
        app.ui.hint("{s}", .{outdated_hint});
    }

    var widths = struct { issue: usize, status: usize, branch: usize }{
        .issue = "ISSUE".len,
        .status = "STATUS".len,
        .branch = "BRANCH".len,
    };
    for (rows) |row| {
        widths.issue = @max(widths.issue, ui.displayWidth(row.issue orelse "—"));
        widths.status = @max(widths.status, ui.displayWidth(row.status));
        widths.branch = @max(widths.branch, ui.displayWidth(row.branch));
    }

    app.ui.info("{f}  {f}  {f}  AGE", .{
        ui.pad("ISSUE", widths.issue),
        ui.pad("STATUS", widths.status),
        ui.pad("BRANCH", widths.branch),
    });
    for (rows) |row| {
        app.ui.info("{f}  {f}  {f}  {f}", .{
            ui.pad(row.issue orelse "—", widths.issue),
            ui.pad(row.status, widths.status),
            ui.pad(row.branch, widths.branch),
            ui.age(now - row.last_activity_at),
        });
    }
}

fn dashboard(app: app_mod.App) !void {
    const terminal = try term.Terminal.enterRaw();
    defer terminal.restore();

    var out_buffer: [64 * 1024]u8 = undefined;
    var out_writer: Io.File.Writer = .init(.stdout(), app.io, &out_buffer);
    var screen: term.Screen = .{ .out = &out_writer.interface };
    const out = screen.out;

    out.writeAll(term.csi ++ "?25l") catch {};
    defer {
        screen.eraseFrame();
        out.writeAll(term.csi ++ "?25h") catch {};
        out.flush() catch {};
    }

    var frame_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer frame_arena.deinit();

    var cursor_id: []const u8 = "";
    var cursor_buf: [std.fs.max_path_bytes]u8 = undefined;
    var confirming_kill = false;
    var key_buf: [8]u8 = undefined;
    var last_cols: u16 = 0;
    const built = exec.selfModified(app.gpa, app.io);

    while (true) {
        _ = frame_arena.reset(.retain_capacity);
        const arena = frame_arena.allocator();
        const now = app_mod.nowSeconds(app.io);
        const dims = terminal.size();

        if (dims.cols != last_cols) {
            screen.reset();
            last_cols = dims.cols;
        }

        const rows = try collect(app, arena, now);
        if (rows.len > 0 and findRow(rows, cursor_id) == null) {
            cursor_id = copyId(&cursor_buf, rows[0].key);
        }

        screen.eraseFrame();
        var lines: usize = 0;

        if (outdatedDaemon(app, arena, built)) {
            const p = ui.palette();
            out.print("  {s}⚠ {s}{s}\n", .{
                p.yellow,
                term.truncate(outdated_warning, dims.cols -| 4),
                p.reset,
            }) catch {};
            lines += 1;
        }

        const widths = watch_table.fit(watch_table.measure(rows), dims.cols);
        if (rows.len == 0) {
            out.print("  {s}No sessions yet — press n to start one.{s}\n", .{
                ui.palette().dim, ui.palette().reset,
            }) catch {};
            lines += 1;
        } else {
            lines += watch_table.render(out, rows, widths, dims.cols, cursor_id, now);
        }

        lines += footer(out, dims.cols, rows, cursor_id, confirming_kill);
        screen.lines = lines;
        out.flush() catch {};

        var fds = [_]std.posix.pollfd{
            .{ .fd = terminal.fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.poll(&fds, 1000) catch 0;
        if (ready == 0) continue;

        switch (term.readKey(terminal, &key_buf)) {
            .cancel => return,
            .up => cursor_id = copyId(&cursor_buf, step(rows, cursor_id, -1)),
            .down => cursor_id = copyId(&cursor_buf, step(rows, cursor_id, 1)),
            .enter => {
                if (findRow(rows, cursor_id)) |row| {
                    const id = if (row.attachable())
                        row.session_id.?
                    else blk: {
                        const started = startForWorktree(app, row) catch |err| {
                            app.ui.fail("Could not start a session: {s}", .{@errorName(err)});
                            continue;
                        };
                        break :blk started.id;
                    };
                    try attachTo(app, &screen, terminal, id);
                }
            },
            .text => |t| {
                const key = term.layoutKey(t) orelse continue;
                if (confirming_kill) {
                    confirming_kill = false;
                    if (key == 'y') {
                        if (findRow(rows, cursor_id)) |row| {
                            if (row.attachable()) kill(app, row.session_id.?);
                        }
                    }
                    continue;
                }
                switch (key) {
                    'q' => return,
                    'n' => try newSession(app, &screen, terminal),
                    'j' => cursor_id = copyId(&cursor_buf, step(rows, cursor_id, 1)),
                    'k' => cursor_id = copyId(&cursor_buf, step(rows, cursor_id, -1)),
                    'x' => confirming_kill = if (findRow(rows, cursor_id)) |row| row.attachable() else false,
                    'r' => {},
                    '1'...'9' => {
                        const index = key - '1';
                        if (index < rows.len) {
                            cursor_id = copyId(&cursor_buf, rows[index].key);
                            if (rows[index].attachable()) {
                                try attachTo(app, &screen, terminal, rows[index].session_id.?);
                            }
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

fn attachTo(
    app: app_mod.App,
    screen: *term.Screen,
    terminal: term.Terminal,
    id: []const u8,
) !void {
    screen.eraseFrame();
    screen.out.writeAll(term.csi ++ "?25h") catch {};
    screen.out.flush() catch {};
    terminal.restore();

    _ = watch_attach.run(app, .{ .session_id = id }) catch {};

    _ = try term.Terminal.enterRaw();
    screen.out.writeAll(term.csi ++ "?25l") catch {};
    screen.reset();
}

fn newSession(app: app_mod.App, screen: *term.Screen, terminal: term.Terminal) !void {
    screen.eraseFrame();
    screen.out.writeAll(term.csi ++ "?25h") catch {};
    screen.out.flush() catch {};
    terminal.restore();

    const cfg = try config.load(app.gpa, app.io, app.environ);
    start_cmd.run(app, .{
        .watch = true,
        .no_attach = true,
        .all = cfg.allIssues,
        .plan_mode = cfg.planMode,
        .cancel_returns = true,
    }) catch {};

    _ = try term.Terminal.enterRaw();
    screen.out.writeAll(term.csi ++ "?25l") catch {};
    screen.reset();
}

fn footer(
    out: *Io.Writer,
    cols: usize,
    rows: []const watch_table.Row,
    cursor_id: []const u8,
    confirming: bool,
) usize {
    const p = ui.palette();
    if (confirming) {
        const row = findRow(rows, cursor_id);
        out.print("  {s}kill {s}? {s}y{s} / {s}n{s}\n", .{
            p.yellow,
            if (row) |r| term.truncate(r.branch, cols -| 20) else "",
            p.bold,
            p.reset,
            p.bold,
            p.reset,
        }) catch {};
        return 1;
    }
    out.print("  {s}{s}{s}\n", .{
        p.dim,
        term.truncate("↑↓ move · enter opens · n new issue · x kill · q quit", cols -| 2),
        p.reset,
    }) catch {};
    return 1;
}

fn collect(app: app_mod.App, arena: std.mem.Allocator, now: i64) ![]watch_table.Row {
    var rows: std.ArrayList(watch_table.Row) = .empty;

    var live: []const sessions.Session = &.{};
    var stale = false;
    if (watch_client.snapshot(app) catch null) |list| {
        live = list;
    } else {
        const state = sessions.load(arena, app.io, app.environ);
        const resolved = try sessions.resolved(arena, app.io, state, now);
        const carried = try arena.alloc(sessions.Session, resolved.len);
        for (resolved, 0..) |r, i| {
            carried[i] = r.session;
            carried[i].status = @tagName(r.status);
            if (r.stale) stale = true;
        }
        live = carried;
    }

    if (app.repo()) |repo| {
        for (try app_mod.worktreeChoices(app, repo)) |choice| {
            const branch = choice.entry.branch orelse app_mod.shortHead(choice.entry.head);
            const match = findSession(live, choice.entry.path);
            try rows.append(arena, .{
                .key = choice.entry.path,
                .session_id = if (match) |m| m.id else null,
                .status = if (match) |m| m.parsedStatus() else null,
                .issue = if (match) |m| m.issue else issueOf(arena, branch),
                .branch = branch,
                .worktree = choice.entry.path,
                .last_activity_at = if (match) |m| m.last_activity_at else 0,
                .exit_code = if (match) |m| m.exit_code else null,
                .stale = stale and match != null,
            });
        }
    } else |_| {}

    for (live) |s| {
        var already = false;
        for (rows.items) |row| {
            if (std.mem.eql(u8, row.worktree, s.worktree)) already = true;
        }
        if (already) continue;
        try rows.append(arena, .{
            .key = s.worktree,
            .session_id = s.id,
            .status = s.parsedStatus(),
            .issue = s.issue,
            .branch = s.branch,
            .worktree = s.worktree,
            .last_activity_at = s.last_activity_at,
            .exit_code = s.exit_code,
            .stale = stale,
        });
    }

    return rows.toOwnedSlice(arena);
}

fn findSession(list: []const sessions.Session, worktree: []const u8) ?sessions.Session {
    for (list) |s| {
        if (std.mem.eql(u8, s.worktree, worktree)) return s;
    }
    return null;
}

fn issueOf(gpa: std.mem.Allocator, branch: []const u8) ?[]const u8 {
    const ref = linear.refFromBranch(branch) orelse return null;
    const team = std.ascii.allocUpperString(gpa, ref.team) catch return null;
    return std.fmt.allocPrint(gpa, "{s}-{d}", .{ team, ref.number }) catch null;
}

fn startForWorktree(app: app_mod.App, row: watch_table.Row) !watch_client.Started {
    var argv: std.ArrayList([]const u8) = .empty;
    if (app.repo()) |repo| {
        if (try mcp.carry(app.gpa, app.io, app.environ, repo.root)) |carried| {
            try argv.appendSlice(app.gpa, &.{ "--mcp-config", carried.path });
        }
    } else |_| {}
    if (claude_projects.hasSessionsFor(app.gpa, app.io, app.environ, row.worktree)) {
        try argv.append(app.gpa, "--resume");
    }

    return watch_client.startSession(app, .{
        .worktree = row.worktree,
        .branch = row.branch,
        .issue = row.issue,
        .repo_root = if (app.repo()) |r| r.root else |_| row.worktree,
        .program = try claude.resolvePath(app.gpa, app.io),
        .argv = argv.items,
    });
}

fn kill(app: app_mod.App, id: []const u8) void {
    var conn = (watch_client.connectExisting(app, .control) catch null) orelse return;
    defer conn.close(app.io);
    conn.sendControl(app.gpa, .kill, .{ .session_id = id, .signal = "TERM" }) catch {};
}

fn findRow(rows: []const watch_table.Row, key: []const u8) ?watch_table.Row {
    for (rows) |row| {
        if (std.mem.eql(u8, row.key, key)) return row;
    }
    return null;
}

pub fn step(rows: []const watch_table.Row, key: []const u8, delta: i2) []const u8 {
    if (rows.len == 0) return "";
    var at: usize = 0;
    for (rows, 0..) |row, i| {
        if (std.mem.eql(u8, row.key, key)) at = i;
    }
    const next = if (delta < 0)
        (if (at == 0) rows.len - 1 else at - 1)
    else
        (if (at + 1 >= rows.len) 0 else at + 1);
    return rows[next].key;
}

fn copyId(buf: []u8, id: []const u8) []const u8 {
    const take = @min(buf.len, id.len);
    @memcpy(buf[0..take], id[0..take]);
    return buf[0..take];
}

pub fn hook(app: app_mod.App, opts: HookOpts) !void {
    const event = opts.event orelse return;

    var buf: [64 * 1024]u8 = undefined;
    var reader = Io.File.stdin().reader(app.io, &buf);
    const raw = reader.interface.allocRemaining(app.gpa, .limited(buf.len)) catch return;

    const payload = watch_hooks.parsePayload(app.gpa, raw) orelse return;
    if (payload.cwd.len == 0) return;

    watch_client.report(app, opts.socket, payload.cwd, payload.session_id, event, payload.permission_mode);
}

test "the --json keys name sessions, never the process behind them" {
    const gpa = std.testing.allocator;

    const body = try snapshotJson(gpa, &.{}, true, false);
    defer gpa.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"sessions_live\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"outdated_build\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"sessions\"") != null);

    try std.testing.expect(std.mem.indexOf(u8, body, "daemon") == null);
}

test "an empty snapshot still carries both flags, rather than dropping them" {
    const gpa = std.testing.allocator;

    const body = try snapshotJson(gpa, &.{}, false, false);
    defer gpa.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"sessions_live\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"outdated_build\": false") != null);
}
