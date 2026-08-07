const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const cp = @import("../claude_projects.zig");
const ui = @import("../ui.zig");
const usage = @import("../usage.zig");

pub const Opts = struct {
    models: bool = false,
    json: bool = false,
};

const Row = struct {
    label: []const u8,
    tag: []const u8,
    path: []const u8,
    totals: usage.Totals,
};

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
    active: usize,
    last: usize,
};

fn measure(rows: []const Row, cells: []const Cells) Widths {
    var w: Widths = .{
        .label = "WORKTREE".len,
        .sessions = "SESS".len,
        .messages = "MSGS".len,
        .input = "CONTEXT".len,
        .output = "OUTPUT".len,
        .cost = "~USD".len,
        .active = "ACTIVE".len,
        .last = "LAST".len,
    };
    for (rows, cells) |row, cell| {
        w.label = @max(w.label, ui.displayWidth(row.label));
        w.sessions = @max(w.sessions, cell.sessions.len);
        w.messages = @max(w.messages, cell.messages.len);
        w.input = @max(w.input, cell.input.len);
        w.output = @max(w.output, cell.output.len);
        w.cost = @max(w.cost, cell.cost.len);
        w.active = @max(w.active, ui.displayWidth(cell.active));
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

const Cells = struct {
    sessions: []const u8,
    messages: []const u8,
    input: []const u8,
    output: []const u8,
    cost: []const u8,
    active: []const u8,
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
            .active = "—",
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
        .active = try std.fmt.allocPrint(gpa, "{f}", .{
            ui.duration(try row.totals.activeSeconds(gpa)),
        }),
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

    const origin = anyTagged(rows);
    app.ui.hint("{f}  {f}  {f}  {f}  {f}  {f}  {f}  {f}{s}", .{
        ui.pad("WORKTREE", w.label),
        ui.pad("SESS", w.sessions),
        ui.pad("MSGS", w.messages),
        ui.pad("CONTEXT", w.input),
        ui.pad("OUTPUT", w.output),
        ui.pad("~USD", w.cost),
        ui.pad("ACTIVE", w.active),
        ui.pad("LAST", if (origin) w.last else 0),
        if (origin) "  ORIGIN" else "",
    });

    for (rows, cells) |row, cell| {
        const tagged = row.tag.len > 0;
        app.ui.info("{f}  {f}  {f}  {f}  {f}  {f}  {f}  {f}{f}", .{
            ui.cyan(try pad(app.gpa, row.label, w.label)),
            ui.dim(try pad(app.gpa, cell.sessions, w.sessions)),
            ui.dim(try pad(app.gpa, cell.messages, w.messages)),
            ui.pad(cell.input, w.input),
            ui.pad(cell.output, w.output),
            ui.pad(cell.cost, w.cost),
            ui.pad(cell.active, w.active),
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

    app.ui.hint("{f}  {f}  {f}  {f}  {f}  {f}  {s}", .{
        ui.pad("TOTAL", w.label),
        ui.pad(total_cells.sessions, w.sessions),
        ui.pad(total_cells.messages, w.messages),
        ui.pad(total_cells.input, w.input),
        ui.pad(total_cells.output, w.output),
        ui.pad(total_cells.cost, w.cost),
        total_cells.active,
    });

    app.ui.hint(
        "CONTEXT counts fresh input plus cache writes and reads; ~USD is Anthropic list price, not what a subscription bills.",
        .{},
    );
    app.ui.hint("ACTIVE is time worked, not elapsed — a gap over {f} is a break and counts for nothing.", .{
        ui.duration(usage.idle_gap_seconds),
    });
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
            \\{{"branch":{f},"path":{f},"tag":"{s}","sessions":{d},"messages":{d},"input":{d},"output":{d},"cache_write_5m":{d},"cache_write_1h":{d},"cache_read":{d},"cost_usd":{d:.4},"unpriced":{},"last":{f},"active_seconds":{d},"models":[
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
            try row.totals.activeSeconds(w),
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
    try out.appendSlice(w, try std.fmt.allocPrint(
        w,
        "],\"skipped_transcripts\":{d},\"idle_gap_seconds\":{d}}}\n",
        .{ skipped, usage.idle_gap_seconds },
    ));
    app.ui.payload("{s}", .{out.items});
}

fn pad(gpa: std.mem.Allocator, text: []const u8, width: usize) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{f}", .{ui.pad(text, width)});
}

fn testRow(label: []const u8, totals: usage.Totals) Row {
    return .{ .label = label, .tag = "", .path = "/x", .totals = totals };
}

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

    const tagged = try renderToString(arena, &.{
        .{ .label = "main", .tag = "main", .path = "/x", .totals = spent },
        .{ .label = "feature/pe-1", .tag = "lcc", .path = "/y", .totals = spent },
    });
    var lines = std.mem.splitScalar(u8, tagged, '\n');
    try std.testing.expect(std.mem.endsWith(u8, lines.next().?, "LAST  ORIGIN"));
    try std.testing.expect(std.mem.endsWith(u8, lines.next().?, "  main"));
    try std.testing.expect(std.mem.endsWith(u8, lines.next().?, "  lcc"));

    const untagged = try renderToString(arena, &.{testRow("feature/pe-1", spent)});
    var plain = std.mem.splitScalar(u8, untagged, '\n');
    try std.testing.expect(std.mem.endsWith(u8, plain.next().?, "LAST"));
    const row = plain.next().?;
    try std.testing.expect(std.mem.indexOf(u8, row, "ORIGIN") == null);
    try std.testing.expect(!std.mem.endsWith(u8, row, " "));
}

test "the active column reports time worked, between ~USD and LAST" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var totals: usage.Totals = .{ .counts = .{ .messages = 3, .output = 900 }, .sessions = 1 };
    const t0: i64 = 1_800_000_000;
    for ([_]i64{ t0, t0 + 4 * 60, t0 + 10 * 60 }) |at| try totals.stamps.append(arena, at);

    const table = try renderToString(arena, &.{testRow("feature/pe-1", totals)});
    var lines = std.mem.splitScalar(u8, table, '\n');

    const header = lines.next().?;
    const cost_at = std.mem.indexOf(u8, header, "~USD").?;
    const active_at = std.mem.indexOf(u8, header, "ACTIVE").?;
    const last_at = std.mem.indexOf(u8, header, "LAST").?;
    try std.testing.expect(cost_at < active_at and active_at < last_at);

    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "10m") != null);

    const untouched = try renderToString(arena, &.{testRow("feature/pe-2", .{})});
    var idle = std.mem.splitScalar(u8, untouched, '\n');
    _ = idle.next();
    try std.testing.expect(std.mem.indexOf(u8, idle.next().?, "0m") == null);
}

test "measure sizes every column to its widest cell, header included" {
    const rows = [_]Row{testRow("feature/pe-256-app-hangs-on-launch", .{})};
    const cells = [_]Cells{.{
        .sessions = "9",
        .messages = "1165",
        .input = "238.8M",
        .output = "980k",
        .cost = "169.84",
        .active = "9h40m",
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
    try std.testing.expectEqual(@as(usize, "SESS".len), w.sessions);
    try std.testing.expectEqual(@as(usize, "CONTEXT".len), w.input);

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
        .active = "1m",
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
