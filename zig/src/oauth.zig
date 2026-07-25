//! Linear OAuth 2.0 with PKCE — browser flow, local callback, token refresh.

const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const keychain = @import("keychain.zig");

pub const service = "lcc";
pub const account = "linear-token";

pub const Token = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_at: ?i64 = null,
    scope: ?[]const u8 = null,
    token_type: ?[]const u8 = null,
    is_pat: ?bool = null,
};

pub const Error = error{
    NotAuthenticated,
    TokenExpiredNoRefresh,
    TokenEndpointFailed,
    CallbackFailed,
    StateMismatch,
    PortInUse,
    AuthorizationDenied,
    CallbackTimedOut,
} || std.mem.Allocator.Error;

/// How long to hold the callback port open before giving up on the browser.
pub const callback_timeout_ms: i64 = 5 * 60 * 1000;

/// Detail for the last failure, for messages worth reading.
pub var last_detail: []const u8 = "";

pub fn nowSeconds(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

fn nowMillis(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .awake);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

/// Blocks until the socket has a connection waiting, or `deadline` passes.
fn waitReadable(io: Io, handle: std.posix.fd_t, deadline: i64) Error!void {
    while (true) {
        const remaining = deadline - nowMillis(io);
        if (remaining <= 0) return Error.CallbackTimedOut;

        var fds = [_]std.posix.pollfd{.{
            .fd = handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, @intCast(@min(remaining, std.math.maxInt(i32)))) catch |err| {
            last_detail = @errorName(err);
            return Error.CallbackFailed;
        };
        if (ready > 0) return;
        // Zero means the poll timed out; loop so a signal-interrupted wait
        // still honours the full deadline.
    }
}

fn base64url(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const buf = try gpa.alloc(u8, encoder.calcSize(raw.len));
    _ = encoder.encode(buf, raw);
    return buf;
}

pub const Pkce = struct {
    verifier: []const u8,
    challenge: []const u8,
};

pub fn generatePkce(gpa: std.mem.Allocator, io: Io) !Pkce {
    var raw: [32]u8 = undefined;
    try io.randomSecure(&raw);
    const verifier = try base64url(gpa, &raw);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const challenge = try base64url(gpa, &digest);

    return .{ .verifier = verifier, .challenge = challenge };
}

pub fn generateState(gpa: std.mem.Allocator, io: Io) ![]u8 {
    var raw: [16]u8 = undefined;
    try io.randomSecure(&raw);
    return base64url(gpa, &raw);
}

/// Percent-encodes everything outside the RFC 3986 unreserved set, which is
/// what `URLSearchParams` effectively does for these values.
fn encodeQueryComponent(w: *Io.Writer, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try w.writeByte(c),
            else => try w.print("%{X:0>2}", .{c}),
        }
    }
}

pub fn buildAuthorizeUrl(
    gpa: std.mem.Allocator,
    client_id: []const u8,
    state: []const u8,
    challenge: []const u8,
) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;

    try w.writeAll(config.authorize_url);
    const params = [_][2][]const u8{
        .{ "client_id", client_id },
        .{ "redirect_uri", config.redirect_uri },
        .{ "response_type", "code" },
        .{ "scope", config.default_scopes },
        .{ "state", state },
        .{ "code_challenge", challenge },
        .{ "code_challenge_method", "S256" },
        .{ "prompt", "consent" },
    };
    for (params, 0..) |param, i| {
        try w.writeByte(if (i == 0) '?' else '&');
        try w.writeAll(param[0]);
        try w.writeByte('=');
        try encodeQueryComponent(w, param[1]);
    }
    return out.toOwnedSlice();
}

const success_html =
    \\<!doctype html><html><head><meta charset="utf-8"><title>lcc</title>
    \\<style>body{font-family:-apple-system,system-ui,sans-serif;background:#0a0a0a;color:#eee;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
    \\.box{text-align:center;padding:2rem 3rem;border:1px solid #2a2a2a;border-radius:12px;background:#111}
    \\h1{margin:0 0 .5rem;font-size:1.4rem}p{margin:0;color:#999;font-size:.95rem}</style></head>
    \\<body><div class="box"><h1>✓ Authentication successful</h1><p>You can return to your terminal.</p></div></body></html>
;

fn errorHtml(gpa: std.mem.Allocator, message: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\<!doctype html><html><head><meta charset="utf-8"><title>lcc</title>
        \\<style>body{{font-family:-apple-system,system-ui,sans-serif;background:#0a0a0a;color:#eee;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}}
        \\.box{{text-align:center;padding:2rem 3rem;border:1px solid #4a1a1a;border-radius:12px;background:#1a0a0a}}
        \\h1{{margin:0 0 .5rem;font-size:1.4rem;color:#ff6b6b}}p{{margin:0;color:#bbb;font-size:.95rem}}</style></head>
        \\<body><div class="box"><h1>Authentication failed</h1><p>{s}</p></div></body></html>
    , .{message});
}

/// Percent-decodes in place semantics: returns a freshly allocated string.
fn decodeComponent(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < value.len) {
        switch (value[i]) {
            '+' => {
                try out.append(gpa, ' ');
                i += 1;
            },
            '%' => {
                if (i + 2 < value.len) {
                    const hi = std.fmt.charToDigit(value[i + 1], 16) catch {
                        try out.append(gpa, value[i]);
                        i += 1;
                        continue;
                    };
                    const lo = std.fmt.charToDigit(value[i + 2], 16) catch {
                        try out.append(gpa, value[i]);
                        i += 1;
                        continue;
                    };
                    try out.append(gpa, hi * 16 + lo);
                    i += 3;
                } else {
                    try out.append(gpa, value[i]);
                    i += 1;
                }
            },
            else => {
                try out.append(gpa, value[i]);
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

fn queryParam(gpa: std.mem.Allocator, target: []const u8, key: []const u8) !?[]u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        return try decodeComponent(gpa, pair[eq + 1 ..]);
    }
    return null;
}

fn pathOf(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    return target[0..q];
}

pub const Callback = struct {
    code: []const u8,
    state: []const u8,
};

/// Serves 127.0.0.1:39126 until Linear redirects the browser back to it.
/// Requests for anything but the callback path get a 404 and are ignored, so a
/// stray favicon fetch cannot end the flow.
pub fn awaitCallback(gpa: std.mem.Allocator, io: Io, expected_state: []const u8) Error!Callback {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(config.redirect_port) };
    var server = address.listen(io, .{ .reuse_address = true }) catch |err| {
        if (err == error.AddressInUse) return Error.PortInUse;
        last_detail = @errorName(err);
        return Error.CallbackFailed;
    };
    defer server.deinit(io);

    const deadline = nowMillis(io) + callback_timeout_ms;

    while (true) {
        // Bound the wait, so an abandoned browser tab does not leave lcc
        // holding the port forever.
        try waitReadable(io, server.socket.handle, deadline);

        var stream = server.accept(io) catch |err| {
            last_detail = @errorName(err);
            return Error.CallbackFailed;
        };
        defer stream.close(io);

        var recv_buf: [16 * 1024]u8 = undefined;
        var send_buf: [8 * 1024]u8 = undefined;
        var reader = stream.reader(io, &recv_buf);
        var writer = stream.writer(io, &send_buf);

        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = http_server.receiveHead() catch continue;

        const target = request.head.target;
        if (!std.mem.eql(u8, pathOf(target), "/oauth/callback")) {
            request.respond("", .{ .status = .not_found }) catch {};
            continue;
        }

        const err_param = queryParam(gpa, target, "error") catch null;
        if (err_param) |e| {
            const desc = (queryParam(gpa, target, "error_description") catch null) orelse e;
            const body = errorHtml(gpa, desc) catch "";
            request.respond(body, .{
                .status = .bad_request,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
            }) catch {};
            last_detail = desc;
            return Error.AuthorizationDenied;
        }

        const code = (queryParam(gpa, target, "code") catch null) orelse {
            const body = errorHtml(gpa, "Missing code or state.") catch "";
            request.respond(body, .{
                .status = .bad_request,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
            }) catch {};
            last_detail = "callback missing code parameter";
            return Error.CallbackFailed;
        };
        const state = (queryParam(gpa, target, "state") catch null) orelse {
            const body = errorHtml(gpa, "Missing code or state.") catch "";
            request.respond(body, .{
                .status = .bad_request,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
            }) catch {};
            last_detail = "callback missing state parameter";
            return Error.CallbackFailed;
        };

        if (!std.mem.eql(u8, state, expected_state)) {
            const body = errorHtml(gpa, "State mismatch — possible CSRF.") catch "";
            request.respond(body, .{
                .status = .bad_request,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
            }) catch {};
            return Error.StateMismatch;
        }

        request.respond(success_html, .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        }) catch {};
        return .{ .code = code, .state = state };
    }
}

const TokenResponse = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_in: ?i64 = null,
    scope: ?[]const u8 = null,
    token_type: ?[]const u8 = null,
};

fn postToken(gpa: std.mem.Allocator, io: Io, fields: []const [2][]const u8) Error!Token {
    var body: Io.Writer.Allocating = .init(gpa);
    for (fields, 0..) |field, i| {
        if (i > 0) body.writer.writeByte('&') catch return Error.TokenEndpointFailed;
        body.writer.writeAll(field[0]) catch return Error.TokenEndpointFailed;
        body.writer.writeByte('=') catch return Error.TokenEndpointFailed;
        encodeQueryComponent(&body.writer, field[1]) catch return Error.TokenEndpointFailed;
    }

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var response: Io.Writer.Allocating = .init(gpa);
    const res = client.fetch(.{
        .location = .{ .url = config.token_url },
        .method = .POST,
        .payload = body.written(),
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .user_agent = .{ .override = "lcc/0.1.0" },
        },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
        .response_writer = &response.writer,
    }) catch |err| {
        last_detail = @errorName(err);
        return Error.TokenEndpointFailed;
    };

    const raw = response.written();
    const status = @intFromEnum(res.status);
    if (status < 200 or status >= 300) {
        last_detail = gpa.dupe(u8, raw[0..@min(raw.len, 300)]) catch "";
        return Error.TokenEndpointFailed;
    }

    const parsed = std.json.parseFromSliceLeaky(TokenResponse, gpa, raw, .{
        .ignore_unknown_fields = true,
    }) catch {
        last_detail = gpa.dupe(u8, raw[0..@min(raw.len, 300)]) catch "";
        return Error.TokenEndpointFailed;
    };

    return .{
        .access_token = parsed.access_token,
        .refresh_token = parsed.refresh_token,
        // Same minute of slack as the TypeScript version, so a token is never
        // used in the last seconds of its life.
        .expires_at = if (parsed.expires_in) |secs| nowSeconds(io) + secs - 60 else null,
        .scope = parsed.scope,
        .token_type = parsed.token_type,
    };
}

pub fn exchangeCode(
    gpa: std.mem.Allocator,
    io: Io,
    client_id: []const u8,
    code: []const u8,
    verifier: []const u8,
) Error!Token {
    return postToken(gpa, io, &.{
        .{ "grant_type", "authorization_code" },
        .{ "code", code },
        .{ "redirect_uri", config.redirect_uri },
        .{ "client_id", client_id },
        .{ "code_verifier", verifier },
    });
}

pub fn refreshAccessToken(
    gpa: std.mem.Allocator,
    io: Io,
    client_id: []const u8,
    refresh_token: []const u8,
) Error!Token {
    var token = try postToken(gpa, io, &.{
        .{ "grant_type", "refresh_token" },
        .{ "refresh_token", refresh_token },
        .{ "client_id", client_id },
    });
    // Linear may omit refresh_token on refresh; preserve previous value
    if (token.refresh_token == null) token.refresh_token = refresh_token;
    return token;
}

pub fn getToken(gpa: std.mem.Allocator) ?Token {
    const raw = keychain.get(gpa, service, account) catch return null;
    const value = raw orelse return null;
    return std.json.parseFromSliceLeaky(Token, gpa, value, .{
        .ignore_unknown_fields = true,
    }) catch null;
}

pub fn setToken(gpa: std.mem.Allocator, token: Token) !void {
    const raw = try std.json.Stringify.valueAlloc(gpa, token, .{
        .emit_null_optional_fields = false,
    });
    defer gpa.free(raw);
    try keychain.set(service, account, raw);
}

pub fn clearToken() void {
    keychain.delete(service, account) catch {};
}

/// Returns a usable token, refreshing it first when it has expired.
pub fn ensureFreshToken(gpa: std.mem.Allocator, io: Io, client_id: []const u8) Error!Token {
    const token = getToken(gpa) orelse return Error.NotAuthenticated;
    if (token.is_pat orelse false) return token;

    const expired = if (token.expires_at) |at| at <= nowSeconds(io) else false;
    if (!expired) return token;

    const refresh = token.refresh_token orelse return Error.TokenExpiredNoRefresh;
    const refreshed = try refreshAccessToken(gpa, io, client_id, refresh);
    setToken(gpa, refreshed) catch {};
    return refreshed;
}
