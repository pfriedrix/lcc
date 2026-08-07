const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const daemon = @import("../daemon.zig");
const sessions = @import("../sessions.zig");
const watch_paths = @import("../watch_paths.zig");
const wire = @import("../wire.zig");

pub const Opts = struct {
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
