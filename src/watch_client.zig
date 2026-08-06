//! The client half: find the daemon, start one when there is none, and speak
//! the protocol.
//!
//! The client never touches the daemon's lock. Its only probe is `connect`,
//! with a short backoff, and a wasted daemon spawn costs a few milliseconds.
//! Probing the lock instead would introduce two races — a client holding it
//! while a daemon starts, and the handoff between them — to save nothing.

const std = @import("std");
const Io = std.Io;
const app_mod = @import("app.zig");
const exec = @import("exec.zig");
const sessions_mod = @import("sessions.zig");
const watch_paths = @import("watch_paths.zig");
const wire = @import("wire.zig");

pub const Error = error{
    /// Nothing is listening, and starting one did not help.
    DaemonUnreachable,
    /// Nothing is listening and we were told not to start one.
    NotRunning,
    ProtocolMismatch,
    Refused,
    BadResponse,
    // A daemon that framed something wrong is not a case any caller can act on
    // differently from a daemon that answered nothing, but the distinction is
    // worth keeping in the message rather than collapsing at the boundary.
} || wire.Error || watch_paths.Error || std.mem.Allocator.Error;

pub const Conn = struct {
    io: Io,
    stream: Io.net.Stream,
    buf: []u8,
    dec: wire.Decoder,

    pub fn close(self: *Conn, io: Io) void {
        self.stream.close(io);
    }

    pub fn send(self: *Conn, gpa: std.mem.Allocator, t: wire.Type, payload: []const u8) !void {
        const header = wire.encodeHeader(t, @intCast(payload.len));
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try out.appendSlice(gpa, &header);
        try out.appendSlice(gpa, payload);
        try writeAll(self.stream.socket.handle, out.items);
    }

    pub fn sendControl(self: *Conn, gpa: std.mem.Allocator, t: wire.Type, value: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(gpa, value, .{});
        defer gpa.free(body);
        try self.send(gpa, t, body);
    }

    /// Blocking. Only ever used on the one-shot request/response paths — the
    /// interactive loops poll and decode for themselves.
    pub fn recv(self: *Conn) !wire.Frame {
        while (true) {
            if (try self.dec.next()) |frame| return frame;
            const room = self.dec.writable();
            if (room.len == 0) return Error.BadResponse;
            const n = std.c.read(self.stream.socket.handle, room.ptr, room.len);
            if (n > 0) {
                self.dec.commit(@intCast(n));
                continue;
            }
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            return Error.DaemonUnreachable;
        }
    }
};

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + sent, bytes.len - sent);
        if (n > 0) {
            sent += @intCast(n);
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        return Error.DaemonUnreachable;
    }
}

/// Connect to a daemon that is already running, or null.
///
/// Asked before connecting rather than after failing: std's
/// `UnixAddress.ConnectError` has no `ConnectionRefused`, so a stale socket
/// falls through to `error.Unexpected`, which prints a stack trace in a debug
/// build. `prompt.zig` documents the same shape for `tcgetattr` on a pipe —
/// ask first, do not make std report it.
pub fn connectExisting(app: app_mod.App, role: wire.Role) Error!?Conn {
    return connectAt(app, role, try watch_paths.socket(app.gpa, app.environ));
}

/// The same, against a socket the caller names rather than one derived from the
/// environment.
///
/// Exists for the hook handler, which is told its socket on the command line.
/// That path is the daemon's own, resolved when the daemon started, and it is
/// the only thing a hook can trust: a hook runs with the *session's*
/// environment, which is the environment of whichever shell started the
/// session, and an `LCC_WATCH_DIR` in there would point the report at a daemon
/// that does not exist. Same reasoning as the absolute `exe` beside it in
/// `watch_hooks.settingsJson`.
pub fn connectAt(app: app_mod.App, role: wire.Role, socket_path: []const u8) Error!?Conn {
    // std will not do this, and the path came off a command line rather than
    // out of `watch_paths.socket` — so this is the last place it can be an
    // error instead of a write past `sockaddr_un.path`.
    try watch_paths.checkSocketPath(socket_path);
    const info = Io.Dir.cwd().statFile(app.io, socket_path, .{}) catch return null;
    _ = info;

    const address = Io.net.UnixAddress.init(socket_path) catch return Error.SocketPathTooLong;
    const stream = address.connect(app.io) catch return null;

    const buf = try app.gpa.alloc(u8, wire.bufferLen());
    var conn: Conn = .{
        .io = app.io,
        .stream = stream,
        .buf = buf,
        .dec = wire.Decoder.init(buf, role) catch return Error.BadResponse,
    };

    conn.sendControl(app.gpa, .hello, wire.Hello{
        .role = @tagName(role),
        .pid = @intCast(std.c.getpid()),
    }) catch return null;

    const frame = conn.recv() catch return null;
    if (frame.type == .err) return Error.ProtocolMismatch;
    if (frame.type != .hello) return Error.BadResponse;
    return conn;
}

/// Connect, starting a daemon if nothing answers.
///
/// Several `lcc start --watch` invocations may each spawn one; the lock inside
/// the daemon means all but one exit immediately.
pub fn connect(app: app_mod.App, role: wire.Role) Error!Conn {
    if (try connectExisting(app, role)) |conn| return conn;

    const exe = exec.selfPath(app.gpa, app.io) catch return Error.DaemonUnreachable;
    const log_path = try watch_paths.logFile(app.gpa, app.environ);
    if (std.fs.path.dirname(log_path)) |parent| {
        Io.Dir.cwd().createDirPath(app.io, parent) catch {};
    }
    exec.detached(app.io, &.{ exe, "daemon" }, log_path) catch return Error.DaemonUnreachable;

    // 50, 100, 200, 400, 800 ms. A daemon that has not answered by then is not
    // starting, and looping silently would hide a lock held by a daemon whose
    // socket someone deleted.
    var delay_ms: u64 = 50;
    for (0..5) |_| {
        std.Io.Timestamp.now(app.io, .awake).addDuration(.fromMilliseconds(@intCast(delay_ms)))
            .withClock(.awake).wait(app.io) catch {};
        if (try connectExisting(app, role)) |conn| return conn;
        delay_ms *= 2;
    }
    return Error.DaemonUnreachable;
}

pub const Started = struct {
    id: []const u8,
    pid: i32,
    status: []const u8,
    started_at: i64,
};

pub const Handoff = struct {
    worktree: []const u8,
    branch: []const u8,
    issue: ?[]const u8,
    repo_root: []const u8,
    program: []const u8,
    argv: []const []const u8,
    size: struct { rows: u16, cols: u16 } = .{ .rows = 40, .cols = 120 },
};

/// The whole `--watch` branch of `lcc start`, so `start.zig` gains one import
/// and one `if`.
pub fn startSession(app: app_mod.App, handoff: Handoff) Error!Started {
    var conn = try connect(app, .control);
    defer conn.close(app.io);

    try conn.sendControl(app.gpa, .register, wire.Register{
        .worktree = handoff.worktree,
        .branch = handoff.branch,
        .issue = handoff.issue,
        .repo_root = handoff.repo_root,
        .program = handoff.program,
        .argv = handoff.argv,
        // The client's environment, never the daemon's: a daemon started days
        // ago by another shell would otherwise hand this session that shell's
        // PATH and every variable Claude Code reads.
        .env = try environSlice(app),
        .cols = handoff.size.cols,
        .rows = handoff.size.rows,
    });

    const frame = try conn.recv();
    if (frame.type == .err) {
        const body = wire.parse(wire.ErrorBody, app.gpa, frame) catch return Error.Refused;
        app.ui.fail("{s}", .{body.message});
        return Error.Refused;
    }
    if (frame.type != .registered) return Error.BadResponse;
    const body = wire.parse(wire.Registered, app.gpa, frame) catch return Error.BadResponse;
    return .{
        .id = body.session_id,
        .pid = body.pid,
        .status = body.status,
        .started_at = body.started_at,
    };
}

/// A snapshot from the daemon, or null when none is running.
///
/// Null rather than an error: no daemon is a legitimate answer — it means no
/// sessions — and every caller has to render that anyway.
pub fn snapshot(app: app_mod.App) Error!?[]const sessions_mod.Session {
    var conn = (try connectExisting(app, .control)) orelse return null;
    defer conn.close(app.io);

    try conn.sendControl(app.gpa, .list, .{});
    const frame = try conn.recv();
    if (frame.type != .snapshot) return Error.BadResponse;
    const body = wire.parse(wire.Snapshot, app.gpa, frame) catch return Error.BadResponse;
    return body.sessions;
}

/// The hook path: one connect, one frame, exit.
///
/// Never starts a daemon. A hook fires on every turn of every session lcc
/// launched, and one that could spawn a process would turn a stopped daemon
/// into a spawn storm.
///
/// `socket` is the path the daemon baked into the hook's command line. Null
/// falls back to the environment, which is what a hand-run `lcc watch-hook`
/// with no `--socket` gets.
pub fn report(
    app: app_mod.App,
    socket: ?[]const u8,
    cwd: []const u8,
    session_id: []const u8,
    event: []const u8,
    permission_mode: []const u8,
) void {
    const opened = if (socket) |path|
        connectAt(app, .control, path)
    else
        connectExisting(app, .control);
    var conn = (opened catch return) orelse return;
    defer conn.close(app.io);
    conn.sendControl(app.gpa, .hook, wire.Hook{
        .cwd = cwd,
        .session_id = session_id,
        .event = event,
        .permission_mode = permission_mode,
    }) catch {};
}

fn environSlice(app: app_mod.App) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = app.environ.iterator();
    while (it.next()) |entry| {
        try out.append(app.gpa, try std.fmt.allocPrint(app.gpa, "{s}={s}", .{
            entry.key_ptr.*, entry.value_ptr.*,
        }));
    }
    return out.toOwnedSlice(app.gpa);
}
