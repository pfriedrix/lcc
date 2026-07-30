//! Local-scope MCP servers, carried into a worktree.
//!
//! `claude mcp add` without `-s user` stores a server in `~/.claude.json` under
//! `projects["<absolute cwd>"].mcpServers` — the key *is* the directory. A worktree
//! is a different directory, so it inherits none of them: the checkout where
//! `linear-server` was added is the only place it exists. No amount of symlinking
//! fixes that, because the servers are not in the repository at all.
//!
//! So lcc reads them and hands them to Claude Code at launch. `--mcp-config <file>`
//! loads servers from a file, and without `--strict-mcp-config` they add to the user,
//! global and plugin scopes rather than replacing them.
//!
//! Read-only, deliberately. `~/.claude.json` is Claude Code's own working state —
//! session ids, costs, per-project history — and it rewrites the whole file from
//! memory when a session ends. A write from the outside survives only until the next
//! session exits, which is the worst kind of bug: it works when you test it.

const std = @import("std");
const Io = std.Io;
const claude_projects = @import("claude_projects.zig");
const config = @import("config.zig");
const disk = @import("disk.zig");

/// `~/.claude.json` runs to ~100 KB of session state in practice. The ceiling is
/// here so a pathological file cannot be read into memory unbounded.
const claude_json_limit = 32 * 1024 * 1024;

pub const Carried = struct {
    /// The generated file, for `claude --mcp-config <path>`.
    path: []const u8,
    /// Server names, in the order `~/.claude.json` lists them.
    names: []const []const u8,
};

/// Claude Code's config file. `LCC_CLAUDE_JSON` overrides it.
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

/// The local-scope servers `repo_root` owns, written where `claude --mcp-config`
/// can read them. Null when the repo has none — then there is nothing to carry and
/// no flag to pass. A malformed or unreadable `~/.claude.json` is also null: MCP
/// servers are a convenience, and failing a worktree over them would be worse than
/// launching without.
///
/// `mcpCarry` in lcc's own config narrows the set. The allow-list is read here rather
/// than passed in because this is already the one place that knows a worktree needs
/// servers handed to it at all, and both call sites would otherwise thread a list they
/// have no other use for.
pub fn carry(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    repo_root: []const u8,
) !?Carried {
    const found = readServers(gpa, io, environ, repo_root) orelse return null;
    if (found.count() == 0) return null;

    const stored = config.loadStored(gpa, io, environ) catch config.Stored{};
    const servers = if (stored.mcpCarry) |allow| try only(gpa, found, allow) else found;
    if (servers.count() == 0) return null;

    // `{"mcpServers": {…}}` — the shape `--mcp-config` reads, same as `.mcp.json`.
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

/// `servers` reduced to the names `allow` lists, in the file's order so the hint lcc
/// prints still matches what Claude Code loads. A name in `allow` this repo does not
/// have is not an error: the list is written once and outlives any one repo's set.
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

/// One file per repository, named after it the way Claude Code names its project
/// directories: every non-alphanumeric byte becomes `-`. Lossy, and that is fine
/// here — this is a cache keyed by a path, not a path to be recovered.
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

/// `projects[repo_root].mcpServers`, or null when the file, the project entry or the
/// key is missing. The resolved path is tried as well: Claude Code records the cwd it
/// was handed, which is the resolved one, while `repo_root` comes from git.
fn readServers(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    repo_root: []const u8,
) ?std.json.ObjectMap {
    const path = claudeJsonPath(gpa, environ) catch return null;
    const raw = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(claude_json_limit)) catch return null;

    // `alloc_always`: the parsed value must outlive `raw`, which the caller's arena
    // would otherwise be sharing slices with.
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
    /// A `~/.claude.json` shaped like the real one: two repos with local-scope
    /// servers, plus the session-state keys that must not leak into what lcc writes.
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

    // Order is the file's order, so the hint lcc prints matches what was added.
    try std.testing.expectEqual(@as(usize, 2), carried.names.len);
    try std.testing.expectEqualStrings("linear-server", carried.names[0]);
    try std.testing.expectEqualStrings("xcode", carried.names[1]);

    const written = try Io.Dir.cwd().readFileAlloc(io, carried.path, arena, .limited(1 << 20));
    // The shape `--mcp-config` expects, holding this repo's servers only.
    const Schema = struct {
        mcpServers: struct {
            @"linear-server": struct { type: []const u8, url: []const u8 },
            xcode: struct { type: []const u8, command: []const u8, args: [][]const u8 },
        },
    };
    const parsed = try std.json.parseFromSliceLeaky(Schema, arena, written, .{});
    try std.testing.expectEqualStrings("https://mcp.linear.app/mcp", parsed.mcpServers.@"linear-server".url);
    try std.testing.expectEqualStrings("mcpbridge", parsed.mcpServers.xcode.args[0]);

    // Another repo's servers, the global ones, and the session state stay out.
    try std.testing.expect(std.mem.indexOf(u8, written, "sentry") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "context7") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "lastSessionId") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "numStartups") == null);

    // One file per repo, under lcc's own config dir — never inside the repo.
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

    // A repo Claude Code has never run in, and one whose `mcpServers` is empty:
    // both mean "no flag to pass", not "pass an empty config".
    try std.testing.expect((try carry(arena, io, &environ, "/repo/unknown")) == null);
    try std.testing.expect((try carry(arena, io, &environ, "/repo/bare")) == null);

    // A missing or unparsable file is a launch without MCP, not a failed launch.
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

    // `xcode` is dropped, and a name this repo does not have is simply not found.
    try config.save(arena, io, &environ, .{ .mcpCarry = &.{ "linear-server", "notion" } });
    const narrowed = (try carry(arena, io, &environ, "/repo/app")).?;
    try std.testing.expectEqual(@as(usize, 1), narrowed.names.len);
    try std.testing.expectEqualStrings("linear-server", narrowed.names[0]);

    const written = try Io.Dir.cwd().readFileAlloc(io, narrowed.path, arena, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, written, "linear-server") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "xcode") == null);

    // An allow-list that matches nothing is "launch without MCP", like an empty repo.
    try config.save(arena, io, &environ, .{ .mcpCarry = &.{"clickup"} });
    try std.testing.expect((try carry(arena, io, &environ, "/repo/app")) == null);

    // An empty list is not a way to say "all of them" — that is what leaving it out does.
    try config.save(arena, io, &environ, .{ .mcpCarry = &.{} });
    try std.testing.expect((try carry(arena, io, &environ, "/repo/app")) == null);
}
