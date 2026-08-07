const std = @import("std");
const app_mod = @import("../app.zig");
const config = @import("../config.zig");
const exec = @import("../exec.zig");
const linear = @import("../linear.zig");
const oauth = @import("../oauth.zig");
const ui = @import("../ui.zig");

pub const Opts = struct {
    logout: bool = false,
    status: bool = false,
    token: ?[]const u8 = null,
};

pub fn run(app: app_mod.App, opts: Opts) !void {
    if (opts.logout) {
        oauth.clearToken();
        app.ui.success("Logged out (token removed from keychain).", .{});
        return;
    }
    if (opts.token) |pat| return withPersonalToken(app, pat);
    if (opts.status) return status(app);
    return login(app);
}

pub fn setup(app: app_mod.App, client_id: []const u8) !void {
    try config.save(app.gpa, app.io, app.environ, .{ .clientId = client_id });
    const where = try config.path(app.gpa, app.environ);
    app.ui.success("Saved client_id to {s}", .{where});
    app.ui.hint(
        "In your Linear OAuth application (linear.app/settings/api/applications),\n" ++
            "  make sure the redirect URI is set to:\n" ++
            "    {s}",
        .{config.redirect_uri},
    );
    app.ui.hint("Next: run `lcc auth` to authorize.", .{});
}

fn login(app: app_mod.App) !void {
    const cfg = try config.load(app.gpa, app.io, app.environ);
    const pkce = try oauth.generatePkce(app.gpa, app.io);
    const state = try oauth.generateState(app.gpa, app.io);
    const url = try oauth.buildAuthorizeUrl(app.gpa, cfg.clientId, state, pkce.challenge);

    app.ui.step("Opening browser to authorize lcc with Linear...", .{});
    app.ui.hint("If the browser doesn't open, visit:\n  {s}", .{url});
    app.ui.flush();

    _ = exec.run(app.gpa, app.io, &.{ "open", url }, null) catch null;

    const callback = oauth.awaitCallback(app.gpa, app.io, state) catch |err| {
        return reportAuthError(app, err);
    };

    const token = oauth.exchangeCode(app.gpa, app.io, cfg.clientId, callback.code, pkce.verifier) catch |err| {
        return reportAuthError(app, err);
    };
    try oauth.setToken(app.gpa, token);

    const me = linear.viewer(app.gpa, app.io, token) catch {
        app.ui.success("Authenticated. (Could not read your profile: {s})", .{linear.last_message});
        return;
    };
    app.ui.success("Authenticated as {f} {f}", .{
        ui.bold(me.name),
        ui.dim(try std.fmt.allocPrint(app.gpa, "<{s}>", .{me.email})),
    });
    if (token.expires_at) |at| {
        app.ui.hint("Access token valid until {s} (auto-refreshes).", .{try formatTime(app.gpa, at)});
    }
}

fn withPersonalToken(app: app_mod.App, pat: []const u8) !void {
    const token: oauth.Token = .{ .access_token = pat, .is_pat = true };
    try oauth.setToken(app.gpa, token);

    const me = linear.viewer(app.gpa, app.io, token) catch {
        oauth.clearToken();
        app.ui.fail("Token validation failed: {s}", .{linear.last_message});
        std.process.exit(1);
    };
    app.ui.success("Stored personal API token. Authenticated as {f}.", .{ui.bold(me.name)});
}

fn status(app: app_mod.App) !void {
    const stored = oauth.getToken(app.gpa) orelse {
        app.ui.warn("Not authenticated. Run `lcc auth`.", .{});
        return;
    };
    const cfg = try config.load(app.gpa, app.io, app.environ);

    const token = oauth.ensureFreshToken(app.gpa, app.io, cfg.clientId) catch |err| {
        return reportAuthError(app, err);
    };

    const me = linear.viewer(app.gpa, app.io, token) catch {
        app.ui.fail("Could not reach Linear: {s}", .{linear.last_message});
        std.process.exit(1);
    };
    app.ui.success("Authenticated as {f} {f}", .{
        ui.bold(me.name),
        ui.dim(try std.fmt.allocPrint(app.gpa, "<{s}>", .{me.email})),
    });

    if (stored.is_pat orelse false) {
        app.ui.hint("Using personal API token (no expiry, no refresh).", .{});
        return;
    }
    app.ui.hint("Scopes: {s}", .{token.scope orelse "(unknown)"});
    if (token.expires_at) |at| {
        app.ui.hint("Expires: {s}", .{try formatTime(app.gpa, at)});
    }
}

fn reportAuthError(app: app_mod.App, err: anyerror) noreturn {
    const detail = oauth.last_detail;
    switch (err) {
        error.PortInUse => app.ui.fail(
            "Port {d} is already in use. Another lcc auth flow may be running — close it and retry.",
            .{config.redirect_port},
        ),
        error.StateMismatch => app.ui.fail("OAuth state mismatch (possible CSRF)", .{}),
        error.CallbackTimedOut => app.ui.fail("Timed out waiting for browser authorization", .{}),
        error.AuthorizationDenied => app.ui.fail("Linear returned error: {s}", .{detail}),
        error.NotAuthenticated => app.ui.fail("Not authenticated. Run `lcc auth` first.", .{}),
        error.TokenExpiredNoRefresh => app.ui.fail(
            "Access token expired and no refresh token available. Run `lcc auth` again.",
            .{},
        ),
        error.TokenEndpointFailed => app.ui.fail("Token endpoint failed: {s}", .{detail}),
        else => app.ui.fail("{s}{s}{s}", .{
            @errorName(err),
            if (detail.len > 0) ": " else "",
            detail,
        }),
    }
    std.process.exit(1);
}

const c = @cImport({
    @cInclude("time.h");
});

fn formatTime(gpa: std.mem.Allocator, unix_seconds: i64) ![]u8 {
    var t: c.time_t = @intCast(unix_seconds);
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&t, &tm) == null) {
        return std.fmt.allocPrint(gpa, "{d}", .{unix_seconds});
    }
    var buf: [64]u8 = undefined;
    const n = c.strftime(&buf, buf.len, "%Y-%m-%d %H:%M:%S", &tm);
    if (n == 0) return std.fmt.allocPrint(gpa, "{d}", .{unix_seconds});
    return gpa.dupe(u8, buf[0..n]);
}
