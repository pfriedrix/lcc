const std = @import("std");
const Io = std.Io;
const sessions = @import("sessions.zig");
const term = @import("term.zig");
const ui = @import("ui.zig");

pub const Row = struct {
    key: []const u8,
    session_id: ?[]const u8,
    status: ?sessions.Status,
    issue: ?[]const u8,
    branch: []const u8,
    worktree: []const u8,
    last_activity_at: i64,
    exit_code: ?i32,
    stale: bool,

    pub fn attachable(self: Row) bool {
        if (self.session_id == null) return false;
        return switch (self.status orelse return false) {
            .starting, .active, .plan, .waiting, .idle => true,
            .exited, .unknown => false,
        };
    }
};

fn glyph(status: ?sessions.Status) []const u8 {
    return switch (status orelse return "·") {
        .waiting => "●",
        .active => "◐",
        .plan => "◈",
        .idle => "○",
        .starting => "◌",
        .exited => "✗",
        .unknown => "?",
    };
}

fn paint(status: ?sessions.Status, palette: ui.Palette) []const u8 {
    return switch (status orelse return palette.dim) {
        .waiting => palette.yellow,
        .active => palette.green,
        .plan => palette.cyan,
        .exited => palette.red,
        .idle, .starting, .unknown => palette.dim,
    };
}

pub const Widths = struct {
    issue: usize = 0,
    status: usize = 0,
    branch: usize = 0,
    age: usize = 0,
    worktree: usize = 0,

    pub fn total(self: Widths) usize {
        var out: usize = 2;
        var first = true;
        inline for (@typeInfo(Widths).@"struct".fields) |field| {
            const w = @field(self, field.name);
            if (w > 0) {
                if (!first) out += 2;
                out += w;
                first = false;
            }
        }
        return out;
    }
};

const headers = .{ .issue = "ISSUE", .status = "STATUS", .branch = "BRANCH", .age = "AGE", .worktree = "WORKTREE" };

pub fn measure(rows: []const Row) Widths {
    var w: Widths = .{
        .issue = headers.issue.len,
        .status = headers.status.len,
        .branch = headers.branch.len,
        .age = headers.age.len,
        .worktree = headers.worktree.len,
    };
    for (rows) |row| {
        w.issue = @max(w.issue, ui.displayWidth(row.issue orelse "—"));
        w.status = @max(w.status, ui.displayWidth(statusText(row.status)) + 2);
        w.branch = @max(w.branch, ui.displayWidth(row.branch));
        w.worktree = @max(w.worktree, ui.displayWidth(row.worktree));
    }
    return w;
}

pub const drop_order = [_][]const u8{ "worktree", "age", "issue" };

const branch_floor = 12;

pub fn fit(widths: Widths, cols: usize) Widths {
    var out = widths;
    if (out.total() <= cols) return out;

    inline for (drop_order) |name| {
        if (out.total() > cols) @field(out, name) = 0;
    }

    if (out.total() > cols) {
        const over = out.total() - cols;
        out.branch = if (out.branch > over + branch_floor) out.branch - over else branch_floor;
    }
    return out;
}

pub fn tooNarrow(widths: Widths, cols: usize) bool {
    return fit(widths, cols).total() > cols;
}

pub fn render(
    out: *Io.Writer,
    rows: []const Row,
    widths: Widths,
    cols: usize,
    cursor_id: []const u8,
    now: i64,
) usize {
    const p = ui.palette();
    if (tooNarrow(widths, cols)) return renderNarrow(out, rows, cols, cursor_id, p);

    var lines: usize = 0;
    writeRow(out, cols, "  ", p.dim, headerCells(widths), p.reset);
    lines += 1;

    var age_buf: [16]u8 = undefined;
    for (rows) |row| {
        const selected = std.mem.eql(u8, row.key, cursor_id);
        const gutter = if (selected) "❯ " else "  ";
        const age = if (row.last_activity_at == 0)
            "—"
        else
            std.fmt.bufPrint(&age_buf, "{f}", .{ui.age(now - row.last_activity_at)}) catch "—";

        var cells: [5]Cell = .{
            .{ .text = row.issue orelse "—", .width = widths.issue, .colour = "" },
            .{ .text = "", .width = widths.status, .colour = paint(row.status, p) },
            .{ .text = row.branch, .width = widths.branch, .colour = if (selected) p.bold else "" },
            .{ .text = age, .width = widths.age, .colour = p.dim },
            .{ .text = row.worktree, .width = widths.worktree, .colour = p.dim },
        };
        var status_buf: [64]u8 = undefined;
        cells[1].text = std.fmt.bufPrint(&status_buf, "{s} {s}{s}", .{
            glyph(row.status),
            statusText(row.status),
            if (row.stale) "~" else "",
        }) catch statusText(row.status);

        writeRow(out, cols, gutter, "", &cells, p.reset);
        lines += 1;
    }
    return lines;
}

pub fn statusText(status: ?sessions.Status) []const u8 {
    return if (status) |s| @tagName(s) else "no session";
}

const Cell = struct { text: []const u8, width: usize, colour: []const u8 };

fn headerCells(widths: Widths) []const Cell {
    const S = struct {
        var cells: [5]Cell = undefined;
    };
    S.cells = .{
        .{ .text = headers.issue, .width = widths.issue, .colour = "" },
        .{ .text = headers.status, .width = widths.status, .colour = "" },
        .{ .text = headers.branch, .width = widths.branch, .colour = "" },
        .{ .text = headers.age, .width = widths.age, .colour = "" },
        .{ .text = headers.worktree, .width = widths.worktree, .colour = "" },
    };
    return &S.cells;
}

fn writeRow(out: *Io.Writer, cols: usize, gutter: []const u8, colour: []const u8, cells: []const Cell, reset: []const u8) void {
    var used: usize = 0;
    out.writeAll(gutter) catch {};
    used += ui.displayWidth(gutter);
    if (colour.len > 0) out.writeAll(colour) catch {};

    var first = true;
    for (cells) |cell| {
        if (cell.width == 0) continue;
        if (!first) {
            if (used + 2 > cols) break;
            out.writeAll("  ") catch {};
            used += 2;
        }
        first = false;
        const room = @min(cell.width, cols -| used);
        if (room == 0) break;
        const text = term.truncate(cell.text, room);
        if (cell.colour.len > 0) out.writeAll(cell.colour) catch {};
        out.writeAll(text) catch {};
        if (cell.colour.len > 0) out.writeAll(reset) catch {};
        const shown = ui.displayWidth(text);
        if (shown < cell.width) out.splatByteAll(' ', cell.width - shown) catch {};
        used += @max(shown, cell.width);
    }
    if (colour.len > 0) out.writeAll(reset) catch {};
    out.writeAll("\n") catch {};
}

fn renderNarrow(out: *Io.Writer, rows: []const Row, cols: usize, cursor_id: []const u8, p: ui.Palette) usize {
    if (cols < 12) {
        out.print("{d} sessions\n", .{rows.len}) catch {};
        return 1;
    }
    var lines: usize = 0;
    var buf: [256]u8 = undefined;
    for (rows) |row| {
        const gutter = if (std.mem.eql(u8, row.key, cursor_id)) "❯ " else "  ";
        const text = std.fmt.bufPrint(&buf, "{s} {s}", .{
            glyph(row.status),
            row.issue orelse row.branch,
        }) catch continue;
        out.print("{s}{s}{s}{s}\n", .{
            gutter,
            paint(row.status, p),
            term.truncate(text, cols -| 2),
            p.reset,
        }) catch {};
        lines += 1;
    }
    return lines;
}

const testing = std.testing;

fn testRows() []const Row {
    const S = struct {
        const rows = [_]Row{
            .{
                .key = "/r/.lcc/worktrees/pe-256",
                .session_id = "s-1",
                .issue = "PE-256",
                .branch = "feature/pe-256-app-hangs-on-launch",
                .worktree = "/r/.lcc/worktrees/pe-256",
                .status = .waiting,
                .last_activity_at = 900,
                .exit_code = null,
                .stale = true,
            },
            .{
                .key = "/r/.lcc/worktrees/other",
                .session_id = null,
                .issue = null,
                .branch = "feature/no-issue-here",
                .worktree = "/r/.lcc/worktrees/other",
                .status = null,
                .last_activity_at = 600,
                .exit_code = null,
                .stale = false,
            },
        };
    };
    return &S.rows;
}

test "measure sizes every column to its widest cell, headers included" {
    const w = measure(testRows());
    try testing.expectEqual(ui.displayWidth("feature/pe-256-app-hangs-on-launch"), w.branch);
    try testing.expectEqual(ui.displayWidth("PE-256"), w.issue);
    try testing.expectEqual(ui.displayWidth("no session") + 2, w.status);

    try testing.expectEqual(@as(usize, "AGE".len), w.age);
    const empty = measure(&.{});
    try testing.expectEqual(@as(usize, "BRANCH".len), empty.branch);
}

test "fit drops columns in order and never drops the status" {
    const full = measure(testRows());
    try testing.expect(full.total() > 60);

    try testing.expectEqual(full, fit(full, full.total()));

    const narrow = fit(full, full.total() - 1);
    try testing.expectEqual(@as(usize, 0), narrow.worktree);
    try testing.expect(narrow.status > 0);

    const narrower = fit(full, 40);
    try testing.expectEqual(@as(usize, 0), narrower.worktree);
    try testing.expectEqual(@as(usize, 0), narrower.age);

    for ([_]usize{ 120, 80, 60, 40, 20, 10 }) |cols| {
        try testing.expect(fit(full, cols).status > 0);
    }
}

test "the branch shrinks rather than the row wrapping" {
    const full = measure(testRows());
    const fitted = fit(full, 46);
    try testing.expect(fitted.branch < full.branch);
    try testing.expect(fitted.branch >= branch_floor);
}

test "render returns exactly the number of lines it drew" {
    var buf: [8192]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    ui.setColor(false);

    const rows = testRows();
    const widths = fit(measure(rows), 120);
    const lines = render(&w, rows, widths, 120, "/r/.lcc/worktrees/pe-256", 1000);

    const drawn = std.mem.count(u8, w.buffered(), "\n");
    try testing.expectEqual(drawn, lines);
    try testing.expectEqual(rows.len + 1, lines);
}

test "no rendered line is wider than the terminal, at any width" {
    const rows = testRows();
    const full = measure(rows);
    ui.setColor(false);

    for ([_]usize{ 200, 120, 80, 60, 46, 30, 20, 10 }) |cols| {
        var buf: [8192]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        const lines = render(&w, rows, fit(full, cols), cols, "/r/.lcc/worktrees/pe-256", 1000);

        var it = std.mem.splitScalar(u8, w.buffered(), '\n');
        var counted: usize = 0;
        while (it.next()) |line| {
            if (line.len == 0) continue;
            counted += 1;
            if (ui.displayWidth(line) > cols) {
                std.debug.print(
                    "at {d} cols a line is {d} wide: \"{s}\"\n",
                    .{ cols, ui.displayWidth(line), line },
                );
                return error.TestExpectedEqual;
            }
        }
        try testing.expectEqual(lines, counted);
    }
}

test "a row is attachable only when something is actually behind it" {
    var row: Row = .{
        .key = "/w",
        .session_id = "s-1",
        .status = .active,
        .issue = null,
        .branch = "b",
        .worktree = "/w",
        .last_activity_at = 0,
        .exit_code = null,
        .stale = false,
    };
    try testing.expect(row.attachable());

    row.status = .unknown;
    try testing.expect(!row.attachable());
    row.status = .exited;
    try testing.expect(!row.attachable());

    row.status = .plan;
    try testing.expect(row.attachable());

    row.status = null;
    row.session_id = null;
    try testing.expect(!row.attachable());
}

test "a status recovered from disk is read, but never offered as a session to attach to" {
    for ([_]sessions.Status{ .waiting, .idle, .plan }) |status| {
        const row: Row = .{
            .key = "/w",
            .session_id = null,
            .status = status,
            .issue = "PE-290",
            .branch = "feature/pe-290",
            .worktree = "/w",
            .last_activity_at = 900,
            .exit_code = null,
            .stale = false,
        };

        try testing.expectEqualStrings(@tagName(status), statusText(row.status));

        if (row.attachable()) {
            std.debug.print(
                "a {s} row rebuilt from a hook report offers itself for attach, but the daemon " ++
                    "that owned that pty is gone: enter would ask for a session id nothing " ++
                    "holds and come back unknown_session instead of starting the work again.\n",
                .{@tagName(status)},
            );
            return error.TestUnexpectedResult;
        }
    }
}

test "a planning row says plan, not active" {
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    ui.setColor(false);

    const rows = [_]Row{.{
        .key = "/w",
        .session_id = "s-1",
        .status = .plan,
        .issue = "PE-256",
        .branch = "feature/pe-256",
        .worktree = "/w",
        .last_activity_at = 900,
        .exit_code = null,
        .stale = false,
    }};
    _ = render(&w, &rows, fit(measure(&rows), 120), 120, "/w", 1000);

    try testing.expect(std.mem.indexOf(u8, w.buffered(), "◈ plan") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "active") == null);
}

test "a worktree with nothing running shows no age, not one measured from the epoch" {
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    ui.setColor(false);
    const rows = testRows();
    _ = render(&w, rows, fit(measure(rows), 120), 120, rows[0].key, 1_800_000_000);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "56y") == null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "—") != null);
}

test "a stale row is marked rather than silently believed" {
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    ui.setColor(false);
    const rows = testRows();
    _ = render(&w, rows, fit(measure(rows), 120), 120, "/r/.lcc/worktrees/pe-256", 1000);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "no session") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "waiting~") != null);
}

test "the selected row is the one whose id matches, not a row index" {
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    ui.setColor(false);
    const rows = testRows();
    _ = render(&w, rows, fit(measure(rows), 120), 120, "/r/.lcc/worktrees/other", 1000);

    var it = std.mem.splitScalar(u8, w.buffered(), '\n');
    _ = it.next();
    const first = it.next().?;
    const second = it.next().?;
    try testing.expect(!std.mem.startsWith(u8, first, "❯"));
    try testing.expect(std.mem.startsWith(u8, second, "❯"));
}
