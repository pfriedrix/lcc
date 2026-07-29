//! `lcc stats` — what every worktree in this repo has spent on Claude Code.
//!
//! One row per worktree, drawn from the transcripts whose cwd is that worktree.
//! `--models` breaks each row down by the model that did the work, which is the
//! dimension that explains a bill: the context tokens dominate the total, and
//! they are priced per model.
//!
//! Worktrees with no transcripts are still listed. "This one has cost nothing
//! yet" is an answer, and a row that silently vanished would look like a bug.

const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const cp = @import("../claude_projects.zig");
const ui = @import("../ui.zig");
const usage = @import("../usage.zig");

pub const Opts = struct {
    /// Break every worktree down by model.
    models: bool = false,
    /// Print the numbers as JSON instead of a table.
    json: bool = false,
};

const Row = struct {
    /// Branch name, or the short head when detached.
    label: []const u8,
    /// `main`, `lcc`, or nothing — where this worktree came from. Rendered under
    /// the ORIGIN column, which is only drawn when some row has one to show.
    tag: []const u8,
    path: []const u8,
    totals: usage.Totals,
};

/// Whether the ORIGIN column is worth a header and its padding. A repo whose
/// worktrees were all made by hand outside the managed prefix has nothing to put
/// there, and an empty column would only cost every row a trailing space.
fn anyTagged(rows: []const Row) bool {
    for (rows) |row| {
        if (row.tag.len > 0) return true;
    }
    return false;
}

pub fn run(app: app_mod.App, opts: Opts) !void {
    const repo = try app.repo();
    const entries = try repo.listWorktrees();
    const prefix = try app_mod.managedPrefix(app, repo);

    // One pass over `~/.claude/projects` for every worktree, rather than one per
    // worktree: `list` reads a prefix of a transcript per directory to learn
    // which cwd it belongs to.
    const cp_root = try cp.root(app.gpa, app.environ);
    const projects = try cp.list(app.gpa, app.io, cp_root);

    var scanner: usage.Scanner = .init(app.gpa, app.io, .open(app.gpa, app.io, app.environ));
    defer scanner.deinit();

    const rows = try app.gpa.alloc(Row, entries.len);
    for (entries, 0..) |entry, i| {
        rows[i] = .{
            .label = if (entry.branch) |b|
                try app.gpa.dupe(u8, b)
            else
                try std.fmt.allocPrint(app.gpa, "{s} (detached)", .{app_mod.shortHead(entry.head)}),
            .tag = if (entry.is_main)
                "main"
            else if (app_mod.isManaged(prefix, entry.path))
                "lcc"
            else
                "",
            .path = entry.path,
            .totals = try scanner.worktree(projects, entry.path),
        };
    }

    // Biggest spender first — the reason to run this command is to find it.
    std.mem.sort(Row, rows, {}, struct {
        fn lessThan(_: void, a: Row, b: Row) bool {
            return a.totals.counts.tokens() > b.totals.counts.tokens();
        }
    }.lessThan);

    if (opts.json) return renderJson(app, rows, scanner.skipped);
    try renderTable(app, rows, opts);

    if (scanner.skipped > 0) {
        app.ui.warn("{d} transcript(s) too large to read — the totals are low by whatever they hold.", .{
            scanner.skipped,
        });
    }
}

const Widths = struct {
    label: usize,
    sessions: usize,
    messages: usize,
    input: usize,
    output: usize,
    cost: usize,
    last: usize,
};

/// Column widths sized to the widest cell, header included. Model rows are
/// measured too — they are indented under the label column, so a long model
/// name can be what sets its width. `cells.models` is empty unless `--models`
/// asked for the breakdown, so there is nothing to gate on here.
fn measure(rows: []const Row, cells: []const Cells) Widths {
    var w: Widths = .{
        .label = "WORKTREE".len,
        .sessions = "SESS".len,
        .messages = "MSGS".len,
        .input = "CONTEXT".len,
        .output = "OUTPUT".len,
        .cost = "~USD".len,
        .last = "LAST".len,
    };
    for (rows, cells) |row, cell| {
        w.label = @max(w.label, ui.displayWidth(row.label));
        w.sessions = @max(w.sessions, cell.sessions.len);
        w.messages = @max(w.messages, cell.messages.len);
        w.input = @max(w.input, cell.input.len);
        w.output = @max(w.output, cell.output.len);
        w.cost = @max(w.cost, cell.cost.len);
        w.last = @max(w.last, ui.displayWidth(cell.last));
        for (cell.models) |model| {
            w.label = @max(w.label, ui.displayWidth(model.label) + model_indent);
            w.messages = @max(w.messages, model.messages.len);
            w.input = @max(w.input, model.input.len);
            w.output = @max(w.output, model.output.len);
            w.cost = @max(w.cost, model.cost.len);
        }
    }
    return w;
}

const model_indent = 2;

/// A row's numbers as text. Formatted once, then measured and printed, so the
/// widths and the cells can never disagree.
const Cells = struct {
    sessions: []const u8,
    messages: []const u8,
    input: []const u8,
    output: []const u8,
    cost: []const u8,
    last: []const u8,
    models: []const ModelCells = &.{},
};

const ModelCells = struct {
    label: []const u8,
    messages: []const u8,
    input: []const u8,
    output: []const u8,
    cost: []const u8,
};

fn format(app: app_mod.App, row: Row, opts: Opts, now: i64) !Cells {
    const gpa = app.gpa;
    if (row.totals.empty()) {
        return .{
            .sessions = "—",
            .messages = "—",
            .input = "—",
            .output = "—",
            .cost = "—",
            .last = "—",
        };
    }

    const counts = row.totals.counts;
    var cells: Cells = .{
        .sessions = try std.fmt.allocPrint(gpa, "{d}", .{row.totals.sessions}),
        .messages = try std.fmt.allocPrint(gpa, "{d}", .{counts.messages}),
        .input = try std.fmt.allocPrint(gpa, "{f}", .{ui.count(counts.contextTokens())}),
        .output = try std.fmt.allocPrint(gpa, "{f}", .{ui.count(counts.output)}),
        .cost = try formatCost(gpa, row.totals),
        .last = if (usage.epochSeconds(row.totals.last)) |at|
            try std.fmt.allocPrint(gpa, "{f}", .{ui.age(now - at)})
        else
            "—",
    };

    if (!opts.models) return cells;

    const models = try row.totals.modelsBySpend(gpa);
    const model_cells = try gpa.alloc(ModelCells, models.len);
    for (models, 0..) |model, i| {
        model_cells[i] = .{
            .label = usage.shortModel(model.name),
            .messages = try std.fmt.allocPrint(gpa, "{d}", .{model.counts.messages}),
            .input = try std.fmt.allocPrint(gpa, "{f}", .{ui.count(model.counts.contextTokens())}),
            .output = try std.fmt.allocPrint(gpa, "{f}", .{ui.count(model.counts.output)}),
            .cost = if (usage.priceFor(model.name) == null)
                "?"
            else
                try std.fmt.allocPrint(gpa, "{d:.2}", .{model.counts.cost_usd}),
        };
    }
    cells.models = model_cells;
    return cells;
}

/// A total that is missing an unpriced model's share is marked, not rounded off
/// silently.
fn formatCost(gpa: std.mem.Allocator, totals: usage.Totals) ![]const u8 {
    if (totals.unpriced) {
        return std.fmt.allocPrint(gpa, "{d:.2}+", .{totals.counts.cost_usd});
    }
    return std.fmt.allocPrint(gpa, "{d:.2}", .{totals.counts.cost_usd});
}

fn renderTable(app: app_mod.App, rows: []const Row, opts: Opts) !void {
    const now = app_mod.nowSeconds(app.io);

    const cells = try app.gpa.alloc(Cells, rows.len);
    for (rows, 0..) |row, i| cells[i] = try format(app, row, opts, now);

    var total: usage.Totals = .{};
    for (rows) |row| try total.add(app.gpa, row.totals);
    const total_cells = try format(app, .{
        .label = "TOTAL",
        .tag = "",
        .path = "",
        .totals = total,
    }, .{}, now);

    const w = measure(rows, cells);

    // The rightmost cell of a line is never padded — padding it would leave
    // trailing spaces on every row, which show up the moment output is piped or
    // pasted somewhere. Which cell that is depends on whether ORIGIN is drawn,
    // both in the header and in every row below it.
    const origin = anyTagged(rows);
    app.ui.hint("{f}  {f}  {f}  {f}  {f}  {f}  {f}{s}", .{
        ui.pad("WORKTREE", w.label),
        ui.pad("SESS", w.sessions),
        ui.pad("MSGS", w.messages),
        ui.pad("CONTEXT", w.input),
        ui.pad("OUTPUT", w.output),
        ui.pad("~USD", w.cost),
        ui.pad("LAST", if (origin) w.last else 0),
        if (origin) "  ORIGIN" else "",
    });

    for (rows, cells) |row, cell| {
        const tagged = row.tag.len > 0;
        app.ui.info("{f}  {f}  {f}  {f}  {f}  {f}  {f}{f}", .{
            ui.cyan(try pad(app.gpa, row.label, w.label)),
            ui.dim(try pad(app.gpa, cell.sessions, w.sessions)),
            ui.dim(try pad(app.gpa, cell.messages, w.messages)),
            ui.pad(cell.input, w.input),
            ui.pad(cell.output, w.output),
            ui.pad(cell.cost, w.cost),
            ui.dim(try pad(app.gpa, cell.last, if (tagged) w.last else 0)),
            ui.dim(if (tagged)
                try std.fmt.allocPrint(app.gpa, "  {s}", .{row.tag})
            else
                ""),
        });
        for (cell.models) |model| {
            const label = try std.fmt.allocPrint(app.gpa, "  {s}", .{model.label});
            app.ui.hint("{f}  {f}  {f}  {f}  {f}  {s}", .{
                ui.pad(label, w.label),
                ui.pad("", w.sessions),
                ui.pad(model.messages, w.messages),
                ui.pad(model.input, w.input),
                ui.pad(model.output, w.output),
                model.cost,
            });
        }
    }

    app.ui.hint("{f}  {f}  {f}  {f}  {f}  {s}", .{
        ui.pad("TOTAL", w.label),
        ui.pad(total_cells.sessions, w.sessions),
        ui.pad(total_cells.messages, w.messages),
        ui.pad(total_cells.input, w.input),
        ui.pad(total_cells.output, w.output),
        total_cells.cost,
    });

    app.ui.hint(
        "CONTEXT counts fresh input plus cache writes and reads; ~USD is Anthropic list price, not what a subscription bills.",
        .{},
    );
    if (total.unpriced) {
        app.ui.hint("A trailing + marks a total missing a model lcc has no price for.", .{});
    }
}

fn renderJson(app: app_mod.App, rows: []const Row, skipped: usize) !void {
    var out: std.ArrayList(u8) = .empty;
    const w = app.gpa;

    try out.appendSlice(w, "{\"worktrees\":[");
    for (rows, 0..) |row, i| {
        if (i > 0) try out.appendSlice(w, ",");
        const counts = row.totals.counts;
        try out.appendSlice(w, try std.fmt.allocPrint(w,
            \\{{"branch":{f},"path":{f},"tag":"{s}","sessions":{d},"messages":{d},"input":{d},"output":{d},"cache_write_5m":{d},"cache_write_1h":{d},"cache_read":{d},"cost_usd":{d:.4},"unpriced":{},"last":{f},"models":[
        , .{
            std.json.fmt(row.label, .{}),
            std.json.fmt(row.path, .{}),
            row.tag,
            row.totals.sessions,
            counts.messages,
            counts.input,
            counts.output,
            counts.cache_write_5m,
            counts.cache_write_1h,
            counts.cache_read,
            counts.cost_usd,
            row.totals.unpriced,
            std.json.fmt(row.totals.last, .{}),
        }));
        for (try row.totals.modelsBySpend(w), 0..) |model, j| {
            if (j > 0) try out.appendSlice(w, ",");
            try out.appendSlice(w, try std.fmt.allocPrint(w,
                \\{{"model":{f},"messages":{d},"input":{d},"output":{d},"cache_write_5m":{d},"cache_write_1h":{d},"cache_read":{d},"cost_usd":{d:.4}}}
            , .{
                std.json.fmt(model.name, .{}),
                model.counts.messages,
                model.counts.input,
                model.counts.output,
                model.counts.cache_write_5m,
                model.counts.cache_write_1h,
                model.counts.cache_read,
                model.counts.cost_usd,
            }));
        }
        try out.appendSlice(w, "]}");
    }
    try out.appendSlice(w, try std.fmt.allocPrint(w, "],\"skipped_transcripts\":{d}}}\n", .{skipped}));
    app.ui.payload("{s}", .{out.items});
}

/// `ui.pad` renders lazily, which colour wrapping cannot use — the escape has to
/// go around text of a known length.
fn pad(gpa: std.mem.Allocator, text: []const u8, width: usize) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{f}", .{ui.pad(text, width)});
}

fn testRow(label: []const u8, totals: usage.Totals) Row {
    return .{ .label = label, .tag = "", .path = "/x", .totals = totals };
}

/// A table rendered into memory, with colour off so the assertions are about
/// the layout rather than the escape codes.
fn renderToString(arena: std.mem.Allocator, rows: []const Row) ![]const u8 {
    const was_colour = ui.colorEnabled();
    ui.setColor(false);
    defer ui.setColor(was_colour);

    var out: Io.Writer.Allocating = .init(arena);
    var err: Io.Writer.Allocating = .init(arena);
    var environ: std.process.Environ.Map = .init(arena);

    try renderTable(.{
        .gpa = arena,
        .io = std.testing.io,
        .environ = &environ,
        .ui = .{ .io = std.testing.io, .out = &out.writer, .err = &err.writer },
    }, rows, .{});
    return out.writer.buffered();
}

test "the origin column is headed, and absent when no worktree has one" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spent: usage.Totals = .{ .counts = .{ .messages = 4, .output = 900 }, .sessions = 1 };

    // With a tag to show, LAST is padded so ORIGIN lines up under its header.
    const tagged = try renderToString(arena, &.{
        .{ .label = "main", .tag = "main", .path = "/x", .totals = spent },
        .{ .label = "feature/pe-1", .tag = "lcc", .path = "/y", .totals = spent },
    });
    var lines = std.mem.splitScalar(u8, tagged, '\n');
    try std.testing.expect(std.mem.endsWith(u8, lines.next().?, "LAST  ORIGIN"));
    try std.testing.expect(std.mem.endsWith(u8, lines.next().?, "  main"));
    try std.testing.expect(std.mem.endsWith(u8, lines.next().?, "  lcc"));

    // With nothing to show, the column is gone entirely — header included, and
    // no row picks up a trailing space where it used to be.
    const untagged = try renderToString(arena, &.{testRow("feature/pe-1", spent)});
    var plain = std.mem.splitScalar(u8, untagged, '\n');
    try std.testing.expect(std.mem.endsWith(u8, plain.next().?, "LAST"));
    const row = plain.next().?;
    try std.testing.expect(std.mem.indexOf(u8, row, "ORIGIN") == null);
    try std.testing.expect(!std.mem.endsWith(u8, row, " "));
}

test "measure sizes every column to its widest cell, header included" {
    const rows = [_]Row{testRow("feature/pe-256-app-hangs-on-launch", .{})};
    const cells = [_]Cells{.{
        .sessions = "9",
        .messages = "1165",
        .input = "238.8M",
        .output = "980k",
        .cost = "169.84",
        .last = "2m",
        .models = &.{.{
            .label = "haiku-4-5",
            .messages = "5",
            .input = "156k",
            .output = "1.9k",
            .cost = "0.09",
        }},
    }};

    const w = measure(&rows, &cells);
    try std.testing.expectEqual(@as(usize, "feature/pe-256-app-hangs-on-launch".len), w.label);
    try std.testing.expectEqual(@as(usize, "1165".len), w.messages);
    try std.testing.expectEqual(@as(usize, "169.84".len), w.cost);
    // Headers are the floor: both of these are wider than the cell under them.
    try std.testing.expectEqual(@as(usize, "SESS".len), w.sessions);
    try std.testing.expectEqual(@as(usize, "CONTEXT".len), w.input);

    // A cell wider than its header pushes the column out.
    var wide = cells;
    wide[0].input = "1238.8M";
    const grown = measure(&rows, &wide);
    try std.testing.expectEqual(@as(usize, "1238.8M".len), grown.input);
}

test "a model name longer than every branch still fits the label column" {
    const rows = [_]Row{testRow("x", .{})};
    const cells = [_]Cells{.{
        .sessions = "1",
        .messages = "1",
        .input = "1",
        .output = "1",
        .cost = "0.01",
        .last = "1m",
        .models = &.{.{
            .label = "some-very-long-model-id-here",
            .messages = "1",
            .input = "1",
            .output = "1",
            .cost = "0.01",
        }},
    }};

    const w = measure(&rows, &cells);
    try std.testing.expectEqual(
        @as(usize, "some-very-long-model-id-here".len + model_indent),
        w.label,
    );
}

test "an unpriced model marks the cost it could not account for" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const priced = try formatCost(arena, .{ .counts = .{ .cost_usd = 1.5 } });
    try std.testing.expectEqualStrings("1.50", priced);

    const partial = try formatCost(arena, .{ .counts = .{ .cost_usd = 1.5 }, .unpriced = true });
    try std.testing.expectEqualStrings("1.50+", partial);
}
