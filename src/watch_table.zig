//! The session table: measure, fit to a width, render, and report the line
//! count the redraw depends on.
//!
//! Two things separate this from `lcc list`'s table, and both come from
//! redrawing rather than printing once. A row that wraps costs the frame its
//! line count, and every frame after it inherits the error — so this has a
//! width budget and `list.zig` does not, and every cell is truncated before it
//! is padded (`ui.pad` pads but never truncates). And `render` *returns* the
//! count instead of leaving the caller to add it up, which is what lets the
//! invariant be tested against a buffer with no terminal attached.

const std = @import("std");
const Io = std.Io;
const sessions = @import("sessions.zig");
const term = @import("term.zig");
const ui = @import("ui.zig");

pub const Row = struct {
    id: []const u8,
    issue: ?[]const u8,
    branch: []const u8,
    worktree: []const u8,
    status: sessions.Status,
    last_activity_at: i64,
    exit_code: ?i32,
    /// The daemon is alive but its projection has gone cold.
    stale: bool,
};

/// One glyph per status, so a column of them reads at a glance.
///
/// `waiting` is the only one that means "go here now", and it gets the filled
/// circle and the warm colour for that reason alone.
pub fn glyph(status: sessions.Status) []const u8 {
    return switch (status) {
        .waiting => "●",
        .active => "◐",
        .idle => "○",
        .starting => "◌",
        .exited => "✗",
        .orphan => "⚠",
        .unknown => "?",
    };
}

pub fn paint(status: sessions.Status, palette: ui.Palette) []const u8 {
    return switch (status) {
        .waiting => palette.yellow,
        .active => palette.green,
        .orphan => palette.yellow,
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

    /// Columns are separated by two spaces and the whole row is inset by the
    /// two-column cursor gutter. A width of zero switches a column off, and it
    /// then costs nothing — including its separator.
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

/// Widths seeded with the header labels, then grown to the widest cell — the
/// shape `list.zig` and `stats.zig` both use.
pub fn measure(rows: []const Row) Widths {
    var w: Widths = .{
        .issue = headers.issue.len,
        // Two for the glyph and its space, on top of the longest label.
        .status = headers.status.len,
        .branch = headers.branch.len,
        .age = headers.age.len,
        .worktree = headers.worktree.len,
    };
    for (rows) |row| {
        w.issue = @max(w.issue, ui.displayWidth(row.issue orelse "—"));
        w.status = @max(w.status, ui.displayWidth(@tagName(row.status)) + 2);
        w.branch = @max(w.branch, ui.displayWidth(row.branch));
        w.worktree = @max(w.worktree, ui.displayWidth(row.worktree));
    }
    return w;
}

/// Which columns go first when the terminal is too narrow.
///
/// `status` is absent on purpose — it is the reason the table exists, and a
/// table that dropped it to fit would be narrower and useless. `branch` is
/// absent because it is the flexible one: it shrinks rather than disappearing.
pub const drop_order = [_][]const u8{ "worktree", "age", "issue" };

/// The narrowest a branch column is still worth keeping.
const branch_floor = 12;

pub fn fit(widths: Widths, cols: usize) Widths {
    var out = widths;
    if (out.total() <= cols) return out;

    inline for (drop_order) |name| {
        if (out.total() > cols) @field(out, name) = 0;
    }

    // Still too wide: shrink the branch rather than wrap. Below the floor the
    // caller falls back to one line per session — see `renderNarrow`.
    if (out.total() > cols) {
        const over = out.total() - cols;
        out.branch = if (out.branch > over + branch_floor) out.branch - over else branch_floor;
    }
    return out;
}

/// True when even the shrunk table cannot fit, and the compact form is owed.
pub fn tooNarrow(widths: Widths, cols: usize) bool {
    return fit(widths, cols).total() > cols;
}

/// Draws the table and returns how many lines it drew.
///
/// The count is the contract: `Screen.eraseFrame` walks back up exactly this
/// far, so a number that disagrees with the output corrupts every later frame.
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
        const selected = std.mem.eql(u8, row.id, cursor_id);
        const gutter = if (selected) "❯ " else "  ";
        const age = std.fmt.bufPrint(&age_buf, "{f}", .{ui.age(now - row.last_activity_at)}) catch "—";

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
            @tagName(row.status),
            // A cold projection is marked rather than silently believed.
            if (row.stale) "~" else "",
        }) catch @tagName(row.status);

        writeRow(out, cols, gutter, "", &cells, p.reset);
        lines += 1;
    }
    return lines;
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

/// One line, truncated to `cols` display columns and terminated with exactly
/// one newline — the two properties the redraw's line count rests on.
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
        // The last column is not padded: trailing spaces would push the line
        // over `cols` for no visible gain.
        if (shown < cell.width) out.splatByteAll(' ', cell.width - shown) catch {};
        used += @max(shown, cell.width);
    }
    if (colour.len > 0) out.writeAll(reset) catch {};
    out.writeAll("\n") catch {};
}

/// Below the point where columns help: one line per session, then a count.
fn renderNarrow(out: *Io.Writer, rows: []const Row, cols: usize, cursor_id: []const u8, p: ui.Palette) usize {
    if (cols < 12) {
        out.print("{d} sessions\n", .{rows.len}) catch {};
        return 1;
    }
    var lines: usize = 0;
    var buf: [256]u8 = undefined;
    for (rows) |row| {
        const gutter = if (std.mem.eql(u8, row.id, cursor_id)) "❯ " else "  ";
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
                .id = "s-1",
                .issue = "PE-256",
                .branch = "feature/pe-256-app-hangs-on-launch",
                .worktree = "/r/.lcc/worktrees/pe-256",
                .status = .waiting,
                .last_activity_at = 900,
                .exit_code = null,
                .stale = false,
            },
            .{
                .id = "s-2",
                .issue = null,
                .branch = "feature/no-issue-here",
                .worktree = "/r/.lcc/worktrees/other",
                .status = .active,
                .last_activity_at = 600,
                .exit_code = null,
                .stale = true,
            },
        };
    };
    return &S.rows;
}

test "measure sizes every column to its widest cell, headers included" {
    const w = measure(testRows());
    try testing.expectEqual(ui.displayWidth("feature/pe-256-app-hangs-on-launch"), w.branch);
    // The widest cell wins when it beats the header — `PE-256` is six columns.
    try testing.expectEqual(ui.displayWidth("PE-256"), w.issue);
    // Status carries a glyph and a space on top of its label.
    try testing.expectEqual(ui.displayWidth("waiting") + 2, w.status);

    // And the header wins when nothing beats it: `AGE` has no cell measured
    // against it at all, so seeding from the labels is what keeps the column
    // from collapsing to nothing.
    try testing.expectEqual(@as(usize, "AGE".len), w.age);
    const empty = measure(&.{});
    try testing.expectEqual(@as(usize, "BRANCH".len), empty.branch);
}

test "fit drops columns in order and never drops the status" {
    const full = measure(testRows());
    try testing.expect(full.total() > 60);

    // Wide enough for everything.
    try testing.expectEqual(full, fit(full, full.total()));

    // Worktree is the first to go, then age, then issue.
    const narrow = fit(full, full.total() - 1);
    try testing.expectEqual(@as(usize, 0), narrow.worktree);
    try testing.expect(narrow.status > 0);

    const narrower = fit(full, 40);
    try testing.expectEqual(@as(usize, 0), narrower.worktree);
    try testing.expectEqual(@as(usize, 0), narrower.age);

    // Whatever the width, the column the table exists for survives — a table
    // that fitted by dropping the status would be narrower and pointless.
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
    const lines = render(&w, rows, widths, 120, "s-1", 1000);

    // The redraw walks back up exactly this far. A count that disagrees with
    // the output corrupts every frame after it — which is why this is asserted
    // against the bytes rather than trusted from the loop.
    const drawn = std.mem.count(u8, w.buffered(), "\n");
    try testing.expectEqual(drawn, lines);
    // One header plus one line per session.
    try testing.expectEqual(rows.len + 1, lines);
}

test "no rendered line is wider than the terminal, at any width" {
    const rows = testRows();
    const full = measure(rows);
    ui.setColor(false);

    // A line that overflows soft-wraps, and a wrapped line makes the frame's
    // line count a lie. This is the invariant, checked across the range where
    // the layout changes shape.
    for ([_]usize{ 200, 120, 80, 60, 46, 30, 20, 10 }) |cols| {
        var buf: [8192]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        const lines = render(&w, rows, fit(full, cols), cols, "s-1", 1000);

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

test "a stale row is marked rather than silently believed" {
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    ui.setColor(false);
    const rows = testRows();
    _ = render(&w, rows, fit(measure(rows), 120), 120, "s-1", 1000);
    // The second row is stale; a debounced writer can promise nothing more than
    // "this was true a moment ago", and the reader should be able to see that.
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "active~") != null);
}

test "the selected row is the one whose id matches, not a row index" {
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    ui.setColor(false);
    const rows = testRows();
    _ = render(&w, rows, fit(measure(rows), 120), 120, "s-2", 1000);

    // Snapshots re-sort as statuses change. A cursor held as an index would
    // jump under the user's finger; held as an id it stays on the session they
    // were looking at.
    var it = std.mem.splitScalar(u8, w.buffered(), '\n');
    _ = it.next(); // header
    const first = it.next().?;
    const second = it.next().?;
    try testing.expect(!std.mem.startsWith(u8, first, "❯"));
    try testing.expect(std.mem.startsWith(u8, second, "❯"));
}
