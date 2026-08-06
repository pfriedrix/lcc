//! Just enough escape-sequence parsing to strip terminal configuration out of
//! replayed scrollback.
//!
//! Explicitly **not** a terminal emulator, and the temptation to grow one is
//! the failure mode here. It once also watched the child's output to decide
//! when to reassert the scroll region and when the cursor slot was free; both
//! went away when the status bar stopped repainting on a schedule, and what is
//! left answers one question — is this sequence configuration or drawing?
//!
//! It has to be an object rather than a function because a sequence can be
//! split across two reads, at whatever boundary the ring happened to wrap on.

const std = @import("std");

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

