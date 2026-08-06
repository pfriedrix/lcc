//! `lcc watch` — what the daemon is running, and the handler its hooks call.
//!
//! Only the non-interactive half exists so far: `--json` is a one-shot
//! snapshot that never enters raw mode, which is both the tool-callable path
//! CLAUDE.md requires and the resolution of a conflict the interactive version
//! has — a full-screen TUI cannot write its frames through `app.ui`.

const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const sessions = @import("../sessions.zig");
const ui = @import("../ui.zig");
const watch_client = @import("../watch_client.zig");
const term = @import("../term.zig");
const watch_attach = @import("../watch_attach.zig");
const watch_hooks = @import("../watch_hooks.zig");
const watch_table = @import("../watch_table.zig");

pub const Opts = struct {
    json: bool = false,
};

/// The `lcc watch-hook` side. Deliberately a separate entry point: it is not a
/// user-facing command, it is what a Claude Code hook execs.
pub const HookOpts = struct {
    socket: ?[]const u8 = null,
    event: ?[]const u8 = null,
};

const Row = struct {
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

pub fn run(app: app_mod.App, opts: Opts) !void {
    // `--json` is a one-shot that never enters raw mode. That is both the
    // tool-callable path CLAUDE.md requires and the resolution of a real
    // conflict: a full-screen TUI cannot write its frames through `app.ui`,
    // and `ui.divert` has no meaning for one.
    if (!opts.json and Io.File.stdout().isTty(app.io) catch false) {
        return dashboard(app);
    }
    if (!opts.json and !(Io.File.stdout().isTty(app.io) catch false)) {
        // Checked before connecting, so the suggestion arrives instead of a
        // failure from somewhere further in.
        app.ui.hint("Not a terminal — use `lcc watch --json`.", .{});
    }
    return snapshotOnce(app, opts);
}

fn snapshotOnce(app: app_mod.App, opts: Opts) !void {
    // The live snapshot when a daemon is up; the on-disk projection when it is
    // not, so the answer is "nothing is running" rather than an error.
    const live = watch_client.snapshot(app) catch null;
    const now = app_mod.nowSeconds(app.io);

    if (live) |list| {
        const rows = try app.gpa.alloc(Row, list.len);
        for (list, 0..) |s, i| rows[i] = toRow(s, false);
        return emit(app, opts, rows, true, now);
    }

    const state = sessions.load(app.gpa, app.io, app.environ);
    const resolved = try sessions.resolved(app.gpa, app.io, state, now);
    const rows = try app.gpa.alloc(Row, resolved.len);
    for (resolved, 0..) |r, i| {
        var row = toRow(r.session, r.stale);
        // The reader's verdict wins over what the file claims: a dead daemon
        // makes every status unknown, and a vanished worktree makes it orphan.
        row.status = @tagName(r.status);
        rows[i] = row;
    }
    return emit(app, opts, rows, false, now);
}

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

fn emit(app: app_mod.App, opts: Opts, rows: []const Row, live: bool, now: i64) !void {
    if (opts.json) {
        const body = try std.json.Stringify.valueAlloc(app.gpa, .{
            .daemon_running = live,
            .sessions = rows,
        }, .{ .whitespace = .indent_2 });
        app.ui.payload("{s}\n", .{body});
        app.ui.flush();
        return;
    }

    if (rows.len == 0) {
        // An empty dashboard is an answer, not a failure — `stats` treats "this
        // one has cost nothing yet" the same way.
        app.ui.info("No watched sessions.", .{});
        app.ui.hint("Start one with: lcc start PE-256 --watch", .{});
        return;
    }

    if (!live) app.ui.warn("No daemon is running — showing the last recorded state.", .{});

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

/// The live dashboard.
///
/// Draw at the top, block at the bottom, recount every frame — `prompt.zig`'s
/// line discipline unchanged. Only the *trigger* for a frame differs: a
/// keystroke there, a keystroke or a second's tick here.
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

    // `app.gpa` is a process arena: a dashboard redrawing once a second for
    // eight hours would grow without bound on formatted cells alone. Nothing
    // per-frame may touch it. No other command in this repo has had to care,
    // because no other command is long-lived.
    var frame_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer frame_arena.deinit();

    // Held as an id, not an index: snapshots re-sort as statuses change, and an
    // index would move the selection under the user's finger.
    var cursor_id: []const u8 = "";
    var cursor_buf: [64]u8 = undefined;
    var confirming_kill = false;
    var key_buf: [8]u8 = undefined;
    // Tracked here rather than in a module variable: this repo has no globals,
    // and the only thing that needs it is this loop.
    var last_cols: u16 = 0;

    while (true) {
        _ = frame_arena.reset(.retain_capacity);
        const arena = frame_arena.allocator();
        const now = app_mod.nowSeconds(app.io);
        const dims = terminal.size();

        // A width change invalidates the line count: rows drawn at the old
        // width may already have wrapped.
        if (dims.cols != last_cols) {
            screen.reset();
            last_cols = dims.cols;
        }

        const rows = try collect(app, arena, now);
        if (rows.len > 0 and findRow(rows, cursor_id) == null) {
            cursor_id = copyId(&cursor_buf, rows[0].id);
        }

        screen.eraseFrame();
        var lines: usize = 0;

        const widths = watch_table.fit(watch_table.measure(rows), dims.cols);
        if (rows.len == 0) {
            out.print("  {s}No watched sessions. Start one with: lcc start PE-256 --watch{s}\n", .{
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
        // The timeout does three jobs, which is why it exists at all: it is the
        // resize tick (no SIGWINCH), the age tick (`4s` becoming `5s`, with no
        // timer machinery — this repo has none), and the staleness tick, since
        // a *wedged* daemon produces no readable event to notice it by.
        const ready = std.posix.poll(&fds, 1000) catch 0;
        if (ready == 0) continue;

        switch (term.readKey(terminal, &key_buf)) {
            .cancel => return,
            .up => cursor_id = copyId(&cursor_buf, step(rows, cursor_id, -1)),
            .down => cursor_id = copyId(&cursor_buf, step(rows, cursor_id, 1)),
            .enter => {
                if (findRow(rows, cursor_id)) |row| {
                    try attachTo(app, &screen, terminal, row.id);
                }
            },
            .text => |t| {
                if (t.len != 1) continue;
                if (confirming_kill) {
                    confirming_kill = false;
                    if (t[0] == 'y') kill(app, cursor_id);
                    continue;
                }
                switch (t[0]) {
                    'q' => return,
                    'j' => cursor_id = copyId(&cursor_buf, step(rows, cursor_id, 1)),
                    'k' => cursor_id = copyId(&cursor_buf, step(rows, cursor_id, -1)),
                    // Two keys, inline, rather than a nested raw-mode widget —
                    // the terminal is already owned and re-entering it for a
                    // yes/no would be a second redraw discipline to keep right.
                    'x' => confirming_kill = findRow(rows, cursor_id) != null,
                    'r' => {},
                    '1'...'9' => {
                        const index = t[0] - '1';
                        if (index < rows.len) {
                            cursor_id = copyId(&cursor_buf, rows[index].id);
                            try attachTo(app, &screen, terminal, rows[index].id);
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

/// Leaving and re-entering cleanly around a passthrough: the dashboard's frame
/// is erased first so the session starts on a clean screen, and the count is
/// dropped so the next frame does not try to walk back over the agent's output.
fn attachTo(app: app_mod.App, screen: *term.Screen, terminal: term.Terminal, id: []const u8) !void {
    screen.eraseFrame();
    screen.out.writeAll(term.csi ++ "?25h") catch {};
    screen.out.flush() catch {};
    terminal.restore();

    _ = watch_attach.run(app, .{ .session_id = id }) catch {};

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
        term.truncate("↑↓ move · enter attach · x kill · q quit (sessions keep running)", cols -| 2),
        p.reset,
    }) catch {};
    return 1;
}

fn collect(app: app_mod.App, arena: std.mem.Allocator, now: i64) ![]watch_table.Row {
    const live = watch_client.snapshot(app) catch null;
    if (live) |list| {
        const rows = try arena.alloc(watch_table.Row, list.len);
        for (list, 0..) |s, i| rows[i] = .{
            .id = s.id,
            .issue = s.issue,
            .branch = s.branch,
            .worktree = s.worktree,
            .status = s.parsedStatus(),
            .last_activity_at = s.last_activity_at,
            .exit_code = s.exit_code,
            .stale = false,
        };
        return rows;
    }

    const state = sessions.load(arena, app.io, app.environ);
    const resolved = try sessions.resolved(arena, app.io, state, now);
    const rows = try arena.alloc(watch_table.Row, resolved.len);
    for (resolved, 0..) |r, i| rows[i] = .{
        .id = r.session.id,
        .issue = r.session.issue,
        .branch = r.session.branch,
        .worktree = r.session.worktree,
        .status = r.status,
        .last_activity_at = r.session.last_activity_at,
        .exit_code = r.session.exit_code,
        .stale = r.stale,
    };
    return rows;
}

fn kill(app: app_mod.App, id: []const u8) void {
    var conn = (watch_client.connectExisting(app, .control) catch null) orelse return;
    defer conn.close(app.io);
    conn.sendControl(app.gpa, .kill, .{ .session_id = id, .signal = "TERM" }) catch {};
}

fn findRow(rows: []const watch_table.Row, id: []const u8) ?watch_table.Row {
    for (rows) |row| {
        if (std.mem.eql(u8, row.id, id)) return row;
    }
    return null;
}

/// The neighbouring session's id, wrapping. Pure, so the wrap is testable.
pub fn step(rows: []const watch_table.Row, id: []const u8, delta: i2) []const u8 {
    if (rows.len == 0) return "";
    var at: usize = 0;
    for (rows, 0..) |row, i| {
        if (std.mem.eql(u8, row.id, id)) at = i;
    }
    const next = if (delta < 0)
        (if (at == 0) rows.len - 1 else at - 1)
    else
        (if (at + 1 >= rows.len) 0 else at + 1);
    return rows[next].id;
}

/// The cursor outlives the arena its row came from, so its id is copied into a
/// buffer that does not get reset with the frame.
fn copyId(buf: []u8, id: []const u8) []const u8 {
    const take = @min(buf.len, id.len);
    @memcpy(buf[0..take], id[0..take]);
    return buf[0..take];
}

/// What a Claude Code hook execs. Reads the hook payload on stdin, forwards it
/// to the daemon, and exits zero whatever happened.
///
/// **Always zero.** This runs on every turn of every watched session; a handler
/// that could fail would be a handler that could disturb the work it is only
/// meant to observe.
pub fn hook(app: app_mod.App, opts: HookOpts) !void {
    const event = opts.event orelse return;

    var buf: [64 * 1024]u8 = undefined;
    var reader = Io.File.stdin().reader(app.io, &buf);
    const raw = reader.interface.allocRemaining(app.gpa, .limited(buf.len)) catch return;

    const payload = watch_hooks.parsePayload(app.gpa, raw) orelse return;
    if (payload.cwd.len == 0) return;

    watch_client.report(app, payload.cwd, payload.session_id, event);
}
