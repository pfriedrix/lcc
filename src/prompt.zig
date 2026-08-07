const std = @import("std");
const Io = std.Io;
const fold = @import("fold.zig");
const term_mod = @import("term.zig");
const ui = @import("ui.zig");

pub const Error = term_mod.Error || std.mem.Allocator.Error;

pub const Item = struct {
    label: []const u8,
    haystack: []const u8 = "",
    description: []const u8 = "",
};

const csi = term_mod.csi;
const Terminal = term_mod.Terminal;
const readKey = term_mod.readKey;
const truncate = term_mod.truncate;

fn pageSize(term: Terminal) usize {
    const rows = term.size().rows;
    return @max(@as(usize, 5), @min(@as(usize, 30), rows -| 4));
}

fn score(haystack: []const u8, query: []const u8) ?i32 {
    var total: i32 = 0;
    var tokens = std.mem.tokenizeAny(u8, query, " \t");
    while (tokens.next()) |token| {
        const at = fold.indexOf(haystack, token) orelse return null;
        total += if (at == 0)
            100
        else if (startsWord(haystack, at))
            50
        else
            10;
    }
    return total;
}

fn startsWord(haystack: []const u8, at: usize) bool {
    if (at == 0) return true;
    return switch (haystack[at - 1]) {
        ' ', '\t', '-', '_', '/', '.', ',', ':', ';', '(', ')', '[', ']', '"', '\'' => true,
        else => false,
    };
}

const Ranked = struct {
    index: usize,
    score: i32,

    fn better(_: void, a: Ranked, b: Ranked) bool {
        if (a.score != b.score) return a.score > b.score;
        return a.index < b.index;
    }
};

test "a confirmation answers to the key, not to the letter it printed" {
    try std.testing.expectEqual(@as(u8, 'y'), term_mod.layoutKey(firstCodepoint("н")).?);
    try std.testing.expectEqual(@as(u8, 'n'), term_mod.layoutKey(firstCodepoint("т")).?);
    try std.testing.expectEqual(@as(u8, 'y'), term_mod.layoutKey(firstCodepoint("y")).?);
    try std.testing.expectEqual(@as(u8, 'n'), term_mod.layoutKey(firstCodepoint("N")).?);
    try std.testing.expect(term_mod.layoutKey(firstCodepoint("ю")) != 'y');
}

test "every token must match" {
    const hay = "PE-247 Fix EXC_BAD_ACCESS data race feature/pe-247 Todo";
    try std.testing.expect(score(hay, "fix race") != null);
    try std.testing.expect(score(hay, "fix nonsense") == null);
    try std.testing.expectEqual(@as(?i32, 0), score(hay, ""));
}

test "cyrillic query matches an uppercase title" {
    const hay = "PE-300 ВИПРАВИТИ ПАДІННЯ КАРТИ feature/pe-300 Todo";
    try std.testing.expect(score(hay, "виправити") != null);
    try std.testing.expect(score(hay, "ПАДІННЯ") != null);
    try std.testing.expect(score(hay, "карти падіння") != null);
}

test "identifier beats word start beats mid-word" {
    const identifier = "PE-247 Fix a thing";
    const word_start = "PE-100 Something pe-ish here";
    const mid_word = "PE-100 Nope typewriter";

    try std.testing.expectEqual(@as(?i32, 100), score(identifier, "PE-247"));
    try std.testing.expectEqual(@as(?i32, 50), score(word_start, "pe-i"));
    try std.testing.expectEqual(@as(?i32, 10), score(mid_word, "pew"));
}

test "ranking puts the identifier match first and is stable otherwise" {
    var items = [_]Ranked{
        .{ .index = 0, .score = 10 },
        .{ .index = 1, .score = 100 },
        .{ .index = 2, .score = 10 },
        .{ .index = 3, .score = 50 },
    };
    std.mem.sort(Ranked, &items, {}, Ranked.better);
    try std.testing.expectEqual(@as(usize, 1), items[0].index);
    try std.testing.expectEqual(@as(usize, 3), items[1].index);
    try std.testing.expectEqual(@as(usize, 0), items[2].index);
    try std.testing.expectEqual(@as(usize, 2), items[3].index);
}

fn popCodepoint(buf: *std.ArrayList(u8)) void {
    if (buf.items.len == 0) return;
    var i = buf.items.len - 1;
    while (i > 0 and (buf.items[i] & 0xC0) == 0x80) i -= 1;
    buf.shrinkRetainingCapacity(i);
}

const Screen = term_mod.Screen;

pub fn search(
    gpa: std.mem.Allocator,
    io: Io,
    message: []const u8,
    items: []const Item,
) Error!?usize {
    if (items.len == 0) return null;

    const term = try Terminal.enterRaw();
    defer term.restore();

    const p = ui.palette();

    var out_buffer: [32 * 1024]u8 = undefined;
    var out_writer: Io.File.Writer = .init(.stdout(), io, &out_buffer);
    var screen: Screen = .{ .out = &out_writer.interface };
    const out = screen.out;

    out.writeAll(csi ++ "?25l") catch {};
    defer {
        out.writeAll(csi ++ "?25h") catch {};
        out.flush() catch {};
    }

    var query: std.ArrayList(u8) = .empty;
    var filtered: std.ArrayList(usize) = .empty;
    var ranked: std.ArrayList(Ranked) = .empty;
    for (items, 0..) |_, i| try filtered.append(gpa, i);

    var cursor: usize = 0;
    var offset: usize = 0;
    var key_buf: [8]u8 = undefined;

    while (true) {
        const dims = term.size();
        const page = pageSize(term);
        const width: usize = @max(@as(usize, 20), dims.cols);

        if (cursor >= filtered.items.len) cursor = filtered.items.len -| 1;
        if (cursor < offset) offset = cursor;
        if (cursor >= offset + page) offset = cursor + 1 - page;
        if (filtered.items.len <= page) offset = 0;

        screen.eraseFrame();
        var lines: usize = 0;

        out.print("{s}?{s} {s} {s}{s}{s}\n", .{ p.green, p.reset, message, p.cyan, query.items, p.reset }) catch {};
        lines += 1;

        if (filtered.items.len == 0) {
            out.print("  {s}no match{s}\n", .{ p.dim, p.reset }) catch {};
            lines += 1;
        } else {
            const end = @min(offset + page, filtered.items.len);
            for (filtered.items[offset..end], offset..) |index, row| {
                const label = truncate(items[index].label, width -| 3);
                if (row == cursor) {
                    out.print("{s}❯{s} {s}{s}{s}\n", .{ p.cyan, p.reset, p.bold, label, p.reset }) catch {};
                } else {
                    out.print("  {s}\n", .{label}) catch {};
                }
                lines += 1;
            }
        }

        if (filtered.items.len > 0) {
            const description = items[filtered.items[cursor]].description;
            if (description.len > 0) {
                out.print("  {s}{s}{s}\n", .{
                    p.dim, truncate(description, width -| 3), p.reset,
                }) catch {};
                lines += 1;
            }
        }

        out.print("{s}  {d}/{d} · ↑↓ move · enter select · esc cancel{s}\n", .{
            p.dim, filtered.items.len, items.len, p.reset,
        }) catch {};
        lines += 1;

        screen.lines = lines;
        out.flush() catch {};

        var refilter = false;
        switch (readKey(term, &key_buf)) {
            .cancel => {
                screen.eraseFrame();
                return null;
            },
            .enter => {
                if (filtered.items.len == 0) continue;
                const chosen = filtered.items[cursor];
                screen.eraseFrame();
                out.print("{s}✓{s} {s}\n", .{ p.green, p.reset, items[chosen].label }) catch {};
                out.flush() catch {};
                return chosen;
            },
            .up => cursor = if (cursor == 0) filtered.items.len -| 1 else cursor - 1,
            .down => cursor = if (cursor + 1 >= filtered.items.len) 0 else cursor + 1,
            .page_up => cursor -|= page,
            .page_down => cursor = @min(cursor + page, filtered.items.len -| 1),
            .backspace => {
                if (query.items.len > 0) {
                    popCodepoint(&query);
                    refilter = true;
                }
            },
            .space => {
                try query.append(gpa, ' ');
                refilter = true;
            },
            .text => |t| {
                try query.appendSlice(gpa, t);
                refilter = true;
            },
            .ignored => {},
        }

        if (refilter) {
            ranked.clearRetainingCapacity();
            for (items, 0..) |item, i| {
                if (score(item.haystack, query.items)) |s| {
                    try ranked.append(gpa, .{ .index = i, .score = s });
                }
            }
            std.mem.sort(Ranked, ranked.items, {}, Ranked.better);

            filtered.clearRetainingCapacity();
            for (ranked.items) |entry| try filtered.append(gpa, entry.index);
            cursor = 0;
            offset = 0;
        }
    }
}

pub fn confirm(
    gpa: std.mem.Allocator,
    io: Io,
    message: []const u8,
    default_yes: bool,
) Error!?bool {
    const term = try Terminal.enterRaw();
    defer term.restore();

    const p = ui.palette();

    var out_buffer: [8 * 1024]u8 = undefined;
    var out_writer: Io.File.Writer = .init(.stdout(), io, &out_buffer);
    var screen: Screen = .{ .out = &out_writer.interface };
    const out = screen.out;

    out.writeAll(csi ++ "?25l") catch {};
    defer {
        out.writeAll(csi ++ "?25h") catch {};
        out.flush() catch {};
    }

    const hint = if (default_yes) "(Y/n)" else "(y/N)";
    var key_buf: [8]u8 = undefined;
    var typed: std.ArrayList(u8) = .empty;

    while (true) {
        screen.eraseFrame();

        var lines: usize = 0;
        out.print("{s}?{s} ", .{ p.green, p.reset }) catch {};
        var it = std.mem.splitScalar(u8, message, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) out.writeAll("\n") catch {};
            out.writeAll(line) catch {};
            lines += 1;
            first = false;
        }
        out.print(" {s}{s}{s} {s}\n", .{ p.dim, hint, p.reset, typed.items }) catch {};

        screen.lines = lines;
        out.flush() catch {};

        var answer: ?bool = null;
        switch (readKey(term, &key_buf)) {
            .cancel => {
                screen.eraseFrame();
                return null;
            },
            .enter => {
                if (typed.items.len == 0) {
                    answer = default_yes;
                } else switch (term_mod.layoutKey(firstCodepoint(typed.items)) orelse 0) {
                    'y' => answer = true,
                    'n' => answer = false,
                    else => typed.clearRetainingCapacity(),
                }
            },
            .backspace => popCodepoint(&typed),
            .text => |t| try typed.appendSlice(gpa, t),
            else => {},
        }

        if (answer) |value| {
            screen.eraseFrame();
            out.print("{s}✓{s} {s} {s}{s}{s}\n", .{
                p.green, p.reset,                    firstLine(message),
                p.cyan,  if (value) "yes" else "no", p.reset,
            }) catch {};
            out.flush() catch {};
            return value;
        }
    }
}

fn firstCodepoint(text: []const u8) []const u8 {
    if (text.len == 0) return text;
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
    return text[0..@min(len, text.len)];
}

fn firstLine(message: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, message, '\n') orelse return message;
    return message[0..nl];
}

pub fn checkbox(
    gpa: std.mem.Allocator,
    io: Io,
    message: []const u8,
    items: []const Item,
    checked_default: bool,
) Error!?[]usize {
    if (items.len == 0) return &.{};

    const term = try Terminal.enterRaw();
    defer term.restore();

    const p = ui.palette();

    var out_buffer: [32 * 1024]u8 = undefined;
    var out_writer: Io.File.Writer = .init(.stdout(), io, &out_buffer);
    var screen: Screen = .{ .out = &out_writer.interface };
    const out = screen.out;

    out.writeAll(csi ++ "?25l") catch {};
    defer {
        out.writeAll(csi ++ "?25h") catch {};
        out.flush() catch {};
    }

    const checked = try gpa.alloc(bool, items.len);
    @memset(checked, checked_default);

    var cursor: usize = 0;
    var offset: usize = 0;
    var key_buf: [8]u8 = undefined;

    while (true) {
        const dims = term.size();
        const page = pageSize(term);
        const width: usize = @max(@as(usize, 20), dims.cols);

        if (cursor < offset) offset = cursor;
        if (cursor >= offset + page) offset = cursor + 1 - page;
        if (items.len <= page) offset = 0;

        screen.eraseFrame();
        var lines: usize = 0;

        out.print("{s}?{s} {s}\n", .{ p.green, p.reset, message }) catch {};
        lines += 1;

        const end = @min(offset + page, items.len);
        for (items[offset..end], offset..) |item, row| {
            const mark = if (checked[row]) "◉" else "◯";
            const label = truncate(item.label, width -| 5);
            if (row == cursor) {
                out.print("{s}❯{s} {s} {s}{s}{s}\n", .{ p.cyan, p.reset, mark, p.bold, label, p.reset }) catch {};
            } else {
                out.print("  {s} {s}\n", .{ mark, label }) catch {};
            }
            lines += 1;
        }

        var selected: usize = 0;
        for (checked) |c| {
            if (c) selected += 1;
        }
        out.print("{s}  {d}/{d} selected · space toggles · enter confirms · esc cancel{s}\n", .{
            p.dim, selected, items.len, p.reset,
        }) catch {};
        lines += 1;

        screen.lines = lines;
        out.flush() catch {};

        switch (readKey(term, &key_buf)) {
            .cancel => {
                screen.eraseFrame();
                return null;
            },
            .enter => {
                screen.eraseFrame();
                var picked: std.ArrayList(usize) = .empty;
                for (checked, 0..) |c, i| {
                    if (c) try picked.append(gpa, i);
                }
                out.print("{s}✓{s} {s} {s}{d} selected{s}\n", .{
                    p.green, p.reset, message, p.cyan, picked.items.len, p.reset,
                }) catch {};
                out.flush() catch {};
                return try picked.toOwnedSlice(gpa);
            },
            .space => checked[cursor] = !checked[cursor],
            .up => cursor = if (cursor == 0) items.len - 1 else cursor - 1,
            .down => cursor = if (cursor + 1 >= items.len) 0 else cursor + 1,
            .page_up => cursor -|= page,
            .page_down => cursor = @min(cursor + page, items.len - 1),
            else => {},
        }
    }
}

pub fn input(
    gpa: std.mem.Allocator,
    io: Io,
    message: []const u8,
    default_value: []const u8,
) Error!?[]u8 {
    const term = try Terminal.enterRaw();
    defer term.restore();

    const p = ui.palette();

    var out_buffer: [8 * 1024]u8 = undefined;
    var out_writer: Io.File.Writer = .init(.stdout(), io, &out_buffer);
    const out = &out_writer.interface;
    defer out.flush() catch {};

    var value: std.ArrayList(u8) = .empty;
    var touched = false;
    var key_buf: [8]u8 = undefined;

    while (true) {
        const width: usize = @max(@as(usize, 20), term.size().cols);

        out.writeAll("\r" ++ csi ++ "2K") catch {};
        if (touched) {
            const shown = truncate(value.items, width -| (ui.displayWidth(message) + 4));
            out.print("{s}?{s} {s} {s}", .{ p.green, p.reset, message, shown }) catch {};
        } else {
            out.print("{s}?{s} {s} {s}{s}{s}", .{ p.green, p.reset, message, p.dim, default_value, p.reset }) catch {};
        }
        out.flush() catch {};

        switch (readKey(term, &key_buf)) {
            .cancel => {
                out.writeAll("\r" ++ csi ++ "2K") catch {};
                return null;
            },
            .enter => {
                const result = if (touched)
                    try gpa.dupe(u8, value.items)
                else
                    try gpa.dupe(u8, default_value);
                out.writeAll("\r" ++ csi ++ "2K") catch {};
                out.print("{s}✓{s} {s} {s}{s}{s}\n", .{ p.green, p.reset, message, p.cyan, result, p.reset }) catch {};
                out.flush() catch {};
                return result;
            },
            .backspace => {
                if (!touched) {
                    touched = true;
                    value.clearRetainingCapacity();
                } else {
                    popCodepoint(&value);
                }
            },
            .space => {
                touched = true;
                try value.append(gpa, ' ');
            },
            .text => |t| {
                touched = true;
                try value.appendSlice(gpa, t);
            },
            else => {},
        }
    }
}
