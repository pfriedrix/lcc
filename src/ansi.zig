//! Just enough escape-sequence parsing to notice when a child undoes something
//! lcc set up.
//!
//! Explicitly **not** a terminal emulator, and the temptation to grow one is
//! the failure mode here. It answers exactly one question: did this chunk of
//! output contain a sequence that invalidates the reserved status row?
//!
//! It has to be an object rather than a function because a sequence can be
//! split across two reads. A scanner that reset between chunks would miss a
//! `CSI r` whose bytes landed either side of a 64 KB boundary — and missing it
//! means the child silently reclaims the row lcc is drawing in.

const std = @import("std");

/// What a chunk contained. Flags rather than an event stream: the caller only
/// ever asks "do I need to reassert", and several in one chunk still need one
/// answer.
pub const Seen = struct {
    /// A DECSTBM — `CSI r` or `CSI <top>;<bottom> r`.
    ///
    /// Measured, not anticipated: a capture of Claude Code's startup has `CSI r`
    /// as its *second* command, before it has drawn anything. A status bar that
    /// set the scroll region once at attach would lose its row to that and
    /// never know.
    scroll_region: bool = false,
    /// `CSI ?1049h` / `CSI ?1049l`. The alternate screen carries its own scroll
    /// region, so entering or leaving it discards ours.
    ///
    /// The same capture shows Claude Code never uses it — it renders inline —
    /// but a future release might, and the cost of handling it is this comment
    /// plus one branch.
    alt_screen: bool = false,

    pub fn any(self: Seen) bool {
        return self.scroll_region or self.alt_screen;
    }

    fn merge(self: Seen, other: Seen) Seen {
        return .{
            .scroll_region = self.scroll_region or other.scroll_region,
            .alt_screen = self.alt_screen or other.alt_screen,
        };
    }
};

pub const Scanner = struct {
    const State = enum { text, esc, csi };
    const max_params = 32;

    state: State = .text,
    params: [max_params]u8 = undefined,
    len: usize = 0,

    pub fn scan(self: *Scanner, chunk: []const u8) Seen {
        var seen: Seen = .{};
        for (chunk) |byte| {
            switch (self.state) {
                .text => if (byte == 0x1b) {
                    self.state = .esc;
                },
                .esc => {
                    if (byte == '[') {
                        self.state = .csi;
                        self.len = 0;
                    } else {
                        // Two-byte escapes (`ESC 7`, `ESC 8`) and charset
                        // selection carry nothing this cares about.
                        self.state = .text;
                    }
                },
                .csi => {
                    // Parameter and intermediate bytes; the final byte is
                    // 0x40..0x7E and ends the sequence.
                    if (byte >= 0x40 and byte <= 0x7e) {
                        seen = seen.merge(self.finish(byte));
                        self.state = .text;
                    } else {
                        // A sequence longer than the buffer is not one of ours,
                        // and dropping the overflow keeps this bounded rather
                        // than letting a hostile stream grow it.
                        if (self.len < max_params) {
                            self.params[self.len] = byte;
                            self.len += 1;
                        }
                    }
                },
            }
        }
        return seen;
    }

    fn finish(self: *Scanner, final: u8) Seen {
        const params = self.params[0..self.len];
        return switch (final) {
            'r' => .{ .scroll_region = true },
            'h', 'l' => .{ .alt_screen = std.mem.eql(u8, params, "?1049") },
            else => .{},
        };
    }
};

/// Drops the sequences that configure a terminal, keeping the ones that draw.
///
/// For replayed scrollback only. A replay exists to repaint a screen, and the
/// bytes in it are whatever the child once wrote — including, at the very
/// start, its terminal setup: `CSI > 1 u` pushes kitty keyboard flags,
/// `CSI > 4 ; 2 m` turns on modifyOtherKeys, `CSI ? 2004 h` turns on bracketed
/// paste. Replaying those does not repaint anything. It pushes a *second* level
/// onto the terminal's keyboard stack, and from then on the child and the
/// terminal disagree about how keys are encoded: the child sends its picker a
/// `\r` it never receives, while the mouse — a separate protocol — keeps
/// working. That is the shape of the bug this exists to prevent.
///
/// SGR is deliberately not touched. `CSI 31 m` is colour, which is content;
/// only the private forms (`>`, `<`, `?`, `=`) configure.
pub const ModeFilter = struct {
    const State = enum { text, esc, csi };

    state: State = .text,
    /// The sequence so far, held back until its final byte says whether it is
    /// content or configuration. Bounded: anything longer is not one of ours.
    pending: [64]u8 = undefined,
    len: usize = 0,

    /// Filters `chunk` into `out`, which must be at least `chunk.len + 64`.
    /// Returns the bytes to write.
    pub fn filter(self: *ModeFilter, chunk: []const u8, out: []u8) []const u8 {
        var n: usize = 0;
        for (chunk) |byte| {
            switch (self.state) {
                .text => {
                    if (byte == 0x1b) {
                        self.state = .esc;
                        self.len = 0;
                    } else {
                        out[n] = byte;
                        n += 1;
                    }
                },
                .esc => {
                    if (byte == '[') {
                        self.state = .csi;
                    } else {
                        // Two-byte escapes are content (cursor save/restore,
                        // charset). Put back what was held.
                        out[n] = 0x1b;
                        n += 1;
                        out[n] = byte;
                        n += 1;
                        self.state = .text;
                    }
                },
                .csi => {
                    if (self.len < self.pending.len) {
                        self.pending[self.len] = byte;
                        self.len += 1;
                    }
                    if (byte >= 0x40 and byte <= 0x7e) {
                        if (!configures(self.pending[0..self.len])) {
                            out[n] = 0x1b;
                            n += 1;
                            out[n] = '[';
                            n += 1;
                            @memcpy(out[n..][0..self.len], self.pending[0..self.len]);
                            n += self.len;
                        }
                        self.state = .text;
                    }
                },
            }
        }
        return out[0..n];
    }
};

/// Whether a CSI body (everything after `ESC [`) sets terminal state rather
/// than drawing.
fn configures(body: []const u8) bool {
    if (body.len == 0) return false;
    const final = body[body.len - 1];
    const private = body[0] == '?' or body[0] == '>' or body[0] == '<' or body[0] == '=';
    return switch (final) {
        // Private mode set/reset: alt screen, bracketed paste, focus
        // reporting, mouse tracking, colour-scheme notifications.
        'h', 'l' => private,
        // Keyboard protocol push, pop and query.
        'u' => private,
        // `CSI > 4 ; 2 m` is modifyOtherKeys; a bare `CSI 31 m` is colour.
        'm' => private,
        // DECSTBM. The child's scroll region is not content, and replaying it
        // would fight the row reserved for the status bar.
        'r' => true,
        else => false,
    };
}

const testing = std.testing;

test "a bare CSI r is noticed — Claude Code emits one before anything else" {
    var s: Scanner = .{};
    // From a real capture: ESC 7, CSI r, ESC 8 are the first three sequences of
    // a session. Missing this hands the reserved row straight back.
    try testing.expect(s.scan("\x1b7\x1b[r\x1b8").scroll_region);
}

test "a parameterised scroll region counts too" {
    var s: Scanner = .{};
    // Any DECSTBM replaces ours, whether it resets or re-sets.
    try testing.expect(s.scan("\x1b[1;39r").scroll_region);
    try testing.expect(s.scan("\x1b[5;20r").scroll_region);
}

test "a sequence split across two reads is still recognised" {
    var s: Scanner = .{};
    // The whole reason this is an object. A 64 KB read boundary falls wherever
    // it falls, and a scanner that reset between chunks would miss the half of
    // the sequences that straddle one.
    try testing.expect(!s.scan("output\x1b").scroll_region);
    try testing.expect(!s.scan("[").scroll_region);
    try testing.expect(s.scan("r more output").scroll_region);

    // And split in the middle of the parameters.
    var t: Scanner = .{};
    try testing.expect(!t.scan("\x1b[1;").scroll_region);
    try testing.expect(t.scan("39r").scroll_region);
}

test "the alternate screen is noticed in both directions" {
    var s: Scanner = .{};
    try testing.expect(s.scan("\x1b[?1049h").alt_screen);
    try testing.expect(s.scan("\x1b[?1049l").alt_screen);

    // A private mode that is not 1049 is not the alternate screen. Treating
    // every `?…h` as one would reassert the scroll region on every cursor-hide,
    // which Claude Code does constantly.
    try testing.expect(!s.scan("\x1b[?25l").alt_screen);
    try testing.expect(!s.scan("\x1b[?2004h").alt_screen);
    try testing.expect(!s.scan("\x1b[?1000h").alt_screen);
}

test "ordinary output and unrelated sequences change nothing" {
    var s: Scanner = .{};
    // The common case by an enormous margin — colour runs, cursor moves and
    // erases — and every false positive here is a needless redraw of the bar.
    for ([_][]const u8{
        "plain text with no escapes at all\n",
        "\x1b[38;2;255;193;7m",
        "\x1b[2K",
        "\x1b[12G",
        "\x1b[4A",
        "\x1b]8;;https://example.com\x07",
        "\x1b(B",
    }) |chunk| {
        try testing.expect(!s.scan(chunk).any());
    }
}

test "a replay keeps what draws and drops what configures" {
    var f: ModeFilter = .{};
    var out: [512]u8 = undefined;

    // The exact opening Claude Code writes, measured from a real capture. The
    // keyboard-protocol pushes in it are what a replay must not repeat: a
    // second push leaves the terminal a level above where the child thinks it
    // is, and its picker then never sees the Enter it is waiting for.
    const startup = "\x1b7\x1b[r\x1b8\x1b[?25h\x1b[?25l\x1b[?2004h\x1b[?1004h" ++
        "\x1b[?2031h\x1b[<u\x1b[>1u\x1b[>4;2m\x1b[?2026h";
    const kept = f.filter(startup, &out);

    for ([_][]const u8{ "\x1b[>1u", "\x1b[<u", "\x1b[>4;2m", "\x1b[?2004h", "\x1b[?1004h", "\x1b[?2031h", "\x1b[r" }) |mode| {
        try testing.expect(std.mem.indexOf(u8, kept, mode) == null);
    }
    // Cursor save and restore are content: they position what follows.
    try testing.expect(std.mem.indexOf(u8, kept, "\x1b7") != null);
    try testing.expect(std.mem.indexOf(u8, kept, "\x1b8") != null);
}

test "colour and cursor movement survive the filter untouched" {
    var f: ModeFilter = .{};
    var out: [512]u8 = undefined;
    // Everything a repaint is actually made of. Dropping any of it would make
    // the replay worse than not replaying at all.
    const drawing = "\x1b[38;2;255;193;7mhello\x1b[39m\x1b[2K\x1b[12G\x1b[4A plain text\n";
    try testing.expectEqualStrings(drawing, f.filter(drawing, &out));
}

test "a mode sequence split across two frames is still dropped" {
    var f: ModeFilter = .{};
    var out: [256]u8 = undefined;
    // The ring hands out slices at whatever boundary it wrapped on, so half a
    // sequence in one frame and half in the next is ordinary.
    try testing.expectEqualStrings("a", f.filter("a\x1b[>1", &out));
    try testing.expectEqualStrings("b", f.filter("ub", &out));
}

test "a scanner survives a sequence longer than its parameter buffer" {
    var s: Scanner = .{};
    // Bounded rather than growable: the bytes come off a pty and nothing
    // guarantees they are well formed.
    const long = "\x1b[" ++ ("1;" ** 60) ++ "m";
    try testing.expect(!s.scan(long).any());
    // And it is still in a sane state afterwards.
    try testing.expect(s.scan("\x1b[r").scroll_region);
}
