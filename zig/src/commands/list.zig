//! `lcc list` — worktrees in the current repo.

const std = @import("std");
const app_mod = @import("../app.zig");
const ui = @import("../ui.zig");

pub fn run(app: app_mod.App) !void {
    const repo = try app.repo();
    const choices = try app_mod.worktreeChoices(app, repo);

    if (choices.len == 0) {
        app.ui.hint("No worktrees.", .{});
        return;
    }

    var width: usize = 6;
    for (choices) |choice| {
        const label = if (choice.entry.branch) |b| b else app_mod.shortHead(choice.entry.head);
        width = @max(width, ui.displayWidth(label));
    }

    for (choices) |choice| {
        const label = if (choice.entry.branch) |b|
            try app.gpa.dupe(u8, b)
        else
            try std.fmt.allocPrint(app.gpa, "{s} (detached)", .{app_mod.shortHead(choice.entry.head)});
        const padded = try std.fmt.allocPrint(app.gpa, "{f}", .{ui.pad(label, width)});

        app.ui.info("{f}  {f}{f}{f}{f}", .{
            ui.cyan(padded),
            ui.dim(choice.entry.path),
            ui.yellow(if (choice.entry.locked) "  locked" else ""),
            ui.red(if (choice.entry.prunable) "  prunable" else ""),
            ui.dim(if (choice.managed) "  lcc" else ""),
        });
    }
}
