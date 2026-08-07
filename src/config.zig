const std = @import("std");
const Io = std.Io;

pub const redirect_port: u16 = 39126;
pub const redirect_uri = "http://localhost:39126/oauth/callback";
pub const authorize_url = "https://linear.app/oauth/authorize";
pub const token_url = "https://api.linear.app/oauth/token";
pub const default_scopes = "read,write";

pub const default_client_id = "6bf6dd7b761b5ce6539cf5a9ed99b4fb";

const default_worktree_template = "{repoRoot}/.lcc/worktrees/{branchLeaf}";
const default_link_patterns = [_][]const u8{
    ".env",
    ".env.*",
    "CLAUDE.md",
    "CLAUDE.local.md",
    ".claude/settings.local.json",
};
const default_link_exclude = [_][]const u8{ ".env.example", ".env.sample", ".env.template" };
const default_active_states = [_][]const u8{ "Todo", "In Progress" };
pub const default_watch_by_default = true;

pub const ListNetwork = enum {
    refresh,
    cached,
    local,

    pub fn parse(text: []const u8) ?ListNetwork {
        return std.meta.stringToEnum(ListNetwork, std.mem.trim(u8, text, " \t"));
    }
};

pub const Stored = struct {
    clientId: ?[]const u8 = null,
    worktreeTemplate: ?[]const u8 = null,
    linkPatterns: ?[]const []const u8 = null,
    linkExclude: ?[]const []const u8 = null,
    envPatterns: ?[]const []const u8 = null,
    envExclude: ?[]const []const u8 = null,
    activeStates: ?[]const []const u8 = null,
    startTaskCommand: ?[]const u8 = null,
    mcpCarry: ?[]const []const u8 = null,
    watchByDefault: ?bool = null,
    planMode: ?bool = null,
    resumeSessions: ?bool = null,
    showTokens: ?bool = null,
    listNetwork: ?[]const u8 = null,
    allIssues: ?bool = null,
    keepBranch: ?bool = null,
    keepDerivedData: ?bool = null,
    keepXcode: ?bool = null,
};

pub const McpCarry = union(enum) {
    all,
    only: []const []const u8,
};

pub const Patch = struct {
    clientId: ?[]const u8 = null,
    worktreeTemplate: ?[]const u8 = null,
    linkPatterns: ?[]const []const u8 = null,
    linkExclude: ?[]const []const u8 = null,
    activeStates: ?[]const []const u8 = null,
    startTaskCommand: ?[]const u8 = null,
    mcpCarry: ?McpCarry = null,
    watchByDefault: ?bool = null,
    planMode: ?bool = null,
    resumeSessions: ?bool = null,
    showTokens: ?bool = null,
    listNetwork: ?ListNetwork = null,
    allIssues: ?bool = null,
    keepBranch: ?bool = null,
    keepDerivedData: ?bool = null,
    keepXcode: ?bool = null,
};

pub const Config = struct {
    clientId: []const u8,
    worktreeTemplate: []const u8,
    linkPatterns: []const []const u8,
    linkExclude: []const []const u8,
    activeStates: []const []const u8,
    startTaskCommand: []const u8,
    mcpCarry: ?[]const []const u8,
    watchByDefault: bool,
    planMode: bool,
    resumeSessions: bool,
    showTokens: bool,
    listNetwork: ListNetwork,
    allIssues: bool,
    keepBranch: bool,
    keepDerivedData: bool,
    keepXcode: bool,
};

pub fn dir(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    const home = environ.get("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ home, ".config", "lcc" });
}

pub fn path(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    const home = environ.get("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ home, ".config", "lcc", "config.json" });
}

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

    return std.json.parseFromSliceLeaky(Stored, gpa, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidConfig;
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
        .linkPatterns = stored.linkPatterns orelse stored.envPatterns orelse &default_link_patterns,
        .linkExclude = stored.linkExclude orelse stored.envExclude orelse &default_link_exclude,
        .activeStates = stored.activeStates orelse &default_active_states,
        .startTaskCommand = stored.startTaskCommand orelse "",
        .mcpCarry = stored.mcpCarry,
        .watchByDefault = stored.watchByDefault orelse default_watch_by_default,
        .planMode = stored.planMode orelse true,
        .resumeSessions = stored.resumeSessions orelse true,
        .showTokens = stored.showTokens orelse true,
        .listNetwork = if (stored.listNetwork) |v| (ListNetwork.parse(v) orelse .cached) else .cached,
        .allIssues = stored.allIssues orelse false,
        .keepBranch = stored.keepBranch orelse false,
        .keepDerivedData = stored.keepDerivedData orelse false,
        .keepXcode = stored.keepXcode orelse false,
    };
}

pub fn save(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    patch: Patch,
) !void {
    var merged = try loadStored(gpa, io, environ);
    if (patch.clientId) |v| merged.clientId = v;
    if (patch.worktreeTemplate) |v| merged.worktreeTemplate = v;
    if (patch.linkPatterns) |v| {
        merged.linkPatterns = v;
        merged.envPatterns = null;
    }
    if (patch.linkExclude) |v| {
        merged.linkExclude = v;
        merged.envExclude = null;
    }
    if (patch.activeStates) |v| merged.activeStates = v;
    if (patch.startTaskCommand) |v| merged.startTaskCommand = v;
    if (patch.watchByDefault) |v| merged.watchByDefault = v;
    if (patch.planMode) |v| merged.planMode = v;
    if (patch.resumeSessions) |v| merged.resumeSessions = v;
    if (patch.showTokens) |v| merged.showTokens = v;
    if (patch.listNetwork) |v| merged.listNetwork = @tagName(v);
    if (patch.allIssues) |v| merged.allIssues = v;
    if (patch.keepBranch) |v| merged.keepBranch = v;
    if (patch.keepDerivedData) |v| merged.keepDerivedData = v;
    if (patch.keepXcode) |v| merged.keepXcode = v;
    if (patch.mcpCarry) |carry| switch (carry) {
        .all => merged.mcpCarry = null,
        .only => |v| merged.mcpCarry = v,
    };

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

fn resolveLinkPatterns(stored: Stored) []const []const u8 {
    return stored.linkPatterns orelse stored.envPatterns orelse &default_link_patterns;
}

fn hasPattern(patterns: []const []const u8, needle: []const u8) bool {
    for (patterns) |pattern| {
        if (std.mem.eql(u8, pattern, needle)) return true;
    }
    return false;
}

test "linkPatterns wins over the older envPatterns, which still works alone" {
    const old: Stored = .{ .envPatterns = &.{".env"} };
    try std.testing.expectEqualStrings(".env", resolveLinkPatterns(old)[0]);

    const both: Stored = .{ .linkPatterns = &.{"x"}, .envPatterns = &.{".env"} };
    try std.testing.expectEqualStrings("x", resolveLinkPatterns(both)[0]);
}

test "the defaults carry Claude Code's own files, not just secrets" {
    const defaults = resolveLinkPatterns(.{});
    try std.testing.expectEqual(@as(usize, 5), defaults.len);

    try std.testing.expect(hasPattern(defaults, ".claude/settings.local.json"));
    try std.testing.expect(hasPattern(defaults, "CLAUDE.md"));
    try std.testing.expect(hasPattern(defaults, "CLAUDE.local.md"));
}
