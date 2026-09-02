const std = @import("std");

pub const ModeFilter = struct {
    const State = enum { text, esc, csi, csi_verbatim };

    const pending_capacity = 64;

    pub const overhead = pending_capacity + 2;

    state: State = .text,
    pending: [pending_capacity]u8 = undefined,
    len: usize = 0,

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
                        out[n] = 0x1b;
                        n += 1;
                        out[n] = byte;
                        n += 1;
                        self.state = .text;
                    }
                },
                .csi => {
                    if (self.len == self.pending.len) {
                        n += self.emitPending(out[n..]);
                        out[n] = byte;
                        n += 1;
                        self.state = if (isFinal(byte)) .text else .csi_verbatim;
                        continue;
                    }
                    self.pending[self.len] = byte;
                    self.len += 1;
                    if (isFinal(byte)) {
                        if (!withheld(self.pending[0..self.len])) n += self.emitPending(out[n..]);
                        self.state = .text;
                    }
                },
                .csi_verbatim => {
                    out[n] = byte;
                    n += 1;
                    if (isFinal(byte)) self.state = .text;
                },
            }
        }
        return out[0..n];
    }

    pub fn flush(self: *ModeFilter, out: []u8) []const u8 {
        var n: usize = 0;
        switch (self.state) {
            .text, .csi_verbatim => {},
            .esc => {
                out[0] = 0x1b;
                n = 1;
            },
            .csi => n = self.emitPending(out),
        }
        self.state = .text;
        self.len = 0;
        return out[0..n];
    }

    fn emitPending(self: *ModeFilter, out: []u8) usize {
        out[0] = 0x1b;
        out[1] = '[';
        @memcpy(out[2..][0..self.len], self.pending[0..self.len]);
        const n = 2 + self.len;
        self.len = 0;
        return n;
    }
};

fn isFinal(byte: u8) bool {
    return byte >= 0x40 and byte <= 0x7e;
}

fn withheld(body: []const u8) bool {
    if (body.len == 0) return false;
    const final = body[body.len - 1];
    const private = body[0] == '?' or body[0] == '>' or body[0] == '<' or body[0] == '=';
    return switch (final) {
        'h', 'l' => private,
        'u' => private,
        'm' => private,
        'r' => true,
        'n', 'c' => true,
        else => false,
    };
}

const testing = std.testing;

test "a replay keeps what draws and drops what configures" {
    var f: ModeFilter = .{};
    var out: [512]u8 = undefined;

    const startup = "\x1b7\x1b[r\x1b8\x1b[?25h\x1b[?25l\x1b[?2004h\x1b[?1004h" ++
        "\x1b[?2031h\x1b[<u\x1b[>1u\x1b[>4;2m\x1b[?2026h";
    const kept = f.filter(startup, &out);

    for ([_][]const u8{ "\x1b[>1u", "\x1b[<u", "\x1b[>4;2m", "\x1b[?2004h", "\x1b[?1004h", "\x1b[?2031h", "\x1b[r" }) |mode| {
        try testing.expect(std.mem.indexOf(u8, kept, mode) == null);
    }
    try testing.expect(std.mem.indexOf(u8, kept, "\x1b7") != null);
    try testing.expect(std.mem.indexOf(u8, kept, "\x1b8") != null);
}

test "colour and cursor movement survive the filter untouched" {
    var f: ModeFilter = .{};
    var out: [512]u8 = undefined;
    const drawing = "\x1b[38;2;255;193;7mhello\x1b[39m\x1b[2K\x1b[12G\x1b[4A plain text\n";
    try testing.expectEqualStrings(drawing, f.filter(drawing, &out));
}

test "a mode sequence split across two frames is still dropped" {
    var f: ModeFilter = .{};
    var out: [256]u8 = undefined;
    try testing.expectEqualStrings("a", f.filter("a\x1b[>1", &out));
    try testing.expectEqualStrings("b", f.filter("ub", &out));
}

test "a question the terminal would answer is never replayed back at it" {
    var f: ModeFilter = .{};
    var out: [256]u8 = undefined;

    const asked = "before\x1b[6n\x1b[c\x1b[>0c\x1b[5nafter";
    const kept = f.filter(asked, &out);
    if (!std.mem.eql(u8, "beforeafter", kept)) {
        std.debug.print(
            "a device query survived the replay as \"{f}\". The terminal answers it, " ++
                "and attach forwards everything on stdin to the pty — so the answer is " ++
                "typed into Claude Code as if the user had entered it.\n",
            .{std.zig.fmtString(kept)},
        );
        return error.TestExpectedEqual;
    }

    var g: ModeFilter = .{};
    try testing.expectEqualStrings("\x1b[38;5;9m", g.filter("\x1b[38;5;9m", &out));
}

test "a CSI too long to judge is passed through whole, never left unterminated" {
    var f: ModeFilter = .{};
    var out: [1024]u8 = undefined;

    const sequence = "\x1b[" ++ ("1" ** 200) ++ "m";

    const kept = f.filter(sequence, &out);
    if (!std.mem.eql(u8, sequence, kept)) {
        std.debug.print(
            "a {d}-byte CSI came back as \"{f}\". Truncating one drops its final byte, " ++
                "and a terminal reading an unterminated CSI swallows every character " ++
                "after it until the next final byte — whole lines of the agent's output " ++
                "simply vanish.\n",
            .{ sequence.len, std.zig.fmtString(kept) },
        );
        return error.TestExpectedEqual;
    }
    try testing.expectEqual(ModeFilter.State.text, f.state);
}

test "the tail of a sequence cut by the end of the replay is handed over, not eaten" {
    var f: ModeFilter = .{};
    var out: [256]u8 = undefined;

    try testing.expectEqualStrings("row", f.filter("row\x1b[38;2", &out));

    const tail = f.flush(&out);
    if (!std.mem.eql(u8, "\x1b[38;2", tail)) {
        std.debug.print(
            "the replay ended mid-sequence and the filter kept \"{f}\" to itself. " ++
                "The live output that follows starts with the rest of that sequence, " ++
                "so the terminal prints it as text and loses the colour it was setting.\n",
            .{std.zig.fmtString(tail)},
        );
        return error.TestExpectedEqual;
    }
    try testing.expectEqual(@as(usize, 0), f.flush(&out).len);
}

test "a lone escape at the end of the replay is handed over too" {
    var f: ModeFilter = .{};
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("x", f.filter("x\x1b", &out));
    try testing.expectEqualStrings("\x1b", f.flush(&out));
}

test "the filter never writes more than its stated overhead past the chunk" {
    const gpa = testing.allocator;
    const chunk_len = 4096;

    const chunk = try gpa.alloc(u8, chunk_len);
    defer gpa.free(chunk);
    const out = try gpa.alloc(u8, chunk_len + ModeFilter.overhead);
    defer gpa.free(out);

    var f: ModeFilter = .{};
    var primer: [8]u8 = undefined;
    _ = f.filter("\x1b[" ++ ("9" ** 64), &primer);

    @memset(chunk, 'a');
    chunk[0] = 'm';
    const kept = f.filter(chunk, out);
    try testing.expect(kept.len <= chunk_len + ModeFilter.overhead);
    try testing.expectEqual(@as(usize, chunk_len + ModeFilter.overhead), kept.len);
}

pub const ModeState = struct {
    const max_modes = 24;
    const body_capacity = 32;

    pub const render_capacity = (max_modes + 3) * (body_capacity + 3);

    const Scan = enum { text, esc, csi };

    const Mode = struct {
        params: [body_capacity]u8 = undefined,
        params_len: usize = 0,
        set: bool = false,
    };

    scan: Scan = .text,
    body: [body_capacity]u8 = undefined,
    body_len: usize = 0,
    overran: bool = false,

    modes: [max_modes]Mode = @splat(.{}),
    mode_count: usize = 0,

    region: [body_capacity]u8 = undefined,
    region_len: usize = 0,
    has_region: bool = false,

    other_keys: [body_capacity]u8 = undefined,
    other_keys_len: usize = 0,
    has_other_keys: bool = false,

    keyboard: [body_capacity]u8 = undefined,
    keyboard_len: usize = 0,
    keyboard_depth: u16 = 0,

    pub fn feed(self: *ModeState, chunk: []const u8) void {
        if (self.scan == .text and std.mem.indexOfScalar(u8, chunk, 0x1b) == null) return;
        for (chunk) |byte| switch (self.scan) {
            .text => {
                if (byte == 0x1b) self.scan = .esc;
            },
            .esc => {
                self.body_len = 0;
                self.overran = false;
                self.scan = if (byte == '[') .csi else .text;
            },
            .csi => {
                if (self.body_len < self.body.len) {
                    self.body[self.body_len] = byte;
                    self.body_len += 1;
                } else {
                    self.overran = true;
                }
                if (isFinal(byte)) {
                    if (!self.overran) self.note(self.body[0..self.body_len]);
                    self.scan = .text;
                }
            },
        };
    }

    pub fn render(self: ModeState, out: []u8) []const u8 {
        var n: usize = 0;
        for (self.modes[0..self.mode_count]) |mode| {
            n += emit(out[n..], mode.params[0..mode.params_len], if (mode.set) 'h' else 'l');
        }
        if (self.has_region) n += emit(out[n..], self.region[0..self.region_len], 'r');
        if (self.has_other_keys) n += emit(out[n..], self.other_keys[0..self.other_keys_len], 'm');
        if (self.keyboard_depth > 0 and self.keyboard_len > 0) {
            n += emit(out[n..], self.keyboard[0..self.keyboard_len], 'u');
        }
        return out[0..n];
    }

    fn note(self: *ModeState, body: []const u8) void {
        if (body.len == 0) return;
        const final = body[body.len - 1];
        const params = body[0 .. body.len - 1];
        const private = params.len > 0 and
            (params[0] == '?' or params[0] == '>' or params[0] == '<' or params[0] == '=');
        switch (final) {
            'h', 'l' => if (private and !transient(params)) self.remember(params, final == 'h'),
            'u' => if (private) self.noteKeyboard(params),
            'm' => if (private) {
                self.other_keys_len = copyInto(&self.other_keys, params);
                self.has_other_keys = true;
            },
            'r' => {
                self.region_len = copyInto(&self.region, params);
                self.has_region = true;
            },
            else => {},
        }
    }

    fn remember(self: *ModeState, params: []const u8, set: bool) void {
        for (self.modes[0..self.mode_count]) |*mode| {
            if (std.mem.eql(u8, mode.params[0..mode.params_len], params)) {
                mode.set = set;
                return;
            }
        }
        if (self.mode_count == self.modes.len) return;
        const mode = &self.modes[self.mode_count];
        mode.params_len = copyInto(&mode.params, params);
        mode.set = set;
        self.mode_count += 1;
    }

    fn noteKeyboard(self: *ModeState, params: []const u8) void {
        switch (params[0]) {
            '>' => {
                self.keyboard_depth +|= 1;
                self.keyboard_len = copyInto(&self.keyboard, params);
            },
            '<' => self.keyboard_depth -|= levels(params[1..]),
            '=' => self.keyboard_len = copyInto(&self.keyboard, params),
            else => {},
        }
    }
};

fn transient(params: []const u8) bool {
    return std.mem.eql(u8, params, "?2026");
}

fn levels(digits: []const u8) u16 {
    const n = std.fmt.parseInt(u16, digits, 10) catch return 1;
    return if (n == 0) 1 else n;
}

fn copyInto(dest: []u8, params: []const u8) usize {
    const take = @min(dest.len, params.len);
    @memcpy(dest[0..take], params[0..take]);
    return take;
}

fn emit(out: []u8, params: []const u8, final: u8) usize {
    out[0] = 0x1b;
    out[1] = '[';
    @memcpy(out[2..][0..params.len], params);
    out[2 + params.len] = final;
    return 3 + params.len;
}

test "a re-attached terminal is set up the way the session left it" {
    var state: ModeState = .{};
    state.feed("\x1b7\x1b[r\x1b8\x1b[?25h\x1b[?25l\x1b[?2004h\x1b[?1004h" ++
        "\x1b[?2031h\x1b[<u\x1b[>1u\x1b[>4;2m\x1b[?2026h");

    var out: [ModeState.render_capacity]u8 = undefined;
    const settled = state.render(&out);

    for ([_][]const u8{ "\x1b[?2004h", "\x1b[?1004h", "\x1b[?2031h", "\x1b[>4;2m", "\x1b[>1u" }) |needed| {
        if (std.mem.indexOf(u8, settled, needed) == null) {
            std.debug.print(
                "the session's startup left \"{f}\" out of the settled state. sanitize() " ++
                    "takes every one of these down on detach and the child only sends them " ++
                    "once, at startup — so re-attaching leaves the terminal and Claude Code " ++
                    "disagreeing about how keys and pastes are encoded.\n",
                .{std.zig.fmtString(settled)},
            );
            return error.TestExpectedEqual;
        }
    }
}

test "the keyboard stack is settled to one push, however many the history holds" {
    var state: ModeState = .{};
    state.feed("\x1b[>1u\x1b[>1u\x1b[>1u");

    var out: [ModeState.render_capacity]u8 = undefined;
    const settled = state.render(&out);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, settled, "u"));
    try testing.expect(std.mem.indexOf(u8, settled, "\x1b[>1u") != null);

    var popped: ModeState = .{};
    popped.feed("\x1b[>1u\x1b[<u");
    try testing.expectEqual(@as(usize, 0), popped.render(&out).len);
}

test "the last word on a mode is the one that is settled" {
    var state: ModeState = .{};
    state.feed("\x1b[?2004h\x1b[?1004h\x1b[?2004l");

    var out: [ModeState.render_capacity]u8 = undefined;
    const settled = state.render(&out);

    try testing.expect(std.mem.indexOf(u8, settled, "\x1b[?2004l") != null);
    try testing.expect(std.mem.indexOf(u8, settled, "\x1b[?2004h") == null);
    try testing.expect(std.mem.indexOf(u8, settled, "\x1b[?1004h") != null);
}

test "a half-open synchronised update is never handed to the terminal" {
    var state: ModeState = .{};
    state.feed("\x1b[?2026h\x1b[?2004h");

    var out: [ModeState.render_capacity]u8 = undefined;
    const settled = state.render(&out);

    if (std.mem.indexOf(u8, settled, "2026") != null) {
        std.debug.print(
            "the settled state opened a synchronised update the child will not close for " ++
                "a whole frame. The terminal shows nothing at all until it does, which " ++
                "looks exactly like an attach that hung.\n",
            .{},
        );
        return error.TestExpectedEqual;
    }
    try testing.expect(std.mem.indexOf(u8, settled, "\x1b[?2004h") != null);
}

test "a session that configured nothing settles to nothing" {
    var state: ModeState = .{};
    state.feed("plain text\n\x1b[31mred\x1b[0m\x1b[2K\x1b[4A");

    var out: [ModeState.render_capacity]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), state.render(&out).len);
}

test "a sequence split across reads is still counted once" {
    var state: ModeState = .{};
    state.feed("\x1b[?20");
    state.feed("04h");

    var out: [ModeState.render_capacity]u8 = undefined;
    try testing.expectEqualStrings("\x1b[?2004h", state.render(&out));
}
