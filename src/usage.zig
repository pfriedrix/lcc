const std = @import("std");
const Io = std.Io;
const cp = @import("claude_projects.zig");
const uc = @import("usage_cache.zig");
const ui = @import("ui.zig");

const transcript_limit = 256 * 1024 * 1024;

const max_depth = 4;

pub const idle_gap_seconds: i64 = 15 * 60;

pub const Counts = struct {
    messages: u64 = 0,
    input: u64 = 0,
    output: u64 = 0,
    cache_write_5m: u64 = 0,
    cache_write_1h: u64 = 0,
    cache_read: u64 = 0,
    cost_usd: f64 = 0,

    pub fn contextTokens(self: Counts) u64 {
        return self.input + self.cache_write_5m + self.cache_write_1h + self.cache_read;
    }

    pub fn tokens(self: Counts) u64 {
        return self.contextTokens() + self.output;
    }

    pub fn cacheWrite(self: Counts) u64 {
        return self.cache_write_5m + self.cache_write_1h;
    }

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

pub const Model = struct {
    name: []const u8,
    counts: Counts = .{},
};

pub const Totals = struct {
    counts: Counts = .{},
    sessions: u64 = 0,
    last: []const u8 = "",
    models: std.ArrayList(Model) = .empty,
    unpriced: bool = false,
    stamps: std.ArrayList(i64) = .empty,

    pub fn empty(self: Totals) bool {
        return self.counts.messages == 0;
    }

    pub fn add(self: *Totals, gpa: std.mem.Allocator, other: Totals) !void {
        self.counts.add(other.counts);
        self.sessions += other.sessions;
        self.unpriced = self.unpriced or other.unpriced;
        if (std.mem.lessThan(u8, self.last, other.last)) self.last = other.last;
        for (other.models.items) |model| {
            (try self.bucket(gpa, model.name)).add(model.counts);
        }
        try self.stamps.appendSlice(gpa, other.stamps.items);
    }

    pub fn activeSeconds(self: Totals, gpa: std.mem.Allocator) !i64 {
        if (self.stamps.items.len < 2) return 0;

        const sorted = try gpa.dupe(i64, self.stamps.items);
        defer gpa.free(sorted);
        std.mem.sort(i64, sorted, {}, std.sort.asc(i64));

        var total: i64 = 0;
        for (sorted[1..], 0..) |at, i| {
            const gap = at - sorted[i];
            if (gap > 0 and gap <= idle_gap_seconds) total += gap;
        }
        return total;
    }

    fn bucket(self: *Totals, gpa: std.mem.Allocator, name: []const u8) !*Counts {
        for (self.models.items) |*model| {
            if (std.mem.eql(u8, model.name, name)) return &model.counts;
        }
        try self.models.append(gpa, .{ .name = name });
        return &self.models.items[self.models.items.len - 1].counts;
    }

    pub fn modelsBySpend(self: Totals, gpa: std.mem.Allocator) ![]const Model {
        const sorted = try gpa.dupe(Model, self.models.items);
        std.mem.sort(Model, sorted, {}, struct {
            fn lessThan(_: void, a: Model, b: Model) bool {
                return a.counts.tokens() > b.counts.tokens();
            }
        }.lessThan);
        return sorted;
    }
};

pub const Scanner = struct {
    gpa: std.mem.Allocator,
    io: Io,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    scratch: std.heap.ArenaAllocator,
    skipped: usize = 0,
    cache: uc.Cache,

    pub fn init(gpa: std.mem.Allocator, io: Io, cache: uc.Cache) Scanner {
        return .{ .gpa = gpa, .io = io, .scratch = .init(gpa), .cache = cache };
    }

    pub fn deinit(self: *Scanner) void {
        self.cache.save();
        self.scratch.deinit();
        self.seen.deinit(self.gpa);
    }

    pub fn project(self: *Scanner, dir_path: []const u8) !Totals {
        var totals: Totals = .{};
        try self.scan(&totals, dir_path, 0);
        return totals;
    }

    fn scan(self: *Scanner, totals: *Totals, dir_path: []const u8, depth: u8) !void {
        if (depth > max_depth) return;

        var dir = Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var it = dir.iterate();
        while (it.next(self.io) catch null) |dirent| {
            switch (dirent.kind) {
                .file => {
                    if (!std.mem.endsWith(u8, dirent.name, ".jsonl")) continue;
                    const path = try std.fs.path.join(self.gpa, &.{ dir_path, dirent.name });
                    try self.transcript(totals, path, depth == 0);
                },
                .directory => {
                    const path = try std.fs.path.join(self.gpa, &.{ dir_path, dirent.name });
                    try self.scan(totals, path, depth + 1);
                },
                else => {},
            }
        }
    }

    pub fn projectDirs(self: *Scanner, dir_paths: []const []const u8) !Totals {
        var totals: Totals = .{};
        for (dir_paths) |path| {
            try totals.add(self.gpa, try self.project(path));
        }
        return totals;
    }

    pub fn worktree(
        self: *Scanner,
        projects: []const cp.Entry,
        worktree_path: []const u8,
    ) !Totals {
        const mine = try cp.forWorktree(self.gpa, self.io, projects, worktree_path);
        const dirs = try self.gpa.alloc([]const u8, mine.len);
        for (mine, 0..) |entry, i| dirs[i] = entry.path;
        return self.projectDirs(dirs);
    }

    fn transcript(self: *Scanner, totals: *Totals, path: []const u8, session: bool) !void {
        const info = Io.Dir.cwd().statFile(self.io, path, .{}) catch return;
        const size = info.size;
        const mtime = std.math.cast(i64, info.mtime.nanoseconds) orelse 0;

        const entry = self.cache.lookup(path, size, mtime) orelse blk: {
            const parsed = self.parse(path) orelse return;
            self.cache.put(path, .{
                .size = size,
                .mtime = mtime,
                .skipped = parsed.skipped,
                .messages = parsed.messages,
            });
            break :blk parsed;
        };

        if (entry.skipped) {
            self.skipped += 1;
            return;
        }
        if (session) totals.sessions += 1;
        try self.apply(totals, entry.messages);
    }

    fn parse(self: *Scanner, path: []const u8) ?uc.Entry {
        _ = self.scratch.reset(.retain_capacity);
        const scratch = self.scratch.allocator();

        const bytes = Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            scratch,
            .limited(transcript_limit),
        ) catch |err| switch (err) {
            error.StreamTooLong => return .{ .skipped = true },
            else => return null,
        };

        var local: std.StringHashMapUnmanaged(void) = .empty;
        var out: std.ArrayList(uc.Message) = .empty;

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const record = std.json.parseFromSliceLeaky(
                Line,
                scratch,
                line,
                .{ .ignore_unknown_fields = true },
            ) catch continue;

            const found = self.extract(record, &local, scratch) orelse continue;
            out.append(self.gpa, found) catch return null;
        }
        return .{ .messages = out.toOwnedSlice(self.gpa) catch return null };
    }

    fn extract(
        self: *Scanner,
        line: Line,
        local: *std.StringHashMapUnmanaged(void),
        scratch: std.mem.Allocator,
    ) ?uc.Message {
        const kind = line.type orelse return null;
        if (!std.mem.eql(u8, kind, "assistant")) return null;
        const msg = line.message orelse return null;
        const usage = msg.usage orelse return null;

        if (msg.id) |id| {
            const slot = local.getOrPut(scratch, id) catch return null;
            if (slot.found_existing) return null;
        }

        var out: uc.Message = .{
            .id = self.gpa.dupe(u8, msg.id orelse "") catch return null,
            .model = self.gpa.dupe(u8, msg.model orelse "") catch return null,
            .input = usage.input_tokens orelse 0,
            .output = usage.output_tokens orelse 0,
            .cache_read = usage.cache_read_input_tokens orelse 0,
            .timestamp = self.gpa.dupe(u8, line.timestamp orelse "") catch return null,
        };

        if (usage.cache_creation) |split| {
            out.cache_write_5m = split.ephemeral_5m_input_tokens orelse 0;
            out.cache_write_1h = split.ephemeral_1h_input_tokens orelse 0;
        } else {
            out.cache_write_5m = usage.cache_creation_input_tokens orelse 0;
        }
        return out;
    }

    fn apply(self: *Scanner, totals: *Totals, messages: []const uc.Message) !void {
        for (messages) |msg| {
            if (msg.id.len > 0) {
                const slot = try self.seen.getOrPut(self.gpa, msg.id);
                if (slot.found_existing) continue;
                slot.key_ptr.* = msg.id;
            }

            var counts: Counts = .{
                .messages = 1,
                .input = msg.input,
                .output = msg.output,
                .cache_write_5m = msg.cache_write_5m,
                .cache_write_1h = msg.cache_write_1h,
                .cache_read = msg.cache_read,
            };
            if (priceFor(msg.model)) |price| {
                counts.cost_usd = price.cost(counts);
            } else if (counts.tokens() > 0) {
                totals.unpriced = true;
            }

            totals.counts.add(counts);

            if (counts.tokens() > 0) {
                (try totals.bucket(self.gpa, msg.model)).add(counts);
            }

            if (std.mem.lessThan(u8, totals.last, msg.timestamp)) {
                totals.last = msg.timestamp;
            }
            if (epochSeconds(msg.timestamp)) |at| {
                try totals.stamps.append(self.gpa, at);
            }
        }
    }
};

pub fn forWorktree(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    worktree_path: []const u8,
) Totals {
    const root = cp.root(gpa, environ) catch return .{};
    const projects = cp.list(gpa, io, root) catch return .{};

    var scanner: Scanner = .init(gpa, io, .open(gpa, io, environ));
    defer scanner.deinit();
    return scanner.worktree(projects, worktree_path) catch .{};
}

pub const Brief = struct {
    totals: Totals,
    now: i64,

    pub fn format(self: Brief, w: *Io.Writer) Io.Writer.Error!void {
        if (self.totals.empty()) return;
        const counts = self.totals.counts;

        try w.print("{f} context", .{ui.count(counts.contextTokens())});
        try w.print(" · {f} output", .{ui.count(counts.output)});
        try w.print(" · {d} session{s}", .{
            self.totals.sessions,
            if (self.totals.sessions == 1) "" else "s",
        });
        if (epochSeconds(self.totals.last)) |at| {
            try w.print(" · {f} ago", .{ui.age(self.now - at)});
        }
        if (counts.cost_usd > 0) {
            try w.print(" · ~${d:.2}{s}", .{
                counts.cost_usd,
                if (self.totals.unpriced) "+" else "",
            });
        }
    }
};

pub fn brief(totals: Totals, now: i64) Brief {
    return .{ .totals = totals, .now = now };
}

const Line = struct {
    type: ?[]const u8 = null,
    timestamp: ?[]const u8 = null,
    message: ?Message = null,

    const Message = struct {
        id: ?[]const u8 = null,
        model: ?[]const u8 = null,
        usage: ?Usage = null,
    };

    const Usage = struct {
        input_tokens: ?u64 = null,
        output_tokens: ?u64 = null,
        cache_creation_input_tokens: ?u64 = null,
        cache_read_input_tokens: ?u64 = null,
        cache_creation: ?CacheCreation = null,
    };

    const CacheCreation = struct {
        ephemeral_5m_input_tokens: ?u64 = null,
        ephemeral_1h_input_tokens: ?u64 = null,
    };
};

pub const Price = struct {
    input: f64,
    output: f64,

    pub fn cost(self: Price, counts: Counts) f64 {
        const per_input = self.input / 1_000_000.0;
        const per_output = self.output / 1_000_000.0;
        return @as(f64, @floatFromInt(counts.input)) * per_input +
            @as(f64, @floatFromInt(counts.output)) * per_output +
            @as(f64, @floatFromInt(counts.cache_write_5m)) * per_input * 1.25 +
            @as(f64, @floatFromInt(counts.cache_write_1h)) * per_input * 2.0 +
            @as(f64, @floatFromInt(counts.cache_read)) * per_input * 0.1;
    }
};

const prices = [_]struct { prefix: []const u8, price: Price }{
    .{ .prefix = "claude-fable-5", .price = .{ .input = 10, .output = 50 } },
    .{ .prefix = "claude-mythos-5", .price = .{ .input = 10, .output = 50 } },
    .{ .prefix = "claude-opus-5", .price = .{ .input = 5, .output = 25 } },
    .{ .prefix = "claude-opus-4", .price = .{ .input = 5, .output = 25 } },
    .{ .prefix = "claude-sonnet-5", .price = .{ .input = 3, .output = 15 } },
    .{ .prefix = "claude-sonnet-4", .price = .{ .input = 3, .output = 15 } },
    .{ .prefix = "claude-haiku-4", .price = .{ .input = 1, .output = 5 } },
};

pub fn priceFor(model: []const u8) ?Price {
    for (prices) |entry| {
        if (std.mem.startsWith(u8, model, entry.prefix)) return entry.price;
    }
    return null;
}

pub fn shortModel(model: []const u8) []const u8 {
    var name = model;
    if (std.mem.startsWith(u8, name, "claude-")) name = name["claude-".len..];
    if (name.len > 9 and name[name.len - 9] == '-') {
        const suffix = name[name.len - 8 ..];
        for (suffix) |c| {
            if (!std.ascii.isDigit(c)) return name;
        }
        return name[0 .. name.len - 9];
    }
    return name;
}

pub fn epochSeconds(iso: []const u8) ?i64 {
    if (iso.len < 19) return null;
    if (iso[4] != '-' or iso[7] != '-' or iso[13] != ':' or iso[16] != ':') return null;
    if (iso[10] != 'T' and iso[10] != ' ') return null;

    const year = std.fmt.parseInt(i64, iso[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, iso[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, iso[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, iso[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, iso[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, iso[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    return daysFromCivil(year, month, day) * std.time.s_per_day +
        hour * 3600 + minute * 60 + second;
}

fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    const shifted_month: i64 = @rem(@as(i64, month) + 9, 12);
    const day_of_year = @divTrunc(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divTrunc(year_of_era, 4) -
        @divTrunc(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn fixture(arena: std.mem.Allocator, io: Io, base: []const u8, data: []const u8) ![]const u8 {
    const dir_path = try std.fs.path.join(arena, &.{ base, "project" });
    try Io.Dir.cwd().createDirPath(io, dir_path);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ dir_path, "a.jsonl" }),
        .data = data,
    });
    return dir_path;
}

test "counts assistant usage once per message id" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cwd = Io.Dir.cwd();

    const dir_path = try std.fs.path.join(arena, &.{ base, "project" });
    try cwd.createDirPath(io, dir_path);

    const first =
        \\{"type":"user","message":{"role":"user","content":"hi"}}
        \\{"type":"assistant","timestamp":"2026-07-28T10:00:00.000Z","message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":50}}}}
        \\
    ;
    const second =
        \\{"type":"assistant","timestamp":"2026-07-28T10:00:00.000Z","message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":50}}}}
        \\{"type":"assistant","timestamp":"2026-07-28T11:00:00.000Z","message":{"id":"msg_b","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":5,"output_tokens":20,"cache_creation_input_tokens":40}}}
        \\
    ;
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ dir_path, "a.jsonl" }),
        .data = first,
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ dir_path, "b.jsonl" }),
        .data = second,
    });

    var scanner: Scanner = .init(arena, io, .none(arena, io));
    defer scanner.deinit();
    const totals = try scanner.project(dir_path);

    try std.testing.expectEqual(@as(u64, 2), totals.counts.messages);
    try std.testing.expectEqual(@as(u64, 2), totals.sessions);
    try std.testing.expectEqual(@as(u64, 15), totals.counts.input);
    try std.testing.expectEqual(@as(u64, 120), totals.counts.output);
    try std.testing.expectEqual(@as(u64, 1000), totals.counts.cache_read);
    try std.testing.expectEqual(@as(u64, 50), totals.counts.cache_write_1h);
    try std.testing.expectEqual(@as(u64, 40), totals.counts.cache_write_5m);
    try std.testing.expect(!totals.unpriced);
    try std.testing.expectEqualStrings("2026-07-28T11:00:00.000Z", totals.last);

    try std.testing.expectEqual(@as(usize, 2), totals.models.items.len);
    var summed: Counts = .{};
    for (totals.models.items) |model| summed.add(model.counts);
    try std.testing.expectEqual(totals.counts.tokens(), summed.tokens());
    try std.testing.expectEqual(@as(u64, 1), totals.models.items[1].counts.messages);
}

test "a message quoting a usage block does not inflate the totals" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const dir_path = try fixture(arena, io, base,
        \\{"type":"assistant","timestamp":"2026-07-28T10:00:00.000Z","message":{"id":"msg_a","model":"claude-opus-5","content":[{"type":"text","text":"usage was {\"input_tokens\":888888,\"output_tokens\":999999}"}],"usage":{"input_tokens":3,"output_tokens":7}}}
        \\
    );

    var scanner: Scanner = .init(arena, io, .none(arena, io));
    defer scanner.deinit();
    const totals = try scanner.project(dir_path);

    try std.testing.expectEqual(@as(u64, 1), totals.counts.messages);
    try std.testing.expectEqual(@as(u64, 3), totals.counts.input);
    try std.testing.expectEqual(@as(u64, 7), totals.counts.output);
}

test "unpriced models keep their tokens and flag the cost" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const dir_path = try fixture(arena, io, base,
        \\{"type":"assistant","message":{"id":"msg_a","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}
        \\{"type":"assistant","message":{"id":"msg_b","model":"claude-next-9","usage":{"input_tokens":100,"output_tokens":200}}}
        \\
    );

    var scanner: Scanner = .init(arena, io, .none(arena, io));
    defer scanner.deinit();
    const totals = try scanner.project(dir_path);

    try std.testing.expectEqual(@as(u64, 300), totals.counts.tokens());
    try std.testing.expectEqual(@as(f64, 0), totals.counts.cost_usd);
    try std.testing.expect(totals.unpriced);
    try std.testing.expectEqual(@as(usize, 1), totals.models.items.len);
    try std.testing.expectEqualStrings("claude-next-9", totals.models.items[0].name);
}

test "usage from a sidechain subagent belongs to the worktree that spawned it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const dir_path = try fixture(arena, io, base,
        \\{"type":"assistant","isSidechain":false,"message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":10}}}
        \\{"type":"assistant","isSidechain":true,"message":{"id":"msg_b","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":40}}}
        \\
    );

    var scanner: Scanner = .init(arena, io, .none(arena, io));
    defer scanner.deinit();
    const totals = try scanner.project(dir_path);

    try std.testing.expectEqual(@as(u64, 2), totals.counts.messages);
    try std.testing.expectEqual(@as(u64, 50), totals.counts.output);
}

test "a subagent's own transcript counts, but not as another session" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cwd = Io.Dir.cwd();

    const dir_path = try std.fs.path.join(arena, &.{ base, "project" });
    const subagents = try std.fs.path.join(arena, &.{ dir_path, "sess-1", "subagents" });
    const tool_results = try std.fs.path.join(arena, &.{ dir_path, "sess-1", "tool-results" });
    try cwd.createDirPath(io, subagents);
    try cwd.createDirPath(io, tool_results);

    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ dir_path, "sess-1.jsonl" }),
        .data =
        \\{"type":"assistant","timestamp":"2026-07-28T10:00:00.000Z","message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":100}}}
        \\
        ,
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ subagents, "agent-1.jsonl" }),
        .data =
        \\{"type":"assistant","timestamp":"2026-07-28T11:00:00.000Z","message":{"id":"msg_b","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":900}}}
        \\
        ,
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ subagents, "agent-1.json" }),
        .data = "{\"usage\":{\"output_tokens\":999999}}\n",
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ tool_results, "out.txt" }),
        .data = "output_tokens 999999\n",
    });

    var scanner: Scanner = .init(arena, io, .none(arena, io));
    defer scanner.deinit();
    const totals = try scanner.project(dir_path);

    try std.testing.expectEqual(@as(u64, 2), totals.counts.messages);
    try std.testing.expectEqual(@as(u64, 1000), totals.counts.output);
    try std.testing.expectEqual(@as(u64, 1), totals.sessions);
    try std.testing.expectEqualStrings("2026-07-28T11:00:00.000Z", totals.last);
}

test "active time counts the gaps inside a stretch, not the breaks between them" {
    const gpa = std.testing.allocator;
    const t0: i64 = 1_800_000_000;

    var totals: Totals = .{};
    defer totals.stamps.deinit(gpa);

    for ([_]i64{ t0, t0 + 5 * 60 }) |at| try totals.stamps.append(gpa, at);
    try std.testing.expectEqual(@as(i64, 5 * 60), try totals.activeSeconds(gpa));

    for ([_]i64{ t0 + 65 * 60, t0 + 75 * 60 }) |at| try totals.stamps.append(gpa, at);
    try std.testing.expectEqual(@as(i64, 15 * 60), try totals.activeSeconds(gpa));

    var shuffled: Totals = .{};
    defer shuffled.stamps.deinit(gpa);
    for ([_]i64{ t0 + 75 * 60, t0, t0 + 65 * 60, t0 + 5 * 60 }) |at| {
        try shuffled.stamps.append(gpa, at);
    }
    try std.testing.expectEqual(@as(i64, 15 * 60), try shuffled.activeSeconds(gpa));

    var edge: Totals = .{};
    defer edge.stamps.deinit(gpa);
    for ([_]i64{ t0, t0 + idle_gap_seconds, t0 + 2 * idle_gap_seconds + 1 }) |at| {
        try edge.stamps.append(gpa, at);
    }
    try std.testing.expectEqual(idle_gap_seconds, try edge.activeSeconds(gpa));

    var single: Totals = .{};
    defer single.stamps.deinit(gpa);
    try single.stamps.append(gpa, t0);
    try std.testing.expectEqual(@as(i64, 0), try single.activeSeconds(gpa));
}

test "a subagent's time overlaps its parent's rather than adding to it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cwd = Io.Dir.cwd();

    const dir_path = try std.fs.path.join(arena, &.{ base, "project" });
    const subagents = try std.fs.path.join(arena, &.{ dir_path, "sess-1", "subagents" });
    try cwd.createDirPath(io, subagents);

    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ dir_path, "sess-1.jsonl" }),
        .data =
        \\{"type":"assistant","timestamp":"2026-07-28T10:00:00.000Z","message":{"id":"msg_p1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":100}}}
        \\{"type":"assistant","timestamp":"2026-07-28T10:10:00.000Z","message":{"id":"msg_p2","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":100}}}
        \\
        ,
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ subagents, "agent-1.jsonl" }),
        .data =
        \\{"type":"assistant","timestamp":"2026-07-28T10:02:00.000Z","message":{"id":"msg_s1","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":20}}}
        \\{"type":"assistant","timestamp":"2026-07-28T10:08:00.000Z","message":{"id":"msg_s2","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":20}}}
        \\
        ,
    });

    var scanner: Scanner = .init(arena, io, .none(arena, io));
    defer scanner.deinit();
    const totals = try scanner.project(dir_path);

    try std.testing.expectEqual(@as(i64, 10 * 60), try totals.activeSeconds(arena));

    const span = epochSeconds("2026-07-28T10:10:00.000Z").? -
        epochSeconds("2026-07-28T10:00:00.000Z").?;
    try std.testing.expect(try totals.activeSeconds(arena) <= span);
}

test "a cached run agrees with a cold one, and notices an appended transcript" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cwd = Io.Dir.cwd();

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_USAGE_CACHE", try std.fs.path.join(arena, &.{ base, "usage.json" }));

    const dir_path = try std.fs.path.join(arena, &.{ base, "project" });
    try cwd.createDirPath(io, dir_path);
    const first = try std.fs.path.join(arena, &.{ dir_path, "a.jsonl" });
    try cwd.writeFile(io, .{
        .sub_path = first,
        .data =
        \\{"type":"assistant","timestamp":"2026-07-28T10:00:00.000Z","message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":900}}}
        \\
        ,
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ dir_path, "b.jsonl" }),
        .data =
        \\{"type":"assistant","timestamp":"2026-07-28T10:00:00.000Z","message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":900}}}
        \\{"type":"assistant","timestamp":"2026-07-28T11:00:00.000Z","message":{"id":"msg_b","model":"claude-haiku-4-5","usage":{"input_tokens":5,"output_tokens":20}}}
        \\
        ,
    });

    var cold: Scanner = .init(arena, io, .open(arena, io, &environ));
    const from_disk = try cold.project(dir_path);
    try std.testing.expect(cold.cache.dirty);
    cold.deinit();

    var warm: Scanner = .init(arena, io, .open(arena, io, &environ));
    const from_cache = try warm.project(dir_path);
    try std.testing.expect(!warm.cache.dirty);
    warm.deinit();

    try std.testing.expectEqual(from_disk.counts.messages, from_cache.counts.messages);
    try std.testing.expectEqual(from_disk.counts.tokens(), from_cache.counts.tokens());
    try std.testing.expectEqual(from_disk.counts.cost_usd, from_cache.counts.cost_usd);
    try std.testing.expectEqual(from_disk.sessions, from_cache.sessions);
    try std.testing.expectEqualStrings(from_disk.last, from_cache.last);
    try std.testing.expectEqual(from_disk.models.items.len, from_cache.models.items.len);
    try std.testing.expectEqual(
        try from_disk.activeSeconds(arena),
        try from_cache.activeSeconds(arena),
    );
    try std.testing.expectEqual(@as(u64, 2), from_cache.counts.messages);
    try std.testing.expectEqual(@as(u64, 120), from_cache.counts.output);

    try cwd.writeFile(io, .{
        .sub_path = first,
        .data =
        \\{"type":"assistant","timestamp":"2026-07-28T10:00:00.000Z","message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":900}}}
        \\{"type":"assistant","timestamp":"2026-07-28T12:00:00.000Z","message":{"id":"msg_c","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":7}}}
        \\
        ,
    });

    var again: Scanner = .init(arena, io, .open(arena, io, &environ));
    const grown = try again.project(dir_path);
    try std.testing.expect(again.cache.dirty);
    again.deinit();

    try std.testing.expectEqual(@as(u64, 3), grown.counts.messages);
    try std.testing.expectEqual(@as(u64, 127), grown.counts.output);
    try std.testing.expectEqualStrings("2026-07-28T12:00:00.000Z", grown.last);
}

test "add merges per-model buckets across project directories" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var a: Totals = .{ .sessions = 1, .last = "2026-07-01T00:00:00Z" };
    _ = try a.bucket(arena, "claude-opus-5");
    a.models.items[0].counts = .{ .messages = 1, .output = 100 };
    a.counts.add(a.models.items[0].counts);

    var b: Totals = .{ .sessions = 2, .last = "2026-07-09T00:00:00Z" };
    (try b.bucket(arena, "claude-opus-5")).add(.{ .messages = 1, .output = 50 });
    (try b.bucket(arena, "claude-haiku-4-5")).add(.{ .messages = 1, .output = 5 });
    b.counts.add(.{ .messages = 2, .output = 55 });

    try a.add(arena, b);

    try std.testing.expectEqual(@as(u64, 3), a.counts.messages);
    try std.testing.expectEqual(@as(u64, 155), a.counts.output);
    try std.testing.expectEqual(@as(u64, 3), a.sessions);
    try std.testing.expectEqualStrings("2026-07-09T00:00:00Z", a.last);
    try std.testing.expectEqual(@as(usize, 2), a.models.items.len);
    try std.testing.expectEqual(@as(u64, 150), a.models.items[0].counts.output);

    const ranked = try a.modelsBySpend(arena);
    try std.testing.expectEqualStrings("claude-opus-5", ranked[0].name);
    try std.testing.expectEqualStrings("claude-haiku-4-5", ranked[1].name);
}

test "brief renders one line, and nothing at all when there is no usage" {
    const gpa = std.testing.allocator;
    const now = epochSeconds("2026-07-28T15:36:00Z").?;

    const nothing = try std.fmt.allocPrint(gpa, "{f}", .{brief(.{}, now)});
    defer gpa.free(nothing);
    try std.testing.expectEqualStrings("", nothing);

    const spent: Totals = .{
        .counts = .{
            .messages = 6,
            .input = 103,
            .output = 17606,
            .cache_write_1h = 32000,
            .cache_read = 3_600_000,
            .cost_usd = 2.5425,
        },
        .sessions = 2,
        .last = "2026-07-28T15:00:00.000Z",
    };
    const line = try std.fmt.allocPrint(gpa, "{f}", .{brief(spent, now)});
    defer gpa.free(line);
    try std.testing.expectEqualStrings(
        "3.6M context · 18k output · 2 sessions · 36m ago · ~$2.54",
        line,
    );

    var single = spent;
    single.sessions = 1;
    single.unpriced = true;
    const one = try std.fmt.allocPrint(gpa, "{f}", .{brief(single, now)});
    defer gpa.free(one);
    try std.testing.expectEqualStrings(
        "3.6M context · 18k output · 1 session · 36m ago · ~$2.54+",
        one,
    );
}

test "brief drops the age when no message carried a timestamp" {
    const gpa = std.testing.allocator;
    const line = try std.fmt.allocPrint(gpa, "{f}", .{brief(.{
        .counts = .{ .messages = 1, .output = 500 },
        .sessions = 1,
    }, 0)});
    defer gpa.free(line);
    try std.testing.expectEqualStrings("0 context · 500 output · 1 session", line);
}

test "price applies the cache multipliers" {
    const price = priceFor("claude-opus-5").?;
    const got = price.cost(.{
        .input = 1_000_000,
        .output = 1_000_000,
        .cache_write_5m = 1_000_000,
        .cache_write_1h = 1_000_000,
        .cache_read = 1_000_000,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 46.75), got, 0.0001);

    try std.testing.expectEqual(@as(f64, 1), priceFor("claude-haiku-4-5-20251001").?.input);
    try std.testing.expectEqual(@as(f64, 5), priceFor("claude-opus-5[1m]").?.input);
    try std.testing.expect(priceFor("<synthetic>") == null);
}

test "shortModel drops the vendor prefix and dated suffix" {
    try std.testing.expectEqualStrings("opus-5", shortModel("claude-opus-5"));
    try std.testing.expectEqualStrings("haiku-4-5", shortModel("claude-haiku-4-5-20251001"));
    try std.testing.expectEqualStrings("<synthetic>", shortModel("<synthetic>"));
    try std.testing.expectEqualStrings("opus-4-8", shortModel("claude-opus-4-8"));
}

test "epochSeconds parses the transcript timestamp shape" {
    try std.testing.expectEqual(@as(i64, 1785251729), epochSeconds("2026-07-28T15:15:29.375Z").?);
    try std.testing.expectEqual(@as(i64, 0), epochSeconds("1970-01-01T00:00:00.000Z").?);
    try std.testing.expectEqual(@as(i64, 951782400), epochSeconds("2000-02-29T00:00:00Z").?);
    try std.testing.expect(epochSeconds("") == null);
    try std.testing.expect(epochSeconds("not-a-timestamp-here") == null);
    try std.testing.expect(epochSeconds("2026-13-99T00:00:00Z") == null);
}
