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
const sessions = @import("sessions.zig");
const uc = @import("usage_cache.zig");
const ui = @import("ui.zig");

/// Transcripts are read whole so a line spanning a read boundary cannot be
/// half-parsed. Anything past this is reported through `skipped` rather than
/// silently undercounted.
const transcript_limit = 256 * 1024 * 1024;

/// How far below a project directory transcripts are looked for. Claude Code
/// puts subagents at `<session-id>/subagents/`, which is two.
const max_depth = 4;

/// The gap between two messages beyond which the work is taken to have stopped.
/// Fifteen minutes clears anything one turn can spend — a long agent run, a
/// build, a wall of output being read — and falls well short of stepping away.
///
/// The number decides what `ACTIVE` means, so it is worth being wrong in a known
/// direction: too low splits one sitting into several and undercounts, too high
/// bills lunch. This errs low, because a duration meant to be compared against a
/// working day is more useful as a floor than as a flattering estimate.
pub const idle_gap_seconds: i64 = 15 * 60;

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
    /// When each counted message landed, in Unix seconds and no particular
    /// order. Kept as the raw set rather than a running duration because active
    /// time is not additive: a subagent runs *alongside* the conversation that
    /// spawned it, so two transcripts that each worked ten minutes may between
    /// them have used ten minutes of anyone's day. `activeSeconds` unions them.
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

    /// Time spent, as against time elapsed. Messages closer together than
    /// `idle_gap_seconds` are one stretch of work and the gap between them
    /// counts — it is thinking, tool calls, and reading the answer. A longer gap
    /// is a break and contributes nothing, which is what separates this from the
    /// span between the first message and the last.
    ///
    /// Undercounts by design at both ends: the first message of a stretch is
    /// credited with no time (whatever went into asking for it happened before
    /// the transcript recorded anything), and a lone message counts as zero.
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
    /// What earlier runs already read. `uc.Cache.none` opts out.
    cache: uc.Cache,
    codex: ?sessions.Snapshot = null,

    pub fn init(gpa: std.mem.Allocator, io: Io, cache: uc.Cache) Scanner {
        return .{ .gpa = gpa, .io = io, .scratch = .init(gpa), .cache = cache };
    }

    /// Teardown writes the cache back, because every caller already defers this
    /// and a cache that needs a second call remembered is a cache that quietly
    /// stops working the first time someone adds a `return` above it.
    pub fn deinit(self: *Scanner) void {
        if (self.codex) |*snapshot| snapshot.deinit();
        self.cache.save();
        self.scratch.deinit();
        self.seen.deinit(self.gpa);
    }

    pub fn includeCodex(self: *Scanner, environ: *const std.process.Environ.Map) void {
        var scanner = sessions.Scanner.initWithIo(self.gpa, self.io, environ);
        defer scanner.deinit();
        self.codex = scanner.scan(.cached) catch null;
    }

    /// Usage across every `.jsonl` in one Claude Code project directory. A
    /// directory that cannot be opened is not an error: usage is decoration,
    /// and a missing transcript should not fail the command that wanted it.
    pub fn project(self: *Scanner, dir_path: []const u8) !Totals {
        var totals: Totals = .{};
        try self.scan(&totals, dir_path, 0);
        return totals;
    }

    /// Subagents do not write into the conversation that spawned them. Each gets
    /// its own transcript under `<session-id>/subagents/`, so the top level of a
    /// project directory holds only part of what the work cost — for a worktree
    /// driven through a pipeline, usually well under half of it. The whole tree
    /// is walked for `.jsonl`; everything else Claude Code keeps down there
    /// (`tool-results/`, the per-subagent `.json` sidecars, `.md` notes) is not
    /// a transcript and carries no usage.
    ///
    /// Only the top level counts towards `sessions`. A subagent is part of a
    /// conversation, not one of its own, and counting it would inflate a column
    /// that answers "how many times did I sit down with this worktree".
    fn scan(self: *Scanner, totals: *Totals, dir_path: []const u8, depth: u8) !void {
        // Claude Code nests two deep. The cap is for a tree that is not its own.
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
                // Symlinks report as `.sym_link` and are left alone, so the walk
                // cannot be sent round a loop.
                .directory => {
                    const path = try std.fs.path.join(self.gpa, &.{ dir_path, dirent.name });
                    try self.scan(totals, path, depth + 1);
                },
                else => {},
            }
        }
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
        var totals = try self.projectDirs(dirs);
        if (self.codex) |*snapshot| try addCodex(self.gpa, &totals, snapshot.usageForWorktree(worktree_path));
        return totals;
    }

    /// One transcript, from the cache when the file on disk is still the one it
    /// was built from, and from the transcript itself otherwise. Both routes end
    /// at `apply`, so a cached run and a cold run cannot drift apart.
    fn transcript(self: *Scanner, totals: *Totals, path: []const u8, session: bool) !void {
        const info = Io.Dir.cwd().statFile(self.io, path, .{}) catch return;
        const size = info.size;
        // Nanoseconds are `i96` at the source; a value that does not fit is not
        // a time this decade, and 0 simply means the entry never matches.
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

    /// Reads a transcript down to the messages that carried usage. Null when the
    /// file could not be read at all — which is not cached, because there is
    /// nothing to say about it and the next run may find it readable.
    ///
    /// Messages are deduplicated against this transcript only. Doing it here
    /// rather than against `seen` is what keeps the result a pure function of
    /// the file: a cache entry must not depend on which transcripts happened to
    /// be read before it, or reusing it would depend on repeating that order.
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
            // A line that is not the shape we expect is a line we do not count.
            // Transcripts hold several record types and gain more over time.
            const record = std.json.parseFromSliceLeaky(
                Line,
                scratch,
                line,
                .{ .ignore_unknown_fields = true },
            ) catch continue;

            const found = self.extract(record, &local, scratch) orelse continue;
            // The messages outlive `scratch`, which is reset for the next file.
            out.append(self.gpa, found) catch return null;
        }
        return .{ .messages = out.toOwnedSlice(self.gpa) catch return null };
    }

    /// The usage a transcript line reports, or null when it reports none or
    /// repeats a message already taken from this transcript.
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

        // The 5m/1h split arrived after the flat total did. Without it, credit
        // the whole write to the 5-minute bucket — that was the only TTL when
        // transcripts recorded the total alone.
        if (usage.cache_creation) |split| {
            out.cache_write_5m = split.ephemeral_5m_input_tokens orelse 0;
            out.cache_write_1h = split.ephemeral_1h_input_tokens orelse 0;
        } else {
            out.cache_write_5m = usage.cache_creation_input_tokens orelse 0;
        }
        return out;
    }

    /// Adds one transcript's messages to a running total, dropping the ones
    /// already counted from somewhere else. This is where cost is worked out, so
    /// the price table is read fresh on every run rather than cached into a
    /// number nobody would think to invalidate.
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

            // A model with nothing to its name would only clutter the breakdown;
            // `<synthetic>` messages are the usual source.
            if (counts.tokens() > 0) {
                (try totals.bucket(self.gpa, msg.model)).add(counts);
            }

            if (std.mem.lessThan(u8, totals.last, msg.timestamp)) {
                totals.last = msg.timestamp;
            }
            // Collected here rather than per transcript so that `activeSeconds`
            // sees one worktree's messages as the single interleaved sequence
            // they were, whichever conversation or subagent wrote each of them.
            if (epochSeconds(msg.timestamp)) |at| {
                try totals.stamps.append(self.gpa, at);
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

    var scanner: Scanner = .init(gpa, io, .open(gpa, io, environ));
    defer scanner.deinit();
    scanner.includeCodex(environ);
    return scanner.worktree(projects, worktree_path) catch .{};
}

fn addCodex(gpa: std.mem.Allocator, totals: *Totals, codex: sessions.Usage) !void {
    totals.counts.messages += codex.counts.messages;
    totals.counts.input += codex.counts.input;
    totals.counts.output += codex.counts.output;
    totals.counts.cache_read += codex.counts.cache_read;
    totals.sessions += codex.sessions;
    if (codex.last) |last| if (std.mem.lessThan(u8, totals.last, last)) {
        totals.last = last;
    };
    for (codex.models) |model| {
        var counts: Counts = .{
            .messages = model.counts.messages,
            .input = model.counts.input,
            .output = model.counts.output,
            .cache_read = model.counts.cache_read,
        };
        if (priceFor(model.name)) |price| {
            counts.cost_usd = price.cost(counts);
            totals.counts.cost_usd += counts.cost_usd;
        } else if (counts.tokens() > 0) {
            totals.unpriced = true;
        }
        (try totals.bucket(gpa, model.name)).add(counts);
    }
    for (codex.stamps) |stamp| if (epochSeconds(stamp)) |at| try totals.stamps.append(gpa, at);
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

    var scanner: Scanner = .init(arena, io, .none(arena, io));
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

    // `<synthetic>` messages carry no tokens, so they must neither raise the
    // flag nor earn a bucket; an unknown real model with tokens must do both.
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

    // A subagent's messages are tagged `isSidechain` but run against the same
    // worktree and cost the same money, so they are counted like any other.
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

    // The layout Claude Code writes: the conversation at the top, each subagent
    // in its own transcript below it, and non-transcript company alongside. A
    // pipeline puts most of the work through subagents, so a scan that stops at
    // the top level can miss more than it finds.
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
    // Neither of these is a transcript, and both sit where the walk goes.
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
    // One conversation, whatever it delegated. The subagent is part of it.
    try std.testing.expectEqual(@as(u64, 1), totals.sessions);
    // The subagent's message is the newest, so it sets `last`.
    try std.testing.expectEqualStrings("2026-07-28T11:00:00.000Z", totals.last);
}

test "active time counts the gaps inside a stretch, not the breaks between them" {
    const gpa = std.testing.allocator;
    const t0: i64 = 1_800_000_000;

    var totals: Totals = .{};
    defer totals.stamps.deinit(gpa);

    // Two messages five minutes apart: one stretch, five minutes of it.
    for ([_]i64{ t0, t0 + 5 * 60 }) |at| try totals.stamps.append(gpa, at);
    try std.testing.expectEqual(@as(i64, 5 * 60), try totals.activeSeconds(gpa));

    // An hour later the work resumes. The hour is a break and is not billed;
    // the ten minutes on the far side of it are.
    for ([_]i64{ t0 + 65 * 60, t0 + 75 * 60 }) |at| try totals.stamps.append(gpa, at);
    try std.testing.expectEqual(@as(i64, 15 * 60), try totals.activeSeconds(gpa));

    // Order is the sequence the messages happened in, not the one they were
    // read in — two transcripts arrive interleaved and neither is sorted.
    var shuffled: Totals = .{};
    defer shuffled.stamps.deinit(gpa);
    for ([_]i64{ t0 + 75 * 60, t0, t0 + 65 * 60, t0 + 5 * 60 }) |at| {
        try shuffled.stamps.append(gpa, at);
    }
    try std.testing.expectEqual(@as(i64, 15 * 60), try shuffled.activeSeconds(gpa));

    // A gap exactly at the threshold is still one sitting: the break is the
    // first gap *longer* than it.
    var edge: Totals = .{};
    defer edge.stamps.deinit(gpa);
    for ([_]i64{ t0, t0 + idle_gap_seconds, t0 + 2 * idle_gap_seconds + 1 }) |at| {
        try edge.stamps.append(gpa, at);
    }
    try std.testing.expectEqual(idle_gap_seconds, try edge.activeSeconds(gpa));

    // One message has no gap to measure. Zero, rather than a guess at how long
    // producing it took.
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

    // The conversation spans 10:00–10:10 and delegates the middle of it. The
    // subagent's two messages land *inside* that window, which is the whole
    // point: they are the same ten minutes of someone's day, not six more.
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

    // Ten minutes, the width of the window. Summing the two transcripts
    // separately would give sixteen — more time than the window holds, and the
    // error grows with every subagent a pipeline runs in parallel.
    try std.testing.expectEqual(@as(i64, 10 * 60), try totals.activeSeconds(arena));

    // Active time can never exceed the span it happened in. Worth asserting
    // rather than reasoning about: it is the invariant the union is there for.
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

    // Two transcripts sharing a message, so the cross-file deduplication has
    // something to do: it is the part a per-file cache could most easily lose.
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
    // Nothing was learned, which is only true if every transcript was a hit.
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
    // The shared message was counted once by both routes, not once per file.
    try std.testing.expectEqual(@as(u64, 2), from_cache.counts.messages);
    try std.testing.expectEqual(@as(u64, 120), from_cache.counts.output);

    // What a live session does between two runs.
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
