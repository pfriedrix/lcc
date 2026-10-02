const std = @import("std");
const app_mod = @import("../app.zig");
const cp = @import("../claude_projects.zig");
const ct = @import("../claude_tmp.zig");
const dd = @import("../derived_data.zig");
const disk = @import("../disk.zig");
const prompt = @import("../prompt.zig");
const ui = @import("../ui.zig");

pub const Opts = struct {
    yes: bool = false,
    build_data: bool = false,
    sessions: bool = false,
    scratch: bool = false,

    fn wants(self: Opts, kind: Kind) bool {
        if (!self.build_data and !self.sessions and !self.scratch) return true;
        return switch (kind) {
            .build_data => self.build_data,
            .sessions => self.sessions,
            .scratch => self.scratch,
        };
    }
};

const Kind = enum { build_data, sessions, scratch };

const Target = union(Kind) {
    build_data: dd.Entry,
    sessions: cp.Entry,
    scratch: ct.Entry,
};

const Candidate = struct {
    target: Target,
    size: u64,

    fn name(self: Candidate) []const u8 {
        return switch (self.target) {
            .build_data => |e| e.name,
            .sessions => |e| e.name,
            .scratch => |e| e.name,
        };
    }

    fn path(self: Candidate) []const u8 {
        return switch (self.target) {
            .build_data => |e| e.path,
            .sessions => |e| e.path,
            .scratch => |e| e.path,
        };
    }

    fn origin(self: Candidate) []const u8 {
        return switch (self.target) {
            .build_data => |e| e.workspace_path,
            .sessions => |e| e.cwd,
            .scratch => |e| e.path,
        };
    }

    fn label(self: Candidate) []const u8 {
        return switch (self.target) {
            .build_data => "build data",
            .sessions => "sessions  ",
            .scratch => "scratch   ",
        };
    }

    fn sizeDesc(_: void, a: Candidate, b: Candidate) bool {
        return a.size > b.size;
    }
};

pub fn run(app: app_mod.App, opts: Opts) !void {
    const dd_root = try dd.root(app.gpa, app.io, app.environ);
    const cp_root = try cp.root(app.gpa, app.environ);
    const ct_root = try ct.root(app.gpa, app.environ);

    var scanned: usize = 0;
    var dead: std.ArrayList(Target) = .empty;

    if (opts.wants(.build_data)) {
        const entries = try dd.list(app.gpa, app.io, dd_root);
        scanned += entries.len;
        for (try dd.orphans(app.gpa, app.io, entries)) |entry| {
            try dead.append(app.gpa, .{ .build_data = entry });
        }
    }
    if (opts.wants(.sessions)) {
        const entries = try cp.list(app.gpa, app.io, cp_root);
        scanned += entries.len;
        for (try cp.orphans(app.gpa, app.io, entries)) |entry| {
            try dead.append(app.gpa, .{ .sessions = entry });
        }
    }
    if (opts.wants(.scratch)) {
        const running = try ct.live(app.gpa, app.io, try ct.sessionsRoot(app.gpa, app.environ));
        if (running == .unknown) {
            app.ui.warn("Could not tell which Claude Code sessions are running — leaving every scratch folder alone.", .{});
        }
        const entries = try ct.list(app.gpa, app.io, ct_root, running);
        scanned += entries.len;
        for (entries) |entry| try dead.append(app.gpa, .{ .scratch = entry });
    }

    if (scanned == 0) {
        app.ui.warn("Nothing to scan — no build data in {f}, no sessions in {f}, no stopped scratch in {f}.", .{
            ui.dim(disk.abbreviate(app.gpa, app.environ, dd_root)),
            ui.dim(disk.abbreviate(app.gpa, app.environ, cp_root)),
            ui.dim(disk.abbreviate(app.gpa, app.environ, ct_root)),
        });
        return;
    }
    if (dead.items.len == 0) {
        app.ui.success("Nothing to clean — no orphans among {d} folder{s}.", .{
            scanned, plural(scanned),
        });
        return;
    }

    app.ui.step("Measuring {d} orphaned folder{s}…", .{ dead.items.len, plural(dead.items.len) });
    app.ui.flush();

    const candidates = try measure(app, dead.items);
    std.mem.sort(Candidate, candidates, {}, Candidate.sizeDesc);

    app.ui.info("{f} in {d} folder{s} nothing is using any more.", .{
        ui.bold(try std.fmt.allocPrint(app.gpa, "{f}", .{ui.bytes(totalSize(candidates))})),
        candidates.len,
        plural(candidates.len),
    });
    if (opts.wants(.sessions)) {
        app.ui.hint("Session transcripts are what `claude --resume` replays — check before deleting.", .{});
    }
    if (opts.wants(.scratch)) {
        app.ui.hint("Scratch folders are temp files of sessions that have stopped — a resumed session starts with an empty one.", .{});
    }

    const picked: []const Candidate = if (opts.yes) candidates else try select(app, candidates);
    if (picked.len == 0) {
        app.ui.hint("Nothing selected.", .{});
        return;
    }

    app.ui.step("Deleting {d} folder{s}…", .{ picked.len, plural(picked.len) });
    var reclaimed: u64 = 0;
    for (picked) |item| {
        const result = switch (item.target) {
            .build_data => |e| dd.remove(app.gpa, app.io, e, dd_root),
            .sessions => |e| cp.remove(app.gpa, app.io, e, cp_root),
            .scratch => |e| ct.remove(app.io, e, ct_root),
        };
        result catch |err| {
            app.ui.warn("Could not remove {s}: {s}", .{ item.name(), @errorName(err) });
            continue;
        };
        reclaimed += item.size;
        app.ui.success("{s} {s} {f}", .{
            item.label(),
            item.name(),
            ui.yellow(try std.fmt.allocPrint(app.gpa, "({f})", .{ui.bytes(item.size)})),
        });
    }
    app.ui.success("Reclaimed {f}.", .{
        ui.bold(try std.fmt.allocPrint(app.gpa, "{f}", .{ui.bytes(reclaimed)})),
    });
}

fn measure(app: app_mod.App, targets: []const Target) ![]Candidate {
    var paths: std.ArrayList([]const u8) = .empty;
    for (targets) |target| switch (target) {
        .build_data => |e| try paths.append(app.gpa, e.path),
        .sessions => |e| try paths.append(app.gpa, e.path),
        .scratch => |e| try paths.appendSlice(app.gpa, e.stopped),
    };
    const sizes = try disk.usage(app.gpa, app.io, paths.items);

    const candidates = try app.gpa.alloc(Candidate, targets.len);
    var at: usize = 0;
    for (targets, 0..) |target, i| {
        const count = switch (target) {
            .scratch => |e| e.stopped.len,
            else => 1,
        };
        var size: u64 = 0;
        for (sizes[at .. at + count]) |s| size += s;
        at += count;
        candidates[i] = .{ .target = target, .size = size };
    }
    return candidates;
}

fn select(app: app_mod.App, candidates: []const Candidate) ![]const Candidate {
    var size_width: usize = 0;
    var name_width: usize = 0;
    const sizes = try app.gpa.alloc([]const u8, candidates.len);
    for (candidates, 0..) |item, i| {
        sizes[i] = try std.fmt.allocPrint(app.gpa, "{f}", .{ui.bytes(item.size)});
        size_width = @max(size_width, sizes[i].len);
        name_width = @max(name_width, ui.displayWidth(item.name()));
    }

    const items = try app.gpa.alloc(prompt.Item, candidates.len);
    for (candidates, 0..) |item, i| {
        items[i] = .{
            .label = try std.fmt.allocPrint(app.gpa, "{s}{s}  {s}  {f}  {s}", .{
                try blanks(app.gpa, size_width - sizes[i].len),
                sizes[i],
                item.label(),
                ui.pad(item.name(), name_width),
                disk.abbreviate(app.gpa, app.environ, item.origin()),
            }),
            .checked = true,
        };
    }

    app.ui.flush();
    const chosen = try prompt.checkbox(
        app.gpa,
        app.io,
        "Select what to delete (space toggles, enter confirms):",
        "",
        items,
    ) orelse std.process.exit(app_mod.cancelled_exit_code);

    const subset = try app.gpa.alloc(Candidate, chosen.len);
    for (chosen, 0..) |index, i| subset[i] = candidates[index];
    return subset;
}

fn totalSize(candidates: []const Candidate) u64 {
    var total: u64 = 0;
    for (candidates) |c| total += c.size;
    return total;
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

fn blanks(gpa: std.mem.Allocator, n: usize) ![]u8 {
    const out = try gpa.alloc(u8, n);
    @memset(out, ' ');
    return out;
}
