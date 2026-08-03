//! Release versions as lcc reads them — out of a `release/X.Y.Z` branch, out of a
//! `vX.Y.Z` git tag, and out of a Linear project's name — and back out as `vX.Y.Z`.
//!
//! A version arrives from three different systems here, which is why this is its
//! own module rather than a corner of `git.zig` or `linear.zig`: putting it in
//! either would make the other two import a sibling sideways, and today they do
//! not know about each other at all. `fold.zig` is the precedent — a small pure
//! utility that belongs to no external system.
//!
//! Zig has no regex, so each scanner below is hand-rolled in the style of
//! `linear.refFromBranch`: pure, `?T`-returning, and answering "no" rather than
//! guessing. `std.SemanticVersion` does the arithmetic once the shape is settled.

const std = @import("std");
const Io = std.Io;

pub const Version = std.SemanticVersion;

/// `v2.6.0` or `2.6.0` — the whole trimmed string and nothing else.
///
/// Strict on purpose, in two ways `std.SemanticVersion.parse` is not. It accepts
/// pre-release and build metadata, so it reads `v2.6.0-rc1` as 2.6.0 and would let
/// a release candidate stand in for the release; both are declined here. And it is
/// anchored, so a project called `v2 rewrite, phase 1` is not a release.
pub fn parse(raw: []const u8) ?Version {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const body = if (trimmed.len > 0 and (trimmed[0] == 'v' or trimmed[0] == 'V'))
        trimmed[1..]
    else
        trimmed;

    const parsed = Version.parse(body) catch return null;
    if (parsed.pre != null or parsed.build != null) return null;
    return parsed;
}

/// The version a release branch names. `release/2.5.2`, `origin/release/2.5.2` and
/// `release/v2.5.2` all answer 2.5.2; `release/2.4` and `hotfix/release/2.4.1` do
/// not.
///
/// Anchored rather than tolerant, unlike `linear.refFromBranch` — whose tolerance
/// is earned by issue keys genuinely turning up in the middle of a branch name.
/// A release prefix does not.
pub fn fromBranch(branch: []const u8) ?Version {
    const short = if (std.mem.startsWith(u8, branch, "origin/"))
        branch["origin/".len..]
    else
        branch;
    if (!std.mem.startsWith(u8, short, "release/")) return null;
    return parse(short["release/".len..]);
}

pub fn less(_: void, a: Version, b: Version) bool {
    return a.order(b) == .lt;
}

pub fn sortAsc(list: []Version) void {
    std.mem.sort(Version, list, {}, less);
}

pub fn max(a: Version, b: Version) Version {
    return if (a.order(b) == .gt) a else b;
}

/// `v2.5.2 → v2.6.0`. Patch releases are cut on a `release/*` branch and never
/// originate from trunk, so trunk's next stop is always a minor.
pub fn nextMinor(v: Version) Version {
    return .{ .major = v.major, .minor = v.minor + 1, .patch = 0 };
}

/// `v2.6.0` rendered with `{f}`, so a human line costs no allocation.
pub const Display = struct {
    version: Version,

    pub fn format(self: Display, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("v{d}.{d}.{d}", .{ self.version.major, self.version.minor, self.version.patch });
    }
};

pub fn show(v: Version) Display {
    return .{ .version = v };
}

/// The same thing owned, for a JSON payload that needs a string it can keep.
pub fn render(gpa: std.mem.Allocator, v: Version) ![]u8 {
    return std.fmt.allocPrint(gpa, "v{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
}

test "parse takes a release version and declines everything that only looks like one" {
    const accepted = [_]struct { text: []const u8, major: usize, minor: usize, patch: usize }{
        .{ .text = "v2.6.0", .major = 2, .minor = 6, .patch = 0 },
        .{ .text = "2.6.0", .major = 2, .minor = 6, .patch = 0 },
        .{ .text = "  v2.6.0\n", .major = 2, .minor = 6, .patch = 0 },
        .{ .text = "V2.6.0", .major = 2, .minor = 6, .patch = 0 },
        .{ .text = "v10.20.30", .major = 10, .minor = 20, .patch = 30 },
    };
    for (accepted) |case| {
        const got = parse(case.text) orelse {
            std.debug.print("expected {s} to parse\n", .{case.text});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(case.major, got.major);
        try std.testing.expectEqual(case.minor, got.minor);
        try std.testing.expectEqual(case.patch, got.patch);
    }

    const declined = [_][]const u8{
        // A release candidate is not the release. `std.SemanticVersion.parse` reads
        // this as 2.6.0, which would let it stand in for one.
        "v2.6.0-rc1",
        "v2.6.0+build.7",
        // Two components is not a version this resolver can order against three.
        "v2.6",
        "v2.6.0.1",
        "v2.06.0",
        // A project name that merely starts with a v.
        "v2 rewrite",
        "version 2.6.0",
        "",
        "v",
    };
    for (declined) |case| {
        if (parse(case)) |got| {
            std.debug.print("expected {s} to be declined, got {f}\n", .{ case, show(got) });
            return error.TestUnexpectedResult;
        }
    }
}

test "fromBranch is anchored, unlike the issue-ref scanner beside it" {
    try std.testing.expectEqual(@as(usize, 5), fromBranch("release/2.5.2").?.minor);
    try std.testing.expectEqual(@as(usize, 2), fromBranch("origin/release/2.5.2").?.patch);
    try std.testing.expectEqual(@as(usize, 5), fromBranch("release/v2.5.2").?.minor);

    // The converse of `linear.refFromBranch`'s "release/2.4.1 is not an issue".
    try std.testing.expect(fromBranch("feature/pe-250-thing") == null);
    try std.testing.expect(fromBranch("main") == null);
    // Two components — a release line, not a release.
    try std.testing.expect(fromBranch("release/2.4") == null);
    // Near misses that a substring search would have taken.
    try std.testing.expect(fromBranch("releases/2.5.2") == null);
    try std.testing.expect(fromBranch("release-2.5.2") == null);
    try std.testing.expect(fromBranch("hotfix/release/2.5.2") == null);
}

test "versions order by number, which is where a lexical sort gets it wrong" {
    // The trap, spelled out: as text `v2.10.0` sorts before `v2.9.0`, so a
    // string-based max answers 2.9.0 — and the next-minor rule then proposes
    // v2.10.0 when the answer is v2.11.0.
    const ten = parse("v2.10.0").?;
    const nine = parse("v2.9.0").?;
    try std.testing.expect(std.mem.order(u8, "v2.10.0", "v2.9.0") == .lt);
    try std.testing.expectEqual(std.math.Order.gt, ten.order(nine));
    try std.testing.expectEqual(@as(usize, 10), max(ten, nine).minor);

    var list = [_]Version{
        parse("v2.9.0").?,
        parse("v2.10.0").?,
        parse("v2.4.1").?,
        parse("v10.0.0").?,
        parse("v2.5.2").?,
    };
    sortAsc(&list);

    const expected = [_][]const u8{ "v2.4.1", "v2.5.2", "v2.9.0", "v2.10.0", "v10.0.0" };
    for (expected, list) |want, got| {
        const rendered = try render(std.testing.allocator, got);
        defer std.testing.allocator.free(rendered);
        try std.testing.expectEqualStrings(want, rendered);
    }
}

test "the next release off trunk is a minor, never a patch" {
    try std.testing.expectEqual(@as(usize, 6), nextMinor(parse("v2.5.2").?).minor);
    try std.testing.expectEqual(@as(usize, 0), nextMinor(parse("v2.5.2").?).patch);
    // Nine to ten, so the bump is arithmetic rather than a digit being appended.
    try std.testing.expectEqual(@as(usize, 10), nextMinor(parse("v2.9.9").?).minor);
    try std.testing.expectEqual(@as(usize, 2), nextMinor(parse("v2.9.9").?).major);
}

test "rendering round-trips through parse" {
    for ([_][]const u8{ "v0.0.0", "v2.6.0", "v10.20.30" }) |want| {
        const rendered = try render(std.testing.allocator, parse(want).?);
        defer std.testing.allocator.free(rendered);
        try std.testing.expectEqualStrings(want, rendered);
    }
}
