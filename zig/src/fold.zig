//! Case-insensitive matching over UTF-8.
//!
//! `std.ascii.indexOfIgnoreCase` only folds A-Z, which silently made search
//! case-sensitive for Ukrainian and Russian issue titles. This folds the three
//! alphabets lcc actually meets: ASCII, Latin-1 Supplement, and Cyrillic.
//!
//! Deliberately *not* a general Unicode implementation. Latin Extended-A
//! (Polish, Czech, Turkish) has irregular case pairs and multi-codepoint
//! foldings; covering it half-correctly would be worse than leaving it out,
//! and none of it shows up in this workspace.

const std = @import("std");

/// Simple lowercase mapping for the covered ranges; identity elsewhere.
pub fn foldCodepoint(cp: u21) u21 {
    if (cp < 0x80) return std.ascii.toLower(@intCast(cp));

    // Latin-1 Supplement: À-Þ → à-þ. U+00D7 (×) sits inside the range and is
    // not a letter.
    if (cp >= 0x00C0 and cp <= 0x00DE and cp != 0x00D7) return cp + 0x20;

    // Cyrillic supplement block: Ѐ-Џ → ѐ-џ, which is where Ё, Є, І and Ї live.
    if (cp >= 0x0400 and cp <= 0x040F) return cp + 0x50;
    // Cyrillic basic: А-Я → а-я.
    if (cp >= 0x0410 and cp <= 0x042F) return cp + 0x20;
    // Historic and non-Slavic Cyrillic, including Ukrainian Ґ (U+0490):
    // strictly even/odd upper/lower pairs.
    if (cp >= 0x0460 and cp <= 0x04FF and cp % 2 == 0) return cp + 1;

    return cp;
}

/// Decodes UTF-8, degrading to one codepoint per byte on malformed input so a
/// search over odd data can never fail or loop.
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

/// Byte offset of the first case-insensitive occurrence of `needle`.
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
    // The regression this module exists for: a lowercase query against an
    // uppercase title.
    try std.testing.expect(contains("ВИПРАВИТИ ПАДІННЯ", "виправити"));
    try std.testing.expect(contains("виправити падіння", "ПАДІННЯ"));
    // Ї, І, Є, Ґ are in the supplement block, not the basic one.
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
    // Multiplication sign must not be treated as a letter.
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
