const std = @import("std");

pub const ModeFilter = struct {
    const State = enum { text, esc, csi };

    state: State = .text,
    pending: [64]u8 = undefined,
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

fn configures(body: []const u8) bool {
    if (body.len == 0) return false;
    const final = body[body.len - 1];
    const private = body[0] == '?' or body[0] == '>' or body[0] == '<' or body[0] == '=';
    return switch (final) {
        'h', 'l' => private,
        'u' => private,
        'm' => private,
        'r' => true,
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
