//! Token usage recorded in Claude Code transcripts.
//!
//! Every assistant message in a transcript carries the `usage` block the API
//! returned for it — input, output, and the cache-write/cache-read split —
//! alongside the model that produced it. Aggregating those per project
//! directory turns into aggregating per worktree, because Claude Code keys a
//! project directory on the cwd it was launched in (see `claude_projects.zig`).
//!
//! Counts are kept per model rather than only in total: `lcc stats` shows the
//! breakdown, and a rollup is a sum over it, so the everyday commands pay
//! nothing for the detail being there.
//!
//! Two things stop the numbers from being wrong. Messages are counted once by
//! `message.id`: a resumed session copies history forward and compaction
//! rewrites it, so the same API response shows up in more than one line and
//! more than one transcript. And lines are parsed as JSON rather than scanned
//! for `"output_tokens"`, because a message's own text can quote a usage block
//! — a transcript of a session that talked about token counts would otherwise
//! inflate itself.

const std = @import("std");
const Io = std.Io;
const cp = @import("claude_projects.zig");
const ui = @import("ui.zig");

/// Transcripts are read whole so a line spanning a read boundary cannot be
/// half-parsed. Anything past this is reported through `skipped` rather than
/// silently undercounted.
const transcript_limit = 256 * 1024 * 1024;

/// What a set of messages spent. The unit of both the per-model buckets and the
/// rollup over them.
pub const Counts = struct {
    /// Assistant messages that reported usage.
    messages: u64 = 0,
    /// Fresh input tokens — what neither cache bucket covered.
    input: u64 = 0,
    output: u64 = 0,
    cache_write_5m: u64 = 0,
    cache_write_1h: u64 = 0,
    cache_read: u64 = 0,
    /// List price for the tokens above, accumulated per message so a mix of
    /// models bills at each one's own rate. Zero for a model the price table
    /// does not know — see `Totals.unpriced`.
    cost_usd: f64 = 0,

    /// Everything the model had to read: fresh input plus both cache buckets.
    /// This is the number that grows without bound across a long session, and
    /// the one worth showing when there is room for exactly one.
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

/// One model's share of a worktree's usage.
pub const Model = struct {
    /// The model id as the transcript recorded it.
    name: []const u8,
    counts: Counts = .{},
};

pub const Totals = struct {
    counts: Counts = .{},
    /// Transcripts the numbers came from.
    sessions: u64 = 0,
    /// The newest timestamp seen, verbatim. Claude Code writes ISO 8601 with a
    /// `Z` suffix, so lexicographic order is chronological and the maximum
    /// needs no parsing until something wants to render it.
    last: []const u8 = "",
    /// Per-model buckets, in first-seen order. Sums to `counts`.
    models: std.ArrayList(Model) = .empty,
    /// A model carried tokens but had no entry in the price table, so
    /// `counts.cost_usd` is an underestimate.
    unpriced: bool = false,

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
    }

    /// The bucket for `name`, created if this is its first message.
    fn bucket(self: *Totals, gpa: std.mem.Allocator, name: []const u8) !*Counts {
        for (self.models.items) |*model| {
            if (std.mem.eql(u8, model.name, name)) return &model.counts;
        }
        try self.models.append(gpa, .{ .name = name });
        return &self.models.items[self.models.items.len - 1].counts;
    }

    /// Model buckets ordered by spend, so a `stats` breakdown leads with what
    /// the tokens actually went to.
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

/// Reads transcripts and keeps the cross-file state the counting depends on:
/// which message ids have been seen, and scratch memory for one transcript at a
/// time.
pub const Scanner = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Message ids already counted, so a message that appears in two
    /// transcripts is billed once. Keys live in `gpa` — `scratch` is reset
    /// between files.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// Per-transcript working memory. Reset rather than freed, so peak usage
    /// tracks the largest transcript instead of their sum.
    scratch: std.heap.ArenaAllocator,
    /// Transcripts that could not be read whole. Non-zero means the totals are
    /// low and the caller should say so.
    skipped: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: Io) Scanner {
        return .{ .gpa = gpa, .io = io, .scratch = .init(gpa) };
    }

    pub fn deinit(self: *Scanner) void {
        self.scratch.deinit();
        self.seen.deinit(self.gpa);
    }

    /// Usage across every `.jsonl` in one Claude Code project directory. A
    /// directory that cannot be opened is not an error: usage is decoration,
    /// and a missing transcript should not fail the command that wanted it.
    pub fn project(self: *Scanner, dir_path: []const u8) !Totals {
        var totals: Totals = .{};

        var dir = Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch
            return totals;
        defer dir.close(self.io);

        var it = dir.iterate();
        while (it.next(self.io) catch null) |dirent| {
            if (dirent.kind != .file or !std.mem.endsWith(u8, dirent.name, ".jsonl")) continue;
            const path = try std.fs.path.join(self.gpa, &.{ dir_path, dirent.name });
            try self.transcript(&totals, path);
        }
        return totals;
    }

    /// Usage across several project directories.
    pub fn projectDirs(self: *Scanner, dir_paths: []const []const u8) !Totals {
        var totals: Totals = .{};
        for (dir_paths) |path| {
            try totals.add(self.gpa, try self.project(path));
        }
        return totals;
    }

    /// Usage for one worktree, resolved against a listing of `~/.claude/projects`.
    /// A worktree can own several project directories — one per directory Claude
    /// Code was launched from — and `cp.forWorktree` matches on the cwd each
    /// transcript recorded, so a session started in a subdirectory counts too.
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

    fn transcript(self: *Scanner, totals: *Totals, path: []const u8) !void {
        _ = self.scratch.reset(.retain_capacity);
        const scratch = self.scratch.allocator();

        const bytes = Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            scratch,
            .limited(transcript_limit),
        ) catch |err| switch (err) {
            error.StreamTooLong => {
                self.skipped += 1;
                return;
            },
            else => return,
        };

        totals.sessions += 1;

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // A line that is not the shape we expect is a line we do not count.
            // Transcripts hold several record types and gain more over time.
            const parsed = std.json.parseFromSliceLeaky(
                Line,
                scratch,
                line,
                .{ .ignore_unknown_fields = true },
            ) catch continue;
            try self.count(totals, parsed);
        }
    }

    fn count(self: *Scanner, totals: *Totals, line: Line) !void {
        const kind = line.type orelse return;
        if (!std.mem.eql(u8, kind, "assistant")) return;
        const message = line.message orelse return;
        const usage = message.usage orelse return;

        if (message.id) |id| {
            const slot = try self.seen.getOrPut(self.gpa, id);
            if (slot.found_existing) return;
            // The key has to outlive the scratch arena the line was parsed in.
            slot.key_ptr.* = try self.gpa.dupe(u8, id);
        }

        var counts: Counts = .{ .messages = 1 };
        counts.input = usage.input_tokens orelse 0;
        counts.output = usage.output_tokens orelse 0;
        counts.cache_read = usage.cache_read_input_tokens orelse 0;

        // The 5m/1h split arrived after the flat total did. Without it, credit
        // the whole write to the 5-minute bucket — that was the only TTL when
        // transcripts recorded the total alone.
        if (usage.cache_creation) |split| {
            counts.cache_write_5m = split.ephemeral_5m_input_tokens orelse 0;
            counts.cache_write_1h = split.ephemeral_1h_input_tokens orelse 0;
        } else {
            counts.cache_write_5m = usage.cache_creation_input_tokens orelse 0;
        }

        const model = message.model orelse "";
        if (priceFor(model)) |price| {
            counts.cost_usd = price.cost(counts);
        } else if (counts.tokens() > 0) {
            totals.unpriced = true;
        }

        totals.counts.add(counts);

        // A model with nothing to its name would only clutter the breakdown;
        // `<synthetic>` messages are the usual source.
        if (counts.tokens() > 0) {
            const bucket = try totals.bucket(self.gpa, try self.gpa.dupe(u8, model));
            bucket.add(counts);
        }

        if (line.timestamp) |ts| {
            if (std.mem.lessThan(u8, totals.last, ts)) {
                totals.last = try self.gpa.dupe(u8, ts);
            }
        }
    }
};

/// Usage for a single worktree, listing `~/.claude/projects` itself. For the
/// commands that touch one worktree; a dashboard shares one listing and one
/// scanner across its rows instead.
///
/// Every failure here is an empty result rather than an error: this number is
/// context on a command that has other work to do, and a missing or unreadable
/// transcript must not stop it.
pub fn forWorktree(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    worktree_path: []const u8,
) Totals {
    const root = cp.root(gpa, environ) catch return .{};
    const projects = cp.list(gpa, io, root) catch return .{};

    var scanner: Scanner = .init(gpa, io);
    defer scanner.deinit();
    return scanner.worktree(projects, worktree_path) catch .{};
}

/// One line of "what this worktree has spent so far", for the commands that open
/// or delete one. Renders nothing at all when there is no usage to report, so a
/// caller can print it unconditionally.
pub const Brief = struct {
    totals: Totals,
    /// Unix seconds, for the relative age of the last message.
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

/// The fields of a transcript line that bear on usage. Everything else in the
/// record is skipped by the parser.
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
    /// USD per million input tokens.
    input: f64,
    /// USD per million output tokens.
    output: f64,

    /// Cache writes bill above the input rate — 1.25× for the 5-minute TTL,
    /// 2× for the hour — and cache reads at a tenth of it.
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

/// Anthropic list price, matched on the model-id prefix so dated snapshots
/// (`claude-haiku-4-5-20251001`) and context suffixes resolve to their family.
/// A model that is not here still has its tokens counted — only the money is
/// left out, and `Totals.unpriced` says so.
///
/// These are published prices, not what a Claude subscription bills. Update
/// them when the pricing page moves; nothing else in lcc reads them.
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

/// A model id short enough for a table column: the vendor prefix and any dated
/// snapshot suffix dropped. `claude-haiku-4-5-20251001` → `haiku-4-5`.
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

/// `2026-07-28T15:15:29.375Z` → Unix seconds. Null for anything not of that
/// shape, which costs a relative-time column and nothing else.
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

/// Days between 1970-01-01 and the given date, by Howard Hinnant's
/// `days_from_civil`. Shifting the year to start in March makes the leap day
/// the last day of the year, which is what removes the special cases.
fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400; // [0, 399]
    // March is 0. `month` is validated 1–12 by the caller, so the operands are
    // positive and `@rem` is the truncating remainder this needs.
    const shifted_month: i64 = @rem(@as(i64, month) + 9, 12);
    const day_of_year = @divTrunc(153 * shifted_month + 2, 5) + day - 1; // [0, 365]
    const day_of_era = year_of_era * 365 + @divTrunc(year_of_era, 4) -
        @divTrunc(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

/// A project directory holding `data` as its only transcript, for tests.
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

    // Two transcripts, and the second replays the first's message — what a
    // resumed session does. The replay must not be counted twice.
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

    var scanner: Scanner = .init(arena, io);
    defer scanner.deinit();
    const totals = try scanner.project(dir_path);

    try std.testing.expectEqual(@as(u64, 2), totals.counts.messages);
    try std.testing.expectEqual(@as(u64, 2), totals.sessions);
    try std.testing.expectEqual(@as(u64, 15), totals.counts.input);
    try std.testing.expectEqual(@as(u64, 120), totals.counts.output);
    try std.testing.expectEqual(@as(u64, 1000), totals.counts.cache_read);
    try std.testing.expectEqual(@as(u64, 50), totals.counts.cache_write_1h);
    // The flat `cache_creation_input_tokens` with no split lands in the 5m bucket.
    try std.testing.expectEqual(@as(u64, 40), totals.counts.cache_write_5m);
    try std.testing.expect(!totals.unpriced);
    try std.testing.expectEqualStrings("2026-07-28T11:00:00.000Z", totals.last);

    // The per-model buckets sum back to the rollup.
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

    // The assistant's own text quotes usage numbers, and `content` is
    // serialised before `usage`. A scan for the first `"output_tokens"` in the
    // line would read 999999 instead of 7.
    const dir_path = try fixture(arena, io, base,
        \\{"type":"assistant","timestamp":"2026-07-28T10:00:00.000Z","message":{"id":"msg_a","model":"claude-opus-5","content":[{"type":"text","text":"usage was {\"input_tokens\":888888,\"output_tokens\":999999}"}],"usage":{"input_tokens":3,"output_tokens":7}}}
        \\
    );

    var scanner: Scanner = .init(arena, io);
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

    // `<synthetic>` messages carry no tokens, so they must neither raise the
    // flag nor earn a bucket; an unknown real model with tokens must do both.
    const dir_path = try fixture(arena, io, base,
        \\{"type":"assistant","message":{"id":"msg_a","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}
        \\{"type":"assistant","message":{"id":"msg_b","model":"claude-next-9","usage":{"input_tokens":100,"output_tokens":200}}}
        \\
    );

    var scanner: Scanner = .init(arena, io);
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

    // A subagent's messages are tagged `isSidechain` but run against the same
    // worktree and cost the same money, so they are counted like any other.
    const dir_path = try fixture(arena, io, base,
        \\{"type":"assistant","isSidechain":false,"message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":10}}}
        \\{"type":"assistant","isSidechain":true,"message":{"id":"msg_b","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":40}}}
        \\
    );

    var scanner: Scanner = .init(arena, io);
    defer scanner.deinit();
    const totals = try scanner.project(dir_path);

    try std.testing.expectEqual(@as(u64, 2), totals.counts.messages);
    try std.testing.expectEqual(@as(u64, 50), totals.counts.output);
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
    // The later timestamp wins regardless of merge order.
    try std.testing.expectEqualStrings("2026-07-09T00:00:00Z", a.last);
    try std.testing.expectEqual(@as(usize, 2), a.models.items.len);
    try std.testing.expectEqual(@as(u64, 150), a.models.items[0].counts.output);

    const ranked = try a.modelsBySpend(arena);
    try std.testing.expectEqualStrings("claude-opus-5", ranked[0].name);
    try std.testing.expectEqualStrings("claude-haiku-4-5", ranked[1].name);
}

test "brief renders one line, and nothing at all when there is no usage" {
    const gpa = std.testing.allocator;
    // 2026-07-28T15:00:00Z plus 36 minutes, so `last` reads as 36m ago.
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

    // One session is not "1 sessions", and a partial total keeps its marker.
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
    // 1M fresh input at $5, 1M output at $25, 1M 5m-write at 1.25×, 1M
    // 1h-write at 2×, 1M read at 0.1× → 5 + 25 + 6.25 + 10 + 0.5.
    const got = price.cost(.{
        .input = 1_000_000,
        .output = 1_000_000,
        .cache_write_5m = 1_000_000,
        .cache_write_1h = 1_000_000,
        .cache_read = 1_000_000,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 46.75), got, 0.0001);

    // Dated snapshots and context suffixes resolve to the family.
    try std.testing.expectEqual(@as(f64, 1), priceFor("claude-haiku-4-5-20251001").?.input);
    try std.testing.expectEqual(@as(f64, 5), priceFor("claude-opus-5[1m]").?.input);
    try std.testing.expect(priceFor("<synthetic>") == null);
}

test "shortModel drops the vendor prefix and dated suffix" {
    try std.testing.expectEqualStrings("opus-5", shortModel("claude-opus-5"));
    try std.testing.expectEqualStrings("haiku-4-5", shortModel("claude-haiku-4-5-20251001"));
    try std.testing.expectEqualStrings("<synthetic>", shortModel("<synthetic>"));
    // Not a date: eight digits have to be the whole suffix.
    try std.testing.expectEqualStrings("opus-4-8", shortModel("claude-opus-4-8"));
}

test "epochSeconds parses the transcript timestamp shape" {
    // Cross-checked against `date -u -j -f "%Y-%m-%dT%H:%M:%SZ"`.
    try std.testing.expectEqual(@as(i64, 1785251729), epochSeconds("2026-07-28T15:15:29.375Z").?);
    try std.testing.expectEqual(@as(i64, 0), epochSeconds("1970-01-01T00:00:00.000Z").?);
    // A leap day, in the year the 400-rule makes leap after the 100-rule said no.
    try std.testing.expectEqual(@as(i64, 951782400), epochSeconds("2000-02-29T00:00:00Z").?);
    try std.testing.expect(epochSeconds("") == null);
    try std.testing.expect(epochSeconds("not-a-timestamp-here") == null);
    try std.testing.expect(epochSeconds("2026-13-99T00:00:00Z") == null);
}
