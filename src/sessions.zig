const std = @import("std");
const codex_projects = @import("codex_projects.zig");

pub const Counts = struct {
    messages: u64 = 0,
    input: u64 = 0,
    output: u64 = 0,
    cache_write_5m: u64 = 0,
    cache_write_1h: u64 = 0,
    cache_read: u64 = 0,
    cost_usd: f64 = 0,

    pub fn add(self: *Counts, other: Counts) void {
        self.messages += other.messages;
        self.input += other.input;
        self.output += other.output;
        self.cache_write_5m += other.cache_write_5m;
        self.cache_write_1h += other.cache_write_1h;
        self.cache_read += other.cache_read;
        self.cost_usd += other.cost_usd;
    }
};

pub const ModelUsage = struct { name: []const u8, counts: Counts = .{} };
pub const Usage = struct {
    counts: Counts = .{},
    sessions: usize = 0,
    last: ?[]const u8 = null,
    models: []const ModelUsage = &.{},
    stamps: []const []const u8 = &.{},
};

pub const ClaudeSession = struct {
    session_id: []const u8,
    path: []const u8,
    cwd: []const u8,
    archived: bool,
    usage: Usage,
};

pub const CodexSession = struct {
    session_id: []const u8,
    rollout_path: []const u8,
    session_root: []const u8,
    cwd: []const u8,
    archived: bool,
    usage: Usage,
};

pub const Session = union(enum) {
    claude: ClaudeSession,
    codex: CodexSession,

    pub fn identity(self: Session) []const u8 {
        return switch (self) {
            .claude => |entry| identityBuffer("claude", entry.session_id),
            .codex => |entry| identityBuffer("codex", entry.session_id),
        };
    }

    pub fn cwd(self: Session) []const u8 {
        return switch (self) {
            .claude => |entry| entry.cwd,
            .codex => |entry| entry.cwd,
        };
    }

    pub fn usage(self: Session) Usage {
        return switch (self) {
            .claude => |entry| entry.usage,
            .codex => |entry| entry.usage,
        };
    }
};

threadlocal var identity_bytes: [1024]u8 = undefined;
fn identityBuffer(provider: []const u8, id: []const u8) []const u8 {
    return std.fmt.bufPrint(&identity_bytes, "{s}:{s}", .{ provider, id }) catch "";
}

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    sessions: []Session,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn all(self: Snapshot) []const Session {
        return self.sessions;
    }

    pub fn sessionsForWorktree(self: *Snapshot, worktree: []const u8) []const Session {
        var matched: std.ArrayList(Session) = .empty;
        for (self.sessions) |entry| {
            if (sameWorktree(entry.cwd(), worktree)) matched.append(self.arena.allocator(), entry) catch return &.{};
        }
        return matched.toOwnedSlice(self.arena.allocator()) catch &.{};
    }

    pub fn usageForWorktree(self: *Snapshot, worktree: []const u8) Usage {
        const arena = self.arena.allocator();
        var result: Usage = .{};
        var models: std.ArrayList(ModelUsage) = .empty;
        var stamps: std.ArrayList([]const u8) = .empty;
        for (self.sessions) |entry| {
            if (!sameWorktree(entry.cwd(), worktree)) continue;
            const one = entry.usage();
            result.sessions += 1;
            result.counts.add(one.counts);
            if (one.last) |last| {
                if (result.last == null or std.mem.lessThan(u8, result.last.?, last)) result.last = last;
            }
            for (one.models) |model| addModel(arena, &models, model) catch return .{};
            stamps.appendSlice(arena, one.stamps) catch return .{};
        }
        result.models = models.toOwnedSlice(arena) catch return .{};
        result.stamps = stamps.toOwnedSlice(arena) catch return .{};
        return result;
    }
};

pub fn merge(gpa: std.mem.Allocator, claude: []const Session, codex: []const Session) !Snapshot {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(Session) = .empty;
    for (claude) |entry| try out.append(arena, try cloneSession(arena, entry));
    for (codex) |entry| try out.append(arena, try cloneSession(arena, entry));
    return .{ .arena = arena_state, .sessions = try out.toOwnedSlice(arena) };
}

pub const ScanMode = enum { cold, cached };
pub const Scanner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,

    pub fn init(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) !Scanner {
        return .{ .gpa = gpa, .io = std.testing.io, .environ = environ };
    }

    pub fn initWithIo(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) Scanner {
        return .{ .gpa = gpa, .io = io, .environ = environ };
    }

    pub fn deinit(_: *Scanner) void {}

    pub fn scan(self: *Scanner, _: ScanMode) !Snapshot {
        var catalog = try codex_projects.scanWithIo(self.gpa, self.io, self.environ);
        defer catalog.deinit();
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        var out: std.ArrayList(Session) = .empty;
        for (catalog.entries) |entry| {
            const parsed = parseCodexUsage(arena, self.io, entry.rollout_path) orelse continue;
            try out.append(arena, .{ .codex = .{
                .session_id = try arena.dupe(u8, entry.session_id),
                .rollout_path = try arena.dupe(u8, entry.rollout_path),
                .session_root = try arena.dupe(u8, entry.session_root),
                .cwd = try arena.dupe(u8, entry.cwd),
                .archived = entry.archived,
                .usage = parsed,
            } });
        }
        return .{ .arena = arena_state, .sessions = try out.toOwnedSlice(arena) };
    }
};

fn sameWorktree(cwd: []const u8, worktree: []const u8) bool {
    if (std.mem.eql(u8, cwd, worktree)) return true;
    if (!std.mem.startsWith(u8, cwd, worktree) or cwd.len <= worktree.len) return false;
    return cwd[worktree.len] == std.fs.path.sep;
}

fn addModel(arena: std.mem.Allocator, models: *std.ArrayList(ModelUsage), value: ModelUsage) !void {
    for (models.items) |*model| {
        if (std.mem.eql(u8, model.name, value.name)) {
            model.counts.add(value.counts);
            return;
        }
    }
    try models.append(arena, .{ .name = try arena.dupe(u8, value.name), .counts = value.counts });
}

fn cloneUsage(arena: std.mem.Allocator, value: Usage) !Usage {
    const models = try arena.alloc(ModelUsage, value.models.len);
    for (value.models, 0..) |model, i| models[i] = .{ .name = try arena.dupe(u8, model.name), .counts = model.counts };
    const stamps = try arena.alloc([]const u8, value.stamps.len);
    for (value.stamps, 0..) |stamp, i| stamps[i] = try arena.dupe(u8, stamp);
    return .{
        .counts = value.counts,
        .sessions = value.sessions,
        .last = if (value.last) |last| try arena.dupe(u8, last) else null,
        .models = models,
        .stamps = stamps,
    };
}

fn cloneSession(arena: std.mem.Allocator, value: Session) !Session {
    return switch (value) {
        .claude => |entry| .{ .claude = .{
            .session_id = try arena.dupe(u8, entry.session_id),
            .path = try arena.dupe(u8, entry.path),
            .cwd = try arena.dupe(u8, entry.cwd),
            .archived = entry.archived,
            .usage = try cloneUsage(arena, entry.usage),
        } },
        .codex => |entry| .{ .codex = .{
            .session_id = try arena.dupe(u8, entry.session_id),
            .rollout_path = try arena.dupe(u8, entry.rollout_path),
            .session_root = try arena.dupe(u8, entry.session_root),
            .cwd = try arena.dupe(u8, entry.cwd),
            .archived = entry.archived,
            .usage = try cloneUsage(arena, entry.usage),
        } },
    };
}

const TokenTotals = struct {
    input_tokens: u64 = 0,
    cached_input_tokens: u64 = 0,
    output_tokens: u64 = 0,
};
const RolloutLine = struct {
    timestamp: ?[]const u8 = null,
    type: ?[]const u8 = null,
    payload: ?struct {
        model: ?[]const u8 = null,
        type: ?[]const u8 = null,
        info: ?struct { total_token_usage: ?TokenTotals = null } = null,
    } = null,
};

fn parseCodexUsage(arena: std.mem.Allocator, io: std.Io, path: []const u8) ?Usage {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch return null;
    var models: std.ArrayList(ModelUsage) = .empty;
    var stamps: std.ArrayList([]const u8) = .empty;
    var total: Counts = .{};
    var previous: TokenTotals = .{};
    var model: []const u8 = "unknown";
    var last: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const record = std.json.parseFromSliceLeaky(RolloutLine, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        const kind = record.type orelse continue;
        const payload = record.payload orelse continue;
        if (std.mem.eql(u8, kind, "turn_context")) {
            if (payload.model) |value| if (value.len > 0) {
                model = value;
            };
            continue;
        }
        if (!std.mem.eql(u8, kind, "event_msg")) continue;
        if (record.timestamp) |stamp| {
            if (last == null or std.mem.lessThan(u8, last.?, stamp)) last = stamp;
        }
        if (std.mem.eql(u8, payload.type orelse "", "user_message") or std.mem.eql(u8, payload.type orelse "", "agent_message")) total.messages += 1;
        if (!std.mem.eql(u8, payload.type orelse "", "token_count")) continue;
        const current = (payload.info orelse continue).total_token_usage orelse continue;
        const reset = current.input_tokens < previous.input_tokens or current.cached_input_tokens < previous.cached_input_tokens or current.output_tokens < previous.output_tokens;
        const delta = Counts{
            .input = if (reset) current.input_tokens else current.input_tokens - previous.input_tokens,
            .output = if (reset) current.output_tokens else current.output_tokens - previous.output_tokens,
            .cache_read = if (reset) current.cached_input_tokens else current.cached_input_tokens - previous.cached_input_tokens,
        };
        total.input += delta.input;
        total.output += delta.output;
        total.cache_read += delta.cache_read;
        addModel(arena, &models, .{ .name = model, .counts = delta }) catch return null;
        if (record.timestamp) |stamp| {
            stamps.append(arena, stamp) catch return null;
        }
        previous = current;
    }
    if (models.items.len > 0) models.items[0].counts.messages = total.messages;
    return .{
        .counts = total,
        .sessions = 1,
        .last = last,
        .models = models.toOwnedSlice(arena) catch return null,
        .stamps = stamps.toOwnedSlice(arena) catch return null,
    };
}
