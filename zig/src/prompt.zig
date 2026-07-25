//! Raw-mode terminal prompts — the `@inquirer/prompts` replacement.
//!
//! Covers the four widgets lcc uses: `search`, `confirm`, `checkbox`, `input`.
//! Cancelling (Ctrl-C or Esc) returns null; callers exit 130, as the
//! TypeScript version did on inquirer's ExitPromptError.

const std = @import("std");
const Io = std.Io;
const fold = @import("fold.zig");
const ui = @import("ui.zig");

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn isatty(fd: c_int) c_int;

pub const Error = error{NotATerminal} || std.mem.Allocator.Error;

pub const Item = struct {
    /// Rendered as-is. Must be plain text: the prompt pads and truncates it,
    /// which ANSI escapes would throw off.
    label: []const u8,
    /// Matched against the query in `search`. Ignored by the other widgets.
    haystack: []const u8 = "",
};

const csi = "\x1b[";

const Terminal = struct {
    fd: std.posix.fd_t,
    saved: std.posix.termios,

    fn enterRaw() Error!Terminal {
        const fd = std.posix.STDIN_FILENO;
        // Ask first: tcgetattr on a pipe reports ENOTTY through std's
        // "unexpected errno" path, which dumps a stack trace in debug builds.
        if (isatty(fd) == 0) return Error.NotATerminal;
        const saved = std.posix.tcgetattr(fd) catch return Error.NotATerminal;
        var raw = saved;
        // Char-at-a-time, no echo, and no signal generation — Ctrl-C arrives as
        // a byte so the terminal can be restored before exiting.
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        // NOW, not FLUSH: anything typed while the issues were still loading is
        // real input the user meant, and FLUSH would silently discard it.
        std.posix.tcsetattr(fd, .NOW, raw) catch return Error.NotATerminal;
        return .{ .fd = fd, .saved = saved };
    }

    fn restore(self: Terminal) void {
        // FLUSH on the way out, so keys pressed after the answer do not spill
        // into the shell that gets the terminal back.
        std.posix.tcsetattr(self.fd, .FLUSH, self.saved) catch {};
    }

    /// Reads whatever is already buffered, without blocking. Used to tell a
    /// bare Esc from the start of an arrow-key sequence.
    fn readPending(self: Terminal, buf: []u8) usize {
        var poll_mode = self.saved;
        poll_mode.lflag.ICANON = false;
        poll_mode.lflag.ECHO = false;
        poll_mode.lflag.ISIG = false;
        poll_mode.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        poll_mode.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(self.fd, .NOW, poll_mode) catch return 0;
        defer {
            var blocking = poll_mode;
            blocking.cc[@intFromEnum(std.posix.V.MIN)] = 1;
            std.posix.tcsetattr(self.fd, .NOW, blocking) catch {};
        }
        return std.posix.read(self.fd, buf) catch 0;
    }

    fn size(self: Terminal) struct { rows: u16, cols: u16 } {
        var ws: std.posix.winsize = undefined;
        if (ioctl(self.fd, std.c.T.IOCGWINSZ, &ws) == 0 and ws.row > 0) {
            return .{ .rows = ws.row, .cols = ws.col };
        }
        return .{ .rows = 24, .cols = 80 };
    }

    fn pageSize(self: Terminal) usize {
        const rows = self.size().rows;
        return @max(@as(usize, 5), @min(@as(usize, 30), rows -| 4));
    }
};

const Key = union(enum) {
    up,
    down,
    page_up,
    page_down,
    enter,
    backspace,
    space,
    cancel,
    text: []const u8,
    ignored,
};

fn readKey(term: Terminal, buf: []u8) Key {
    const n = std.posix.read(term.fd, buf[0..1]) catch return .cancel;
    if (n == 0) return .cancel;
    const b = buf[0];
    switch (b) {
        0x03, 0x04 => return .cancel, // Ctrl-C, Ctrl-D
        0x0d, 0x0a => return .enter,
        0x7f, 0x08 => return .backspace,
        ' ' => return .space,
        0x1b => {
            var seq: [8]u8 = undefined;
            const got = term.readPending(&seq);
            if (got == 0) return .cancel; // bare Esc
            if (got >= 2 and seq[0] == '[') {
                switch (seq[1]) {
                    'A' => return .up,
                    'B' => return .down,
                    '5' => return .page_up,
                    '6' => return .page_down,
                    else => return .ignored,
                }
            }
            return .ignored;
        },
        else => {
            if (b < 0x20) return .ignored;
            // UTF-8 continuation bytes arrive in the same read burst.
            const seq_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
            if (seq_len > 1) {
                const extra = std.posix.read(term.fd, buf[1..seq_len]) catch 0;
                return .{ .text = buf[0 .. 1 + extra] };
            }
            return .{ .text = buf[0..1] };
        },
    }
}

/// Truncates on a codepoint boundary so a narrow terminal cannot wrap a row
/// and desynchronise the redraw's line count.
fn truncate(s: []const u8, max_cols: usize) []const u8 {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (cols >= max_cols) return s[0..i];
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(len, s.len - i);
        cols += 1;
    }
    return s;
}

/// Every whitespace-separated token must appear, as in the TypeScript version.
/// The score then orders the survivors: a token landing at the very start of
/// the haystack (the issue identifier) outranks one starting a word, which
/// outranks one buried mid-word.
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

/// True when the byte before `at` is a separator rather than part of a word.
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

    /// Best score first; ties keep the order the caller supplied, which is the
    /// state-then-recency ordering the issue list arrives in.
    fn better(_: void, a: Ranked, b: Ranked) bool {
        if (a.score != b.score) return a.score > b.score;
        return a.index < b.index;
    }
};

test "every token must match" {
    const hay = "PE-247 Fix EXC_BAD_ACCESS data race feature/pe-247 Todo";
    try std.testing.expect(score(hay, "fix race") != null);
    try std.testing.expect(score(hay, "fix nonsense") == null);
    // An empty query keeps everything, at a neutral score.
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

    // Leading match on the identifier.
    try std.testing.expectEqual(@as(?i32, 100), score(identifier, "PE-247"));
    // "pe-ish" starts a word.
    try std.testing.expectEqual(@as(?i32, 50), score(word_start, "pe-i"));
    // "pe" inside "typewriter" is buried.
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
    // Equal scores keep their original relative order.
    try std.testing.expectEqual(@as(usize, 0), items[2].index);
    try std.testing.expectEqual(@as(usize, 2), items[3].index);
}

/// Drops one whole codepoint from the end of a growable buffer.
fn popCodepoint(buf: *std.ArrayList(u8)) void {
    if (buf.items.len == 0) return;
    var i = buf.items.len - 1;
    while (i > 0 and (buf.items[i] & 0xC0) == 0x80) i -= 1;
    buf.shrinkRetainingCapacity(i);
}

/// Owns the terminal for the lifetime of one prompt: raw mode, hidden cursor,
/// and in-place redraw of a known number of lines.
const Screen = struct {
    term: Terminal,
    out: *Io.Writer,
    lines: usize = 0,

    fn eraseFrame(self: *Screen) void {
        if (self.lines == 0) return;
        self.out.writeAll("\r") catch {};
        for (0..self.lines) |_| self.out.writeAll(csi ++ "1A" ++ csi ++ "2K") catch {};
        self.lines = 0;
    }
};

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
    var screen: Screen = .{ .term = term, .out = &out_writer.interface };
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
        const page = term.pageSize();
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

/// `message` may span several lines; the y/n hint goes after the last one.
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
    var screen: Screen = .{ .term = term, .out = &out_writer.interface };
    const out = screen.out;

    out.writeAll(csi ++ "?25l") catch {};
    defer {
        out.writeAll(csi ++ "?25h") catch {};
        out.flush() catch {};
    }

    const hint = if (default_yes) "(Y/n)" else "(y/N)";
    var key_buf: [8]u8 = undefined;
    // Typed, then submitted with Enter — the same two-step inquirer's confirm
    // uses, so muscle memory of "y⏎" does not leak a stray newline.
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
                } else switch (typed.items[0]) {
                    'y', 'Y' => answer = true,
                    'n', 'N' => answer = false,
                    // Anything else is not an answer: clear and ask again.
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
                p.green,                          p.reset, firstLine(message),
                p.cyan, if (value) "yes" else "no", p.reset,
            }) catch {};
            out.flush() catch {};
            return value;
        }
    }
}

fn firstLine(message: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, message, '\n') orelse return message;
    return message[0..nl];
}

/// Multi-select. Returns the indices that were checked when Enter was pressed.
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
    var screen: Screen = .{ .term = term, .out = &out_writer.interface };
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
        const page = term.pageSize();
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

/// Single-line text entry. Enter on an untouched field keeps `default_value`.
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

        // Single line — clearing and redrawing in place needs no line counting.
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
                    // First edit starts from an empty field, like inquirer's
                    // default handling.
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
