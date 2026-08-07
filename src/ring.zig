const std = @import("std");

pub const Ring = struct {
    buf: []u8,
    written: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, capacity: usize) !Ring {
        std.debug.assert(capacity > 0);
        return .{ .buf = try gpa.alloc(u8, capacity) };
    }

    pub fn deinit(r: *Ring, gpa: std.mem.Allocator) void {
        gpa.free(r.buf);
        r.* = undefined;
    }

    pub fn oldest(r: Ring) u64 {
        return r.written -| r.buf.len;
    }

    pub fn append(r: *Ring, bytes: []const u8) void {
        const tail = if (bytes.len > r.buf.len) bytes[bytes.len - r.buf.len ..] else bytes;
        const at = r.written + (bytes.len - tail.len);
        const start: usize = @intCast(at % r.buf.len);
        const first = @min(tail.len, r.buf.len - start);
        @memcpy(r.buf[start..][0..first], tail[0..first]);
        if (first < tail.len) @memcpy(r.buf[0 .. tail.len - first], tail[first..]);
        r.written += bytes.len;
    }

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

    pub fn clamp(r: Ring, cursor: u64) struct { cursor: u64, skipped: bool } {
        const floor = r.oldest();
        if (cursor < floor) return .{ .cursor = floor, .skipped = true };
        return .{ .cursor = cursor, .skipped = false };
    }
};

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

    r.append("abcde");
    r.append("fghij");

    const parts = r.since(2);
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

    const fresh = r.since(0);
    try std.testing.expectEqual(@as(usize, 0), fresh[0].len + fresh[1].len);

    r.append("hello");
    const done = r.since(r.written);
    try std.testing.expectEqual(@as(usize, 0), done[0].len);
    try std.testing.expectEqual(@as(usize, 0), done[1].len);
}

test "clamp reports the skip exactly when bytes were lost" {
    const gpa = std.testing.allocator;
    var r = try Ring.init(gpa, 8);
    defer r.deinit(gpa);

    r.append("abcdefgh");
    r.append("ijkl");

    const kept = r.clamp(4);
    try std.testing.expectEqual(@as(u64, 4), kept.cursor);
    try std.testing.expect(!kept.skipped);

    const lost = r.clamp(0);
    try std.testing.expectEqual(@as(u64, 4), lost.cursor);
    try std.testing.expect(lost.skipped);

    const current = r.clamp(12);
    try std.testing.expectEqual(@as(u64, 12), current.cursor);
    try std.testing.expect(!current.skipped);
}

test "one append larger than the whole ring keeps the tail" {
    const gpa = std.testing.allocator;
    var r = try Ring.init(gpa, 4);
    defer r.deinit(gpa);

    r.append("abcdefghij");
    const got = try collect(gpa, r, 0);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("ghij", got);

    try std.testing.expectEqual(@as(u64, 10), r.written);
    try std.testing.expect(r.clamp(0).skipped);
}

test "bytes survive a wrap that lands exactly on the boundary" {
    const gpa = std.testing.allocator;
    var r = try Ring.init(gpa, 8);
    defer r.deinit(gpa);

    r.append("abcdefgh");
    try std.testing.expectEqual(@as(usize, 0), r.since(8)[0].len);

    r.append("ij");
    const got = try collect(gpa, r, 8);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("ij", got);
}
