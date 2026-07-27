//! Shared context handed to every command, plus the bits two commands need.

const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const git = @import("git.zig");
const prompt = @import("prompt.zig");
const ui = @import("ui.zig");

pub const App = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    ui: ui.Ui,

    pub fn repo(self: App) !git.Repo {
        return self.repoAt(null);
    }

    /// The repository containing `cwd`, for `--repo`. The path is carried into
    /// `Repo.cwd` as well: once a caller has named a repository, "the current
    /// branch" means the one checked out *there*, not in the directory lcc
    /// happens to have been run from.
    pub fn repoAt(self: App, cwd: ?[]const u8) !git.Repo {
        const root = try git.repoRoot(self.gpa, self.io, cwd);
        return .{ .gpa = self.gpa, .io = self.io, .root = root, .cwd = cwd };
    }
};

/// Cancelling a prompt exits 130, the conventional SIGINT status — the same
/// thing the TypeScript version did with inquirer's ExitPromptError.
pub const cancelled_exit_code: u8 = 130;

pub const Choice = struct {
    entry: git.WorktreeEntry,
    managed: bool,
};

/// Worktrees other than the main one, tagged with whether lcc created them.
pub fn worktreeChoices(app: App, repo: git.Repo) ![]Choice {
    const entries = try repo.listWorktrees();
    const cfg = try config.load(app.gpa, app.io, app.environ);
    const managed_prefix = try git.worktreePathPrefix(app.gpa, cfg.worktreeTemplate, repo.root);

    var out: std.ArrayList(Choice) = .empty;
    for (entries) |entry| {
        if (entry.is_main) continue;
        try out.append(app.gpa, .{
            .entry = entry,
            // An empty prefix matches everything, which would tag every worktree.
            .managed = managed_prefix.len > 0 and
                std.mem.startsWith(u8, entry.path, managed_prefix),
        });
    }
    return out.toOwnedSlice(app.gpa);
}

pub fn worktreeLabel(gpa: std.mem.Allocator, choice: Choice) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    const w = gpa;

    const name = if (choice.entry.branch) |b|
        try gpa.dupe(u8, b)
    else
        try std.fmt.allocPrint(gpa, "{s} (detached)", .{shortHead(choice.entry.head)});

    try line.appendSlice(w, name);
    const width = ui.displayWidth(name);
    if (width < 40) try line.appendNTimes(w, ' ', 40 - width);
    try line.appendSlice(w, "  ");
    try line.appendSlice(w, choice.entry.path);

    if (choice.entry.locked) try line.appendSlice(w, "  locked");
    if (choice.entry.prunable) try line.appendSlice(w, "  prunable");
    if (choice.managed) try line.appendSlice(w, "  lcc");
    return line.toOwnedSlice(w);
}

pub fn shortHead(head: []const u8) []const u8 {
    return head[0..@min(8, head.len)];
}

/// The picker used by both `lcc open` and `lcc remove`.
pub fn pickWorktree(app: App, choices: []const Choice, message: []const u8) !?Choice {
    const items = try app.gpa.alloc(prompt.Item, choices.len);
    for (choices, 0..) |choice, i| {
        const label = try worktreeLabel(app.gpa, choice);
        items[i] = .{
            .label = label,
            .haystack = try std.fmt.allocPrint(app.gpa, "{s} {s}", .{
                choice.entry.branch orelse choice.entry.head,
                choice.entry.path,
            }),
            .description = choice.entry.path,
        };
    }
    app.ui.flush();
    const index = try prompt.search(app.gpa, app.io, message, items) orelse return null;
    return choices[index];
}
