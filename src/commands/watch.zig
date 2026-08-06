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
const watch_hooks = @import("../watch_hooks.zig");

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
