const std = @import("std");
const app_mod = @import("../app.zig");
const claude = @import("../claude.zig");
const claude_projects = @import("../claude_projects.zig");
const disk = @import("../disk.zig");
const git = @import("../git.zig");
const mcp = @import("../mcp.zig");
const prompt = @import("../prompt.zig");
const ui = @import("../ui.zig");
const usage = @import("../usage.zig");
const xcode = @import("../xcode.zig");

pub const Target = enum { claude, xcode };

pub fn resolveTarget(raw: ?[]const u8) ?Target {
    const value = raw orelse return .claude;
    if (std.ascii.eqlIgnoreCase(value, "claude")) return .claude;
    if (std.ascii.eqlIgnoreCase(value, "xcode")) return .xcode;
    return null;
}

pub const Preference = union(enum) {
    unset,
    flag: []const u8,
    config: []const u8,
};

pub const Opts = struct {
    target: Target = .claude,
    no_resume: bool = false,
    xcode_app: Preference = .unset,
};

pub fn run(app: app_mod.App, opts: Opts) !void {
    const target = opts.target;
    const xcodes: []const xcode.Install = if (target == .xcode)
        try xcode.installs(app.gpa, app.io, app.environ)
    else
        &.{};
    const named = if (target == .xcode) try namedXcode(app, xcodes, opts.xcode_app) else null;

    const repo = try app.repo();
    const choices = try app_mod.worktreeChoices(app, repo);
    if (choices.len == 0) {
        app.ui.warn("No worktrees to open (only the main one exists).", .{});
        return;
    }

    const message = switch (target) {
        .claude => "Pick a worktree to open in claude:",
        .xcode => "Pick a worktree to open in xcode:",
    };
    const picked = try app_mod.pickWorktree(app, choices, message) orelse
        std.process.exit(app_mod.cancelled_exit_code);

    switch (target) {
        .xcode => try openInXcode(app, picked, xcodes, named),
        .claude => try openInClaude(app, repo, picked, opts.no_resume),
    }
}

fn openInClaude(
    app: app_mod.App,
    repo: git.Repo,
    picked: app_mod.Choice,
    no_resume: bool,
) !void {
    const resumable = !no_resume and
        claude_projects.hasSessionsFor(app.gpa, app.io, app.environ, picked.entry.path);

    const carried = try mcp.carry(app.gpa, app.io, app.environ, repo.root);

    const label = picked.entry.branch orelse app_mod.shortHead(picked.entry.head);
    app.ui.info("{f} in {f} {f}", .{
        ui.bold("Launching Claude Code"),
        ui.dim(picked.entry.path),
        ui.cyan(label),
    });
    if (!resumable and !no_resume) app.ui.hint("No sessions here yet — starting fresh.", .{});

    const spent = usage.forWorktree(app.gpa, app.io, app.environ, picked.entry.path);
    if (!spent.empty()) {
        app.ui.hint("Spent here: {f}", .{usage.brief(spent, app_mod.nowSeconds(app.io))});
    }
    if (carried) |c| {
        app.ui.hint("MCP: carrying {d} local server(s) from {s} — {s}", .{
            c.names.len,
            std.fs.path.basename(repo.root),
            try std.mem.join(app.gpa, ", ", c.names),
        });
    }
    app.ui.flush();

    var extra: std.ArrayList([]const u8) = .empty;
    if (carried) |c| try extra.appendSlice(app.gpa, &.{ "--mcp-config", c.path });
    if (try mcp.deny(app.gpa, app.io, app.environ)) |path| {
        try extra.appendSlice(app.gpa, &.{ "--settings", path });
    }
    if (resumable) try extra.append(app.gpa, "--resume");

    const code = try claude.launch(app.gpa, app.io, picked.entry.path, extra.items);
    std.process.exit(code);
}

fn openInXcode(
    app: app_mod.App,
    picked: app_mod.Choice,
    xcodes: []const xcode.Install,
    named: ?xcode.Install,
) !void {
    const target = try xcode.findTarget(app.gpa, app.io, picked.entry.path, 4) orelse {
        app.ui.warn("No .xcworkspace, .xcodeproj, or Package.swift found in {f}.", .{
            ui.dim(picked.entry.path),
        });
        return;
    };

    const chosen = try chooseXcode(app, xcodes, named);
    const application = if (chosen) |install| install.path else "Xcode";
    const heading: []const u8 = if (chosen) |install|
        try std.fmt.allocPrint(app.gpa, "Opening {s}", .{try install.title(app.gpa)})
    else
        "Opening Xcode";

    const label = picked.entry.branch orelse app_mod.shortHead(picked.entry.head);
    app.ui.info("{f} — {f} {f}", .{
        ui.bold(heading),
        ui.cyan(try xcode.describe(app.gpa, target)),
        ui.dim(try std.fmt.allocPrint(app.gpa, "({s})", .{label})),
    });
    app.ui.flush();

    xcode.open(app.gpa, app.io, application, target.path) catch {
        app.ui.fail(
            "Failed to open Xcode. Is Xcode installed?\n  Tried: open -a {s} {s}\n{s}",
            .{ application, target.path, xcode.last_error },
        );
        std.process.exit(1);
    };
    app.ui.success("Xcode launched.", .{});
}

fn namedXcode(
    app: app_mod.App,
    found: []const xcode.Install,
    preference: Preference,
) !?xcode.Install {
    switch (preference) {
        .flag => |wanted| return try resolve(app, found, wanted) orelse {
            app.ui.fail("No installed Xcode is called '{s}'.{s}", .{ wanted, try listing(app, found) });
            std.process.exit(1);
        },
        .config => |wanted| {
            if (try resolve(app, found, wanted)) |install| return install;
            app.ui.warn("xcodeApp names '{s}', which is not installed.", .{wanted});
            return null;
        },
        .unset => return null,
    }
}

pub const Decision = union(enum) {
    chosen: xcode.Install,
    ask,
    any,
};

pub fn decide(found: []const xcode.Install, named: ?xcode.Install) Decision {
    if (named) |install| return .{ .chosen = install };
    if (found.len == 0) return .any;
    if (found.len == 1) return .{ .chosen = found[0] };
    return .ask;
}

fn chooseXcode(
    app: app_mod.App,
    found: []const xcode.Install,
    named: ?xcode.Install,
) !?xcode.Install {
    return switch (decide(found, named)) {
        .chosen => |install| install,
        .any => null,
        .ask => try pickXcode(app, found),
    };
}

fn resolve(app: app_mod.App, found: []const xcode.Install, wanted: []const u8) !?xcode.Install {
    if (xcode.match(found, wanted)) |install| return install;
    if (!std.fs.path.isAbsolute(wanted)) return null;
    return xcode.describeApp(app.gpa, app.io, wanted);
}

fn listing(app: app_mod.App, found: []const xcode.Install) ![]const u8 {
    if (found.len == 0) return " None was found at all.";

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(app.gpa, " Installed:");
    for (found) |install| {
        try out.appendSlice(app.gpa, try std.fmt.allocPrint(app.gpa, "\n  {s}  {s}", .{
            try install.title(app.gpa),
            install.path,
        }));
    }
    return out.items;
}

fn pickXcode(app: app_mod.App, found: []const xcode.Install) !xcode.Install {
    const items = try app.gpa.alloc(prompt.Item, found.len);
    for (found, 0..) |install, i| {
        items[i] = .{
            .label = try rowLabel(app.gpa, install),
            .haystack = try std.fmt.allocPrint(app.gpa, "{s} {s} {s}", .{
                install.name,
                install.version,
                install.path,
            }),
            .description = disk.abbreviate(app.gpa, app.environ, install.path),
        };
    }

    app.ui.flush();
    const index = try prompt.search(app.gpa, app.io, "Which Xcode?", items) orelse
        std.process.exit(app_mod.cancelled_exit_code);

    app.ui.hint("Always this one: lcc config xcodeApp {s}", .{found[index].name});
    return found[index];
}

fn rowLabel(gpa: std.mem.Allocator, install: xcode.Install) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, try install.title(gpa));
    if (install.build.len > 0) {
        try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, " ({s})", .{install.build}));
    }
    if (install.active) try out.appendSlice(gpa, " · xcode-select");
    return out.items;
}

test "one Xcode installed is not a question, and none found is not an error" {
    const only = [_]xcode.Install{.{ .path = "/Applications/Xcode.app", .name = "Xcode" }};
    try std.testing.expectEqualStrings("Xcode", decide(&only, null).chosen.name);
    try std.testing.expect(decide(&.{}, null) == .any);

    const two = [_]xcode.Install{
        .{ .path = "/Applications/Xcode.app", .name = "Xcode" },
        .{ .path = "/Applications/Xcode-beta.app", .name = "Xcode-beta" },
    };
    try std.testing.expect(decide(&two, null) == .ask);
}

test "an Xcode already named is used even when it is not one of the installed" {
    const two = [_]xcode.Install{
        .{ .path = "/Applications/Xcode.app", .name = "Xcode" },
        .{ .path = "/Applications/Xcode-beta.app", .name = "Xcode-beta" },
    };
    const named: xcode.Install = .{ .path = "/Volumes/Big/Xcode-15.app", .name = "Xcode-15" };
    try std.testing.expectEqualStrings("Xcode-15", decide(&two, named).chosen.name);
    try std.testing.expectEqualStrings("Xcode-15", decide(&.{}, named).chosen.name);
}
