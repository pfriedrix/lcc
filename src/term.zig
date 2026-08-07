const std = @import("std");
const Io = std.Io;

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn isatty(fd: c_int) c_int;

pub const Error = error{NotATerminal};

pub const csi = "\x1b[";

pub const Size = struct { rows: u16, cols: u16 };

pub const Terminal = struct {
    fd: std.posix.fd_t,
    saved: std.posix.termios,
    raw: std.posix.termios,

    pub fn enterRaw() Error!Terminal {
        const fd = std.posix.STDIN_FILENO;
        if (isatty(fd) == 0) return Error.NotATerminal;
        const saved = std.posix.tcgetattr(fd) catch return Error.NotATerminal;
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.IXON = false;
        raw.iflag.BRKINT = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.PARMRK = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(fd, .NOW, raw) catch return Error.NotATerminal;
        return .{ .fd = fd, .saved = saved, .raw = raw };
    }

    pub fn restore(self: Terminal) void {
        std.posix.tcsetattr(self.fd, .FLUSH, self.saved) catch {};
    }

    pub fn readPending(self: Terminal, buf: []u8) usize {
        var poll_mode = self.raw;
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

    pub fn size(self: Terminal) Size {
        var ws: std.posix.winsize = undefined;
        if (ioctl(self.fd, std.c.T.IOCGWINSZ, &ws) == 0 and ws.row > 0) {
            return .{ .rows = ws.row, .cols = ws.col };
        }
        return .{ .rows = 24, .cols = 80 };
    }
};

pub const Key = union(enum) {
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

pub fn readKey(term: Terminal, buf: []u8) Key {
    const n = std.posix.read(term.fd, buf[0..1]) catch return .cancel;
    if (n == 0) return .cancel;
    const b = buf[0];
    switch (b) {
        0x03, 0x04 => return .cancel,
        0x0d, 0x0a => return .enter,
        0x7f, 0x08 => return .backspace,
        ' ' => return .space,
        0x1b => {
            var seq: [8]u8 = undefined;
            const got = term.readPending(&seq);
            if (got == 0) return .cancel;
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
            const seq_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
            if (seq_len > 1) {
                const extra = std.posix.read(term.fd, buf[1..seq_len]) catch 0;
                return .{ .text = buf[0 .. 1 + extra] };
            }
            return .{ .text = buf[0..1] };
        },
    }
}

const layout_pairs = [_]struct { []const u8, u8 }{
    .{ "й", 'q' },
    .{ "ц", 'w' },
    .{ "у", 'e' },
    .{ "к", 'r' },
    .{ "е", 't' },
    .{ "н", 'y' },
    .{ "г", 'u' },
    .{ "ш", 'i' },
    .{ "щ", 'o' },
    .{ "з", 'p' },
    .{ "х", '[' },
    .{ "ї", ']' },
    .{ "ф", 'a' },
    .{ "і", 's' },
    .{ "ы", 's' },
    .{ "в", 'd' },
    .{ "а", 'f' },
    .{ "п", 'g' },
    .{ "р", 'h' },
    .{ "о", 'j' },
    .{ "л", 'k' },
    .{ "д", 'l' },
    .{ "ж", ';' },
    .{ "є", '\'' },
    .{ "э", '\'' },
    .{ "я", 'z' },
    .{ "ч", 'x' },
    .{ "с", 'c' },
    .{ "м", 'v' },
    .{ "и", 'b' },
    .{ "т", 'n' },
    .{ "ь", 'm' },
    .{ "б", ',' },
    .{ "ю", '.' },
};

pub fn layoutKey(text: []const u8) ?u8 {
    if (text.len == 1) {
        const byte = text[0];
        if (byte >= 'a' and byte <= 'z') return byte;
        if (byte >= 'A' and byte <= 'Z') return byte + 32;
        if (byte >= '0' and byte <= '9') return byte;
        if (byte == '[' or byte == ']' or byte == ';' or byte == '\'' or byte == ',' or byte == '.') return byte;
        return null;
    }
    for (layout_pairs) |pair| {
        if (std.mem.eql(u8, text, pair[0])) return pair[1];
    }
    var upper_buf: [8]u8 = undefined;
    for (layout_pairs) |pair| {
        const upper = toUpperCyrillic(&upper_buf, pair[0]) orelse continue;
        if (std.mem.eql(u8, text, upper)) return pair[1];
    }
    return null;
}

fn toUpperCyrillic(buf: []u8, lower: []const u8) ?[]const u8 {
    const cp = std.unicode.utf8Decode(lower) catch return null;
    const upper: u21 = switch (cp) {
        0x0430...0x044F => cp - 0x20,
        0x0456 => 0x0406,
        0x0457 => 0x0407,
        0x0454 => 0x0404,
        else => return null,
    };
    const len = std.unicode.utf8Encode(upper, buf) catch return null;
    return buf[0..len];
}

pub fn truncate(s: []const u8, max_cols: usize) []const u8 {
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

pub const Screen = struct {
    out: *Io.Writer,
    lines: usize = 0,

    pub fn eraseFrame(self: *Screen) void {
        if (self.lines == 0) return;
        self.out.writeAll("\r") catch {};
        for (0..self.lines) |_| self.out.writeAll(csi ++ "1A" ++ csi ++ "2K") catch {};
        self.lines = 0;
    }

    pub fn reset(self: *Screen) void {
        self.out.writeAll(csi ++ "2J" ++ csi ++ "H") catch {};
        self.lines = 0;
    }
};

pub fn sanitize(w: *Io.Writer) void {
    w.writeAll(csi ++ "?1049l" ++
        csi ++ "?1000l" ++
        csi ++ "?1002l" ++
        csi ++ "?1003l" ++
        csi ++ "?1006l" ++
        csi ++ "?2004l" ++
        csi ++ "?1004l" ++
        csi ++ "?2031l" ++
        csi ++ "<u" ++
        csi ++ ">4;0m" ++
        csi ++ "r" ++
        csi ++ "?7h" ++
        csi ++ "?25h" ++
        csi ++ "0m") catch {};
}

const testing = std.testing;

test "truncate cuts on a codepoint boundary, never mid-character" {
    try testing.expectEqualStrings("abc", truncate("abcdef", 3));
    try testing.expectEqualStrings("abcdef", truncate("abcdef", 99));
    try testing.expectEqualStrings("", truncate("abcdef", 0));

    const cyrillic = "ВИПРАВИТИ";
    const cut = truncate(cyrillic, 4);
    try testing.expectEqualStrings("ВИПР", cut);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));

    try testing.expectEqualStrings("🚀", truncate("🚀🚀", 1));
    try testing.expectEqualStrings("", truncate("🚀🚀", 0));
}

test "eraseFrame walks back up exactly as far as the last frame reached" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var screen: Screen = .{ .out = &w };

    screen.eraseFrame();
    try testing.expectEqual(@as(usize, 0), w.end);

    screen.lines = 3;
    screen.eraseFrame();
    try testing.expectEqualStrings(
        "\r" ++ csi ++ "1A" ++ csi ++ "2K" ++ csi ++ "1A" ++ csi ++ "2K" ++ csi ++ "1A" ++ csi ++ "2K",
        w.buffered(),
    );
    try testing.expectEqual(@as(usize, 0), screen.lines);
}

test "reset clears the whole screen and forgets the count" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var screen: Screen = .{ .out = &w, .lines = 7 };

    screen.reset();
    try testing.expectEqualStrings(csi ++ "2J" ++ csi ++ "H", w.buffered());
    try testing.expectEqual(@as(usize, 0), screen.lines);
}

test "raw mode leaves the bytes alone, but still lets lcc's own output wrap" {
    var t: std.posix.termios = undefined;
    t.lflag = .{ .ICANON = true, .ECHO = true, .ISIG = true };
    t.iflag = .{ .ICRNL = true, .IXON = true, .BRKINT = true };
    t.oflag = .{ .OPOST = true, .ONLCR = true };

    t.lflag.ICANON = false;
    t.lflag.ECHO = false;
    t.lflag.ISIG = false;
    t.iflag.ICRNL = false;
    t.iflag.INLCR = false;
    t.iflag.IGNCR = false;
    t.iflag.IXON = false;
    t.iflag.BRKINT = false;
    t.iflag.ISTRIP = false;
    t.iflag.PARMRK = false;

    try testing.expect(!t.iflag.ICRNL);
    try testing.expect(!t.iflag.INLCR);
    try testing.expect(!t.iflag.IGNCR);
    try testing.expect(!t.iflag.IXON);
    try testing.expect(t.oflag.OPOST);
    try testing.expect(t.oflag.ONLCR);
}

test "a shortcut is a key position, not a character" {
    try testing.expectEqual(@as(u8, 'q'), layoutKey("q").?);
    try testing.expectEqual(@as(u8, 'n'), layoutKey("n").?);
    try testing.expectEqual(@as(u8, 'q'), layoutKey("Q").?);

    try testing.expectEqual(@as(u8, 'n'), layoutKey("т").?);
    try testing.expectEqual(@as(u8, 'q'), layoutKey("й").?);
    try testing.expectEqual(@as(u8, 'x'), layoutKey("ч").?);
    try testing.expectEqual(@as(u8, 'j'), layoutKey("о").?);
    try testing.expectEqual(@as(u8, 'k'), layoutKey("л").?);
    try testing.expectEqual(@as(u8, 'y'), layoutKey("н").?);

    try testing.expectEqual(@as(u8, 'n'), layoutKey("Т").?);
    try testing.expectEqual(@as(u8, 'y'), layoutKey("Н").?);

    try testing.expectEqual(@as(u8, 's'), layoutKey("і").?);
    try testing.expectEqual(@as(u8, 's'), layoutKey("ы").?);

    try testing.expectEqual(@as(u8, '3'), layoutKey("3").?);

    try testing.expect(layoutKey(" ") == null);
    try testing.expect(layoutKey("→") == null);
    try testing.expect(layoutKey("") == null);
}

test "sanitize leaves the alternate screen before anything else" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    sanitize(&w);
    const out = w.buffered();

    try testing.expect(std.mem.startsWith(u8, out, csi ++ "?1049l"));

    for ([_][]const u8{
        csi ++ "?1003l",
        csi ++ "?2004l",
        csi ++ "?25h",
        csi ++ "0m",
        csi ++ "?1004l",
        csi ++ "?2031l",
        csi ++ "<u",
        csi ++ ">4;0m",
    }) |needle| {
        try testing.expect(std.mem.indexOf(u8, out, needle) != null);
    }
}
