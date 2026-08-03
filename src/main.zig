const std = @import("std");
const Io = std.Io;

const app_mod = @import("app.zig");
const auth_cmd = @import("commands/auth.zig");
const clean_cmd = @import("commands/clean.zig");
const list_cmd = @import("commands/list.zig");
const open_cmd = @import("commands/open.zig");
const remove_cmd = @import("commands/remove.zig");
const setup_cmd = @import("commands/setup.zig");
const start_cmd = @import("commands/start.zig");
const stats_cmd = @import("commands/stats.zig");
const config = @import("config.zig");
const ui = @import("ui.zig");

const version = "0.1.0";

const usage =
    \\Usage: lcc <command> [options]
    \\
    \\Pick a Linear issue → git worktree + symlinked local files + coding agent
    \\
    \\Commands:
    \\  start [PE-N]             Bootstrap a worktree for an issue — picker when none is named
    \\    --all                  show all assigned issues regardless of activeStates filter
    \\    --json                 print what was resolved instead of launching an agent (needs PE-N)
    \\    --base <ref>           base a new branch on <ref> instead of asking
    \\    --repo <path>          the repository the issue's code is in, when lcc cannot
    \\                           tell — it remembers the answer per issue, and finds a
    \\                           repo that already has a branch for it on its own
    \\  auth                     Authenticate with Linear (OAuth browser flow)
    \\    --logout               remove stored token
    \\    --status               show current authentication state
    \\    --token <pat>          headless fallback: store a personal API token directly
    \\  auth setup --client-id <id>
    \\                           Configure OAuth client_id (one-time)
    \\  setup                    Interactively configure lcc
    \\  list | ls                Dashboard of the worktrees in the current repo
    \\    --local                skip the PR and Linear columns (no network)
    \\    --no-tokens            skip the TOKENS column (skips reading transcripts)
    \\    --refresh              re-ask GitHub and Linear instead of reusing a recent answer
    \\  stats                    What each worktree has spent across Claude Code and Codex
    \\    --models               break every worktree down by model
    \\    --json                 print the numbers instead of a table
    \\  open | o [claude|codex|xcode]
    \\                           Open a worktree in the configured agent, or override it
    \\    --no-resume            start the selected agent fresh
    \\  remove | rm              Select and remove one or more worktrees, branches, and build data
    \\    --merged               bulk: every worktree and branch already merged
    \\    --local                decide from local refs only — no fetch, no asking
    \\                           GitHub whether the branch's PR was merged
    \\    -f, --force            force remove even with uncommitted changes
    \\    -y, --yes              skip confirmation after selecting worktrees
    \\    --keep-derived-data    leave the Xcode DerivedData folder in place
    \\    --keep-branch          leave the git branch in place
    \\    --keep-xcode           don't ask Xcode to close the worktree it has open
    \\    --sessions             also delete Claude Code and Codex session transcripts
    \\  clean                    Delete what worktrees that no longer exist left behind
    \\    --build-data           only Xcode DerivedData
    \\    --sessions             only Claude Code and Codex session transcripts
    \\    -y, --yes              delete every orphaned folder without prompting
    \\
    \\  -h, --help               show this help
    \\  -V, --version            show version
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    ui.detectColor(io, init.environ_map);

    var out_buffer: [16 * 1024]u8 = undefined;
    var err_buffer: [4 * 1024]u8 = undefined;
    var out_writer: Io.File.Writer = .init(.stdout(), io, &out_buffer);
    var err_writer: Io.File.Writer = .init(.stderr(), io, &err_buffer);

    const app: app_mod.App = .{
        .gpa = arena,
        .io = io,
        .environ = init.environ_map,
        .ui = .{
            .io = io,
            .out = &out_writer.interface,
            .err = &err_writer.interface,
        },
    };
    defer app.ui.flush();

    const args = try init.minimal.args.toSlice(arena);
    dispatch(app, args[1..]) catch |err| {
        app.ui.fail("{s}", .{describe(err)});
        app.ui.flush();
        std.process.exit(1);
    };
}

fn dispatch(app: app_mod.App, args: []const []const u8) !void {
    // No arguments prints the command list. Every action is named explicitly —
    // there is no default command, so `lcc` alone never touches a repository.
    if (args.len == 0) {
        app.ui.info("{s}", .{usage});
        return;
    }

    const first = args[0];
    if (eq(first, "-h") or eq(first, "--help") or eq(first, "help")) {
        app.ui.info("{s}", .{usage});
        return;
    }
    if (eq(first, "-V") or eq(first, "--version")) {
        app.ui.info("{s}", .{version});
        return;
    }
    if (eq(first, "auth")) return authCommand(app, args[1..]);
    if (eq(first, "setup")) return setup_cmd.run(app);
    if (eq(first, "list") or eq(first, "ls")) return listCommand(app, args[1..]);
    if (eq(first, "open") or eq(first, "o")) return openCommand(app, args[1..]);
    if (eq(first, "remove") or eq(first, "rm")) return removeCommand(app, args[1..]);
    if (eq(first, "clean")) return cleanCommand(app, args[1..]);
    if (eq(first, "start")) return startCommand(app, args[1..]);
    if (eq(first, "stats")) return statsCommand(app, args[1..]);
    if (std.mem.startsWith(u8, first, "-")) return error.UnknownOption;
    return error.UnknownCommand;
}

fn startCommand(app: app_mod.App, args: []const []const u8) !void {
    var opts: start_cmd.Opts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "--all")) {
            opts.all = true;
        } else if (eq(arg, "--json")) {
            opts.json = true;
        } else if (eq(arg, "--base")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.base = args[i];
        } else if (eq(arg, "--repo")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.repo = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else if (opts.issue == null) {
            opts.issue = arg;
        } else return error.TooManyArguments;
    }

    // stdout belongs to the payload in machine mode; the progress lines still go
    // somewhere a human can see them.
    var machine = app;
    machine.ui.divert = opts.json;
    return start_cmd.run(machine, opts);
}

fn authCommand(app: app_mod.App, args: []const []const u8) !void {
    if (args.len > 0 and eq(args[0], "setup")) {
        var client_id: ?[]const u8 = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (eq(args[i], "--client-id")) {
                i += 1;
                if (i >= args.len) return error.MissingOptionValue;
                client_id = args[i];
            } else return error.UnknownOption;
        }
        return auth_cmd.setup(app, client_id orelse return error.MissingClientId);
    }

    var opts: auth_cmd.Opts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eq(args[i], "--logout")) {
            opts.logout = true;
        } else if (eq(args[i], "--status")) {
            opts.status = true;
        } else if (eq(args[i], "--token")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.token = args[i];
        } else return error.UnknownOption;
    }
    return auth_cmd.run(app, opts);
}

fn openCommand(app: app_mod.App, args: []const []const u8) !void {
    var target_arg: ?[]const u8 = null;
    var no_resume = false;
    for (args) |arg| {
        if (eq(arg, "--no-resume")) {
            no_resume = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else if (target_arg == null) {
            target_arg = arg;
        } else return error.TooManyArguments;
    }

    const configured = if (target_arg == null)
        (try config.load(app.gpa, app.io, app.environ)).agent
    else
        config.Agent.claude;
    const target = open_cmd.resolveTarget(target_arg, configured) orelse {
        app.ui.fail("Unknown open target '{s}'. Use one of: claude, codex, xcode.", .{target_arg.?});
        std.process.exit(1);
    };
    return open_cmd.run(app, target, no_resume);
}

fn listCommand(app: app_mod.App, args: []const []const u8) !void {
    var opts: list_cmd.Opts = .{};
    for (args) |arg| {
        if (eq(arg, "--local")) {
            opts.local = true;
        } else if (eq(arg, "--no-tokens")) {
            opts.tokens = false;
        } else if (eq(arg, "--refresh")) {
            opts.refresh = true;
        } else return error.UnknownOption;
    }
    return list_cmd.run(app, opts);
}

fn statsCommand(app: app_mod.App, args: []const []const u8) !void {
    var opts: stats_cmd.Opts = .{};
    for (args) |arg| {
        if (eq(arg, "--models")) {
            opts.models = true;
        } else if (eq(arg, "--json")) {
            opts.json = true;
        } else return error.UnknownOption;
    }

    // stdout belongs to the payload in machine mode, same as `start --json`.
    var machine = app;
    machine.ui.divert = opts.json;
    return stats_cmd.run(machine, opts);
}

fn removeCommand(app: app_mod.App, args: []const []const u8) !void {
    var opts: remove_cmd.Opts = .{};
    for (args) |arg| {
        if (eq(arg, "-f") or eq(arg, "--force")) {
            opts.force = true;
        } else if (eq(arg, "-y") or eq(arg, "--yes")) {
            opts.yes = true;
        } else if (eq(arg, "--keep-derived-data")) {
            opts.keep_derived_data = true;
        } else if (eq(arg, "--keep-branch")) {
            opts.keep_branch = true;
        } else if (eq(arg, "--keep-xcode")) {
            opts.keep_xcode = true;
        } else if (eq(arg, "--sessions")) {
            opts.sessions = true;
        } else if (eq(arg, "--merged")) {
            opts.merged = true;
        } else if (eq(arg, "--local")) {
            opts.local = true;
        } else return error.UnknownOption;
    }
    return remove_cmd.run(app, opts);
}

fn cleanCommand(app: app_mod.App, args: []const []const u8) !void {
    var opts: clean_cmd.Opts = .{};
    for (args) |arg| {
        if (eq(arg, "-y") or eq(arg, "--yes")) {
            opts.yes = true;
        } else if (eq(arg, "--build-data")) {
            opts.build_data = true;
        } else if (eq(arg, "--sessions")) {
            opts.sessions = true;
        } else return error.UnknownOption;
    }
    return clean_cmd.run(app, opts);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test {
    // Zig only collects tests from files the root references during test
    // analysis, so name every module here or `zig build test` runs nothing.
    _ = @import("app.zig");
    _ = @import("claude.zig");
    _ = @import("claude_projects.zig");
    _ = @import("codex_project_config.zig");
    _ = @import("codex_projects.zig");
    _ = @import("sessions.zig");
    _ = @import("config.zig");
    _ = @import("derived_data.zig");
    _ = @import("disk.zig");
    _ = @import("exec.zig");
    _ = @import("fold.zig");
    _ = @import("git.zig");
    _ = @import("github.zig");
    _ = @import("keychain.zig");
    _ = @import("linear.zig");
    _ = @import("link.zig");
    _ = @import("mcp.zig");
    _ = @import("oauth.zig");
    _ = @import("prompt.zig");
    _ = @import("remote_cache.zig");
    _ = @import("repos.zig");
    _ = @import("ui.zig");
    _ = @import("usage.zig");
    _ = @import("usage_cache.zig");
    _ = @import("xcode.zig");
    _ = @import("commands/list.zig");
    _ = @import("commands/remove.zig");
    _ = @import("commands/setup.zig");
    _ = @import("commands/start.zig");
    _ = @import("commands/stats.zig");
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.NotAGitRepository => "Not inside a git repository. Run `lcc` from within your repo.",
        error.ClaudeNotFound => "Could not find `claude` on PATH. Install Claude Code: https://docs.claude.com/en/docs/claude-code",
        error.CodexNotFound => "Could not find `codex` on PATH. Install Codex CLI: https://developers.openai.com/codex/cli/",
        error.NotATerminal => "lcc needs an interactive terminal for this command.",
        error.UnknownCommand => "Unknown command. Run `lcc --help`.",
        error.UnknownOption => "Unknown option. Run `lcc --help`.",
        error.MissingOptionValue => "Missing value for option. Run `lcc --help`.",
        error.MissingClientId => "auth setup requires --client-id <id>.",
        error.InvalidConfig => "Configuration is invalid. Fix ~/.config/lcc/config.json.",
        error.TooManyArguments => "Too many arguments. Run `lcc --help`.",
        error.NoHomeDirectory => "HOME is not set.",
        else => @errorName(err),
    };
}
