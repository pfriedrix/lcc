//! A fixed byte ring with monotonic sequence numbers, so a reader that stops
//! reading loses bytes instead of costing the writer memory.
//!
//! This is the whole backpressure design for `lcc watch`. A session's output
//! goes into one ring; every attached client holds a `u64` cursor into it
//! rather than a queue of its own. So a client that has stopped reading — a
//! suspended terminal, a stalled ssh link — loses *scrollback*, never the
//! session's output, and costs the daemon neither an allocation nor a wakeup.
//! The alternative, a per-client byte queue, makes one wedged client able to
//! exhaust memory on behalf of an agent that is working perfectly.
//!
//! `written` is bytes-ever-written and never wraps: at a sustained megabyte a
//! second a `u64` takes half a million years to overflow, which is what lets a
//! cursor be a plain integer with no generation counter beside it.

const std = @import("std");

pub const Ring = struct {
    buf: []u8,
    /// Bytes ever appended. Readers hold one of these, not a pointer, so a
    /// wrap that happens between two reads is arithmetic rather than a
    /// dangling slice.
    written: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, capacity: usize) !Ring {
        std.debug.assert(capacity > 0);
        return .{ .buf = try gpa.alloc(u8, capacity) };
    }

    pub fn deinit(r: *Ring, gpa: std.mem.Allocator) void {
        gpa.free(r.buf);
        r.* = undefined;
    }

    /// The lowest cursor still backed by bytes. Anything below it has been
    /// overwritten.
    pub fn oldest(r: Ring) u64 {
        return r.written -| r.buf.len;
    }

    /// Never fails, never allocates, never blocks — the three properties the
    /// daemon's output path depends on. Oldest bytes fall out.
    pub fn append(r: *Ring, bytes: []const u8) void {
        // A write larger than the ring can only end as its own tail, so skip
        // straight there rather than wrapping the buffer several times over.
        const tail = if (bytes.len > r.buf.len) bytes[bytes.len - r.buf.len ..] else bytes;
        // Where the tail lands, not where the write began: a truncated append
        // still ends where the full one would have, so the dropped prefix has
        // to advance the position too. Using the start offset instead leaves
        // the bytes rotated, and `since` then reads them out of order.
        const at = r.written + (bytes.len - tail.len);
        const start: usize = @intCast(at % r.buf.len);
        const first = @min(tail.len, r.buf.len - start);
        @memcpy(r.buf[start..][0..first], tail[0..first]);
        if (first < tail.len) @memcpy(r.buf[0 .. tail.len - first], tail[first..]);
        // The full length, not the truncated tail: `written` counts what the
        // session produced, and a reader compares its cursor against it to
        // learn that it fell behind.
        r.written += bytes.len;
    }

    /// What `cursor` has not seen, in order, split where the buffer wraps.
    /// Both slices empty means caught up — which is what keeps `POLLOUT` off a
    /// client that has nothing waiting, and with it the daemon's idle cost at
    /// zero wakeups.
    ///
    /// A cursor below `oldest` is treated as `oldest`: the bytes are simply
    /// gone. Callers that need to *tell* the client it lost some ask `clamp`
    /// first.
    pub fn since(r: Ring, cursor: u64) [2][]const u8 {
        const from = @max(cursor, r.oldest());
        if (from >= r.written) return .{ &.{}, &.{} };

        const available: usize = @intCast(r.written - from);
        const start: usize = @intCast(from % r.buf.len);
        const first = @min(available, r.buf.len - start);
        return .{
            r.buf[start..][0..first],
            r.buf[0 .. available - first],
        };
    }

    /// The cursor moved forward into the ring, and whether that lost anything.
    /// `skipped` is what makes a client redraw from scratch instead of
    /// resuming mid-escape-sequence against a screen it can no longer derive.
    pub fn clamp(r: Ring, cursor: u64) struct { cursor: u64, skipped: bool } {
        const floor = r.oldest();
        if (cursor < floor) return .{ .cursor = floor, .skipped = true };
        return .{ .cursor = cursor, .skipped = false };
    }
};

/// `since` as one contiguous string, for tests. Production never needs it —
/// the daemon writes the two slices straight to a socket.
fn collect(gpa: std.mem.Allocator, r: Ring, cursor: u64) ![]u8 {
    const parts = r.since(cursor);
    const out = try gpa.alloc(u8, parts[0].len + parts[1].len);
    @memcpy(out[0..parts[0].len], parts[0]);
    @memcpy(out[parts[0].len..], parts[1]);
    return out;
}

test "a reader that never reads loses the oldest bytes, not the newest" {
    const gpa = std.testing.allocator;
    var r = try Ring.init(gpa, 8);
    defer r.deinit(gpa);

    r.append("abcdefgh");
    r.append("ijklmnop");
    r.append("qrstuvwx");

    // Three ring-fulls in, a reader starting from zero gets the *last* eight
    // bytes. Losing the newest instead would be the exact wrong failure: on
    // reattach the only output anyone cares about is what just happened.
    const got = try collect(gpa, r, 0);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("qrstuvwx", got);
    try std.testing.expectEqual(@as(u64, 24), r.written);
    try std.testing.expectEqual(@as(u64, 16), r.oldest());
}

test "since spans the wrap in two slices, in order" {
    const gpa = std.testing.allocator;
    var r = try Ring.init(gpa, 8);
    defer r.deinit(gpa);

    r.append("abcde"); // occupies 0..5
    r.append("fghij"); // wraps: fgh at 5..8, ij at 0..2

    const parts = r.since(2);
    // Two slices, not one: the caller writes them back to back, and getting
    // the order wrong scrambles the terminal rather than failing loudly.
    try std.testing.expectEqualStrings("cdefgh", parts[0]);
    try std.testing.expectEqualStrings("ij", parts[1]);

    const got = try collect(gpa, r, 2);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("cdefghij", got);
}

test "a caught-up cursor asks for nothing" {
    const gpa = std.testing.allocator;
    var r = try Ring.init(gpa, 16);
    defer r.deinit(gpa);

    // An empty ring is caught up at zero.
    const fresh = r.since(0);
    try std.testing.expectEqual(@as(usize, 0), fresh[0].len + fresh[1].len);

    r.append("hello");
    const done = r.since(r.written);
    // Both slices empty is what the daemon reads as "do not arm POLLOUT for
    // this client". A non-empty answer here is a loop that never sleeps.
    try std.testing.expectEqual(@as(usize, 0), done[0].len);
    try std.testing.expectEqual(@as(usize, 0), done[1].len);
}

test "clamp reports the skip exactly when bytes were lost" {
    const gpa = std.testing.allocator;
    var r = try Ring.init(gpa, 8);
    defer r.deinit(gpa);

    r.append("abcdefgh");
    r.append("ijkl"); // written = 12, oldest = 4

    // Still inside the ring: no loss, and the cursor is left alone.
    const kept = r.clamp(4);
    try std.testing.expectEqual(@as(u64, 4), kept.cursor);
    try std.testing.expect(!kept.skipped);

    // Fell off the back: moved up to the floor, and said so.
    const lost = r.clamp(0);
    try std.testing.expectEqual(@as(u64, 4), lost.cursor);
    try std.testing.expect(lost.skipped);

    // Caught up is not a skip.
    const current = r.clamp(12);
    try std.testing.expectEqual(@as(u64, 12), current.cursor);
    try std.testing.expect(!current.skipped);
}

test "one append larger than the whole ring keeps the tail" {
    const gpa = std.testing.allocator;
    var r = try Ring.init(gpa, 4);
    defer r.deinit(gpa);

    // A single 64 KiB read from a pty into a smaller ring is an ordinary event
    // during a full-screen repaint, not an edge case — and copying the whole
    // thing round the ring several times to arrive at the same answer would be
    // wasted work on the hot path.
    r.append("abcdefghij");
    const got = try collect(gpa, r, 0);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("ghij", got);

    // `written` counts what was produced, not what survived — that is how a
    // client learns it fell behind.
    try std.testing.expectEqual(@as(u64, 10), r.written);
    try std.testing.expect(r.clamp(0).skipped);
}

test "bytes survive a wrap that lands exactly on the boundary" {
    const gpa = std.testing.allocator;
    var r = try Ring.init(gpa, 8);
    defer r.deinit(gpa);

    // An append ending flush against the end of the buffer leaves `start` at
    // 0 next time round, which is the off-by-one most ring implementations get
    // wrong in one direction or the other.
    r.append("abcdefgh");
    try std.testing.expectEqual(@as(usize, 0), r.since(8)[0].len);

    r.append("ij");
    const got = try collect(gpa, r, 8);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("ij", got);
}
