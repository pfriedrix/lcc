//! `lcc daemon` — run the session daemon, or ask what it is doing.
//!
//! **Not in `usage`, and not for users.** `watch_client` re-execs this to bring
//! the session host up; `--foreground` and `--status` exist for whoever is
//! debugging that. Someone running `lcc` has sessions, not a daemon, and every
//! sentence they read says so.
//!
//! What they do need — seeing the sessions and ending all of them — is
//! `lcc open` and `lcc open --stop-all`. Both live in `commands/watch.zig`, so
//! the visible vocabulary and the plumbing stay separable.

const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const daemon = @import("../daemon.zig");
const sessions = @import("../sessions.zig");
const watch_paths = @import("../watch_paths.zig");
const wire = @import("../wire.zig");

pub const Opts = struct {
    /// Stay attached to this terminal instead of detaching.
    foreground: bool = false,
    status: bool = false,
    json: bool = false,
};

pub fn run(app: app_mod.App, opts: Opts) !void {
    if (opts.status) return status(app, opts);
    return daemon.run(app, .{ .foreground = opts.foreground });
}

fn status(app: app_mod.App, opts: Opts) !void {
    const state = sessions.load(app.gpa, app.io, app.environ);
    const running = sessions.alive(state);
    const socket_path = watch_paths.socket(app.gpa, app.environ) catch "";

    if (opts.json) {
        const body = try std.json.Stringify.valueAlloc(app.gpa, .{
            .running = running,
            .pid = if (state.daemon) |d| d.pid else null,
            .socket = socket_path,
            .protocol = wire.protocol,
            .sessions = state.sessions.len,
        }, .{ .whitespace = .indent_2 });
        app.ui.payload("{s}\n", .{body});
        app.ui.flush();
        return;
    }

    if (!running) {
        app.ui.info("No daemon running.", .{});
        // The breadcrumb case: a daemon that died leaves pids behind, and they
        // are the only record that anything was running.
        if (state.sessions.len > 0) {
            app.ui.warn(
                "{d} session(s) were recorded before it stopped — their agents may still be running.",
                .{state.sessions.len},
            );
        }
        return;
    }

    app.ui.success("Daemon running (pid {d}), {d} session(s).", .{
        if (state.daemon) |d| d.pid else 0,
        state.sessions.len,
    });
    app.ui.hint("Socket: {s}", .{socket_path});
}
