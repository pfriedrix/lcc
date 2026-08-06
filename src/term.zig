//! Raw mode, terminal size, in-place frame redraw and key decoding — the
//! mechanics `prompt.zig` kept private until a second caller needed them.
//!
//! Split out of `prompt.zig` unchanged, for `lcc watch`: a live session table
//! redraws on a schedule rather than on a keystroke, but it needs exactly the
//! same raw mode, the same line-counting erase, and the same codepoint-safe
//! truncation. Duplicating that would mean two redraw disciplines drifting
//! apart, and only one of them ever getting a fix.
//!
//! Nothing here threads `Io`. These are ioctls and reads on a tty file
//! descriptor, which `Io` has no vtable entry for; `oauth.zig`'s `waitReadable`
//! is the same call made the same way.

const std = @import("std");
const Io = std.Io;

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn isatty(fd: c_int) c_int;

pub const Error = error{NotATerminal};

pub const csi = "\x1b[";

pub const Size = struct { rows: u16, cols: u16 };

pub const Terminal = struct {
    fd: std.posix.fd_t,
    /// What to put back on the way out.
    saved: std.posix.termios,
    /// What was actually set. `readPending` used to rebuild its mode from
    /// `saved`, which quietly turned the input translation back on for the
    /// length of an escape sequence — the same flags this type exists to keep
    /// off.
    raw: std.posix.termios,

    pub fn enterRaw() Error!Terminal {
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
        // Input translation off, which "raw mode" was only pretending to be.
        //
        // `ICRNL` is the one that mattered and the one that hid: the line
        // discipline turns the CR the terminal sends for Enter into an NL
        // before anyone reads it. The pickers never noticed, because `readKey`
        // treats both as `.enter`. But `lcc watch` forwards these bytes
        // verbatim to another program, and Claude Code's resume picker acts on
        // CR and ignores NL — so every key worked there except Enter, which is
        // exactly the shape of a translation that touches one byte and no
        // others.
        //
        // `IXON` goes too, so Ctrl-S and Ctrl-Q reach the agent instead of
        // freezing the terminal on the way.
        raw.iflag.ICRNL = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.IXON = false;
        raw.iflag.BRKINT = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.PARMRK = false;
        // `OPOST` deliberately stays on. Everything lcc draws itself ends lines
        // with a bare `\n` and relies on the terminal adding the carriage
        // return; clearing it would stair-step every frame this program prints.
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        // NOW, not FLUSH: anything typed while the issues were still loading is
        // real input the user meant, and FLUSH would silently discard it.
        std.posix.tcsetattr(fd, .NOW, raw) catch return Error.NotATerminal;
        return .{ .fd = fd, .saved = saved, .raw = raw };
    }

    pub fn restore(self: Terminal) void {
        // FLUSH on the way out, so keys pressed after the answer do not spill
        // into the shell that gets the terminal back.
        std.posix.tcsetattr(self.fd, .FLUSH, self.saved) catch {};
    }

    /// Reads whatever is already buffered, without blocking. Used to tell a
    /// bare Esc from the start of an arrow-key sequence.
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

/// Cyrillic letters, paired with the Latin letter on the same physical key.
///
/// ЙЦУКЕН and QWERTY agree on where the keys are; only what they print
/// differs. Ukrainian and Russian differ from each other in two positions
/// (`s` and `'`), and both are listed — a layout switch is not a decision to
/// stop using the program.
const layout_pairs = [_]struct { []const u8, u8 }{
    .{ "й", 'q' }, .{ "ц", 'w' }, .{ "у", 'e' }, .{ "к", 'r' }, .{ "е", 't' },
    .{ "н", 'y' }, .{ "г", 'u' }, .{ "ш", 'i' }, .{ "щ", 'o' }, .{ "з", 'p' },
    .{ "х", '[' }, .{ "ї", ']' }, .{ "ф", 'a' }, .{ "і", 's' }, .{ "ы", 's' },
    .{ "в", 'd' }, .{ "а", 'f' }, .{ "п", 'g' }, .{ "р", 'h' }, .{ "о", 'j' },
    .{ "л", 'k' }, .{ "д", 'l' }, .{ "ж", ';' }, .{ "є", '\'' }, .{ "э", '\'' },
    .{ "я", 'z' }, .{ "ч", 'x' }, .{ "с", 'c' }, .{ "м", 'v' }, .{ "и", 'b' },
    .{ "т", 'n' }, .{ "ь", 'm' }, .{ "б", ',' }, .{ "ю", '.' },
};

/// The Latin letter at the physical key that produced `text`.
///
/// Single-letter shortcuts are positions on a keyboard, not characters in a
/// language. Reading the character directly means every binding silently stops
/// working the moment someone switches layout — and they do not switch back to
/// press one key. `lcc remove`'s y/n was the worst of it: on a Cyrillic layout
/// there was no way to confirm at all.
///
/// Null for anything that is not a letter position, so callers can tell a
/// shortcut from text.
pub fn layoutKey(text: []const u8) ?u8 {
    if (text.len == 1) {
        const byte = text[0];
        if (byte >= 'a' and byte <= 'z') return byte;
        if (byte >= 'A' and byte <= 'Z') return byte + 32;
        if (byte >= '0' and byte <= '9') return byte;
        // Punctuation shared by both layouts.
        if (byte == '[' or byte == ']' or byte == ';' or byte == '\'' or byte == ',' or byte == '.') return byte;
        return null;
    }
    // Cyrillic is two bytes; compare whole codepoints rather than bytes so an
    // uppercase form is matched by its own entry rather than by arithmetic.
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

/// The uppercase form of a two-byte Cyrillic letter.
///
/// The block is laid out so that а–я at U+0430–U+044F map to А–Я at
/// U+0410–U+042F. Only і, ї and є sit outside it and need their own pairs;
/// э is inside the range already.
fn toUpperCyrillic(buf: []u8, lower: []const u8) ?[]const u8 {
    const cp = std.unicode.utf8Decode(lower) catch return null;
    const upper: u21 = switch (cp) {
        0x0430...0x044F => cp - 0x20,
        0x0456 => 0x0406, // і
        0x0457 => 0x0407, // ї
        0x0454 => 0x0404, // є
        else => return null,
    };
    const len = std.unicode.utf8Encode(upper, buf) catch return null;
    return buf[0..len];
}

/// Truncates on a codepoint boundary so a narrow terminal cannot wrap a row
/// and desynchronise the redraw's line count.
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

/// In-place redraw of a known number of lines: hidden cursor, and an erase that
/// walks back up exactly as far as the last frame reached.
///
/// Holds no terminal — only the writer and the count. It used to carry a
/// `Terminal` that nothing ever read, and dropping it is what lets the erase be
/// tested against a fixed buffer instead of a tty.
pub const Screen = struct {
    out: *Io.Writer,
    lines: usize = 0,

    pub fn eraseFrame(self: *Screen) void {
        if (self.lines == 0) return;
        self.out.writeAll("\r") catch {};
        for (0..self.lines) |_| self.out.writeAll(csi ++ "1A" ++ csi ++ "2K") catch {};
        self.lines = 0;
    }

    /// A width change invalidates the line count: rows drawn at the old width
    /// may already have wrapped, so walking back up `lines` rows lands
    /// somewhere in the middle of the last frame and every frame after it
    /// inherits the error. One full clear, and the count starts again.
    pub fn reset(self: *Screen) void {
        self.out.writeAll(csi ++ "2J" ++ csi ++ "H") catch {};
        self.lines = 0;
    }
};

/// Undo everything a full-screen program may have left switched on, for the
/// moment lcc hands the terminal back.
///
/// Only `lcc watch` needs this: it passes another program's output straight
/// through, so whatever Claude Code turned on is still on when the user
/// detaches. A shell inheriting mouse reporting or the alternate screen behaves
/// strangely in ways nobody traces back to lcc — and the program that would
/// normally have cleaned up is still running, deliberately.
///
/// The alternate screen goes first so everything after it lands on the screen
/// the user is being given back.
///
/// The keyboard-protocol resets at the end are not speculative padding: a
/// capture of Claude Code's own startup emits `CSI ?1004h`, `CSI ?2031h`,
/// `CSI > 1 u` and `CSI > 4;2 m` within the first eighty bytes. Left set, the
/// first two spray `\x1b[I` / `\x1b[O` at the shell on every window focus
/// change, and the second two hand it a different encoding for ordinary
/// keypresses. Those are the strange-shell symptoms nobody traces back.
pub fn sanitize(w: *Io.Writer) void {
    w.writeAll(csi ++ "?1049l" ++ // leave the alternate screen
        csi ++ "?1000l" ++ // mouse: click tracking
        csi ++ "?1002l" ++ // mouse: drag tracking
        csi ++ "?1003l" ++ // mouse: any-motion tracking
        csi ++ "?1006l" ++ // mouse: SGR extended coordinates
        csi ++ "?2004l" ++ // bracketed paste
        csi ++ "?1004l" ++ // focus in/out reporting
        csi ++ "?2031l" ++ // colour-scheme change notifications
        csi ++ "<u" ++ // pop the kitty keyboard flags pushed with `CSI > 1 u`
        csi ++ ">4;0m" ++ // modifyOtherKeys back to the default encoding
        csi ++ "r" ++ // scroll region: the whole screen
        csi ++ "?7h" ++ // autowrap back on
        csi ++ "?25h" ++ // cursor visible
        csi ++ "0m" // attributes back to default
    ) catch {};
}

const testing = std.testing;

test "truncate cuts on a codepoint boundary, never mid-character" {
    // ASCII: the byte count and the column count agree.
    try testing.expectEqualStrings("abc", truncate("abcdef", 3));
    try testing.expectEqualStrings("abcdef", truncate("abcdef", 99));
    try testing.expectEqualStrings("", truncate("abcdef", 0));

    // Cyrillic is two bytes per codepoint, and Linear titles are full of it.
    // Cutting at a byte offset would emit half a character, which a terminal
    // renders as a replacement glyph of unpredictable width — and an unexpected
    // width is exactly what desynchronises the redraw's line count.
    const cyrillic = "ВИПРАВИТИ";
    const cut = truncate(cyrillic, 4);
    try testing.expectEqualStrings("ВИПР", cut);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));

    // A four-byte codepoint is kept whole or dropped whole.
    try testing.expectEqualStrings("🚀", truncate("🚀🚀", 1));
    try testing.expectEqualStrings("", truncate("🚀🚀", 0));
}

test "eraseFrame walks back up exactly as far as the last frame reached" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var screen: Screen = .{ .out = &w };

    // Nothing drawn yet: erasing must emit nothing at all. A stray `CSI 1A`
    // here would scroll the shell's own prompt off the top.
    screen.eraseFrame();
    try testing.expectEqual(@as(usize, 0), w.end);

    screen.lines = 3;
    screen.eraseFrame();
    try testing.expectEqualStrings(
        "\r" ++ csi ++ "1A" ++ csi ++ "2K" ++ csi ++ "1A" ++ csi ++ "2K" ++ csi ++ "1A" ++ csi ++ "2K",
        w.buffered(),
    );
    // The count has to be spent, or the next erase walks up twice as far.
    try testing.expectEqual(@as(usize, 0), screen.lines);
}

test "reset clears the whole screen and forgets the count" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var screen: Screen = .{ .out = &w, .lines = 7 };

    screen.reset();
    try testing.expectEqualStrings(csi ++ "2J" ++ csi ++ "H", w.buffered());
    // The point of reset is that `lines` was untrustworthy — it must not
    // survive into the next frame.
    try testing.expectEqual(@as(usize, 0), screen.lines);
}

test "raw mode leaves the bytes alone, but still lets lcc's own output wrap" {
    // Asserted on the struct rather than on a terminal, since a test has no
    // tty. `enterRaw` builds exactly this from what tcgetattr returned.
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

    // The whole bug: with ICRNL on, the Enter key arrives as NL and a program
    // downstream that acts on CR never sees it.
    try testing.expect(!t.iflag.ICRNL);
    try testing.expect(!t.iflag.INLCR);
    try testing.expect(!t.iflag.IGNCR);
    // Ctrl-S must reach the agent rather than freezing the terminal in front
    // of it.
    try testing.expect(!t.iflag.IXON);
    // And output translation stays: every frame lcc draws ends in a bare `\n`
    // and needs the terminal to add the carriage return.
    try testing.expect(t.oflag.OPOST);
    try testing.expect(t.oflag.ONLCR);
}

test "a shortcut is a key position, not a character" {
    // Latin, unchanged.
    try testing.expectEqual(@as(u8, 'q'), layoutKey("q").?);
    try testing.expectEqual(@as(u8, 'n'), layoutKey("n").?);
    // Shift or caps lock is still the same key.
    try testing.expectEqual(@as(u8, 'q'), layoutKey("Q").?);

    // Ukrainian ЙЦУКЕН: the key labelled `n` prints `т`. Reading the character
    // is what makes every binding stop working on a layout switch — and nobody
    // switches back to press one key.
    try testing.expectEqual(@as(u8, 'n'), layoutKey("т").?);
    try testing.expectEqual(@as(u8, 'q'), layoutKey("й").?);
    try testing.expectEqual(@as(u8, 'x'), layoutKey("ч").?);
    try testing.expectEqual(@as(u8, 'j'), layoutKey("о").?);
    try testing.expectEqual(@as(u8, 'k'), layoutKey("л").?);
    // `lcc remove` asks y/n, and on a Cyrillic layout there was no way to say
    // either — the confirmation for a destructive command was unreachable.
    try testing.expectEqual(@as(u8, 'y'), layoutKey("н").?);

    // Uppercase Cyrillic is the same key too.
    try testing.expectEqual(@as(u8, 'n'), layoutKey("Т").?);
    try testing.expectEqual(@as(u8, 'y'), layoutKey("Н").?);

    // Both layouts reach `s`, which they spell differently.
    try testing.expectEqual(@as(u8, 's'), layoutKey("і").?);
    try testing.expectEqual(@as(u8, 's'), layoutKey("ы").?);

    // Digits are the same position in every layout.
    try testing.expectEqual(@as(u8, '3'), layoutKey("3").?);

    // Not a letter position: the caller must be able to tell a shortcut from
    // text, or typing into a search box would trigger commands.
    try testing.expect(layoutKey(" ") == null);
    try testing.expect(layoutKey("→") == null);
    try testing.expect(layoutKey("") == null);
}

test "sanitize leaves the alternate screen before anything else" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    sanitize(&w);
    const out = w.buffered();

    // Order matters once: every reset after this one has to land on the screen
    // the user is getting back, not on the one being torn down.
    try testing.expect(std.mem.startsWith(u8, out, csi ++ "?1049l"));

    // The ones that actually break a shell if they survive a detach. The last
    // four were not guessed: they undo modes observed in a capture of Claude
    // Code's own first eighty bytes.
    for ([_][]const u8{
        csi ++ "?1003l", // any-motion mouse: turns every cursor move into input
        csi ++ "?2004l", // bracketed paste: wraps pasted text in escapes
        csi ++ "?25h", // a shell with an invisible cursor
        csi ++ "0m", // a shell rendered in Claude Code's last colour
        csi ++ "?1004l", // focus reporting: \x1b[I on every window focus change
        csi ++ "?2031l", // colour-scheme notifications
        csi ++ "<u", // kitty keyboard flags Claude Code pushes at startup
        csi ++ ">4;0m", // modifyOtherKeys: re-encodes ordinary keypresses
    }) |needle| {
        try testing.expect(std.mem.indexOf(u8, out, needle) != null);
    }
}
