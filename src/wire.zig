const std = @import("std");
const Io = std.Io;
const sessions = @import("sessions.zig");

pub const protocol: u32 = 1;

pub const header_len = 5;

pub const max_payload = 64 * 1024;

pub const Error = error{
    FrameTooLarge,
    UnknownFrameType,
    WrongRole,
    ShortBuffer,
} || std.mem.Allocator.Error;

pub const Role = enum { control, attach };

pub const Type = enum(u8) {
    hello = 0x01,

    register = 0x10,
    list = 0x11,
    subscribe = 0x12,
    kill = 0x13,
    stop = 0x14,
    hook = 0x15,

    snapshot = 0x20,
    event = 0x21,
    registered = 0x22,
    err = 0x2f,

    attach = 0x30,
    detach = 0x31,
    resize = 0x32,
    input = 0x33,
    take_input = 0x34,

    attached = 0x40,
    output = 0x41,
    replay = 0x44,
    exited = 0x42,
    input_revoked = 0x43,

    _,
};

pub fn known(t: Type) bool {
    return switch (t) {
        .hello,
        .register,
        .list,
        .subscribe,
        .kill,
        .stop,
        .hook,
        .snapshot,
        .event,
        .registered,
        .err,
        .attach,
        .detach,
        .resize,
        .input,
        .take_input,
        .attached,
        .output,
        .replay,
        .exited,
        .input_revoked,
        => true,
        _ => false,
    };
}

pub fn allowedOn(t: Type, role: Role) bool {
    return switch (@intFromEnum(t) >> 4) {
        0x0 => true,
        0x1, 0x2 => role == .control,
        0x3, 0x4 => role == .attach,
        else => false,
    };
}

pub fn bufferLen() usize {
    return max_payload + header_len;
}

pub const Frame = struct {
    type: Type,
    payload: []const u8,
};

pub fn encodeHeader(t: Type, len: u32) [header_len]u8 {
    var out: [header_len]u8 = undefined;
    out[0] = @intFromEnum(t);
    std.mem.writeInt(u32, out[1..header_len], len, .little);
    return out;
}

pub fn decodeHeader(bytes: *const [header_len]u8) Error!struct { type: Type, len: u32 } {
    const t: Type = @enumFromInt(bytes[0]);
    if (!known(t)) return Error.UnknownFrameType;
    const len = std.mem.readInt(u32, bytes[1..header_len], .little);
    if (len > max_payload) return Error.FrameTooLarge;
    return .{ .type = t, .len = len };
}

pub fn writeFrame(w: *Io.Writer, t: Type, payload: []const u8) (Io.Writer.Error || Error)!void {
    if (payload.len > max_payload) return Error.FrameTooLarge;
    const header = encodeHeader(t, @intCast(payload.len));
    try w.writeAll(&header);
    try w.writeAll(payload);
}

pub fn writeControl(
    gpa: std.mem.Allocator,
    w: *Io.Writer,
    t: Type,
    value: anytype,
) (Io.Writer.Error || Error)!void {
    const body = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(body);
    try writeFrame(w, t, body);
}

pub fn parse(comptime T: type, gpa: std.mem.Allocator, frame: Frame) !T {
    return std.json.parseFromSliceLeaky(T, gpa, frame.payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub const Decoder = struct {
    buf: []u8,
    len: usize = 0,
    taken: usize = 0,
    role: Role,

    pub fn init(buf: []u8, role: Role) Error!Decoder {
        if (buf.len < bufferLen()) return Error.ShortBuffer;
        return .{ .buf = buf, .role = role };
    }

    fn release(self: *Decoder) void {
        if (self.taken == 0) return;
        std.mem.copyForwards(u8, self.buf[0 .. self.len - self.taken], self.buf[self.taken..self.len]);
        self.len -= self.taken;
        self.taken = 0;
    }

    pub fn writable(self: *Decoder) []u8 {
        self.release();
        return self.buf[self.len..];
    }

    pub fn commit(self: *Decoder, n: usize) void {
        self.len += n;
    }

    pub fn push(self: *Decoder, bytes: []const u8) Error!void {
        const room = self.writable();
        if (bytes.len > room.len) return Error.FrameTooLarge;
        @memcpy(room[0..bytes.len], bytes);
        self.commit(bytes.len);
    }

    pub fn next(self: *Decoder) Error!?Frame {
        self.release();
        if (self.len < header_len) return null;

        const head = try decodeHeader(self.buf[0..header_len]);
        if (!allowedOn(head.type, self.role)) return Error.WrongRole;

        const total = header_len + head.len;
        if (self.len < total) return null;

        self.taken = total;
        return .{ .type = head.type, .payload = self.buf[header_len..total] };
    }
};

pub const Hello = struct {
    protocol: u32 = @This().current,
    role: []const u8,
    pid: i32,

    pub const current = protocol;
};

pub const Register = struct {
    worktree: []const u8,
    branch: []const u8,
    issue: ?[]const u8,
    repo_root: []const u8,
    program: []const u8,
    argv: []const []const u8,
    env: []const []const u8,
    cols: u16,
    rows: u16,
};

pub const Registered = struct {
    session_id: []const u8,
    pid: i32,
    status: []const u8,
    started_at: i64,
};

pub const Snapshot = struct {
    daemon_pid: i32,
    protocol: u32,
    sessions: []const sessions.Session,
    truncated: bool,
};

pub const Event = struct {
    kind: []const u8,
    session_id: []const u8,
    session: ?sessions.Session,
};

pub const Attach = struct {
    session_id: []const u8,
    cols: u16,
    rows: u16,
    replay: bool,
};

pub const Attached = struct {
    session_id: []const u8,
    cols: u16,
    rows: u16,
    input: bool,
    attached_clients: u32,
};

pub const Resize = struct { cols: u16, rows: u16 };

pub const Hook = struct {
    cwd: []const u8,
    session_id: []const u8,
    event: []const u8,
    permission_mode: []const u8 = "",
};
pub const Kill = struct { session_id: []const u8, signal: []const u8 };
pub const Stop = struct { force: bool };
pub const Exited = struct { session_id: []const u8, exit_code: ?i32, signal: ?i32 };
pub const ErrorBody = struct { code: []const u8, message: []const u8 };

test "a header round-trips, and an unknown type is refused rather than guessed" {
    const head = encodeHeader(.output, 4211);
    const back = try decodeHeader(&head);
    try std.testing.expectEqual(Type.output, back.type);
    try std.testing.expectEqual(@as(u32, 4211), back.len);

    const bogus = [_]u8{ 0x7e, 0, 0, 0, 0 };
    try std.testing.expectError(Error.UnknownFrameType, decodeHeader(&bogus));
}

test "a length past the cap is refused before anything is sized from it" {
    var head = encodeHeader(.output, max_payload + 1);
    try std.testing.expectError(Error.FrameTooLarge, decodeHeader(&head));

    head = encodeHeader(.output, std.math.maxInt(u32));
    try std.testing.expectError(Error.FrameTooLarge, decodeHeader(&head));

    head = encodeHeader(.output, max_payload);
    _ = try decodeHeader(&head);
}

test "every frame the protocol permits fits the buffer every decoder is given" {
    try std.testing.expect(max_payload + header_len <= bufferLen());
}

test "role separation rejects a frame that arrived on the wrong connection" {
    try std.testing.expect(allowedOn(.hello, .control));
    try std.testing.expect(allowedOn(.hello, .attach));
    try std.testing.expect(allowedOn(.snapshot, .control));
    try std.testing.expect(!allowedOn(.snapshot, .attach));
    try std.testing.expect(allowedOn(.output, .attach));
    try std.testing.expect(!allowedOn(.output, .control));

    var buf: [bufferLen()]u8 = undefined;
    var dec = try Decoder.init(&buf, .attach);
    try dec.push(&encodeHeader(.list, 0));
    try std.testing.expectError(Error.WrongRole, dec.next());
}

test "the decoder reassembles frames split at every possible byte offset" {
    const gpa = std.testing.allocator;

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);

    const payloads = [_][]const u8{ "first", "", "a much longer third payload \x00\xff\x1b[31m" };
    const types = [_]Type{ .output, .output, .output };
    for (types, payloads) |t, p| {
        try stream.appendSlice(gpa, &encodeHeader(t, @intCast(p.len)));
        try stream.appendSlice(gpa, p);
    }

    var split: usize = 1;
    while (split < stream.items.len) : (split += 1) {
        var buf: [bufferLen()]u8 = undefined;
        var dec = try Decoder.init(&buf, .attach);

        var got: usize = 0;
        const chunks = [_][]const u8{ stream.items[0..split], stream.items[split..] };
        for (chunks) |chunk| {
            try dec.push(chunk);
            while (try dec.next()) |frame| {
                try std.testing.expectEqualStrings(payloads[got], frame.payload);
                got += 1;
            }
        }
        try std.testing.expectEqual(payloads.len, got);
    }
}

test "a zero-length payload is an empty slice, not a missing frame" {
    var buf: [bufferLen()]u8 = undefined;
    var dec = try Decoder.init(&buf, .attach);

    try dec.push(&encodeHeader(.detach, 0));
    const frame = (try dec.next()).?;
    try std.testing.expectEqual(Type.detach, frame.type);
    try std.testing.expectEqual(@as(usize, 0), frame.payload.len);
    try std.testing.expect((try dec.next()) == null);
}

test "a decoder given too small a buffer says so instead of overflowing later" {
    var small: [16]u8 = undefined;
    try std.testing.expectError(Error.ShortBuffer, Decoder.init(&small, .attach));
    var one_short: [max_payload + header_len - 1]u8 = undefined;
    try std.testing.expectError(Error.ShortBuffer, Decoder.init(&one_short, .control));
}

test "writeFrame emits the header and the body as one unit" {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);

    try writeControl(gpa, &w, .resize, Resize{ .cols = 120, .rows = 40 });
    const out = w.buffered();

    const head = try decodeHeader(out[0..header_len]);
    try std.testing.expectEqual(Type.resize, head.type);
    try std.testing.expectEqual(out.len - header_len, head.len);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const back = try parse(Resize, arena_state.allocator(), .{
        .type = head.type,
        .payload = out[header_len..],
    });
    try std.testing.expectEqual(@as(u16, 120), back.cols);
    try std.testing.expectEqual(@as(u16, 40), back.rows);
}

test "writeFrame refuses an oversized payload rather than emitting a bad length" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const huge = try std.testing.allocator.alloc(u8, max_payload + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'x');
    try std.testing.expectError(Error.FrameTooLarge, writeFrame(&w, .output, huge));
    try std.testing.expectEqual(@as(usize, 0), w.end);
}

test "the hello payload keeps the shape a mismatched version must still read" {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeControl(gpa, &w, .hello, Hello{ .role = "control", .pid = 4123 });

    const Schema = struct { protocol: u32, role: []const u8, pid: i32 };
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSliceLeaky(
        Schema,
        arena_state.allocator(),
        w.buffered()[header_len..],
        .{},
    );
    try std.testing.expectEqual(protocol, parsed.protocol);
    try std.testing.expectEqualStrings("control", parsed.role);
}

test "a register carries argv and the whole environment, escaping intact" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);

    try writeControl(gpa, &w, .register, Register{
        .worktree = "/r/.lcc/worktrees/pe-256",
        .branch = "feature/pe-256-fix",
        .issue = "PE-256",
        .repo_root = "/r",
        .program = "/usr/local/bin/claude",
        .argv = &.{ "--permission-mode", "plan", "--", "--- \n- step \"one\"\\two" },
        .env = &.{ "PATH=/usr/bin", "WEIRD=a\"b\\c\nd" },
        .cols = 174,
        .rows = 48,
    });

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const back = try parse(Register, arena_state.allocator(), .{
        .type = .register,
        .payload = w.buffered()[header_len..],
    });
    try std.testing.expectEqualStrings("--- \n- step \"one\"\\two", back.argv[3]);
    try std.testing.expectEqualStrings("WEIRD=a\"b\\c\nd", back.env[1]);
    try std.testing.expectEqualStrings("PE-256", back.issue.?);
}

test "an absent issue is null in the payload, not a dropped key" {
    const gpa = std.testing.allocator;
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeControl(gpa, &w, .register, Register{
        .worktree = "/w",
        .branch = "feature/no-issue",
        .issue = null,
        .repo_root = "/r",
        .program = "/bin/claude",
        .argv = &.{},
        .env = &.{},
        .cols = 80,
        .rows = 24,
    });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"issue\":null") != null);
}
