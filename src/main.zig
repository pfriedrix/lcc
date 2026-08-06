const std = @import("std");
const Io = std.Io;

const app_mod = @import("app.zig");
const auth_cmd = @import("commands/auth.zig");
const clean_cmd = @import("commands/clean.zig");
const config_cmd = @import("commands/config.zig");
const daemon_cmd = @import("commands/daemon.zig");
const issue_cmd = @import("commands/issue.zig");
const list_cmd = @import("commands/list.zig");
const open_cmd = @import("commands/open.zig");
const remove_cmd = @import("commands/remove.zig");
const setup_cmd = @import("commands/setup.zig");
const start_cmd = @import("commands/start.zig");
const stats_cmd = @import("commands/stats.zig");
const watch_cmd = @import("commands/watch.zig");
const config = @import("config.zig");
const ui = @import("ui.zig");

const version = "0.1.0";

const usage =
    \\Usage: lcc <command> [options]
    \\
    \\Pick a Linear issue → git worktree + symlinked local files + Claude Code in plan mode
    \\
    \\Commands:
    \\  start [PE-N]             Bootstrap a worktree for an issue and open it in plan mode
    \\                           — picker when no issue is named
    \\    --all                  show all assigned issues regardless of activeStates filter
    \\    --json                 print what was resolved instead of launching an agent (needs PE-N)
    \\    --base <ref>           base a new branch on <ref> instead of asking
    \\    --repo <path>          the repository the issue's code is in, when lcc cannot
    \\                           tell — it remembers the answer per issue, and finds a
    \\                           repo that already has a branch for it on its own
    \\    --plan <file>          start from a plan that already exists instead of
    \\                           opening in plan mode — reaches the agent as {plan}
    \\                           in startTaskCommand, as a path, not inlined
    \\    --no-watch             run in this terminal instead of handing the session
    \\                           to the lcc daemon — it then dies with the terminal.
    \\                           The default is to watch; `lcc config watchByDefault
    \\                           false` makes --no-watch the default instead
    \\    --watch                hand it to the daemon even when that is off
    \\    --no-attach            print the session id instead of opening the dashboard
    \\  watch                    Alias for `open`
    \\  daemon                   Run or control the session daemon
    \\    --foreground           stay attached to this terminal
    \\    --stop                 ask a running daemon to exit
    \\      --force              kill its sessions rather than letting them finish
    \\    --status               whether one is running, and how many sessions
    \\    --json                 with --status, print it instead of a summary
    \\  issue <sub> PE-N         Read or write one Linear issue — no repository needed
    \\    show                   state, project, labels and description — read-only
    \\    state "<name>"         move it, by the team's own workflow-state name
    \\      --type <type>        narrow a name two states share
    \\    comment -m <text>      add a comment — or -f <file> to read it off disk
    \\    project --assign vX.Y.Z
    \\                           put it in a release project
    \\      --create             create the project when it does not exist yet
    \\      --force              move it out of a project it is already in
    \\    project --resolve      work out which release it targets — read-only
    \\      --fetch              refresh the view of origin first
    \\    --json                 print the result instead of a human summary
    \\  auth                     Authenticate with Linear (OAuth browser flow)
    \\    --logout               remove stored token
    \\    --status               show current authentication state
    \\    --token <pat>          headless fallback: store a personal API token directly
    \\  auth setup --client-id <id>
    \\                           Configure OAuth client_id (one-time)
    \\  setup                    Interactively configure lcc
    \\  config [<setting>] [<value>]
    \\                           Read or write one setting — no prompt, unlike setup
    \\    --json                 print the result instead of a human summary
    \\  list | ls                Dashboard of the worktrees in the current repo
    \\    --local                skip the PR and Linear columns (no network)
    \\    --no-tokens            skip the TOKENS column (skips reading transcripts)
    \\    --refresh              re-ask GitHub and Linear instead of reusing a recent answer
    \\  stats                    What each worktree has spent in Claude Code
    \\    --models               break every worktree down by model
    \\    --json                 print the numbers instead of a table
    \\  open | o                 The worktrees, and what is running in them
    \\                           enter opens one · n takes another issue · x kills
    \\    --json                 print the sessions instead of the dashboard
    \\    --no-status-bar        give an attached session the whole terminal
    \\  open xcode               Pick a worktree and open it in Xcode instead
    \\  remove | rm              Select and remove one or more worktrees, branches, and build data
    \\    --merged               bulk: every worktree and branch already merged
    \\    --local                decide from local refs only — no fetch, no asking
    \\                           GitHub whether the branch's PR was merged
    \\    -f, --force            force remove even with uncommitted changes
    \\    -y, --yes              skip confirmation after selecting worktrees
    \\    --keep-derived-data    leave the Xcode DerivedData folder in place
    \\    --keep-branch          leave the git branch in place
    \\    --keep-xcode           don't ask Xcode to close the worktree it has open
    \\    --sessions             also delete Claude Code session transcripts
    \\  clean                    Delete what worktrees that no longer exist left behind
    \\    --build-data           only Xcode DerivedData
    \\    --sessions             only Claude Code session transcripts
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
    if (eq(first, "config")) return configCommand(app, args[1..]);
    if (eq(first, "list") or eq(first, "ls")) return listCommand(app, args[1..]);
    if (eq(first, "open") or eq(first, "o")) return openCommand(app, args[1..]);
    if (eq(first, "watch")) return watchCommand(app, args[1..]);
    if (eq(first, "remove") or eq(first, "rm")) return removeCommand(app, args[1..]);
    if (eq(first, "clean")) return cleanCommand(app, args[1..]);
    if (eq(first, "issue")) return issueCommand(app, args[1..]);
    if (eq(first, "start")) return startCommand(app, args[1..]);
    if (eq(first, "stats")) return statsCommand(app, args[1..]);
    if (eq(first, "watch-hook")) return watchHookCommand(app, args[1..]);
    if (eq(first, "daemon")) return daemonCommand(app, args[1..]);
    if (std.mem.startsWith(u8, first, "-")) return error.UnknownOption;
    return error.UnknownCommand;
}

fn startCommand(app: app_mod.App, args: []const []const u8) !void {
    var opts: start_cmd.Opts = .{};
    var all: ?bool = null;
    var plan_mode: ?bool = null;
    var watch: ?bool = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "--all")) {
            all = true;
        } else if (eq(arg, "--no-all")) {
            all = false;
        } else if (eq(arg, "--plan-mode")) {
            plan_mode = true;
        } else if (eq(arg, "--no-plan-mode")) {
            plan_mode = false;
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
        } else if (eq(arg, "--plan")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.plan = args[i];
        } else if (eq(arg, "--watch")) {
            watch = true;
        } else if (eq(arg, "--no-watch")) {
            watch = false;
        } else if (eq(arg, "--no-attach")) {
            opts.no_attach = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else if (opts.issue == null) {
            opts.issue = arg;
        } else return error.TooManyArguments;
    }

    const cfg = try config.load(app.gpa, app.io, app.environ);
    opts.all = orConfig(all, cfg.allIssues);
    opts.plan_mode = orConfig(plan_mode, cfg.planMode);
    opts.watch = orConfig(watch, cfg.watchByDefault);

    // stdout belongs to the payload in machine mode; the progress lines still go
    // somewhere a human can see them.
    var machine = app;
    machine.ui.divert = opts.json;
    return start_cmd.run(machine, opts);
}

fn issueCommand(app: app_mod.App, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingIssueSubcommand;

    const verb = issue_cmd.resolveVerb(args[0]) orelse {
        app.ui.fail("Unknown issue subcommand '{s}'. Use one of: show, state, comment, project.", .{args[0]});
        std.process.exit(1);
    };

    var opts: issue_cmd.Opts = .{ .sub = issue_cmd.Sub.empty(verb) };
    // Past the verb, the way `auth setup` starts at 1.
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "--json")) {
            opts.json = true;
            continue;
        }
        switch (opts.sub) {
            .show => {},
            .state => |*sub| {
                if (eq(arg, "--type")) {
                    i += 1;
                    if (i >= args.len) return error.MissingOptionValue;
                    sub.type = args[i];
                    continue;
                }
            },
            .comment => |*sub| {
                if (eq(arg, "-m") or eq(arg, "--message")) {
                    i += 1;
                    if (i >= args.len) return error.MissingOptionValue;
                    sub.body = args[i];
                    continue;
                }
                if (eq(arg, "-f") or eq(arg, "--file")) {
                    i += 1;
                    if (i >= args.len) return error.MissingOptionValue;
                    sub.file = args[i];
                    continue;
                }
            },
            .project => |*sub| {
                if (eq(arg, "--assign")) {
                    i += 1;
                    if (i >= args.len) return error.MissingOptionValue;
                    sub.assign = args[i];
                    continue;
                }
                if (eq(arg, "--resolve")) {
                    sub.resolve = true;
                    continue;
                }
                if (eq(arg, "--fetch")) {
                    sub.fetch = true;
                    continue;
                }
                if (eq(arg, "--create")) {
                    sub.create = true;
                    continue;
                }
                if (eq(arg, "--force")) {
                    sub.force = true;
                    continue;
                }
            },
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;
        if (opts.issue == null) {
            opts.issue = arg;
        } else switch (opts.sub) {
            // The only verb with a second positional.
            .state => |*sub| {
                if (sub.name != null) return error.TooManyArguments;
                sub.name = arg;
            },
            else => return error.TooManyArguments,
        }
    }
    if (opts.issue == null) return error.MissingIssueIdentifier;
    switch (opts.sub) {
        .show => {},
        .state => |sub| if (sub.name == null) return error.MissingStateName,
        .comment => |sub| {
            if (sub.body != null and sub.file != null) return error.ConflictingCommentSource;
            if (sub.body == null and sub.file == null) return error.MissingCommentBody;
        },
        .project => |sub| {
            if (sub.assign != null and sub.resolve) return error.ConflictingProjectAction;
            if (sub.assign == null and !sub.resolve) return error.MissingProjectAction;
        },
    }

    // stdout belongs to the payload in machine mode, same as `start --json`.
    var machine = app;
    machine.ui.divert = opts.json;
    return issue_cmd.run(machine, opts);
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
    var resume_opt: ?bool = null;
    var passthrough: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        if (eq(arg, "--no-resume")) {
            resume_opt = false;
        } else if (eq(arg, "--resume")) {
            resume_opt = true;
        } else if (eq(arg, "--json") or eq(arg, "--status-bar") or eq(arg, "--no-status-bar")) {
            try passthrough.append(app.gpa, arg);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else if (target_arg == null) {
            target_arg = arg;
        } else return error.TooManyArguments;
    }

    const target = open_cmd.resolveTarget(target_arg) orelse {
        app.ui.fail("Unknown open target '{s}'. Use one of: claude, xcode.", .{target_arg.?});
        std.process.exit(1);
    };

    // Xcode keeps the old picker: it opens a worktree in an editor and has
    // nothing to do with sessions. Claude Code is the dashboard now — a
    // worktree and whether something is running in it are one question, and
    // which half you got used to depend on which of two commands you typed.
    if (target == .claude) return watchCommand(app, passthrough.items);

    const cfg = try config.load(app.gpa, app.io, app.environ);
    return open_cmd.run(app, target, !orConfig(resume_opt, cfg.resumeSessions));
}

fn listCommand(app: app_mod.App, args: []const []const u8) !void {
    var opts: list_cmd.Opts = .{};
    var tokens: ?bool = null;
    var network: ?config.ListNetwork = null;
    for (args) |arg| {
        if (eq(arg, "--local")) {
            network = .local;
        } else if (eq(arg, "--refresh")) {
            network = .refresh;
        } else if (eq(arg, "--cached")) {
            // The way back from a stored `listNetwork` of local or refresh.
            network = .cached;
        } else if (eq(arg, "--no-tokens")) {
            tokens = false;
        } else if (eq(arg, "--tokens")) {
            tokens = true;
        } else return error.UnknownOption;
    }

    const cfg = try config.load(app.gpa, app.io, app.environ);
    const mode = network orelse cfg.listNetwork;
    opts.local = mode == .local;
    opts.refresh = mode == .refresh;
    opts.tokens = orConfig(tokens, cfg.showTokens);
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
    var keep_derived_data: ?bool = null;
    var keep_branch: ?bool = null;
    var keep_xcode: ?bool = null;
    for (args) |arg| {
        if (eq(arg, "-f") or eq(arg, "--force")) {
            opts.force = true;
        } else if (eq(arg, "-y") or eq(arg, "--yes")) {
            opts.yes = true;
        } else if (eq(arg, "--keep-derived-data")) {
            keep_derived_data = true;
        } else if (eq(arg, "--no-keep-derived-data")) {
            keep_derived_data = false;
        } else if (eq(arg, "--keep-branch")) {
            keep_branch = true;
        } else if (eq(arg, "--no-keep-branch")) {
            keep_branch = false;
        } else if (eq(arg, "--keep-xcode")) {
            keep_xcode = true;
        } else if (eq(arg, "--no-keep-xcode")) {
            keep_xcode = false;
        } else if (eq(arg, "--sessions")) {
            opts.sessions = true;
        } else if (eq(arg, "--merged")) {
            opts.merged = true;
        } else if (eq(arg, "--local")) {
            opts.local = true;
        } else return error.UnknownOption;
    }

    const cfg = try config.load(app.gpa, app.io, app.environ);
    opts.keep_derived_data = orConfig(keep_derived_data, cfg.keepDerivedData);
    opts.keep_branch = orConfig(keep_branch, cfg.keepBranch);
    opts.keep_xcode = orConfig(keep_xcode, cfg.keepXcode);
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

fn configCommand(app: app_mod.App, args: []const []const u8) !void {
    var opts: config_cmd.Opts = .{};
    for (args) |arg| {
        if (eq(arg, "--json")) {
            opts.json = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else if (opts.key == null) {
            opts.key = arg;
        } else if (opts.value == null) {
            // Everything after the setting is its value, whitespace and all —
            // `startTaskCommand` is a sentence, not a token.
            opts.value = arg;
        } else return error.TooManyArguments;
    }

    var machine = app;
    machine.ui.divert = opts.json;
    return config_cmd.run(machine, opts);
}

fn watchCommand(app: app_mod.App, args: []const []const u8) !void {
    var opts: watch_cmd.Opts = .{};
    var status_bar: ?bool = null;
    for (args) |arg| {
        if (eq(arg, "--json")) {
            opts.json = true;
        } else if (eq(arg, "--no-status-bar")) {
            status_bar = false;
        } else if (eq(arg, "--status-bar")) {
            status_bar = true;
        } else return error.UnknownOption;
    }

    const cfg = try config.load(app.gpa, app.io, app.environ);
    opts.status_bar = orConfig(status_bar, cfg.statusBar);

    // stdout belongs to the payload in machine mode, same as `start --json`.
    var machine = app;
    machine.ui.divert = opts.json;
    return watch_cmd.run(machine, opts);
}

fn watchHookCommand(app: app_mod.App, args: []const []const u8) !void {
    var opts: watch_cmd.HookOpts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eq(args[i], "--socket")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.socket = args[i];
        } else if (eq(args[i], "--event")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.event = args[i];
        } else return error.UnknownOption;
    }
    // Never fails. A Claude Code hook runs on every turn of every watched
    // session, and one that could report an error would be one that could
    // disturb the work it exists only to observe.
    watch_cmd.hook(app, opts) catch {};
}

fn daemonCommand(app: app_mod.App, args: []const []const u8) !void {
    var opts: daemon_cmd.Opts = .{};
    for (args) |arg| {
        if (eq(arg, "--foreground")) {
            opts.foreground = true;
        } else if (eq(arg, "--stop")) {
            opts.stop = true;
        } else if (eq(arg, "--force")) {
            opts.force = true;
        } else if (eq(arg, "--status")) {
            opts.status = true;
        } else if (eq(arg, "--json")) {
            opts.json = true;
        } else return error.UnknownOption;
    }

    var machine = app;
    machine.ui.divert = opts.json;
    return daemon_cmd.run(machine, opts);
}

/// A flag that may not have been given, resolved against what the file says.
///
/// Defaults live here rather than inside each command because this is the only
/// layer that can tell "not passed" from "passed false" — an `Opts` field is a
/// plain bool by the time a command sees it, which is what keeps the commands
/// and their many helpers free of tri-state.
fn orConfig(flag: ?bool, configured: bool) bool {
    return flag orelse configured;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test {
    // Zig only collects tests from files the root references during test
    // analysis, so name every module here or `zig build test` runs nothing.
    _ = @import("ansi.zig");
    _ = @import("app.zig");
    _ = @import("claude.zig");
    _ = @import("claude_projects.zig");
    _ = @import("config.zig");
    _ = @import("daemon.zig");
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
    _ = @import("pty.zig");
    _ = @import("release.zig");
    _ = @import("remote_cache.zig");
    _ = @import("repos.zig");
    _ = @import("ring.zig");
    _ = @import("semver.zig");
    _ = @import("sessions.zig");
    _ = @import("term.zig");
    _ = @import("ui.zig");
    _ = @import("usage.zig");
    _ = @import("usage_cache.zig");
    _ = @import("watch_attach.zig");
    _ = @import("watch_bar.zig");
    _ = @import("watch_client.zig");
    _ = @import("watch_hooks.zig");
    _ = @import("watch_paths.zig");
    _ = @import("watch_session.zig");
    _ = @import("watch_status.zig");
    _ = @import("watch_table.zig");
    _ = @import("wire.zig");
    _ = @import("xcode.zig");
    _ = @import("commands/config.zig");
    _ = @import("commands/daemon.zig");
    _ = @import("commands/issue.zig");
    _ = @import("commands/list.zig");
    _ = @import("commands/remove.zig");
    _ = @import("commands/setup.zig");
    _ = @import("commands/start.zig");
    _ = @import("commands/start_plan_test.zig");
    _ = @import("commands/stats.zig");
    _ = @import("commands/watch.zig");
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.NotAGitRepository => "Not inside a git repository. Run `lcc` from within your repo.",
        error.ClaudeNotFound => "Could not find `claude` on PATH. Install Claude Code: https://docs.claude.com/en/docs/claude-code",
        error.NotATerminal => "lcc needs an interactive terminal for this command.",
        error.UnknownCommand => "Unknown command. Run `lcc --help`.",
        error.UnknownOption => "Unknown option. Run `lcc --help`.",
        error.MissingOptionValue => "Missing value for option. Run `lcc --help`.",
        error.MissingClientId => "auth setup requires --client-id <id>.",
        error.MissingIssueSubcommand => "issue needs a subcommand: show, state, comment, project.",
        error.MissingProjectAction => "`lcc issue project` needs --assign <vX.Y.Z> or --resolve.",
        error.ConflictingProjectAction => "`lcc issue project` takes --assign or --resolve, not both.",
        error.MissingIssueIdentifier => "issue needs an identifier, e.g. `lcc issue show PE-42`.",
        error.MissingStateName => "`lcc issue state` needs a state name, e.g. `lcc issue state PE-42 \"In Progress\"`.",
        error.ConflictingCommentSource => "`lcc issue comment` takes -m or -f, not both.",
        error.MissingCommentBody => "`lcc issue comment` needs -m <text> or -f <file>.",
        error.InvalidConfig => "Configuration is invalid. Fix ~/.config/lcc/config.json.",
        error.TooManyArguments => "Too many arguments. Run `lcc --help`.",
        error.NoHomeDirectory => "HOME is not set.",
        else => @errorName(err),
    };
}
