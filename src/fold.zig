const std = @import("std");

pub fn foldCodepoint(cp: u21) u21 {
    if (cp < 0x80) return std.ascii.toLower(@intCast(cp));

    if (cp >= 0x00C0 and cp <= 0x00DE and cp != 0x00D7) return cp + 0x20;

    if (cp >= 0x0400 and cp <= 0x040F) return cp + 0x50;
    if (cp >= 0x0410 and cp <= 0x042F) return cp + 0x20;
    if (cp >= 0x0460 and cp <= 0x04FF and cp % 2 == 0) return cp + 1;

    return cp;
}

const Codepoints = struct {
    bytes: []const u8,
    i: usize = 0,

    fn next(self: *Codepoints) ?u21 {
        if (self.i >= self.bytes.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.bytes[self.i]) catch {
            defer self.i += 1;
            return self.bytes[self.i];
        };
        if (self.i + len > self.bytes.len) {
            defer self.i += 1;
            return self.bytes[self.i];
        }
        const cp = std.unicode.utf8Decode(self.bytes[self.i..][0..len]) catch {
            defer self.i += 1;
            return self.bytes[self.i];
        };
        self.i += len;
        return cp;
    }
};

fn matchesAt(haystack: []const u8, start: usize, needle: []const u8) bool {
    var h: Codepoints = .{ .bytes = haystack, .i = start };
    var n: Codepoints = .{ .bytes = needle };
    while (n.next()) |needle_cp| {
        const hay_cp = h.next() orelse return false;
        if (foldCodepoint(hay_cp) != foldCodepoint(needle_cp)) return false;
    }
    return true;
}

pub fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    var it: Codepoints = .{ .bytes = haystack };
    while (it.i < haystack.len) {
        const start = it.i;
        if (matchesAt(haystack, start, needle)) return start;
        _ = it.next() orelse break;
    }
    return null;
}

pub fn contains(haystack: []const u8, needle: []const u8) bool {
    return indexOf(haystack, needle) != null;
}

pub fn eql(a: []const u8, b: []const u8) bool {
    var ai: Codepoints = .{ .bytes = a };
    var bi: Codepoints = .{ .bytes = b };
    while (true) {
        const x = ai.next();
        const y = bi.next();
        if (x == null and y == null) return true;
        if (x == null or y == null) return false;
        if (foldCodepoint(x.?) != foldCodepoint(y.?)) return false;
    }
}

test "ascii folding" {
    try std.testing.expect(contains("Fix EXC_BAD_ACCESS race", "exc_bad_access"));
    try std.testing.expect(contains("lowercase", "LOWERCASE"));
    try std.testing.expect(!contains("abc", "abd"));
    try std.testing.expectEqual(@as(?usize, 4), indexOf("Fix EXC", "exc"));
}

test "cyrillic folding covers russian and ukrainian letters" {
    try std.testing.expect(contains("ВИПРАВИТИ ПАДІННЯ", "виправити"));
    try std.testing.expect(contains("виправити падіння", "ПАДІННЯ"));
    try std.testing.expect(contains("ЇЖАК", "їжак"));
    try std.testing.expect(contains("ІНДЕКС", "індекс"));
    try std.testing.expect(contains("ЄДНІСТЬ", "єдність"));
    try std.testing.expect(contains("ҐАНОК", "ґанок"));
    try std.testing.expect(contains("ЁЖИК", "ёжик"));
    try std.testing.expect(!contains("привіт", "прощай"));
}

test "latin-1 accents fold" {
    try std.testing.expect(contains("CAFÉ", "café"));
    try std.testing.expect(contains("Über", "ÜBER"));
    try std.testing.expectEqual(@as(u21, 0x00D7), foldCodepoint(0x00D7));
}

test "eql compares whole strings" {
    try std.testing.expect(eql("In Progress", "in progress"));
    try std.testing.expect(eql("В роботі", "в роботі"));
    try std.testing.expect(!eql("Todo", "To do"));
    try std.testing.expect(!eql("Todo", "Todos"));
}

test "malformed utf-8 does not break the search" {
    const bad = [_]u8{ 'a', 0xFF, 0xC3, 'b' };
    try std.testing.expect(contains(&bad, "a"));
    try std.testing.expect(!contains(&bad, "zz"));
}
