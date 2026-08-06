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

test "a scanner survives a sequence longer than its parameter buffer" {
    var s: Scanner = .{};
    // Bounded rather than growable: the bytes come off a pty and nothing
    // guarantees they are well formed.
    const long = "\x1b[" ++ ("1;" ** 60) ++ "m";
    try testing.expect(!s.scan(long).any());
    // And it is still in a sane state afterwards.
    try testing.expect(s.scan("\x1b[r").scroll_region);
}
