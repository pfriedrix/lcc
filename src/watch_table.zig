const std = @import("std");
const Io = std.Io;
const linear = @import("linear.zig");
const sessions = @import("sessions.zig");
const term = @import("term.zig");
const ui = @import("ui.zig");

pub const Row = struct {
    key: []const u8,
    session_id: ?[]const u8,
    status: ?sessions.Status,
    issue: ?[]const u8,
    branch: []const u8,
    task: []const u8 = "",
    doing: []const u8 = "",
    git: []const u8 = "",
    worktree: []const u8,
    status_at: i64 = 0,
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
    task: usize = 0,
    doing: usize = 0,
    git: usize = 0,
    age: usize = 0,

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

const headers = .{
    .issue = "ISSUE",
    .status = "STATUS",
    .task = "TASK",
    .doing = "DOING",
    .git = "GIT",
    .age = "AGE",
};

pub const task_ceiling = 36;
pub const doing_ceiling = 28;

pub fn measure(rows: []const Row, now: i64) Widths {
    var w: Widths = .{
        .issue = headers.issue.len,
        .status = headers.status.len,
        .task = headers.task.len,
        .age = headers.age.len,
    };
    var buf: [status_limit]u8 = undefined;
    var age_buf: [age_limit]u8 = undefined;
    for (rows) |row| {
        w.issue = @max(w.issue, ui.displayWidth(row.issue orelse "—"));
        w.status = @max(w.status, ui.displayWidth(statusCell(&buf, row)));
        w.task = @max(w.task, ui.displayWidth(row.task));
        w.doing = @max(w.doing, ui.displayWidth(row.doing));
        w.git = @max(w.git, ui.displayWidth(row.git));
        w.age = @max(w.age, ui.displayWidth(ageCell(&age_buf, row, now)));
    }
    w.task = @min(w.task, task_ceiling);
    w.doing = @min(w.doing, doing_ceiling);
    if (w.doing > 0) w.doing = @max(w.doing, headers.doing.len);
    if (w.git > 0) w.git = @max(w.git, headers.git.len);
    return w;
}

pub const drop_order = [_][]const u8{ "age", "git", "doing", "issue" };

const task_floor = 12;

pub fn fit(widths: Widths, cols: usize) Widths {
    var out = widths;
    if (out.total() <= cols) return out;

    shrinkTask(&out, cols);

    inline for (drop_order) |name| {
        if (out.total() > cols) @field(out, name) = 0;
    }

    shrinkTask(&out, cols);
    return out;
}

fn shrinkTask(out: *Widths, cols: usize) void {
    if (out.total() <= cols) return;
    const over = out.total() - cols;
    out.task = if (out.task > over + task_floor) out.task - over else task_floor;
}

pub const status_limit = 64;
pub const age_limit = 16;

pub fn statusCell(buf: []u8, row: Row) []const u8 {
    var w: Io.Writer = .fixed(buf);
    w.print("{s} {s}", .{ glyph(row.status), statusText(row.status) }) catch
        return statusText(row.status);
    if (row.stale) w.writeAll("~") catch {};

    const status = row.status orelse return w.buffered();
    if (status == .exited) {
        if (row.exit_code) |code| w.print(" {d}", .{code}) catch {};
    }
    return w.buffered();
}

pub fn ageCell(buf: []u8, row: Row, now: i64) []const u8 {
    if (row.status == null) return "—";
    const at = if (row.status_at > 0) row.status_at else row.last_activity_at;
    if (at == 0) return "—";
    return std.fmt.bufPrint(buf, "{f}", .{ui.age(now - at)}) catch "—";
}

pub fn taskFrom(gpa: std.mem.Allocator, branch: []const u8) []const u8 {
    const leaf = if (std.mem.lastIndexOfScalar(u8, branch, '/')) |at| branch[at + 1 ..] else branch;
    if (leaf.len == 0) return branch;
    if (verbatim(leaf)) return leaf;

    const body = withoutRef(leaf);
    const text = if (body.len == 0) leaf else body;

    const out = gpa.dupe(u8, text) catch return text;
    for (out) |*byte| {
        if (byte.* == '-' or byte.* == '_') byte.* = ' ';
    }
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

fn verbatim(leaf: []const u8) bool {
    if (std.mem.eql(u8, leaf, "master") or std.mem.eql(u8, leaf, "main")) return true;
    if (leaf.len < 7) return false;
    for (leaf) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn withoutRef(leaf: []const u8) []const u8 {
    const ref = linear.refFromBranch(leaf) orelse return leaf;

    var end: usize = 0;
    while (end < leaf.len and std.ascii.isAlphabetic(leaf[end])) end += 1;
    if (end == 0 or end >= leaf.len or leaf[end] != '-') return leaf;
    if (!std.ascii.eqlIgnoreCase(ref.team, leaf[0..end])) return leaf;

    var digits = end + 1;
    while (digits < leaf.len and std.ascii.isDigit(leaf[digits])) digits += 1;
    if (digits == end + 1) return leaf;
    if ((std.fmt.parseInt(u32, leaf[end + 1 .. digits], 10) catch return leaf) != ref.number) return leaf;

    if (digits < leaf.len and (leaf[digits] == '-' or leaf[digits] == '_')) digits += 1;
    return leaf[digits..];
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

    for (rows) |row| {
        const selected = std.mem.eql(u8, row.key, cursor_id);
        const gutter = if (selected) "❯ " else "  ";

        var status_buf: [status_limit]u8 = undefined;
        var age_buf: [age_limit]u8 = undefined;
        const cells: [6]Cell = .{
            .{ .text = row.issue orelse "—", .width = widths.issue, .colour = "" },
            .{ .text = statusCell(&status_buf, row), .width = widths.status, .colour = paint(row.status, p) },
            .{ .text = row.task, .width = widths.task, .colour = if (selected) p.bold else "" },
            .{ .text = row.doing, .width = widths.doing, .colour = p.dim },
            .{ .text = row.git, .width = widths.git, .colour = p.dim },
            .{ .text = ageCell(&age_buf, row, now), .width = widths.age, .colour = p.dim },
        };

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
        var cells: [6]Cell = undefined;
    };
    S.cells = .{
        .{ .text = headers.issue, .width = widths.issue, .colour = "" },
        .{ .text = headers.status, .width = widths.status, .colour = "" },
        .{ .text = headers.task, .width = widths.task, .colour = "" },
        .{ .text = headers.doing, .width = widths.doing, .colour = "" },
        .{ .text = headers.git, .width = widths.git, .colour = "" },
        .{ .text = headers.age, .width = widths.age, .colour = "" },
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
            row.issue orelse row.task,
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
                .task = "App hangs on launch",
                .doing = "Bash swift test",
                .git = "3 dirty ↑2",
                .worktree = "/r/.lcc/worktrees/pe-256",
                .status = .waiting,
                .status_at = 900,
                .last_activity_at = 900,
                .exit_code = null,
                .stale = true,
            },
            .{
                .key = "/r/.lcc/worktrees/other",
                .session_id = null,
                .issue = null,
                .branch = "feature/no-issue-here",
                .task = "No issue here",
                .doing = "",
                .git = "clean",
                .worktree = "/r/.lcc/worktrees/other",
                .status = null,
                .status_at = 0,
                .last_activity_at = 600,
                .exit_code = null,
                .stale = false,
            },
        };
    };
    return &S.rows;
}

test "measure sizes every column to its widest cell, headers included" {
    const w = measure(testRows(), 1000);
    try testing.expectEqual(ui.displayWidth("App hangs on launch"), w.task);
    try testing.expectEqual(ui.displayWidth("PE-256"), w.issue);
    try testing.expectEqual(ui.displayWidth("Bash swift test"), w.doing);
    try testing.expectEqual(ui.displayWidth("3 dirty ↑2"), w.git);
    try testing.expect(w.status >= ui.displayWidth("· no session"));

    const empty = measure(&.{}, 1000);
    try testing.expectEqual(@as(usize, "TASK".len), empty.task);
}

test "a column with nothing in it is not drawn at all" {
    const rows = [_]Row{.{
        .key = "/w",
        .session_id = null,
        .status = null,
        .issue = "PE-9",
        .branch = "feature/pe-9-unrelated",
        .task = "Unrelated",
        .worktree = "/w",
        .last_activity_at = 0,
        .exit_code = null,
        .stale = false,
    }};

    const w = measure(&rows, 1000);
    if (w.doing != 0 or w.git != 0) {
        std.debug.print(
            "DOING measured {d} and GIT {d} with nothing to put in either: two headers and " ++
                "four columns of separator are spent on empty cells, on exactly the narrow " ++
                "terminal where that width is what pushes TASK below its floor.\n",
            .{ w.doing, w.git },
        );
        return error.TestExpectedEqual;
    }

    var buf: [4096]u8 = undefined;
    var out: Io.Writer = .fixed(&buf);
    ui.setColor(false);
    _ = render(&out, &rows, fit(w, 120), 120, "/w", 1000);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "DOING") == null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "GIT") == null);
}

test "fit drops columns in order and never drops the status" {
    const full = measure(testRows(), 1000);
    try testing.expect(full.total() > 60);

    try testing.expectEqual(full, fit(full, full.total()));

    const narrow = fit(full, full.total() - 1);
    try testing.expectEqual(full.age, narrow.age);
    try testing.expectEqual(full.git, narrow.git);
    try testing.expectEqual(full.doing, narrow.doing);
    try testing.expect(narrow.task < full.task);
    try testing.expect(narrow.status > 0);

    const narrower = fit(full, 40);
    try testing.expectEqual(@as(usize, 0), narrower.age);
    try testing.expectEqual(@as(usize, 0), narrower.git);
    try testing.expectEqual(@as(usize, 0), narrower.doing);

    for ([_]usize{ 120, 80, 60, 40, 20, 10 }) |cols| {
        try testing.expect(fit(full, cols).status > 0);
    }
}

test "the task shrinks rather than the row wrapping" {
    const full = measure(testRows(), 1000);

    const fitted = fit(full, 30);
    try testing.expect(fitted.task < full.task);
    try testing.expect(fitted.task >= task_floor);

    const squeezed = fit(full, 18);
    try testing.expectEqual(@as(usize, task_floor), squeezed.task);
}

test "render returns exactly the number of lines it drew" {
    var buf: [8192]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    ui.setColor(false);

    const rows = testRows();
    const widths = fit(measure(rows, 1000), 120);
    const lines = render(&w, rows, widths, 120, "/r/.lcc/worktrees/pe-256", 1000);

    const drawn = std.mem.count(u8, w.buffered(), "\n");
    try testing.expectEqual(drawn, lines);
    try testing.expectEqual(rows.len + 1, lines);
}

test "no rendered line is wider than the terminal, at any width" {
    const rows = testRows();
    const full = measure(rows, 1000);
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
        .task = "B",
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
            .task = "Pe 290",
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
        .task = "Pe 256",
        .worktree = "/w",
        .last_activity_at = 900,
        .exit_code = null,
        .stale = false,
    }};
    _ = render(&w, &rows, fit(measure(&rows, 1000), 120), 120, "/w", 1000);

    try testing.expect(std.mem.indexOf(u8, w.buffered(), "◈ plan") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "active") == null);
}

test "a worktree with nothing running shows no age, not one measured from the epoch" {
    const now = 1_800_000_000;
    const rows = testRows();

    var age_buf: [age_limit]u8 = undefined;
    for (rows) |row| {
        if (row.status != null) continue;
        const cell = ageCell(&age_buf, row, now);
        if (!std.mem.eql(u8, cell, "—")) {
            std.debug.print(
                "a row with no session is dated \"{s}\" from the timestamp the last hook left " ++
                    "behind in that worktree. Nothing is running there to have been silent for " ++
                    "that long, so the number measures the epoch rather than a session, and the " ++
                    "row reads as an abandoned agent instead of an empty worktree.\n",
                .{cell},
            );
            return error.TestExpectedEqual;
        }
    }

    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    ui.setColor(false);
    _ = render(&w, rows, fit(measure(rows, now), 120), 120, rows[0].key, now);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "no session") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "—") != null);
}

test "a stale row is marked rather than silently believed" {
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    ui.setColor(false);
    const rows = testRows();
    _ = render(&w, rows, fit(measure(rows, 1000), 120), 120, "/r/.lcc/worktrees/pe-256", 1000);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "no session") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "waiting~") != null);
}

test "the selected row is the one whose id matches, not a row index" {
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    ui.setColor(false);
    const rows = testRows();
    _ = render(&w, rows, fit(measure(rows, 1000), 120), 120, "/r/.lcc/worktrees/other", 1000);

    var it = std.mem.splitScalar(u8, w.buffered(), '\n');
    _ = it.next();
    const first = it.next().?;
    const second = it.next().?;
    try testing.expect(!std.mem.startsWith(u8, first, "❯"));
    try testing.expect(std.mem.startsWith(u8, second, "❯"));
}

test "an age ten months old says months, not minutes" {
    const month = 30 * 24 * 60 * 60;
    const row: Row = .{
        .key = "/w",
        .session_id = null,
        .status = .idle,
        .issue = "PE-1",
        .branch = "feature/pe-1-old",
        .task = "Old",
        .worktree = "/w",
        .status_at = 1_000_000,
        .last_activity_at = 1_000_000,
        .exit_code = null,
        .stale = false,
    };
    const now = row.status_at + 10 * month;

    var buf: [age_limit]u8 = undefined;
    const cell = ageCell(&buf, row, now);
    try testing.expectEqualStrings("10mo", cell);

    const rows = [_]Row{row};
    const widths = measure(&rows, now);
    if (widths.age < ui.displayWidth(cell)) {
        std.debug.print(
            "the age column measured {d} for a {d}-wide cell, so `10mo` is cut to `10m` " ++
                "and ten months of silence reads as ten minutes — which is the difference " ++
                "between an abandoned worktree and a live one.\n",
            .{ widths.age, ui.displayWidth(cell) },
        );
        return error.TestExpectedEqual;
    }
}

test "a waiting row is dated from when it started waiting, not from the last hook of any kind" {
    const row: Row = .{
        .key = "/w",
        .session_id = "s-1",
        .status = .waiting,
        .issue = "PE-2",
        .branch = "feature/pe-2",
        .task = "Two",
        .worktree = "/w",
        .status_at = 1000,
        .last_activity_at = 4000,
        .exit_code = null,
        .stale = false,
    };

    var buf: [age_limit]u8 = undefined;
    const cell = ageCell(&buf, row, 4600);
    if (std.mem.indexOf(u8, cell, "1h") == null) {
        std.debug.print(
            "the cell reads \"{s}\": it is dated from the last hook of any kind rather than " ++
                "from the moment the session started waiting, so a prompt that has been up for " ++
                "an hour reads as ten minutes old every time a subagent reports in behind it.\n",
            .{cell},
        );
        return error.TestExpectedEqual;
    }
}

test "a session that fell over says so, rather than looking like one that finished" {
    var row: Row = .{
        .key = "/w",
        .session_id = "s-1",
        .status = .exited,
        .issue = "PE-3",
        .branch = "feature/pe-3",
        .task = "Three",
        .worktree = "/w",
        .status_at = 1000,
        .last_activity_at = 1000,
        .exit_code = 1,
        .stale = false,
    };

    var buf: [status_limit]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, statusCell(&buf, row), "exited 1") != null);

    row.exit_code = 0;
    try testing.expect(std.mem.indexOf(u8, statusCell(&buf, row), "exited 0") != null);
}

test "a task name drops the prefix and the issue the ISSUE column already carries" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { branch: []const u8, want: []const u8 }{
        .{ .branch = "feature/pe-256-app-hangs-on-launch", .want = "App hangs on launch" },
        .{ .branch = "fix/pe-270-crash-in-mapview", .want = "Crash in mapview" },
        .{ .branch = "chore/PE-9-tidy_up", .want = "Tidy up" },
        .{ .branch = "feature/no-issue-here", .want = "No issue here" },
        .{ .branch = "pe-301-widget-refresh", .want = "Widget refresh" },
    };

    for (cases) |case| {
        try testing.expectEqualStrings(case.want, taskFrom(arena, case.branch));
    }
}

test "a branch that is not a task name is left as it is" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "master", "main", "abcdef01" }) |branch| {
        try testing.expectEqualStrings(branch, taskFrom(arena, branch));
    }
}

test "a branch that is nothing but its issue keeps the issue rather than going blank" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = taskFrom(arena, "feature/pe-256");
    if (got.len == 0) {
        std.debug.print(
            "a branch named only for its issue produced an empty TASK: the row is then a " ++
                "status and a blank, and on a terminal narrow enough to have dropped ISSUE " ++
                "there is nothing left on it to say which worktree it is.\n",
            .{},
        );
        return error.TestExpectedEqual;
    }
    try testing.expectEqualStrings("Pe 256", got);
}


test "a long task name is cut before a column of facts is dropped" {
    const rows = [_]Row{.{
        .key = "/w",
        .session_id = "s-1",
        .status = .waiting,
        .issue = "PE-338",
        .branch = "feature/pe-338-keep-error-observation-alive-after-the-main-sheet-is",
        .task = "Keep error observation alive after the main sheet is",
        .doing = "Edit ErrorObservation.swift",
        .git = "3 dirty ↑2",
        .worktree = "/Users/me/Projects/app.worktrees/pe-338-keep-error-observation",
        .status_at = 900,
        .last_activity_at = 900,
        .exit_code = null,
        .stale = false,
    }};

    const fitted = fit(measure(&rows, 1000), 80);
    try testing.expect(fitted.total() <= 80);

    if (fitted.git == 0 or fitted.doing == 0) {
        std.debug.print(
            "at 80 columns the frame kept {d} columns of task name and dropped GIT ({d}) / " ++
                "DOING ({d}). A branch slug is prose and routinely runs past fifty characters, " ++
                "so on the terminal width most people actually use it would swallow both of the " ++
                "columns that say whether the row needs anything — to spell out a name whose " ++
                "first twenty characters already identified it.\n",
            .{ fitted.task, fitted.git, fitted.doing },
        );
        return error.TestExpectedEqual;
    }
    try testing.expect(fitted.task >= task_floor);
}

test "no column is measured wider than the share of the row it is worth" {
    const rows = [_]Row{.{
        .key = "/w",
        .session_id = "s-1",
        .status = .active,
        .issue = "PE-1",
        .branch = "feature/pe-1",
        .task = "A task name far longer than any terminal should have to spell out in full",
        .doing = "Bash a command long enough to fill a line of its own and then some more",
        .git = "clean",
        .worktree = "/w",
        .last_activity_at = 900,
        .exit_code = null,
        .stale = false,
    }};

    const w = measure(&rows, 1000);
    try testing.expectEqual(@as(usize, task_ceiling), w.task);
    try testing.expectEqual(@as(usize, doing_ceiling), w.doing);
}
