//! `~/.config/lcc/config.json` — same file and same keys as the TypeScript version.

const std = @import("std");
const Io = std.Io;

pub const redirect_port: u16 = 39126;
pub const redirect_uri = "http://localhost:39126/oauth/callback";
pub const authorize_url = "https://linear.app/oauth/authorize";
pub const token_url = "https://api.linear.app/oauth/token";
pub const default_scopes = "read,write";

/// Public OAuth client for the `lcc` tool. client_id is non-secret by OAuth design;
/// PKCE protects the flow without requiring a client_secret. Override with
/// LCC_CLIENT_ID env var or `lcc auth setup --client-id <id>` for forks / self-hosted.
pub const default_client_id = "6bf6dd7b761b5ce6539cf5a9ed99b4fb";

const default_worktree_template = "{repoRoot}/.lcc/worktrees/{branchLeaf}";
const default_env_patterns = [_][]const u8{ ".env", ".env.*" };
const default_env_exclude = [_][]const u8{ ".env.example", ".env.sample", ".env.template" };
const default_active_states = [_][]const u8{ "Todo", "In Progress" };

/// What the file may contain. Every field optional: absence means "use the default".
pub const Stored = struct {
    clientId: ?[]const u8 = null,
    worktreeTemplate: ?[]const u8 = null,
    envPatterns: ?[]const []const u8 = null,
    envExclude: ?[]const []const u8 = null,
    activeStates: ?[]const []const u8 = null,
    startTaskCommand: ?[]const u8 = null,
};

pub const Config = struct {
    clientId: []const u8,
    worktreeTemplate: []const u8,
    envPatterns: []const []const u8,
    envExclude: []const []const u8,
    activeStates: []const []const u8,
    startTaskCommand: []const u8,
};

pub fn dir(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    const home = environ.get("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ home, ".config", "lcc" });
}

pub fn path(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    const home = environ.get("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ home, ".config", "lcc", "config.json" });
}

/// Reads the file if present. Strings are allocated with `gpa` and live as long
/// as it does — callers use an arena.
pub fn loadStored(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) !Stored {
    const file_path = try path(gpa, environ);
    defer gpa.free(file_path);

    const raw = Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer gpa.free(raw);

    // `alloc_always`: the default borrows slices out of `raw` where it can, and
    // `raw` is freed on the way out of this function.
    return std.json.parseFromSliceLeaky(Stored, gpa, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return .{};
}

pub fn load(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) !Config {
    const stored = try loadStored(gpa, io, environ);
    const env_client_id = blk: {
        const v = environ.get("LCC_CLIENT_ID") orelse break :blk null;
        break :blk if (v.len > 0) v else null;
    };
    return .{
        .clientId = env_client_id orelse stored.clientId orelse default_client_id,
        .worktreeTemplate = stored.worktreeTemplate orelse default_worktree_template,
        .envPatterns = stored.envPatterns orelse &default_env_patterns,
        .envExclude = stored.envExclude orelse &default_env_exclude,
        .activeStates = stored.activeStates orelse &default_active_states,
        .startTaskCommand = stored.startTaskCommand orelse "",
    };
}

/// Merges `patch` over what is on disk, then rewrites the file. Fields left
/// null in `patch` keep their stored value.
pub fn save(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    patch: Stored,
) !void {
    var merged = try loadStored(gpa, io, environ);
    if (patch.clientId) |v| merged.clientId = v;
    if (patch.worktreeTemplate) |v| merged.worktreeTemplate = v;
    if (patch.envPatterns) |v| merged.envPatterns = v;
    if (patch.envExclude) |v| merged.envExclude = v;
    if (patch.activeStates) |v| merged.activeStates = v;
    if (patch.startTaskCommand) |v| merged.startTaskCommand = v;

    const body = try std.json.Stringify.valueAlloc(gpa, merged, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    defer gpa.free(body);

    const config_dir = try dir(gpa, environ);
    defer gpa.free(config_dir);
    const file_path = try path(gpa, environ);
    defer gpa.free(file_path);

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, config_dir);
    var file = try cwd.createFile(io, file_path, .{ .truncate = true });
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(body);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}
