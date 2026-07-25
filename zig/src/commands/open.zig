//! `lcc open [xcode]` — resume Claude Code in a worktree, or open it in Xcode.

const std = @import("std");
const app_mod = @import("../app.zig");
const claude = @import("../claude.zig");
const ui = @import("../ui.zig");
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
        .claude => try openInClaude(app, picked, no_resume),
    }
}

fn openInClaude(app: app_mod.App, picked: app_mod.Choice, no_resume: bool) !void {
    const label = picked.entry.branch orelse app_mod.shortHead(picked.entry.head);
    app.ui.info("{f} in {f} {f}", .{
        ui.bold("Launching Claude Code"),
        ui.dim(picked.entry.path),
        ui.cyan(label),
    });
    app.ui.flush();

    const extra: []const []const u8 = if (no_resume) &.{} else &.{"--resume"};
    const code = try claude.launch(app.gpa, app.io, picked.entry.path, extra);
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
