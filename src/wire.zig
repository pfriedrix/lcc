//! What travels on the daemon socket: a five-byte header, then bytes.
//!
//! Control payloads are JSON, so the protocol stays inspectable and matches the
//! discipline the `--json` command surface already follows. Data payloads — pty
//! output and keystrokes — are raw. They are not text: Claude Code draws box
//! characters and anything it runs can print arbitrary bytes, so `Stringify`
//! would mangle or refuse them, and base64 would be mandatory rather than
//! optional. That would cost an allocation and a copy per chunk, on both sides,
//! for every screen repaint. Length framing never touches the payload.
//!
//! **Two connections per client, not one multiplexed.** Control is JSON at a
//! low rate; an attach connection carries one session's bytes and is opened and
//! closed with the attachment. Splitting them means a 60 KB repaint cannot delay
//! a status update, there is no channel id in the header, and switching
//! sessions stops being a race — the new attachment is established and its
//! replay taken *before* the old one is dropped, so nothing falls in the gap.

const std = @import("std");
const Io = std.Io;
const sessions = @import("sessions.zig");

/// Bumped when the framing or any payload shape changes. `lcc` on PATH is a
/// symlink to `zig-out/bin/lcc`, so a `zig build` swaps the client under a
/// running daemon — this mismatch is a weekly event during development, and it
/// has to produce a sentence rather than a garbled stream into a live session.
pub const protocol: u32 = 1;

pub const header_len = 5;

/// One cap for every frame, on both connections.
///
/// A full repaint at 200x60 with colour runs about 50 KB, so one repaint is one
/// frame and the sender splits anything larger. A snapshot is the only control
/// frame that could want more, and at the daemon's session cap it comes to
/// roughly 26 KB — so a second, larger cap would buy nothing and cost the thing
/// that matters: a client's decoder buffer has to be sized at `accept`, before
/// `hello` has said which role the connection is. One size removes that
/// ordering problem entirely. Past the cap the daemon truncates the session
/// list and says so, rather than failing.
pub const max_payload = 64 * 1024;

pub const Error = error{
    FrameTooLarge,
    UnknownFrameType,
    WrongRole,
    ShortBuffer,
} || std.mem.Allocator.Error;

pub const Role = enum { control, attach };

/// The high nibble carries role and direction, so a frame that arrived on the
/// wrong connection is rejected by arithmetic rather than a lookup table.
///
///   0x0_  either connection, either direction
///   0x1_  client -> daemon, control      0x2_  daemon -> client, control
///   0x3_  client -> daemon, attach       0x4_  daemon -> client, attach
///
/// Non-exhaustive: an unknown byte off the wire must be a rejected value, not
/// undefined behaviour.
pub const Type = enum(u8) {
    hello = 0x01,

    register = 0x10,
    list = 0x11,
    subscribe = 0x12,
    kill = 0x13,
    stop = 0x14,
    /// A Claude Code hook reporting what a session is doing, keyed by cwd.
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
    /// Scrollback, as opposed to what the child is writing now. Distinct
    /// because a replay must be filtered before it reaches a terminal — see
    /// `ansi.ModeFilter` — and the client cannot tell one from the other by
    /// looking at the bytes.
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
        0x0 => true, // hello, on both
        0x1, 0x2 => role == .control,
        0x3, 0x4 => role == .attach,
        else => false,
    };
}

/// The buffer every decoder must be given, whatever its role.
pub fn bufferLen() usize {
    return max_payload + header_len;
}

pub const Frame = struct {
    type: Type,
    /// Points into the decoder's buffer, and is invalidated by the next call
    /// to `next` or `commit`.
    payload: []const u8,
};

pub fn encodeHeader(t: Type, len: u32) [header_len]u8 {
    var out: [header_len]u8 = undefined;
    out[0] = @intFromEnum(t);
    std.mem.writeInt(u32, out[1..header_len], len, .little);
    return out;
}

/// Little-endian: both ends are the same binary on the same machine, and
/// `readInt(.little)` is what the platform reads for free.
pub fn decodeHeader(bytes: *const [header_len]u8) Error!struct { type: Type, len: u32 } {
    const t: Type = @enumFromInt(bytes[0]);
    if (!known(t)) return Error.UnknownFrameType;
    const len = std.mem.readInt(u32, bytes[1..header_len], .little);
    // Checked before anything is sized, indexed or allocated from it. The
    // length is whatever the peer wrote, and `Io.Reader.take(n)` past its
    // buffer *panics* rather than erroring — over a raw-mode terminal that is a
    // stack trace across someone's session.
    if (len > max_payload) return Error.FrameTooLarge;
    return .{ .type = t, .len = len };
}

/// Header and payload in one call, so a reader can never observe a header
/// without the body behind it.
pub fn writeFrame(w: *Io.Writer, t: Type, payload: []const u8) (Io.Writer.Error || Error)!void {
    if (payload.len > max_payload) return Error.FrameTooLarge;
    const header = encodeHeader(t, @intCast(payload.len));
    try w.writeAll(&header);
    try w.writeAll(payload);
}

/// The only place JSON and framing meet, so the length in the header and the
/// bytes behind it cannot disagree.
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

/// Reassembles frames from reads that split them anywhere.
///
/// Explicit rather than an `Io.Reader`, because the loops that use this poll
/// stdin and a socket together: blocking for the rest of a frame while a
/// keystroke is waiting is the one thing those loops exist to avoid.
///
/// The buffer is supplied by the caller because the two roles need different
/// sizes, and a 256 KB array cannot live on a stack.
pub const Decoder = struct {
    buf: []u8,
    /// Valid bytes in `buf`.
    len: usize = 0,
    /// The frame handed out last time, still occupying the front of `buf`.
    /// Dropped on the next call, so the slice stays valid until then.
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

    /// Free space to read into, so the socket read lands in the decoder's
    /// buffer instead of a scratch one that then has to be copied.
    pub fn writable(self: *Decoder) []u8 {
        self.release();
        return self.buf[self.len..];
    }

    pub fn commit(self: *Decoder, n: usize) void {
        self.len += n;
    }

    /// For callers that already hold the bytes. Reading a socket should use
    /// `writable`/`commit` and avoid the copy.
    pub fn push(self: *Decoder, bytes: []const u8) Error!void {
        const room = self.writable();
        // Cannot happen once every length is validated at the header: the
        // buffer holds the largest frame the role permits, plus its header.
        if (bytes.len > room.len) return Error.FrameTooLarge;
        @memcpy(room[0..bytes.len], bytes);
        self.commit(bytes.len);
    }

    /// The next whole frame, or null when more bytes are needed.
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

// ---------------------------------------------------------------------------
// Control payloads
//
// Every key is always present and an absent value is null rather than dropped,
// the same contract `lcc start --json` keeps. The tests below re-declare each
// shape independently and parse with `ignore_unknown_fields = false`, so
// renaming, dropping *or adding* a key fails here rather than in the daemon.
// ---------------------------------------------------------------------------

/// Frozen. Type byte `0x01`, JSON payload, `protocol` first. Any future version
/// must keep this one frame decodable, or an old client meeting a new daemon
/// gets bytes it cannot parse instead of a sentence it can read.
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
    /// The client's whole environment. Without it a daemon started days ago by
    /// one shell would hand every later session that shell's `PATH`.
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
    /// Set when the list was cut to fit `max_payload`. A contract, not
    /// a failure — a caller that sees it knows the view is partial.
    truncated: bool,
};

/// One whole session replaces one row. Not a field diff: a diff can desync, and
/// a protocol this small has no reconciliation path back. A full row is a few
/// hundred bytes and cannot.
pub const Event = struct {
    kind: []const u8, // added | changed | removed
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
    /// The *effective* size — the componentwise minimum over attached clients,
    /// so a client with a larger terminal can see why it has a margin.
    cols: u16,
    rows: u16,
    input: bool,
    attached_clients: u32,
};

pub const Resize = struct { cols: u16, rows: u16 };

/// What `lcc watch-hook` forwards. `cwd` is the worktree, which is already the
/// key the daemon files sessions under — so a hook needs no session id from
/// lcc's side and no correlation table to keep in step.
pub const Hook = struct {
    cwd: []const u8,
    session_id: []const u8,
    event: []const u8,
    /// Claude Code's permission mode, when the event that fired carried one.
    ///
    /// Defaulted rather than required, so this stayed additive: an empty value
    /// means "nothing reported", which the daemon already has to handle for the
    /// events that never carry a mode at all.
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

    // A corrupt stream must end the connection. Reinterpreting an unknown byte
    // would eventually mean feeding someone's session bytes as keystrokes.
    const bogus = [_]u8{ 0x7e, 0, 0, 0, 0 };
    try std.testing.expectError(Error.UnknownFrameType, decodeHeader(&bogus));
}

test "a length past the cap is refused before anything is sized from it" {
    // The length field is whatever the peer wrote. `Io.Reader.take(n)` beyond
    // its buffer panics rather than erroring, so this check is what stands
    // between a hostile or buggy length and a stack trace over a raw terminal.
    var head = encodeHeader(.output, max_payload + 1);
    try std.testing.expectError(Error.FrameTooLarge, decodeHeader(&head));

    head = encodeHeader(.output, std.math.maxInt(u32));
    try std.testing.expectError(Error.FrameTooLarge, decodeHeader(&head));

    // Exactly at the cap is fine — an off-by-one here would drop full repaints.
    head = encodeHeader(.output, max_payload);
    _ = try decodeHeader(&head);
}

test "every frame the protocol permits fits the buffer every decoder is given" {
    // The invariant that keeps `bufferLen` honest: a frame larger than the
    // buffer it must land in is not a recoverable error, it is a protocol
    // contradicting its own sizing. One cap makes this trivially true — the
    // test stays because the property is what matters, not the arithmetic, and
    // reintroducing a per-type cap would have to keep it.
    try std.testing.expect(max_payload + header_len <= bufferLen());
}

test "role separation rejects a frame that arrived on the wrong connection" {
    try std.testing.expect(allowedOn(.hello, .control));
    try std.testing.expect(allowedOn(.hello, .attach));
    try std.testing.expect(allowedOn(.snapshot, .control));
    try std.testing.expect(!allowedOn(.snapshot, .attach));
    try std.testing.expect(allowedOn(.output, .attach));
    try std.testing.expect(!allowedOn(.output, .control));

    // And the decoder enforces it, rather than leaving it to each call site.
    var buf: [bufferLen()]u8 = undefined;
    var dec = try Decoder.init(&buf, .attach);
    try dec.push(&encodeHeader(.list, 0));
    try std.testing.expectError(Error.WrongRole, dec.next());
}

test "the decoder reassembles frames split at every possible byte offset" {
    const gpa = std.testing.allocator;

    // The test that makes the decoder trustworthy. A socket splits wherever the
    // kernel feels like it, and the failure it produces — a frame silently
    // reassembled wrong — surfaces as corrupted terminal output a long way from
    // here.
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
        // All three, every time, wherever the cut landed.
        try std.testing.expectEqual(payloads.len, got);
    }
}

test "a zero-length payload is an empty slice, not a missing frame" {
    var buf: [bufferLen()]u8 = undefined;
    var dec = try Decoder.init(&buf, .attach);

    // `detach` carries nothing. If an empty payload read as "need more bytes"
    // the connection would hang on the one frame whose whole meaning is that
    // it arrived.
    try dec.push(&encodeHeader(.detach, 0));
    const frame = (try dec.next()).?;
    try std.testing.expectEqual(Type.detach, frame.type);
    try std.testing.expectEqual(@as(usize, 0), frame.payload.len);
    try std.testing.expect((try dec.next()) == null);
}

test "a decoder given too small a buffer says so instead of overflowing later" {
    // The mistake this catches is sizing a decoder by hand and getting it
    // wrong — the buffer has to hold the largest frame the protocol permits, or
    // a legal frame arrives and cannot be assembled.
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
    // The length in the header has to match the bytes behind it, or every
    // subsequent frame on the connection is misaligned.
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
    // Nothing was written: a truncated header would desync the peer.
    try std.testing.expectEqual(@as(usize, 0), w.end);
}

test "the hello payload keeps the shape a mismatched version must still read" {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeControl(gpa, &w, .hello, Hello{ .role = "control", .pid = 4123 });

    // Declared independently and parsed with unknown fields *rejected*, so
    // renaming, dropping or adding a key fails here. `hello` is frozen: an old
    // client meeting a new daemon has to get a version number it can read.
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

    // Environment values contain quotes, backslashes and newlines in practice,
    // and argv carries the initial prompt — which opens with `---` front matter
    // often enough that mangling it would be routine rather than exotic.
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
    // The same contract the `--json` surface keeps: a reader always finds the
    // key and never has to tell "absent" from "not applicable".
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"issue\":null") != null);
}
