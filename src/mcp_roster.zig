const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const exec = @import("exec.zig");

const stale_after_seconds: i64 = 24 * 60 * 60;
const cache_limit = 1 << 20;

const Stored = struct {
    fetchedAt: i64 = 0,
    names: []const []const u8 = &.{},
};

pub fn path(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]const u8 {
    if (environ.get("LCC_MCP_ROSTER")) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) return gpa.dupe(u8, override);
    }
    const dir = try config.dir(gpa, environ);
    return std.fs.path.join(gpa, &.{ dir, "mcp-roster.json" });
}

pub fn parse(gpa: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const at = std.mem.indexOf(u8, trimmed, ": ") orelse continue;
        const name = std.mem.trim(u8, trimmed[0..at], " \t");
        if (name.len == 0) continue;
        if (has(out.items, name)) continue;
        try out.append(gpa, try gpa.dupe(u8, name));
    }
    return out.toOwnedSlice(gpa);
}

fn has(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

pub fn cached(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    now: i64,
) ?[]const []const u8 {
    const file_path = path(gpa, environ) catch return null;
    const raw = Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(cache_limit)) catch return null;
    const stored = std.json.parseFromSliceLeaky(Stored, gpa, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    if (!fresh(stored.fetchedAt, now)) return null;
    return stored.names;
}

pub fn fresh(fetched_at: i64, now: i64) bool {
    if (fetched_at > now) return false;
    return now - fetched_at < stale_after_seconds;
}

pub fn write(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    names: []const []const u8,
    now: i64,
) !void {
    const body = try std.json.Stringify.valueAlloc(gpa, Stored{
        .fetchedAt = now,
        .names = names,
    }, .{ .whitespace = .indent_2 });

    const file_path = try path(gpa, environ);
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(file_path)) |parent| try cwd.createDirPath(io, parent);
    try cwd.writeFile(io, .{ .sub_path = file_path, .data = body });
}

pub fn refresh(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    cwd: ?[]const u8,
    now: i64,
) ![]const []const u8 {
    const out = try exec.run(gpa, io, &.{ "claude", "mcp", "list" }, cwd);
    defer out.deinit(gpa);
    const names = try parse(gpa, out.stdout);
    if (names.len == 0) return names;
    write(gpa, io, environ, names, now) catch {};
    return names;
}

pub fn resolve(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    cwd: ?[]const u8,
    now: i64,
) ![]const []const u8 {
    if (cached(gpa, io, environ, now)) |names| return names;
    return refresh(gpa, io, environ, cwd, now) catch &.{};
}

const testing = std.testing;

const sample =
    \\Checking MCP server health…
    \\
    \\claude.ai KMA MCP Gateway: https://mcp.kissmyapps.site/mcp - ! Needs authentication
    \\claude.ai Google Calendar: https://calendarmcp.googleapis.com/mcp/v1 - ✔ Connected
    \\plugin:figma:figma: https://mcp.figma.com/mcp - ✔ Connected
    \\context7: npx -y @upstash/context7-mcp - ✔ Connected
    \\pencil: /Applications/Pencil.app/Contents/MacOS/x --app desktop - ✘ Failed to connect — ENOENT: ENOENT: no such file
    \\context7: npx -y @upstash/context7-mcp - ✔ Connected
;

test "a listing yields the names, however many colons and spaces they carry" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const names = try parse(arena, sample);
    try testing.expectEqual(@as(usize, 5), names.len);
    try testing.expectEqualStrings("claude.ai KMA MCP Gateway", names[0]);
    try testing.expectEqualStrings("claude.ai Google Calendar", names[1]);
    try testing.expectEqualStrings("plugin:figma:figma", names[2]);
    try testing.expectEqualStrings("context7", names[3]);
    try testing.expectEqualStrings("pencil", names[4]);
}

test "the header, the blank lines and a repeated row are not servers" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (try parse(arena, sample)) |name| {
        try testing.expect(std.mem.indexOf(u8, name, "Checking") == null);
        try testing.expect(name.len > 0);
    }
    try testing.expectEqual(@as(usize, 0), (try parse(arena, "")).len);
    try testing.expectEqual(@as(usize, 0), (try parse(arena, "No MCP servers configured.\n")).len);
}

test "a roster older than a day is no answer, so the next setup asks Claude Code again" {
    const day: i64 = 24 * 60 * 60;
    try testing.expect(fresh(1000, 1000));
    try testing.expect(fresh(1000, 1000 + day - 1));
    try testing.expect(!fresh(1000, 1000 + day));
    try testing.expect(!fresh(1000, 999));
}

test "the cache round-trips, and a stale or damaged one reads as nothing" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", base);

    try testing.expect(cached(arena, io, &environ, 5000) == null);

    try write(arena, io, &environ, &.{ "context7", "claude.ai Slack" }, 5000);
    const names = cached(arena, io, &environ, 5000).?;
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("claude.ai Slack", names[1]);

    try testing.expect(cached(arena, io, &environ, 5000 + 24 * 60 * 60) == null);

    const file_path = try path(arena, &environ);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "{\"names\": " });
    try testing.expect(cached(arena, io, &environ, 5000) == null);
}

test "LCC_MCP_ROSTER moves the cache off the real config directory" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", "/home/someone");
    try testing.expect(std.mem.endsWith(u8, try path(arena, &environ), "/.config/lcc/mcp-roster.json"));

    try environ.put("LCC_MCP_ROSTER", "/tmp/roster.json");
    try testing.expectEqualStrings("/tmp/roster.json", try path(arena, &environ));
}
