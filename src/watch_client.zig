const std = @import("std");
const Io = std.Io;
const app_mod = @import("app.zig");
const exec = @import("exec.zig");
const sessions_mod = @import("sessions.zig");
const watch_paths = @import("watch_paths.zig");
const wire = @import("wire.zig");

pub const Error = error{
    DaemonUnreachable,
    NotRunning,
    ProtocolMismatch,
    Refused,
    BadResponse,
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

pub fn connectExisting(app: app_mod.App, role: wire.Role) Error!?Conn {
    return connectAt(app, role, try watch_paths.socket(app.gpa, app.environ));
}

pub fn connectAt(app: app_mod.App, role: wire.Role, socket_path: []const u8) Error!?Conn {
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

pub fn connect(app: app_mod.App, role: wire.Role) Error!Conn {
    if (try connectExisting(app, role)) |conn| return conn;

    const exe = exec.selfPath(app.gpa, app.io) catch return Error.DaemonUnreachable;
    const log_path = try watch_paths.logFile(app.gpa, app.environ);
    if (std.fs.path.dirname(log_path)) |parent| {
        Io.Dir.cwd().createDirPath(app.io, parent) catch {};
    }
    exec.detached(app.io, &.{ exe, "daemon" }, log_path) catch return Error.DaemonUnreachable;

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

pub fn snapshot(app: app_mod.App) Error!?[]const sessions_mod.Session {
    var conn = (try connectExisting(app, .control)) orelse return null;
    defer conn.close(app.io);

    try conn.sendControl(app.gpa, .list, .{});
    const frame = try conn.recv();
    if (frame.type != .snapshot) return Error.BadResponse;
    const body = wire.parse(wire.Snapshot, app.gpa, frame) catch return Error.BadResponse;
    return body.sessions;
}

pub fn report(
    app: app_mod.App,
    socket: ?[]const u8,
    cwd: []const u8,
    session_id: []const u8,
    event: []const u8,
    permission_mode: []const u8,
    session: []const u8,
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
        .session = session,
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
