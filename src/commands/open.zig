//! `lcc open [xcode]` — resume Claude Code in a worktree, or open it in Xcode.

const std = @import("std");
const app_mod = @import("../app.zig");
const claude = @import("../claude.zig");
const claude_projects = @import("../claude_projects.zig");
const git = @import("../git.zig");
const mcp = @import("../mcp.zig");
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

pub fn run(app: app_mod.App, target: Target, no_resume: bool) !void {
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
        .xcode => try openInXcode(app, picked),
        .claude => try openInClaude(app, repo, picked, no_resume),
    }
}

fn openInClaude(
    app: app_mod.App,
    repo: git.Repo,
    picked: app_mod.Choice,
    no_resume: bool,
) !void {
    // `--resume` in a directory Claude Code has never run in opens a picker with
    // nothing to pick, so only ask for it once a transcript exists.
    const resumable = !no_resume and
        claude_projects.hasSessionsFor(app.gpa, app.io, app.environ, picked.entry.path);

    // Same reason `lcc start` does it: local-scope MCP servers are keyed on the
    // directory they were added in, so a worktree sees none of the repo's own.
    const carried = try mcp.carry(app.gpa, app.io, app.environ, repo.root);

    const label = picked.entry.branch orelse app_mod.shortHead(picked.entry.head);
    app.ui.info("{f} in {f} {f}", .{
        ui.bold("Launching Claude Code"),
        ui.dim(picked.entry.path),
        ui.cyan(label),
    });
    if (!resumable and !no_resume) app.ui.hint("No sessions here yet — starting fresh.", .{});

    // What this task has cost so far, before adding to it.
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
    if (resumable) try extra.append(app.gpa, "--resume");

    const code = try claude.launch(app.gpa, app.io, picked.entry.path, extra.items);
    std.process.exit(code);
}

fn openInXcode(app: app_mod.App, picked: app_mod.Choice) !void {
    const target = try xcode.findTarget(app.gpa, app.io, picked.entry.path, 4) orelse {
        app.ui.warn("No .xcworkspace, .xcodeproj, or Package.swift found in {f}.", .{
            ui.dim(picked.entry.path),
        });
        return;
    };
    const label = picked.entry.branch orelse app_mod.shortHead(picked.entry.head);
    app.ui.info("{f} — {f} {f}", .{
        ui.bold("Opening Xcode"),
        ui.cyan(try xcode.describe(app.gpa, target)),
        ui.dim(try std.fmt.allocPrint(app.gpa, "({s})", .{label})),
    });
    app.ui.flush();

    xcode.open(app.gpa, app.io, target.path) catch {
        app.ui.fail(
            "Failed to open Xcode. Is Xcode installed?\n  Tried: open -a Xcode {s}\n{s}",
            .{ target.path, xcode.last_error },
        );
        std.process.exit(1);
    };
    app.ui.success("Xcode launched.", .{});
}
