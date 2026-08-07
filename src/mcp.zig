const std = @import("std");
const Io = std.Io;
const claude_projects = @import("claude_projects.zig");
const config = @import("config.zig");
const disk = @import("disk.zig");

const claude_json_limit = 32 * 1024 * 1024;

pub const Carried = struct {
    path: []const u8,
    names: []const []const u8,
};

pub fn claudeJsonPath(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]const u8 {
    if (environ.get("LCC_CLAUDE_JSON")) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) return gpa.dupe(u8, override);
    }
    const home = environ.get("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ home, ".claude.json" });
}

pub fn carry(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    repo_root: []const u8,
) !?Carried {
    const found = readServers(gpa, io, environ, repo_root) orelse return null;
    if (found.count() == 0) return null;

    const stored = try config.loadStored(gpa, io, environ);
    const servers = if (stored.mcpCarry) |allow| try only(gpa, found, allow) else found;
    if (servers.count() == 0) return null;

    const body = try std.json.Stringify.valueAlloc(
        gpa,
        .{ .mcpServers = std.json.Value{ .object = servers } },
        .{ .whitespace = .indent_2 },
    );

    const path = try filePath(gpa, environ, repo_root);
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| try cwd.createDirPath(io, parent);
    try cwd.writeFile(io, .{ .sub_path = path, .data = body });

    return .{ .path = path, .names = try gpa.dupe([]const u8, servers.keys()) };
}

fn only(
    gpa: std.mem.Allocator,
    servers: std.json.ObjectMap,
    allow: []const []const u8,
) !std.json.ObjectMap {
    var kept: std.json.ObjectMap = .empty;
    for (servers.keys(), servers.values()) |name, value| {
        for (allow) |wanted| {
            if (std.ascii.eqlIgnoreCase(name, wanted)) {
                try kept.put(gpa, name, value);
                break;
            }
        }
    }
    return kept;
}

fn filePath(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    repo_root: []const u8,
) ![]const u8 {
    const dir = try config.dir(gpa, environ);
    const name = try std.fmt.allocPrint(gpa, "{s}.json", .{
        try claude_projects.dirName(gpa, repo_root),
    });
    return std.fs.path.join(gpa, &.{ dir, "mcp", name });
}

fn readServers(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    repo_root: []const u8,
) ?std.json.ObjectMap {
    const path = claudeJsonPath(gpa, environ) catch return null;
    const raw = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(claude_json_limit)) catch return null;

    const root = std.json.parseFromSliceLeaky(std.json.Value, gpa, raw, .{
        .allocate = .alloc_always,
    }) catch return null;

    if (root != .object) return null;
    const projects = root.object.get("projects") orelse return null;
    if (projects != .object) return null;

    const entry = projects.object.get(repo_root) orelse blk: {
        const resolved = disk.realPath(gpa, io, repo_root);
        if (std.mem.eql(u8, resolved, repo_root)) return null;
        break :blk projects.object.get(resolved) orelse return null;
    };
    if (entry != .object) return null;

    const servers = entry.object.get("mcpServers") orelse return null;
    if (servers != .object) return null;
    return servers.object;
}

const testing = struct {
    const claude_json =
        \\{
        \\  "numStartups": 412,
        \\  "mcpServers": { "context7": { "type": "stdio", "command": "npx" } },
        \\  "projects": {
        \\    "/repo/app": {
        \\      "lastSessionId": "abc",
        \\      "mcpServers": {
        \\        "linear-server": { "type": "http", "url": "https://mcp.linear.app/mcp" },
        \\        "xcode": { "type": "stdio", "command": "xcrun", "args": ["mcpbridge"] }
        \\      }
        \\    },
        \\    "/repo/other": {
        \\      "mcpServers": { "sentry": { "type": "http", "url": "https://mcp.sentry.dev/mcp" } }
        \\    },
        \\    "/repo/bare": { "lastCost": 1.5, "mcpServers": {} }
        \\  }
        \\}
    ;
};

test "carry writes the repo's own servers and nothing else" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const json_path = try std.fs.path.join(arena, &.{ base, "claude.json" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = json_path, .data = testing.claude_json });

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", base);
    try environ.put("LCC_CLAUDE_JSON", json_path);

    const carried = (try carry(arena, io, &environ, "/repo/app")).?;

    try std.testing.expectEqual(@as(usize, 2), carried.names.len);
    try std.testing.expectEqualStrings("linear-server", carried.names[0]);
    try std.testing.expectEqualStrings("xcode", carried.names[1]);

    const written = try Io.Dir.cwd().readFileAlloc(io, carried.path, arena, .limited(1 << 20));
    const Schema = struct {
        mcpServers: struct {
            @"linear-server": struct { type: []const u8, url: []const u8 },
            xcode: struct { type: []const u8, command: []const u8, args: [][]const u8 },
        },
    };
    const parsed = try std.json.parseFromSliceLeaky(Schema, arena, written, .{});
    try std.testing.expectEqualStrings("https://mcp.linear.app/mcp", parsed.mcpServers.@"linear-server".url);
    try std.testing.expectEqualStrings("mcpbridge", parsed.mcpServers.xcode.args[0]);

    try std.testing.expect(std.mem.indexOf(u8, written, "sentry") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "context7") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "lastSessionId") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "numStartups") == null);

    try std.testing.expect(std.mem.startsWith(u8, carried.path, base));
    try std.testing.expect(std.mem.indexOf(u8, carried.path, "-repo-app.json") != null);
}

test "carry is null when there is nothing to carry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const json_path = try std.fs.path.join(arena, &.{ base, "claude.json" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = json_path, .data = testing.claude_json });

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", base);
    try environ.put("LCC_CLAUDE_JSON", json_path);

    try std.testing.expect((try carry(arena, io, &environ, "/repo/unknown")) == null);
    try std.testing.expect((try carry(arena, io, &environ, "/repo/bare")) == null);

    try environ.put("LCC_CLAUDE_JSON", try std.fs.path.join(arena, &.{ base, "gone.json" }));
    try std.testing.expect((try carry(arena, io, &environ, "/repo/app")) == null);

    const broken = try std.fs.path.join(arena, &.{ base, "broken.json" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = broken, .data = "{\"projects\": " });
    try environ.put("LCC_CLAUDE_JSON", broken);
    try std.testing.expect((try carry(arena, io, &environ, "/repo/app")) == null);
}

test "mcpCarry narrows what a worktree is handed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const json_path = try std.fs.path.join(arena, &.{ base, "claude.json" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = json_path, .data = testing.claude_json });

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", base);
    try environ.put("LCC_CLAUDE_JSON", json_path);

    try config.save(arena, io, &environ, .{ .mcpCarry = .{ .only = &.{ "XCODE", "linear-server", "notion" } } });
    const narrowed = (try carry(arena, io, &environ, "/repo/app")).?;
    try std.testing.expectEqual(@as(usize, 2), narrowed.names.len);
    try std.testing.expectEqualStrings("linear-server", narrowed.names[0]);
    try std.testing.expectEqualStrings("xcode", narrowed.names[1]);

    const written = try Io.Dir.cwd().readFileAlloc(io, narrowed.path, arena, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, written, "linear-server") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "xcode") != null);

    try config.save(arena, io, &environ, .{ .mcpCarry = .{ .only = &.{"clickup"} } });
    try std.testing.expect((try carry(arena, io, &environ, "/repo/app")) == null);

    try config.save(arena, io, &environ, .{ .mcpCarry = .{ .only = &.{} } });
    try std.testing.expect((try carry(arena, io, &environ, "/repo/app")) == null);

    try config.save(arena, io, &environ, .{ .mcpCarry = .all });
    const all = (try carry(arena, io, &environ, "/repo/app")).?;
    try std.testing.expectEqual(@as(usize, 2), all.names.len);

    const config_path = try config.path(arena, &environ);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = "{\"mcpCarry\": \"linear-server\"}" });
    try std.testing.expectError(error.InvalidConfig, carry(arena, io, &environ, "/repo/app"));
}
