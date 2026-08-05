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
    saved: std.posix.termios,

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
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        // NOW, not FLUSH: anything typed while the issues were still loading is
        // real input the user meant, and FLUSH would silently discard it.
        std.posix.tcsetattr(fd, .NOW, raw) catch return Error.NotATerminal;
        return .{ .fd = fd, .saved = saved };
    }

    pub fn restore(self: Terminal) void {
        // FLUSH on the way out, so keys pressed after the answer do not spill
        // into the shell that gets the terminal back.
        std.posix.tcsetattr(self.fd, .FLUSH, self.saved) catch {};
    }

    /// Reads whatever is already buffered, without blocking. Used to tell a
    /// bare Esc from the start of an arrow-key sequence.
    pub fn readPending(self: Terminal, buf: []u8) usize {
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
pub fn sanitize(w: *Io.Writer) void {
    w.writeAll(csi ++ "?1049l" ++ // leave the alternate screen
        csi ++ "?1000l" ++ // mouse: click tracking
        csi ++ "?1002l" ++ // mouse: drag tracking
        csi ++ "?1003l" ++ // mouse: any-motion tracking
        csi ++ "?1006l" ++ // mouse: SGR extended coordinates
        csi ++ "?2004l" ++ // bracketed paste
        csi ++ "r" ++ // scroll region: the whole screen
        csi ++ "?7h" ++ // autowrap back on
        csi ++ "?25h" ++ // cursor visible
        csi ++ "0m" // attributes back to default
    ) catch {};
}

test "truncate cuts on a codepoint boundary, never mid-character" {
    // ASCII: the byte count and the column count agree.
    try std.testing.expectEqualStrings("abc", truncate("abcdef", 3));
    try std.testing.expectEqualStrings("abcdef", truncate("abcdef", 99));
    try std.testing.expectEqualStrings("", truncate("abcdef", 0));

    // Cyrillic is two bytes per codepoint, and Linear titles are full of it.
    // Cutting at a byte offset would emit half a character, which a terminal
    // renders as a replacement glyph of unpredictable width — and an unexpected
    // width is exactly what desynchronises the redraw's line count.
    const cyrillic = "ВИПРАВИТИ";
    const cut = truncate(cyrillic, 4);
    try std.testing.expectEqualStrings("ВИПР", cut);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));

    // A four-byte codepoint is kept whole or dropped whole.
    try std.testing.expectEqualStrings("🚀", truncate("🚀🚀", 1));
    try std.testing.expectEqualStrings("", truncate("🚀🚀", 0));
}

test "eraseFrame walks back up exactly as far as the last frame reached" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var screen: Screen = .{ .out = &w };

    // Nothing drawn yet: erasing must emit nothing at all. A stray `CSI 1A`
    // here would scroll the shell's own prompt off the top.
    screen.eraseFrame();
    try std.testing.expectEqual(@as(usize, 0), w.end);

    screen.lines = 3;
    screen.eraseFrame();
    try std.testing.expectEqualStrings(
        "\r" ++ csi ++ "1A" ++ csi ++ "2K" ++ csi ++ "1A" ++ csi ++ "2K" ++ csi ++ "1A" ++ csi ++ "2K",
        w.buffered(),
    );
    // The count has to be spent, or the next erase walks up twice as far.
    try std.testing.expectEqual(@as(usize, 0), screen.lines);
}

test "reset clears the whole screen and forgets the count" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var screen: Screen = .{ .out = &w, .lines = 7 };

    screen.reset();
    try std.testing.expectEqualStrings(csi ++ "2J" ++ csi ++ "H", w.buffered());
    // The point of reset is that `lines` was untrustworthy — it must not
    // survive into the next frame.
    try std.testing.expectEqual(@as(usize, 0), screen.lines);
}

test "sanitize leaves the alternate screen before anything else" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    sanitize(&w);
    const out = w.buffered();

    // Order matters once: every reset after this one has to land on the screen
    // the user is getting back, not on the one being torn down.
    try std.testing.expect(std.mem.startsWith(u8, out, csi ++ "?1049l"));

    // The four that actually break a shell if they survive a detach.
    for ([_][]const u8{
        csi ++ "?1003l", // any-motion mouse: turns every cursor move into input
        csi ++ "?2004l", // bracketed paste: wraps pasted text in escapes
        csi ++ "?25h", // a shell with an invisible cursor
        csi ++ "0m", // a shell rendered in Claude Code's last colour
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, out, needle) != null);
    }
}
