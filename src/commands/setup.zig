//! `lcc setup` — interactive configuration.

const std = @import("std");
const app_mod = @import("../app.zig");
const config = @import("../config.zig");
const prompt = @import("../prompt.zig");
const ui = @import("../ui.zig");

pub fn run(app: app_mod.App) !void {
    const cfg = try config.load(app.gpa, app.io, app.environ);

    app.ui.info("{f}", .{ui.bold("Configure lcc")});
    app.ui.hint("Press Enter to keep current value. Ctrl-C to abort.", .{});
    app.ui.info("", .{});
    app.ui.flush();

    const start_task_command = try prompt.input(
        app.gpa,
        app.io,
        "Start-task command (placeholders: {identifier}, {branch}, {url}; empty = disabled):",
        cfg.startTaskCommand,
    ) orelse std.process.exit(app_mod.cancelled_exit_code);

    const worktree_template = try prompt.input(
        app.gpa,
        app.io,
        "Worktree path template:",
        cfg.worktreeTemplate,
    ) orelse std.process.exit(app_mod.cancelled_exit_code);

    const joined_states = try std.mem.join(app.gpa, ", ", cfg.activeStates);
    const states_raw = try prompt.input(
        app.gpa,
        app.io,
        "Active Linear states (comma-separated):",
        joined_states,
    ) orelse std.process.exit(app_mod.cancelled_exit_code);

    const joined_patterns = try std.mem.join(app.gpa, ", ", cfg.linkPatterns);
    const patterns_raw = try prompt.input(
        app.gpa,
        app.io,
        "Files to symlink into each worktree (comma-separated, paths may nest):",
        joined_patterns,
    ) orelse std.process.exit(app_mod.cancelled_exit_code);

    try config.save(app.gpa, app.io, app.environ, .{
        .startTaskCommand = start_task_command,
        .worktreeTemplate = worktree_template,
        .activeStates = try splitList(app.gpa, states_raw),
        .linkPatterns = try splitList(app.gpa, patterns_raw),
    });

    const where = try config.path(app.gpa, app.environ);
    app.ui.success("Saved to {s}", .{where});
}

fn splitList(gpa: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len > 0) try items.append(gpa, trimmed);
    }
    return items.toOwnedSlice(gpa);
}
