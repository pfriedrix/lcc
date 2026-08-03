const std = @import("std");
const Io = std.Io;

const codex_projects = @import("codex_projects.zig");

pub const ProjectConfig = enum { copy, link };
pub const Status = enum { copied, linked, skipped_exists };
pub const BootstrapOptions = struct {
    source_root: []const u8,
    target_root: []const u8,
    link_patterns: []const []const u8 = &.{},
    project_config: ProjectConfig = .link,
};
pub const Operation = struct {
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    rel: []const u8,
    target: []const u8,
    status: Status,

    pub fn deinit(self: *Operation) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn bootstrap(gpa: std.mem.Allocator, opts: BootstrapOptions) !?Operation {
    return bootstrapWithIo(gpa, std.testing.io, opts);
}

pub fn bootstrapWithIo(gpa: std.mem.Allocator, io: Io, opts: BootstrapOptions) !?Operation {
    _ = opts.link_patterns;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    const rel = ".codex/config.toml";
    const source = try std.fs.path.join(arena, &.{ opts.source_root, ".codex", "config.toml" });
    const target = try std.fs.path.join(arena, &.{ opts.target_root, ".codex", "config.toml" });
    const cwd = Io.Dir.cwd();
    cwd.access(io, source, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    try ensureTargetParentWithinRoot(cwd, io, arena, opts.target_root);
    var status: Status = .skipped_exists;
    if (cwd.access(io, target, .{})) |_| {} else |err| switch (err) {
        error.FileNotFound => {
            try cwd.createDirPath(io, std.fs.path.dirname(target).?);
            switch (opts.project_config) {
                .copy => {
                    try cwd.copyFile(source, cwd, target, io, .{});
                    status = .copied;
                },
                .link => {
                    try cwd.symLink(io, source, target, .{});
                    status = .linked;
                },
            }
        },
        else => return err,
    }
    return .{
        .arena = arena_state,
        .source = source,
        .rel = rel,
        .target = target,
        .status = status,
    };
}

fn ensureTargetParentWithinRoot(cwd: Io.Dir, io: Io, arena: std.mem.Allocator, target_root: []const u8) !void {
    const target_parent = try std.fs.path.join(arena, &.{ target_root, ".codex" });
    const target_parent_stat = cwd.statFile(io, target_parent, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    _ = target_parent_stat;
    const canonical_root = try cwd.realPathFileAlloc(io, target_root, arena);
    const canonical_parent = cwd.realPathFileAlloc(io, target_parent, arena) catch return error.PathOutsideTarget;
    if (!pathWithin(canonical_root, canonical_parent)) return error.PathOutsideTarget;
}

fn pathWithin(root: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, root, path)) return true;
    return std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == std.fs.path.sep;
}

pub const Mcp = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    names: []const []const u8,

    pub fn deinit(self: *Mcp) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn discoverMcp(
    gpa: std.mem.Allocator,
    repo_root: []const u8,
    environ: *const std.process.Environ.Map,
) !?Mcp {
    return discoverMcpWithIo(gpa, std.testing.io, repo_root, environ);
}

pub fn discoverMcpWithIo(
    gpa: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    environ: *const std.process.Environ.Map,
) !?Mcp {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try std.fs.path.join(arena, &.{ repo_root, ".codex", "config.toml" });
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            arena_state.deinit();
            return null;
        },
        else => return err,
    };
    // A repo whose `.codex` *is* the Codex home carries nothing: Codex already
    // loads that file by itself, so reporting its servers as the project's would
    // double-count what the agent reads natively. This is the same reason `start`
    // skips the Claude carry on the main checkout.
    if (isCodexHomeConfig(io, arena, path, environ)) {
        arena_state.deinit();
        return null;
    }
    var names: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const name = parseMcpHeader(line) orelse continue;
        var duplicate = false;
        for (names.items) |existing| duplicate = duplicate or std.mem.eql(u8, existing, name);
        if (!duplicate) try names.append(arena, try arena.dupe(u8, name));
    }
    if (names.items.len == 0) {
        arena_state.deinit();
        return null;
    }
    return .{ .arena = arena_state, .path = path, .names = try names.toOwnedSlice(arena) };
}

/// Whether `path` is the very file Codex loads on its own — `$CODEX_HOME/config.toml`,
/// or `$HOME/.codex/config.toml` when that is unset. Compared canonically, so a
/// `.codex` symlinked at the Codex home is recognised too. Anything that cannot be
/// resolved is not the home config: a missing global config means every repo-local
/// one is genuinely the project's.
fn isCodexHomeConfig(
    io: Io,
    arena: std.mem.Allocator,
    path: []const u8,
    environ: *const std.process.Environ.Map,
) bool {
    const codex_home = codex_projects.home(arena, environ) catch return false;
    const home_config = std.fs.path.join(arena, &.{ codex_home, "config.toml" }) catch return false;
    const cwd = Io.Dir.cwd();
    const canonical_home = cwd.realPathFileAlloc(io, home_config, arena) catch return false;
    const canonical_path = cwd.realPathFileAlloc(io, path, arena) catch return false;
    return std.mem.eql(u8, canonical_home, canonical_path);
}

fn parseMcpHeader(line: []const u8) ?[]const u8 {
    if (line.len < 3 or line[0] != '[' or line[line.len - 1] != ']') return null;
    const body = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (std.mem.startsWith(u8, body, "mcp_servers.")) return unquote(body["mcp_servers.".len..]);
    if (std.mem.startsWith(u8, body, "\"mcp_servers\".")) return unquote(body["\"mcp_servers\".".len..]);
    return null;
}

fn unquote(raw: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len == 0) return null;
    if (value[0] == '"') {
        if (value.len < 2 or value[value.len - 1] != '"') return null;
        return value[1 .. value.len - 1];
    }
    if (std.mem.indexOfAny(u8, value, " \t[]") != null) return null;
    return value;
}
