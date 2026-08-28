const std = @import("std");

pub fn string(gpa: std.mem.Allocator, xml: []const u8, key: []const u8) !?[]const u8 {
    const tag = try std.fmt.allocPrint(gpa, "<key>{s}</key>", .{key});
    defer gpa.free(tag);

    const key_at = std.mem.indexOf(u8, xml, tag) orelse return null;
    const after = xml[key_at + tag.len ..];

    const open_at = std.mem.indexOf(u8, after, "<string>") orelse return null;
    for (after[0..open_at]) |c| {
        if (!std.ascii.isWhitespace(c)) return null;
    }
    const value_start = open_at + "<string>".len;
    const close_at = std.mem.indexOfPos(u8, after, value_start, "</string>") orelse return null;

    const value = std.mem.trim(u8, after[value_start..close_at], " \t\r\n");
    if (value.len == 0) return null;
    return try decodeEntities(gpa, value);
}

fn decodeEntities(gpa: std.mem.Allocator, value: []const u8) ![]const u8 {
    const replacements = [_][2][]const u8{
        .{ "&lt;", "<" },
        .{ "&gt;", ">" },
        .{ "&quot;", "\"" },
        .{ "&apos;", "'" },
        .{ "&amp;", "&" },
    };
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < value.len) {
        if (value[i] == '&') {
            for (replacements) |pair| {
                if (std.mem.startsWith(u8, value[i..], pair[0])) {
                    try out.appendSlice(gpa, pair[1]);
                    i += pair[0].len;
                    continue :outer;
                }
            }
        }
        try out.append(gpa, value[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

test "a key names its own value, not the one two keys further down" {
    const gpa = std.testing.allocator;
    const xml =
        \\<plist><dict>
        \\<key>BuildVersion</key>
        \\<string>2</string>
        \\<key>CFBundleShortVersionString</key>
        \\<string>26.6</string>
        \\</dict></plist>
    ;
    const version = (try string(gpa, xml, "CFBundleShortVersionString")).?;
    defer gpa.free(version);
    try std.testing.expectEqualStrings("26.6", version);

    const build = (try string(gpa, xml, "BuildVersion")).?;
    defer gpa.free(build);
    try std.testing.expectEqualStrings("2", build);

    try std.testing.expect((try string(gpa, xml, "ProductBuildVersion")) == null);
}

test "a key answered by something other than a string is not that string" {
    const gpa = std.testing.allocator;
    const xml = "<key>Flag</key><true/><key>Name</key><string>App</string>";
    try std.testing.expect((try string(gpa, xml, "Flag")) == null);
}

test "entities come back as the characters they stand for" {
    const gpa = std.testing.allocator;
    const xml = "<key>Path</key><string>/Users/me/App &amp; Co/A&lt;B&gt;.xcodeproj</string>";
    const got = (try string(gpa, xml, "Path")).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/Users/me/App & Co/A<B>.xcodeproj", got);
}

test "an empty value is no value" {
    const gpa = std.testing.allocator;
    try std.testing.expect((try string(gpa, "<key>V</key><string>  </string>", "V")) == null);
    try std.testing.expect((try string(gpa, "<key>V</key>", "V")) == null);
}
