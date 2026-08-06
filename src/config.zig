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
/// Gitignored files worth sharing with every worktree. `.claude/settings.local.json`
/// is the permission allowlist: without it, each new worktree re-asks for approvals
/// that were already granted in the main checkout.
///
/// `CLAUDE.md` and `CLAUDE.local.md` are here for the repos that keep theirs out of
/// git — a worktree of one hands Claude Code no project instructions at all, which is
/// the same session in a repo it knows nothing about. Claude Code walks up the parent
/// directories looking for both, so a worktree *nested* inside the repo finds them
/// without any help; the link is what covers a template that puts worktrees beside the
/// repo instead. Linking never replaces a file that is already there, so a repo that
/// commits its `CLAUDE.md` keeps the copy its branch carries.
const default_link_patterns = [_][]const u8{
    ".env",
    ".env.*",
    "CLAUDE.md",
    "CLAUDE.local.md",
    ".claude/settings.local.json",
};
const default_link_exclude = [_][]const u8{ ".env.example", ".env.sample", ".env.template" };
const default_active_states = [_][]const u8{ "Todo", "In Progress" };
/// On by default. A session that outlives the terminal that started it is the
/// behaviour worth having without asking for it; `--no-watch` and this key are
/// the two ways back to a plain foreground launch.
pub const default_watch_by_default = true;

/// What `lcc list` may do about the PR and Linear columns.
///
/// One setting rather than two booleans because the three states are exclusive
/// and two flags would let someone ask for both "skip the network" and "ignore
/// the cache", which has no meaning.
pub const ListNetwork = enum {
    /// Ask GitHub and Linear again.
    refresh,
    /// Reuse a recent answer.
    cached,
    /// Skip those columns entirely.
    local,

    pub fn parse(text: []const u8) ?ListNetwork {
        return std.meta.stringToEnum(ListNetwork, std.mem.trim(u8, text, " \t"));
    }
};

/// What the file may contain. Every field optional: absence means "use the default".
pub const Stored = struct {
    clientId: ?[]const u8 = null,
    worktreeTemplate: ?[]const u8 = null,
    linkPatterns: ?[]const []const u8 = null,
    linkExclude: ?[]const []const u8 = null,
    /// Pre-nested-path names for the two above. Still read so an existing
    /// config keeps working; `linkPatterns`/`linkExclude` win when both are set.
    envPatterns: ?[]const []const u8 = null,
    envExclude: ?[]const []const u8 = null,
    activeStates: ?[]const []const u8 = null,
    startTaskCommand: ?[]const u8 = null,
    /// Which of the repo's local-scope MCP servers a worktree is worth handing.
    /// Absent carries all of them. A server the work never calls still costs every
    /// agent in the session its name and its instructions, on every turn.
    mcpCarry: ?[]const []const u8 = null,
    /// Whether `lcc start` hands the session to the daemon rather than taking
    /// over the terminal. On unless turned off — a session that survives its
    /// terminal is what you want by default, and `--no-watch` covers the one-off.
    watchByDefault: ?bool = null,
    /// Reserve the bottom row of an attached session for lcc's status bar.
    statusBar: ?bool = null,
    /// Open new sessions in Claude Code's plan mode. A `--plan` file turns it
    /// off regardless: the session already has a plan.
    planMode: ?bool = null,
    /// `lcc open` resumes the worktree's last session rather than starting fresh.
    resumeSessions: ?bool = null,
    /// The TOKENS column in `lcc list`. Off skips reading transcripts, which is
    /// the whole cost of that column.
    showTokens: ?bool = null,
    /// How `lcc list` treats the PR and Linear columns: `refresh`, `cached` or
    /// `local`. Stored as text — the enum's numbering is an implementation
    /// detail and must not reach disk.
    listNetwork: ?[]const u8 = null,
    /// Offer every assigned issue in the picker, not just `activeStates`.
    allIssues: ?bool = null,
    /// What `lcc remove` leaves behind by default.
    keepBranch: ?bool = null,
    keepDerivedData: ?bool = null,
    keepXcode: ?bool = null,
};

/// How a settings update changes the physical `mcpCarry` key. `all` removes the
/// key, preserving the distinction between carrying everything and carrying none.
pub const McpCarry = union(enum) {
    all,
    only: []const []const u8,
};

/// Values to merge into the stored configuration. A null field is left untouched.
pub const Patch = struct {
    clientId: ?[]const u8 = null,
    worktreeTemplate: ?[]const u8 = null,
    linkPatterns: ?[]const []const u8 = null,
    linkExclude: ?[]const []const u8 = null,
    activeStates: ?[]const []const u8 = null,
    startTaskCommand: ?[]const u8 = null,
    mcpCarry: ?McpCarry = null,
    watchByDefault: ?bool = null,
    statusBar: ?bool = null,
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
    statusBar: bool,
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
        .statusBar = stored.statusBar orelse true,
        .planMode = stored.planMode orelse true,
        .resumeSessions = stored.resumeSessions orelse true,
        .showTokens = stored.showTokens orelse true,
        // An unrecognised value reads as the default rather than failing the
        // whole file — a hand-edited typo should cost one setting, not the run.
        .listNetwork = if (stored.listNetwork) |v| (ListNetwork.parse(v) orelse .cached) else .cached,
        .allIssues = stored.allIssues orelse false,
        .keepBranch = stored.keepBranch orelse false,
        .keepDerivedData = stored.keepDerivedData orelse false,
        .keepXcode = stored.keepXcode orelse false,
    };
}

/// Merges `patch` over what is on disk, then rewrites the file. Fields left
/// null in `patch` keep their stored value.
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
        // Drop the superseded key rather than leave two sources of truth on disk.
        merged.envPatterns = null;
    }
    if (patch.linkExclude) |v| {
        merged.linkExclude = v;
        merged.envExclude = null;
    }
    if (patch.activeStates) |v| merged.activeStates = v;
    if (patch.startTaskCommand) |v| merged.startTaskCommand = v;
    if (patch.watchByDefault) |v| merged.watchByDefault = v;
    if (patch.statusBar) |v| merged.statusBar = v;
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

/// The precedence `load` applies, without touching the filesystem.
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

    // Secrets are the obvious half; these three are what a worktree needs to be the
    // same working environment as the checkout it was cut from.
    try std.testing.expect(hasPattern(defaults, ".claude/settings.local.json"));
    try std.testing.expect(hasPattern(defaults, "CLAUDE.md"));
    try std.testing.expect(hasPattern(defaults, "CLAUDE.local.md"));
}
