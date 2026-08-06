//! `lcc daemon` — run the session daemon, stop it, or ask what it is doing.
//!
//! Named explicitly rather than left implicit. `lcc start --watch` starts one
//! on demand, but a background process a user cannot see, inspect or stop is
//! not something to acquire by accident.

const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const daemon = @import("../daemon.zig");
const sessions = @import("../sessions.zig");
const ui = @import("../ui.zig");
const watch_client = @import("../watch_client.zig");
const watch_paths = @import("../watch_paths.zig");
const wire = @import("../wire.zig");

pub const Opts = struct {
    /// Stay attached to this terminal instead of detaching.
    foreground: bool = false,
    stop: bool = false,
    /// SIGKILL the sessions rather than asking them to finish.
    force: bool = false,
    status: bool = false,
    json: bool = false,
};

pub fn run(app: app_mod.App, opts: Opts) !void {
    if (opts.status) return status(app, opts);
    if (opts.stop) return stop(app, opts);
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

fn stop(app: app_mod.App, opts: Opts) !void {
    var conn = (watch_client.connectExisting(app, .control) catch null) orelse {
        app.ui.info("No daemon running.", .{});
        return;
    };
    defer conn.close(app.io);

    try conn.sendControl(app.gpa, .stop, wire.Stop{ .force = opts.force });
    if (opts.force) {
        app.ui.success("Asked the daemon to stop and kill its sessions.", .{});
    } else {
        app.ui.success("Asked the daemon to stop.", .{});
    }
}
