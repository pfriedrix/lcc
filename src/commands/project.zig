const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const config = @import("../config.zig");
const linear = @import("../linear.zig");
const oauth = @import("../oauth.zig");

pub const Verb = enum { content };

pub fn resolveVerb(raw: []const u8) ?Verb {
    if (std.ascii.eqlIgnoreCase(raw, "content")) return .content;
    return null;
}

pub const Opts = struct {
    name: ?[]const u8 = null,
    team: ?[]const u8 = null,
    get: bool = false,
    set_file: ?[]const u8 = null,
    json: bool = false,
    verb: Verb = .content,
};

const max_content = 1 << 20;

const ContentReport = struct {
    project: ProjectEntry,
    bytes: usize,
    content: []const u8,
    written: bool,
};

const ProjectEntry = struct {
    id: []const u8,
    name: []const u8,
};

pub fn run(app: app_mod.App, opts: Opts) !void {
    const name = opts.name orelse bail(
        app,
        opts.json,
        "usage",
        "project content needs a project name, e.g. `lcc project content v2.6.0 --get`.",
        .{},
    );
    const team = opts.team orelse teamFromBranch(app) orelse bail(
        app,
        opts.json,
        "team_unknown",
        "Nothing names a team here. Pass --team, or run this from a branch carrying an issue key.",
        .{},
    );

    const token = try authorize(app, opts);

    const found = linear.fetchProjectPage(app.gpa, app.io, token, team, name) catch |err| bail(
        app,
        opts.json,
        "linear_failed",
        "Linear request failed ({s}, HTTP {d}): {s}",
        .{ @errorName(err), linear.last_status, linear.last_message },
    );
    const page = found orelse bail(
        app,
        opts.json,
        "project_not_found",
        "No project called '{s}' reachable from {s}.",
        .{ name, team },
    );

    if (opts.set_file) |path| return write(app, opts, token, page, path);
    return read(app, opts, page);
}

fn read(app: app_mod.App, opts: Opts, page: linear.ProjectPage) !void {
    const value: ContentReport = .{
        .project = .{ .id = page.id, .name = page.name },
        .bytes = page.content.len,
        .content = page.content,
        .written = false,
    };

    if (opts.json) {
        const body = try std.json.Stringify.valueAlloc(app.gpa, value, .{ .whitespace = .indent_2 });
        app.ui.payload("{s}\n", .{body});
        app.ui.flush();
        return;
    }
    app.ui.payload("{s}\n", .{page.content});
    app.ui.flush();
}

fn write(
    app: app_mod.App,
    opts: Opts,
    token: oauth.Token,
    page: linear.ProjectPage,
    path: []const u8,
) !void {
    const content = contentFromFile(app, opts, path);

    if (!opts.json) {
        app.ui.step("Writing {d} bytes to {s}...", .{ content.len, page.name });
        app.ui.flush();
    }

    const saved = linear.setProjectContent(app.gpa, app.io, token, page.id, content) catch |err| bail(
        app,
        opts.json,
        "linear_failed",
        "Linear refused the write ({s}, HTTP {d}): {s}",
        .{ @errorName(err), linear.last_status, linear.last_message },
    );

    const value: ContentReport = .{
        .project = .{ .id = saved.id, .name = saved.name },
        .bytes = saved.content.len,
        .content = saved.content,
        .written = true,
    };

    if (opts.json) {
        const body = try std.json.Stringify.valueAlloc(app.gpa, value, .{ .whitespace = .indent_2 });
        app.ui.payload("{s}\n", .{body});
        app.ui.flush();
        return;
    }
    app.ui.success("{s}: page is now {d} bytes.", .{ saved.name, saved.content.len });
    app.ui.flush();
}

fn contentFromFile(app: app_mod.App, opts: Opts, raw: []const u8) []const u8 {
    const resolved = Io.Dir.cwd().realPathFileAlloc(app.io, raw, app.gpa) catch |err| switch (err) {
        error.FileNotFound => bail(app, opts.json, "content_not_found", "No file at {s}.", .{raw}),
        else => bail(app, opts.json, "content_unreadable", "Cannot read {s}: {s}", .{ raw, @errorName(err) }),
    };
    const info = Io.Dir.cwd().statFile(app.io, resolved, .{}) catch |err|
        bail(app, opts.json, "content_unreadable", "Cannot read {s}: {s}", .{ raw, @errorName(err) });
    if (info.kind != .file) {
        bail(app, opts.json, "content_not_found", "{s} is a {s}, not a file.", .{ raw, @tagName(info.kind) });
    }
    if (info.size > max_content) {
        bail(app, opts.json, "content_too_large", "{s} is {d} bytes; the limit is {d}.", .{ raw, info.size, max_content });
    }

    return Io.Dir.cwd().readFileAlloc(app.io, resolved, app.gpa, .limited(max_content)) catch |err|
        bail(app, opts.json, "content_unreadable", "Cannot read {s}: {s}", .{ raw, @errorName(err) });
}

fn teamFromBranch(app: app_mod.App) ?[]const u8 {
    const repo = app.repo() catch return null;
    const branch = (repo.currentBranch() catch return null) orelse return null;
    const ref = linear.refFromBranch(branch) orelse return null;
    return ref.team;
}

fn authorize(app: app_mod.App, opts: Opts) !oauth.Token {
    app.ui.hint("Reading the Linear token from the Keychain...", .{});
    app.ui.flush();
    switch (oauth.readToken(app.gpa)) {
        .token => {},
        .missing => bail(app, opts.json, "not_authenticated", "Not authenticated. Run `lcc auth` first.", .{}),
        .unreadable => |why| bail(
            app,
            opts.json,
            "keychain_unreadable",
            "The Linear token is in the Keychain, but reading it failed: {s}. " ++
                "Answer `Always Allow` if macOS asks again; `lcc auth` re-stores it if it stays refused.",
            .{why},
        ),
    }

    const cfg = try config.load(app.gpa, app.io, app.environ);

    return oauth.ensureFreshToken(app.gpa, app.io, cfg.clientId) catch |err| bail(
        app,
        opts.json,
        "auth_failed",
        "{s}: {s}",
        .{ @errorName(err), oauth.last_detail },
    );
}

fn bail(
    app: app_mod.App,
    json: bool,
    code: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) noreturn {
    const message = std.fmt.allocPrint(app.gpa, fmt, args) catch "";
    if (json) {
        const body = std.json.Stringify.valueAlloc(app.gpa, .{
            .@"error" = .{ .code = code, .message = message },
        }, .{ .whitespace = .indent_2 }) catch "{\"error\":{\"code\":\"internal\"}}";
        app.ui.payload("{s}\n", .{body});
    } else {
        app.ui.fail("{s}", .{message});
    }
    app.ui.flush();
    std.process.exit(1);
}

test "resolveVerb takes the subcommand however it is cased, and nothing else" {
    try std.testing.expectEqual(Verb.content, resolveVerb("content").?);
    try std.testing.expectEqual(Verb.content, resolveVerb("CONTENT").?);
    try std.testing.expect(resolveVerb("contents") == null);
    try std.testing.expect(resolveVerb("") == null);
}
