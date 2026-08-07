const std = @import("std");
const Io = std.Io;
const app_mod = @import("app.zig");
const exec = @import("exec.zig");
const pty = @import("pty.zig");
const sessions_mod = @import("sessions.zig");
const watch_client = @import("watch_client.zig");
const watch_hooks = @import("watch_hooks.zig");
const watch_paths = @import("watch_paths.zig");
const watch_session = @import("watch_session.zig");
const wire = @import("wire.zig");

extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;

pub const Options = struct {
    foreground: bool = false,
    idle_exit_seconds: i64 = 30 * 60,
    max_sessions: u32 = 64,
    max_clients_per_session: u32 = 8,
    scrollback_bytes: usize = 256 * 1024,
};

pub const BindError = error{
    SocketPathOccupied,
} || watch_paths.Error || Io.File.OpenError || Io.net.UnixAddress.ListenError;

pub const Bound = struct {
    lock_file: Io.File,
    server: Io.net.Server,
    socket_path: []const u8,

    pub fn deinit(self: *Bound, io: Io) void {
        self.server.deinit(io);
        Io.Dir.cwd().deleteFile(io, self.socket_path) catch {};
        self.lock_file.unlock(io);
        self.lock_file.close(io);
    }
};

pub fn bind(app: app_mod.App, opts: Options) BindError!?Bound {
    _ = opts;
    const dir = try watch_paths.dir(app.gpa, app.environ);
    const socket_path = try watch_paths.socket(app.gpa, app.environ);
    const lock_path = try watch_paths.lock(app.gpa, app.environ);

    const cwd = Io.Dir.cwd();
    cwd.createDirPath(app.io, dir) catch {};

    if (app.gpa.dupeZ(u8, dir)) |dir_z| {
        _ = chmod(dir_z.ptr, 0o700);
    } else |_| {}

    const lock_file = try cwd.createFile(app.io, lock_path, .{ .truncate = false });
    errdefer lock_file.close(app.io);
    if (!try lock_file.tryLock(app.io, .exclusive)) {
        lock_file.close(app.io);
        return null;
    }

    cwd.deleteFile(app.io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return BindError.SocketPathOccupied,
    };

    const address = Io.net.UnixAddress.init(socket_path) catch return BindError.SocketPathTooLong;
    const server = try address.listen(app.io, .{});
    return .{ .lock_file = lock_file, .server = server, .socket_path = socket_path };
}

pub const Deadlines = struct {
    registry_flush_at: ?i64 = null,
    reap_retry_at: ?i64 = null,
    listener_resume_at: ?i64 = null,
    idle_exit_at: ?i64 = null,
    decay_at: ?i64 = null,
};

pub fn nextTimeout(now_ms: i64, d: Deadlines) i32 {
    var soonest: ?i64 = null;
    inline for (@typeInfo(Deadlines).@"struct".fields) |field| {
        if (@field(d, field.name)) |at| {
            if (soonest == null or at < soonest.?) soonest = at;
        }
    }
    const at = soonest orelse return -1;
    if (at <= now_ms) return 0;
    const delta = at - now_ms;
    return @intCast(@min(delta, std.math.maxInt(i32)));
}

var wake_write_fd: std.atomic.Value(i32) = .init(-1);

fn onChild(_: std.c.SIG) callconv(.c) void {
    const fd = wake_write_fd.load(.monotonic);
    if (fd < 0) return;
    const byte = [_]u8{0};
    _ = std.c.write(fd, &byte, 1);
}

const Client = struct {
    stream: Io.net.Stream,
    fd: std.posix.fd_t,
    role: wire.Role = .control,
    said_hello: bool = false,
    dec_buf: []u8,
    dec: wire.Decoder,
    out: std.ArrayList(u8) = .empty,
    attached: ?[]const u8 = null,
    cursor: u64 = 0,
    replay_until: u64 = 0,
    size: pty.Size = .{ .rows = 24, .cols = 80 },
    handshake_deadline: i64,
    dead: bool = false,

    fn wantsWrite(self: Client) bool {
        return self.out.items.len > 0;
    }
};

fn readFd(fd: std.posix.fd_t, buf: []u8) pty.Read {
    while (true) {
        const rc = std.c.read(fd, buf.ptr, buf.len);
        if (rc > 0) return .{ .n = @intCast(rc) };
        if (rc == 0) return .closed;
        switch (std.posix.errno(rc)) {
            .INTR => continue,
            .AGAIN => return .again,
            else => return .closed,
        }
    }
}

fn writeFd(fd: std.posix.fd_t, bytes: []const u8) pty.Write {
    while (true) {
        const rc = std.c.write(fd, bytes.ptr, bytes.len);
        if (rc >= 0) return .{ .n = @intCast(rc) };
        switch (std.posix.errno(rc)) {
            .INTR => continue,
            .AGAIN => return .again,
            else => return .closed,
        }
    }
}

fn setNonblocking(fd: std.posix.fd_t) void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    var o: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
    o.NONBLOCK = true;
    _ = std.c.fcntl(fd, std.posix.F.SETFL, @as(c_int, @bitCast(o)));
}

fn daemonize(app: app_mod.App) void {
    app.ui.flush();

    if (std.c.fork() != 0) std.c._exit(0);
    _ = std.c.setsid();
    if (std.c.fork() != 0) std.c._exit(0);

    const log_path = watch_paths.logFile(app.gpa, app.environ) catch return;
    if (std.fs.path.dirname(log_path)) |parent| {
        Io.Dir.cwd().createDirPath(app.io, parent) catch {};
    }
    const log = Io.Dir.cwd().createFile(app.io, log_path, .{ .truncate = false }) catch return;
    _ = std.c.dup2(log.handle, 1);
    _ = std.c.dup2(log.handle, 2);
}

const Loop = struct {
    app: app_mod.App,
    opts: Options,
    bound: *Bound,
    hooks_path: []const u8,
    list: std.ArrayList(watch_session.Session) = .empty,
    clients: std.ArrayList(Client) = .empty,
    wake_r: std.posix.fd_t,
    started_at: i64 = 0,
    next_id: u32 = 1,
    running: bool = true,
    dirty: bool = true,
    deadlines: Deadlines = .{},

    fn now(self: *Loop) i64 {
        return app_mod.nowSeconds(self.app.io);
    }

    fn find(self: *Loop, id: []const u8) ?*watch_session.Session {
        for (self.list.items) |*s| {
            if (std.mem.eql(u8, s.id, id)) return s;
        }
        return null;
    }

    fn findByWorktree(self: *Loop, cwd: []const u8) ?*watch_session.Session {
        for (self.list.items) |*s| {
            if (std.mem.eql(u8, s.worktree, cwd)) return s;
        }
        return null;
    }

    fn send(self: *Loop, client: *Client, t: wire.Type, payload: []const u8) void {
        const header = wire.encodeHeader(t, @intCast(payload.len));
        client.out.appendSlice(self.app.gpa, &header) catch {
            client.dead = true;
            return;
        };
        client.out.appendSlice(self.app.gpa, payload) catch {
            client.dead = true;
        };
    }

    fn sendControl(self: *Loop, client: *Client, t: wire.Type, value: anytype) void {
        const body = std.json.Stringify.valueAlloc(self.app.gpa, value, .{}) catch return;
        defer self.app.gpa.free(body);
        self.send(client, t, body);
    }

    fn fail(self: *Loop, client: *Client, code: []const u8, message: []const u8) void {
        self.sendControl(client, .err, wire.ErrorBody{ .code = code, .message = message });
    }

    fn announceExit(self: *Loop, session: *watch_session.Session) void {
        for (self.clients.items) |*c| {
            const id = c.attached orelse continue;
            if (!std.mem.eql(u8, id, session.id)) continue;
            self.sendControl(c, .exited, wire.Exited{
                .session_id = session.id,
                .exit_code = session.exitCode(),
                .signal = null,
            });
        }
    }

    fn reapAndAnnounce(self: *Loop, session: *watch_session.Session, at: i64) bool {
        if (session.exit != null) return false;
        if (!session.reap(at)) return false;
        self.announceExit(session);
        return true;
    }
};

pub fn run(app: app_mod.App, opts: Options) !void {
    _ = try watch_paths.socket(app.gpa, app.environ);

    if (!opts.foreground) daemonize(app);

    const ignore: std.posix.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]std.c.SIG{ .HUP, .INT, .QUIT, .TSTP, .TTIN, .TTOU }) |sig| {
        std.posix.sigaction(sig, &ignore, null);
    }

    var wake: [2]std.posix.fd_t = .{ -1, -1 };
    if (std.c.pipe(&wake) != 0) return error.SpawnFailed;
    setNonblocking(wake[0]);
    setNonblocking(wake[1]);
    _ = std.c.fcntl(wake[0], std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC));
    _ = std.c.fcntl(wake[1], std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC));
    wake_write_fd.store(wake[1], .monotonic);

    const on_child: std.posix.Sigaction = .{
        .handler = .{ .handler = onChild },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.CHLD, &on_child, null);

    if (std.posix.getrlimit(.NOFILE)) |limit| {
        var raised = limit;
        raised.cur = @min(limit.max, 4096);
        std.posix.setrlimit(.NOFILE, raised) catch {};
    } else |_| {}

    var bound = (try bind(app, opts)) orelse return;
    defer bound.deinit(app.io);

    var loop: Loop = .{
        .app = app,
        .opts = opts,
        .bound = &bound,
        .hooks_path = try writeHookSettings(app),
        .wake_r = wake[0],
        .started_at = app_mod.nowSeconds(app.io),
    };
    try serve(&loop);
}

fn writeHookSettings(app: app_mod.App) ![]const u8 {
    const exe = try exec.selfPath(app.gpa, app.io);
    const socket_path = try watch_paths.socket(app.gpa, app.environ);
    const body = try watch_hooks.settingsJson(app.gpa, exe, socket_path);
    const path = try watch_paths.hooks(app.gpa, app.environ);
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = body });
    return path;
}

fn serve(loop: *Loop) !void {
    const gpa = loop.app.gpa;
    var fds: std.ArrayList(std.posix.pollfd) = .empty;
    defer fds.deinit(gpa);

    var idle_since: ?i64 = loop.now();

    while (loop.running) {
        tick(loop, loop.now(), &idle_since);

        fds.clearRetainingCapacity();
        try fds.append(gpa, .{ .fd = loop.wake_r, .events = std.posix.POLL.IN, .revents = 0 });

        const listener_at = fds.items.len;
        const accepting = loop.list.items.len < loop.opts.max_sessions and
            loop.deadlines.listener_resume_at == null;
        if (accepting) {
            try fds.append(gpa, .{
                .fd = loop.bound.server.socket.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            });
        }

        const sessions_at = fds.items.len;
        const session_count = loop.list.items.len;
        for (loop.list.items) |*s| {
            var events: i16 = if (s.master_open) std.posix.POLL.IN else 0;
            if (s.wantsWrite()) events |= std.posix.POLL.OUT;
            try fds.append(gpa, .{ .fd = if (s.master_open) s.master else -1, .events = events, .revents = 0 });
        }

        const clients_at = fds.items.len;
        const client_count = loop.clients.items.len;
        for (loop.clients.items) |*c| {
            var events: i16 = std.posix.POLL.IN;
            if (c.wantsWrite()) events |= std.posix.POLL.OUT;
            try fds.append(gpa, .{ .fd = c.fd, .events = events, .revents = 0 });
        }

        const now_ms = loop.now() * std.time.ms_per_s;
        _ = std.posix.poll(fds.items, nextTimeout(now_ms, loop.deadlines)) catch {};

        const at = loop.now();

        if (fds.items[0].revents != 0) drainWake(loop);
        if (accepting and fds.items[listener_at].revents != 0) acceptClient(loop, at);

        for (0..session_count) |i| {
            const revents = fds.items[sessions_at + i].revents;
            if (revents == 0) continue;
            const s = &loop.list.items[i];
            if (revents & std.posix.POLL.OUT != 0) s.onWritable();
            if (revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
                if (s.onReadable(at)) {
                    if (loop.reapAndAnnounce(s, at)) loop.dirty = true;
                }
            }
        }

        for (0..client_count) |i| {
            const revents = fds.items[clients_at + i].revents;
            if (revents == 0) continue;
            if (revents & std.posix.POLL.OUT != 0) flushClient(loop, &loop.clients.items[i]);
            if (revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
                readClient(loop, &loop.clients.items[i], at);
            }
        }

        pump(loop);
        reapDead(loop);
    }

    flushRegistry(loop, loop.now());
}

fn drainWake(loop: *Loop) void {
    var buf: [256]u8 = undefined;
    while (readFd(loop.wake_r, &buf) == .n) {}
    const at = loop.now();
    for (loop.list.items) |*s| {
        if (loop.reapAndAnnounce(s, at)) loop.dirty = true;
    }
}

fn acceptClient(loop: *Loop, at: i64) void {
    const stream = loop.bound.server.accept(loop.app.io) catch |err| switch (err) {
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => {
            loop.deadlines.listener_resume_at = (loop.now() + 1) * std.time.ms_per_s;
            return;
        },
        else => return,
    };

    const buf = loop.app.gpa.alloc(u8, wire.bufferLen()) catch {
        stream.close(loop.app.io);
        return;
    };
    const dec = wire.Decoder.init(buf, .control) catch {
        stream.close(loop.app.io);
        return;
    };
    const fd = stream.socket.handle;
    setNonblocking(fd);

    loop.clients.append(loop.app.gpa, .{
        .stream = stream,
        .fd = fd,
        .dec_buf = buf,
        .dec = dec,
        .handshake_deadline = at + 5,
    }) catch stream.close(loop.app.io);
}

fn readClient(loop: *Loop, client: *Client, at: i64) void {
    while (true) {
        const room = client.dec.writable();
        if (room.len == 0) break;
        switch (readFd(client.fd, room)) {
            .n => |n| client.dec.commit(n),
            .again => break,
            .closed => {
                client.dead = true;
                return;
            },
        }
        while (client.dec.next() catch {
            client.dead = true;
            return;
        }) |frame| handleFrame(loop, client, frame, at);
        if (client.dead) return;
    }
}

fn handleFrame(loop: *Loop, client: *Client, frame: wire.Frame, at: i64) void {
    const gpa = loop.app.gpa;

    if (!client.said_hello) {
        if (frame.type != .hello) {
            loop.fail(client, "expected_hello", "The first frame must be a hello.");
            client.dead = true;
            return;
        }
        const hello = wire.parse(wire.Hello, gpa, frame) catch {
            client.dead = true;
            return;
        };
        if (hello.protocol != wire.protocol) {
            loop.fail(client, "protocol_mismatch", "This daemon speaks a different protocol version.");
            client.dead = true;
            return;
        }
        client.role = if (std.mem.eql(u8, hello.role, "attach")) .attach else .control;
        client.dec.role = client.role;
        client.said_hello = true;
        client.handshake_deadline = 0;
        loop.sendControl(client, .hello, wire.Hello{
            .role = @tagName(client.role),
            .pid = @intCast(std.c.getpid()),
        });
        return;
    }

    if (!wire.allowedOn(frame.type, client.role)) {
        loop.fail(client, "wrong_role", "That frame does not belong on this connection.");
        client.dead = true;
        return;
    }

    switch (frame.type) {
        .register => registerSession(loop, client, frame, at),
        .list => sendSnapshot(loop, client),
        .kill => {
            const body = wire.parse(wire.Kill, gpa, frame) catch return;
            if (loop.find(body.session_id)) |s| {
                s.stop(std.mem.eql(u8, body.signal, "KILL"));
            } else loop.fail(client, "unknown_session", "No such session.");
        },
        .stop => {
            const body = wire.parse(wire.Stop, gpa, frame) catch return;
            for (loop.list.items) |*s| s.stop(body.force);
            loop.running = false;
        },
        .hook => {
            const body = wire.parse(wire.Hook, gpa, frame) catch return;
            const event = watch_hooks.Event.parse(body.event) orelse return;
            const session = loop.findByWorktree(body.cwd) orelse return;
            if (session.note(event, body.permission_mode, at)) loop.dirty = true;
        },
        .attach => attachClient(loop, client, frame),
        .detach => detachClient(loop, client),
        .resize => {
            const body = wire.parse(wire.Resize, gpa, frame) catch return;
            client.size = .{ .rows = body.rows, .cols = body.cols };
            renegotiate(loop);
        },
        .input => {
            const id = client.attached orelse return;
            if (loop.find(id)) |s| s.queueInput(frame.payload);
        },
        else => {},
    }
}

fn registerSession(loop: *Loop, client: *Client, frame: wire.Frame, at: i64) void {
    const gpa = loop.app.gpa;
    const body = wire.parse(wire.Register, gpa, frame) catch {
        loop.fail(client, "bad_register", "Malformed register payload.");
        return;
    };
    if (loop.list.items.len >= loop.opts.max_sessions) {
        loop.fail(client, "session_limit", "Too many sessions.");
        return;
    }

    const id = std.fmt.allocPrint(gpa, "s-{x:0>8}", .{loop.next_id}) catch return;
    loop.next_id += 1;

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(gpa, &.{ "--settings", loop.hooks_path }) catch return;
    argv.appendSlice(gpa, body.argv) catch return;

    const session = watch_session.Session.start(gpa, .{
        .id = id,
        .worktree = body.worktree,
        .branch = body.branch,
        .issue = body.issue,
        .repo_root = body.repo_root,
    }, .{
        .program = body.program,
        .argv = argv.items,
        .env = body.env,
        .cwd = body.worktree,
        .size = .{ .rows = body.rows, .cols = body.cols },
    }, loop.opts.scrollback_bytes, at) catch {
        loop.fail(client, "spawn_failed", "Could not start a session.");
        return;
    };

    loop.list.append(gpa, session) catch return;
    loop.dirty = true;
    loop.sendControl(client, .registered, wire.Registered{
        .session_id = id,
        .pid = @intCast(session.pid),
        .status = @tagName(session.shown()),
        .started_at = session.started_at,
    });
}

fn sendSnapshot(loop: *Loop, client: *Client) void {
    const gpa = loop.app.gpa;
    var rows = gpa.alloc(sessions_mod.Session, loop.list.items.len) catch return;
    for (loop.list.items, 0..) |*s, i| rows[i] = s.entry();

    var truncated = false;
    while (rows.len > 0) {
        const body = std.json.Stringify.valueAlloc(gpa, wire.Snapshot{
            .daemon_pid = @intCast(std.c.getpid()),
            .protocol = wire.protocol,
            .sessions = rows,
            .truncated = truncated,
        }, .{}) catch return;
        if (body.len <= wire.max_payload) {
            loop.send(client, .snapshot, body);
            gpa.free(body);
            return;
        }
        gpa.free(body);
        rows = rows[0 .. rows.len / 2];
        truncated = true;
    }
}

fn attachClient(loop: *Loop, client: *Client, frame: wire.Frame) void {
    const gpa = loop.app.gpa;
    const body = wire.parse(wire.Attach, gpa, frame) catch return;
    const session = loop.find(body.session_id) orelse {
        loop.fail(client, "unknown_session", "No such session.");
        return;
    };

    client.attached = session.id;
    client.size = .{ .rows = body.rows, .cols = body.cols };
    client.cursor = if (body.replay) session.scrollback.oldest() else session.scrollback.written;
    client.replay_until = session.scrollback.written;

    var attached: u32 = 0;
    for (loop.clients.items) |*c| {
        if (c.attached) |id| {
            if (std.mem.eql(u8, id, session.id)) attached += 1;
        }
    }
    loop.sendControl(client, .attached, wire.Attached{
        .session_id = session.id,
        .cols = session.size.cols,
        .rows = session.size.rows,
        .input = true,
        .attached_clients = attached,
    });
    renegotiate(loop);
}

fn detachClient(loop: *Loop, client: *Client) void {
    client.attached = null;
    renegotiate(loop);
}

fn renegotiate(loop: *Loop) void {
    const gpa = loop.app.gpa;
    for (loop.list.items) |*s| {
        var sizes: std.ArrayList(pty.Size) = .empty;
        defer sizes.deinit(gpa);
        for (loop.clients.items) |*c| {
            const id = c.attached orelse continue;
            if (!std.mem.eql(u8, id, s.id)) continue;
            sizes.append(gpa, c.size) catch continue;
        }
        const size = watch_session.negotiateSize(sizes.items) orelse continue;
        if (size.rows == s.size.rows and size.cols == s.size.cols) continue;
        s.size = size;
        if (s.master_open) pty.resize(s.master, size);
    }
}

fn pump(loop: *Loop) void {
    for (loop.clients.items) |*c| {
        if (c.dead or c.out.items.len > 0) continue;
        const id = c.attached orelse continue;
        const session = loop.find(id) orelse continue;

        const clamped = session.scrollback.clamp(c.cursor);
        c.cursor = clamped.cursor;
        const parts = session.scrollback.since(c.cursor);
        const available = parts[0].len + parts[1].len;
        if (available == 0) continue;

        const room = if (c.cursor < c.replay_until)
            @min(available, c.replay_until - c.cursor)
        else
            available;
        const take = @min(room, wire.max_payload);
        const first = @min(parts[0].len, take);
        const kind: wire.Type = if (c.cursor < c.replay_until) .replay else .output;
        const header = wire.encodeHeader(kind, @intCast(take));
        c.out.appendSlice(loop.app.gpa, &header) catch continue;
        c.out.appendSlice(loop.app.gpa, parts[0][0..first]) catch continue;
        if (take > first) c.out.appendSlice(loop.app.gpa, parts[1][0 .. take - first]) catch continue;
        c.cursor += take;
    }
}

fn flushClient(loop: *Loop, client: *Client) void {
    while (client.out.items.len > 0) {
        switch (writeFd(client.fd, client.out.items)) {
            .n => |n| {
                if (n == 0) return;
                std.mem.copyForwards(u8, client.out.items[0 .. client.out.items.len - n], client.out.items[n..]);
                client.out.shrinkRetainingCapacity(client.out.items.len - n);
            },
            .again => return,
            .closed => {
                client.dead = true;
                return;
            },
        }
    }
    _ = loop;
}

fn tick(loop: *Loop, at: i64, idle_since: *?i64) void {
    for (loop.list.items) |*s| {
        if (s.tick(at)) loop.dirty = true;
        if (!s.master_open and loop.reapAndAnnounce(s, at)) loop.dirty = true;
    }

    if (loop.dirty and loop.deadlines.registry_flush_at == null) {
        loop.deadlines.registry_flush_at = (at + 1) * std.time.ms_per_s;
    }
    if (loop.deadlines.registry_flush_at) |due| {
        if (at * std.time.ms_per_s >= due) {
            flushRegistry(loop, at);
            loop.deadlines.registry_flush_at = null;
        }
    }
    if (loop.deadlines.listener_resume_at) |due| {
        if (at * std.time.ms_per_s >= due) loop.deadlines.listener_resume_at = null;
    }

    var live: usize = 0;
    for (loop.list.items) |*s| {
        if (s.exit == null) live += 1;
    }
    if (live == 0 and loop.clients.items.len == 0) {
        if (idle_since.* == null) idle_since.* = at;
        if (at - idle_since.*.? >= loop.opts.idle_exit_seconds) loop.running = false;
        loop.deadlines.idle_exit_at = (idle_since.*.? + loop.opts.idle_exit_seconds) * std.time.ms_per_s;
    } else {
        idle_since.* = null;
        loop.deadlines.idle_exit_at = null;
    }
}

fn flushRegistry(loop: *Loop, at: i64) void {
    const gpa = loop.app.gpa;
    const rows = gpa.alloc(sessions_mod.Session, loop.list.items.len) catch return;
    defer gpa.free(rows);
    for (loop.list.items, 0..) |*s, i| rows[i] = s.entry();

    sessions_mod.save(gpa, loop.app.io, loop.app.environ, .{
        .daemon = .{
            .pid = @intCast(std.c.getpid()),
            .started_at = loop.started_at,
            .socket = loop.bound.socket_path,
            .protocol = wire.protocol,
            .wrote_at = at,
        },
        .sessions = rows,
    }) catch {};
    loop.dirty = false;
}

fn reapDead(loop: *Loop) void {
    var i: usize = 0;
    while (i < loop.clients.items.len) {
        const c = &loop.clients.items[i];
        const timed_out = c.handshake_deadline != 0 and loop.now() > c.handshake_deadline;
        if (c.dead or timed_out) {
            c.stream.close(loop.app.io);
            c.out.deinit(loop.app.gpa);
            loop.app.gpa.free(c.dec_buf);
            _ = loop.clients.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

const testing = std.testing;

test "with nothing pending the daemon blocks rather than ticking" {
    try testing.expectEqual(@as(i32, -1), nextTimeout(1_000, .{}));
}

test "the nearest deadline wins, and one already past is zero, never negative" {
    const now: i64 = 10_000;

    try testing.expectEqual(@as(i32, 500), nextTimeout(now, .{ .registry_flush_at = now + 500 }));

    try testing.expectEqual(@as(i32, 250), nextTimeout(now, .{
        .registry_flush_at = now + 500,
        .reap_retry_at = now + 250,
        .idle_exit_at = now + 900_000,
    }));

    try testing.expectEqual(@as(i32, 0), nextTimeout(now, .{ .registry_flush_at = now }));
    try testing.expectEqual(@as(i32, 0), nextTimeout(now, .{ .registry_flush_at = now - 5_000 }));
}

test "a deadline beyond i32 milliseconds is clamped, not wrapped" {
    const huge = nextTimeout(0, .{ .idle_exit_at = std.math.maxInt(i64) });
    try testing.expectEqual(std.math.maxInt(i32), huge);
    try testing.expect(huge > 0);
}

test "bind takes the lock, and a second bind on the same directory declines" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_WATCH_DIR", base);

    const socket_path = watch_paths.socket(arena, &environ) catch |err| switch (err) {
        error.SocketPathTooLong => return error.SkipZigTest,
        else => return err,
    };
    _ = socket_path;

    var out_buf: [1024]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out_w: Io.Writer = .fixed(&out_buf);
    var err_w: Io.Writer = .fixed(&err_buf);
    const app: app_mod.App = .{
        .gpa = arena,
        .io = io,
        .environ = &environ,
        .ui = .{ .io = io, .out = &out_w, .err = &err_w },
    };

    var first = (try bind(app, .{})) orelse return error.TestExpectedEqual;
    defer first.deinit(io);

    const before = try Io.Dir.cwd().statFile(io, first.socket_path, .{});
    try testing.expect((try bind(app, .{})) == null);
    const after = try Io.Dir.cwd().statFile(io, first.socket_path, .{});
    try testing.expectEqual(before.inode, after.inode);
}

test "a stale socket left by a killed daemon is replaced, not tripped over" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_WATCH_DIR", base);

    const socket_path = watch_paths.socket(arena, &environ) catch |err| switch (err) {
        error.SocketPathTooLong => return error.SkipZigTest,
        else => return err,
    };

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = socket_path, .data = "stale" });

    var out_buf: [1024]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out_w: Io.Writer = .fixed(&out_buf);
    var err_w: Io.Writer = .fixed(&err_buf);
    const app: app_mod.App = .{
        .gpa = arena,
        .io = io,
        .environ = &environ,
        .ui = .{ .io = io, .out = &out_w, .err = &err_w },
    };

    var bound = (try bind(app, .{})) orelse return error.TestExpectedEqual;
    defer bound.deinit(io);
}

const TestConn = struct {
    fd: std.posix.fd_t,
    buf: []u8,
    dec: wire.Decoder,

    fn open(gpa: std.mem.Allocator, io: Io, socket_path: []const u8) !TestConn {
        const address = try Io.net.UnixAddress.init(socket_path);
        const stream = try address.connect(io);
        const buf = try gpa.alloc(u8, wire.bufferLen());
        return .{
            .fd = stream.socket.handle,
            .buf = buf,
            .dec = try wire.Decoder.init(buf, .control),
        };
    }

    fn send(self: *TestConn, gpa: std.mem.Allocator, t: wire.Type, value: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(gpa, value, .{});
        defer gpa.free(body);
        try self.raw(t, body);
    }

    fn raw(self: *TestConn, t: wire.Type, payload: []const u8) !void {
        const header = wire.encodeHeader(t, @intCast(payload.len));
        _ = std.c.write(self.fd, &header, header.len);
        if (payload.len > 0) _ = std.c.write(self.fd, payload.ptr, payload.len);
    }

    fn recv(self: *TestConn, want: wire.Type, budget_ms: *i32) !wire.Frame {
        while (budget_ms.* > 0) {
            if (try self.dec.next()) |frame| {
                if (frame.type == want) return frame;
                continue;
            }
            var fds = [_]std.posix.pollfd{
                .{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&fds, 100) catch 0;
            budget_ms.* -= 100;
            if (ready == 0) continue;
            const room = self.dec.writable();
            const n = std.c.read(self.fd, room.ptr, room.len);
            if (n <= 0) return error.TestUnexpectedResult;
            self.dec.commit(@intCast(n));
        }
        return error.TestExpectedEqual;
    }

    fn hello(self: *TestConn, gpa: std.mem.Allocator, budget_ms: *i32) !void {
        try self.send(gpa, .hello, wire.Hello{ .role = "control", .pid = 0 });
        _ = try self.recv(.hello, budget_ms);
    }

    fn close(self: *TestConn) void {
        _ = std.c.close(self.fd);
    }
};

fn runForTest(app: app_mod.App, opts: Options) void {
    run(app, opts) catch {};
}

fn standIn(arena: std.mem.Allocator, io: Io, base: []const u8, script: []const u8) ![]const u8 {
    const path = try std.fs.path.join(arena, &.{ base, "claude-stand-in" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = script });
    if (chmod(try arena.dupeZ(u8, path), 0o755) != 0) return error.Unexpected;
    return path;
}

const stand_in_cat = "#!/bin/sh\nexec cat\n";

test "a registered session runs, echoes, and its output survives a reconnect" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_WATCH_DIR", base);
    const socket_path = watch_paths.socket(arena, &environ) catch |err| switch (err) {
        error.SocketPathTooLong => return error.SkipZigTest,
        else => return err,
    };

    var daemon_arena: std.heap.ArenaAllocator = .init(gpa);
    defer daemon_arena.deinit();
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out_w: Io.Writer = .fixed(&out_buf);
    var err_w: Io.Writer = .fixed(&err_buf);
    const daemon_app: app_mod.App = .{
        .gpa = daemon_arena.allocator(),
        .io = io,
        .environ = &environ,
        .ui = .{ .io = io, .out = &out_w, .err = &err_w },
    };

    const thread = try std.Thread.spawn(.{}, runForTest, .{ daemon_app, Options{
        .foreground = true,
        .idle_exit_seconds = 3600,
    } });
    defer thread.join();

    var budget: i32 = 15_000;
    while (budget > 0) : (budget -= 50) {
        if (Io.Dir.cwd().statFile(io, socket_path, .{})) |_| break else |_| {}
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }

    {
        var conn = try TestConn.open(arena, io, socket_path);
        defer conn.close();
        var b: i32 = 15_000;
        try conn.hello(arena, &b);

        try conn.send(arena, .register, wire.Register{
            .worktree = base,
            .branch = "feature/pe-1-test",
            .issue = "PE-1",
            .repo_root = base,
            .program = try standIn(arena, io, base, stand_in_cat),
            .argv = &.{},
            .env = &.{"TERM=dumb"},
            .cols = 80,
            .rows = 24,
        });
        const registered = try conn.recv(.registered, &b);
        const body = try wire.parse(wire.Registered, arena, registered);
        try testing.expect(body.session_id.len > 0);
        try testing.expect(body.pid > 0);

        try conn.send(arena, .hello, wire.Hello{ .role = "attach", .pid = 0 });
        var attach_conn = try TestConn.open(arena, io, socket_path);
        defer attach_conn.close();
        var ab: i32 = 15_000;
        try attach_conn.send(arena, .hello, wire.Hello{ .role = "attach", .pid = 0 });
        _ = try attach_conn.recv(.hello, &ab);
        attach_conn.dec.role = .attach;
        try attach_conn.send(arena, .attach, wire.Attach{
            .session_id = body.session_id,
            .cols = 80,
            .rows = 24,
            .replay = true,
        });
        _ = try attach_conn.recv(.attached, &ab);

        try attach_conn.raw(.input, "hello-from-lcc\n");
        var seen: std.ArrayList(u8) = .empty;
        defer seen.deinit(gpa);
        while (ab > 0) {
            const frame = try attach_conn.recv(.output, &ab);
            try seen.appendSlice(gpa, frame.payload);
            if (std.mem.indexOf(u8, seen.items, "hello-from-lcc") != null) break;
        }
        try testing.expect(std.mem.indexOf(u8, seen.items, "hello-from-lcc") != null);

        try conn.send(arena, .hook, wire.Hook{
            .cwd = base,
            .session_id = "irrelevant",
            .event = "waiting",
        });
        var waited: i32 = 5_000;
        while (waited > 0) : (waited -= 100) {
            try conn.send(arena, .list, .{});
            const snap = try conn.recv(.snapshot, &b);
            const view = try wire.parse(wire.Snapshot, arena, snap);
            if (view.sessions.len == 1 and std.mem.eql(u8, view.sessions[0].status, "waiting")) break;
            io.sleep(.fromMilliseconds(100), .awake) catch {};
        }
        try testing.expect(waited > 0);

        try conn.send(arena, .hook, wire.Hook{
            .cwd = "/nowhere-at-all",
            .session_id = "x",
            .event = "active",
        });
        try conn.send(arena, .list, .{});
        const after = try conn.recv(.snapshot, &b);
        const after_view = try wire.parse(wire.Snapshot, arena, after);
        try testing.expectEqualStrings("waiting", after_view.sessions[0].status);

        try conn.send(arena, .hook, wire.Hook{
            .cwd = base,
            .session_id = "irrelevant",
            .event = "active",
            .permission_mode = "plan",
        });
        waited = 5_000;
        while (waited > 0) : (waited -= 100) {
            try conn.send(arena, .list, .{});
            const snap = try conn.recv(.snapshot, &b);
            const view = try wire.parse(wire.Snapshot, arena, snap);
            if (std.mem.eql(u8, view.sessions[0].status, "plan")) break;
            io.sleep(.fromMilliseconds(100), .awake) catch {};
        }
        try testing.expect(waited > 0);
    }

    {
        var conn = try TestConn.open(arena, io, socket_path);
        defer conn.close();
        var b: i32 = 15_000;
        try conn.hello(arena, &b);
        try conn.send(arena, .list, .{});
        const snap = try conn.recv(.snapshot, &b);
        const body = try wire.parse(wire.Snapshot, arena, snap);
        try testing.expectEqual(@as(usize, 1), body.sessions.len);
        try testing.expectEqualStrings("PE-1", body.sessions[0].issue.?);

        var attach_conn = try TestConn.open(arena, io, socket_path);
        defer attach_conn.close();
        var ab: i32 = 15_000;
        try attach_conn.send(arena, .hello, wire.Hello{ .role = "attach", .pid = 0 });
        _ = try attach_conn.recv(.hello, &ab);
        attach_conn.dec.role = .attach;
        try attach_conn.send(arena, .attach, wire.Attach{
            .session_id = body.sessions[0].id,
            .cols = 80,
            .rows = 24,
            .replay = true,
        });
        _ = try attach_conn.recv(.attached, &ab);

        var replay: std.ArrayList(u8) = .empty;
        defer replay.deinit(gpa);
        while (ab > 0) {
            const frame = try attach_conn.recv(.output, &ab);
            try replay.appendSlice(gpa, frame.payload);
            if (std.mem.indexOf(u8, replay.items, "hello-from-lcc") != null) break;
        }
        try testing.expect(std.mem.indexOf(u8, replay.items, "hello-from-lcc") != null);

        try conn.send(arena, .stop, wire.Stop{ .force = true });
    }
}

test "a hook reports to the socket it was handed, not to the one its environment names" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_WATCH_DIR", base);
    const socket_path = watch_paths.socket(arena, &environ) catch |err| switch (err) {
        error.SocketPathTooLong => return error.SkipZigTest,
        else => return err,
    };

    var daemon_arena: std.heap.ArenaAllocator = .init(gpa);
    defer daemon_arena.deinit();
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out_w: Io.Writer = .fixed(&out_buf);
    var err_w: Io.Writer = .fixed(&err_buf);
    const daemon_app: app_mod.App = .{
        .gpa = daemon_arena.allocator(),
        .io = io,
        .environ = &environ,
        .ui = .{ .io = io, .out = &out_w, .err = &err_w },
    };

    const thread = try std.Thread.spawn(.{}, runForTest, .{ daemon_app, Options{
        .foreground = true,
        .idle_exit_seconds = 3600,
    } });
    defer thread.join();

    var budget: i32 = 15_000;
    while (budget > 0) : (budget -= 50) {
        if (Io.Dir.cwd().statFile(io, socket_path, .{})) |_| break else |_| {}
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }

    var conn = try TestConn.open(arena, io, socket_path);
    defer conn.close();
    var b: i32 = 15_000;
    try conn.hello(arena, &b);
    defer conn.send(arena, .stop, wire.Stop{ .force = true }) catch {};

    try conn.send(arena, .register, wire.Register{
        .worktree = base,
        .branch = "feature/pe-2-hooks",
        .issue = "PE-2",
        .repo_root = base,
        .program = try standIn(arena, io, base, stand_in_cat),
        .argv = &.{},
        .env = &.{"TERM=dumb"},
        .cols = 80,
        .rows = 24,
    });
    const body = try wire.parse(wire.Registered, arena, try conn.recv(.registered, &b));
    try testing.expectEqualStrings("starting", body.status);

    var elsewhere: std.process.Environ.Map = .init(arena);
    try elsewhere.put("LCC_WATCH_DIR", try std.fs.path.join(arena, &.{ base, "no-daemon-here" }));
    var hook_out: Io.Writer = .fixed(&out_buf);
    var hook_err: Io.Writer = .fixed(&err_buf);
    const hook_app: app_mod.App = .{
        .gpa = arena,
        .io = io,
        .environ = &elsewhere,
        .ui = .{ .io = io, .out = &hook_out, .err = &hook_err },
    };

    const statusNow = struct {
        fn get(c: *TestConn, a: std.mem.Allocator, budget_ms: *i32) ![]const u8 {
            try c.send(a, .list, .{});
            const view = try wire.parse(wire.Snapshot, a, try c.recv(.snapshot, budget_ms));
            return if (view.sessions.len == 1) view.sessions[0].status else "<none>";
        }
    }.get;

    watch_client.report(hook_app, null, base, "s", "waiting", "");
    io.sleep(.fromMilliseconds(300), .awake) catch {};
    try testing.expectEqualStrings("starting", try statusNow(&conn, arena, &b));

    watch_client.report(hook_app, socket_path, base, "s", "waiting", "");
    var waited: i32 = 5_000;
    while (waited > 0) : (waited -= 100) {
        if (std.mem.eql(u8, try statusNow(&conn, arena, &b), "waiting")) break;
        io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
    try testing.expect(waited > 0);
}

test "a session is launched with the hook settings, read back off the real process" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_WATCH_DIR", base);
    const socket_path = watch_paths.socket(arena, &environ) catch |err| switch (err) {
        error.SocketPathTooLong => return error.SkipZigTest,
        else => return err,
    };
    const hooks_path = try watch_paths.hooks(arena, &environ);

    var daemon_arena: std.heap.ArenaAllocator = .init(gpa);
    defer daemon_arena.deinit();
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out_w: Io.Writer = .fixed(&out_buf);
    var err_w: Io.Writer = .fixed(&err_buf);
    const daemon_app: app_mod.App = .{
        .gpa = daemon_arena.allocator(),
        .io = io,
        .environ = &environ,
        .ui = .{ .io = io, .out = &out_w, .err = &err_w },
    };

    const thread = try std.Thread.spawn(.{}, runForTest, .{ daemon_app, Options{
        .foreground = true,
        .idle_exit_seconds = 3600,
    } });
    defer thread.join();

    var budget: i32 = 15_000;
    while (budget > 0) : (budget -= 50) {
        if (Io.Dir.cwd().statFile(io, socket_path, .{})) |_| break else |_| {}
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }

    var conn = try TestConn.open(arena, io, socket_path);
    defer conn.close();
    var b: i32 = 15_000;
    try conn.hello(arena, &b);
    defer conn.send(arena, .stop, wire.Stop{ .force = true }) catch {};

    try conn.send(arena, .register, wire.Register{
        .worktree = base,
        .branch = "feature/pe-3-settings",
        .issue = "PE-3",
        .repo_root = base,
        .program = try standIn(arena, io, base, "#!/bin/sh\nsleep 30\n"),
        .argv = &.{ "--mcp-config", "/tmp/carried.json", "--resume" },
        .env = &.{"TERM=dumb"},
        .cols = 80,
        .rows = 24,
    });
    const body = try wire.parse(wire.Registered, arena, try conn.recv(.registered, &b));

    const pid = try std.fmt.allocPrint(arena, "{d}", .{body.pid});
    const line = try exec.capture(arena, io, &.{ "ps", "-p", pid, "-ww", "-o", "command=" }, null);

    const flag = try std.fmt.allocPrint(arena, "--settings {s}", .{hooks_path});
    try testing.expect(std.mem.indexOf(u8, line, flag) != null);
    try Io.Dir.cwd().access(io, hooks_path, .{});

    try testing.expect(std.mem.indexOf(u8, line, "--mcp-config /tmp/carried.json --resume") != null);
}

test "a child that exits tells the attached client instead of leaving it on a dead screen" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_WATCH_DIR", base);
    const socket_path = watch_paths.socket(arena, &environ) catch |err| switch (err) {
        error.SocketPathTooLong => return error.SkipZigTest,
        else => return err,
    };

    var daemon_arena: std.heap.ArenaAllocator = .init(gpa);
    defer daemon_arena.deinit();
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out_w: Io.Writer = .fixed(&out_buf);
    var err_w: Io.Writer = .fixed(&err_buf);
    const daemon_app: app_mod.App = .{
        .gpa = daemon_arena.allocator(),
        .io = io,
        .environ = &environ,
        .ui = .{ .io = io, .out = &out_w, .err = &err_w },
    };

    const thread = try std.Thread.spawn(.{}, runForTest, .{ daemon_app, Options{
        .foreground = true,
        .idle_exit_seconds = 3600,
    } });
    defer thread.join();

    var budget: i32 = 15_000;
    while (budget > 0) : (budget -= 50) {
        if (Io.Dir.cwd().statFile(io, socket_path, .{})) |_| break else |_| {}
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }

    var conn = try TestConn.open(arena, io, socket_path);
    defer conn.close();
    var b: i32 = 15_000;
    try conn.hello(arena, &b);

    try conn.send(arena, .register, wire.Register{
        .worktree = base,
        .branch = "feature/pe-2-exit",
        .issue = "PE-2",
        .repo_root = base,
        .program = try standIn(arena, io, base, stand_in_cat),
        .argv = &.{},
        .env = &.{"TERM=dumb"},
        .cols = 80,
        .rows = 24,
    });
    const body = try wire.parse(wire.Registered, arena, try conn.recv(.registered, &b));

    var attach_conn = try TestConn.open(arena, io, socket_path);
    defer attach_conn.close();
    var ab: i32 = 15_000;
    try attach_conn.send(arena, .hello, wire.Hello{ .role = "attach", .pid = 0 });
    _ = try attach_conn.recv(.hello, &ab);
    attach_conn.dec.role = .attach;
    try attach_conn.send(arena, .attach, wire.Attach{
        .session_id = body.session_id,
        .cols = 80,
        .rows = 24,
        .replay = true,
    });
    _ = try attach_conn.recv(.attached, &ab);

    try attach_conn.raw(.input, "hello\n");
    var echoed: std.ArrayList(u8) = .empty;
    defer echoed.deinit(gpa);
    while (ab > 0) {
        const frame = try attach_conn.recv(.output, &ab);
        try echoed.appendSlice(gpa, frame.payload);
        if (std.mem.indexOf(u8, echoed.items, "hello") != null) break;
    }

    try attach_conn.raw(.input, &.{0x04});

    _ = attach_conn.recv(.exited, &ab) catch |err| {
        std.debug.print(
            "no `exited` frame arrived within {d}ms of the child ending: {s}.\n" ++
                "An attached client has no other way to learn the session is over, " ++
                "so it sits on the dead screen until the detach key is pressed.\n",
            .{ 15_000 - ab, @errorName(err) },
        );
        return err;
    };

    try conn.send(arena, .stop, wire.Stop{ .force = true });
}

test "a grandchild still holding the pty cannot hide the child's exit" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_WATCH_DIR", base);
    const socket_path = watch_paths.socket(arena, &environ) catch |err| switch (err) {
        error.SocketPathTooLong => return error.SkipZigTest,
        else => return err,
    };

    var daemon_arena: std.heap.ArenaAllocator = .init(gpa);
    defer daemon_arena.deinit();
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out_w: Io.Writer = .fixed(&out_buf);
    var err_w: Io.Writer = .fixed(&err_buf);
    const daemon_app: app_mod.App = .{
        .gpa = daemon_arena.allocator(),
        .io = io,
        .environ = &environ,
        .ui = .{ .io = io, .out = &out_w, .err = &err_w },
    };

    const thread = try std.Thread.spawn(.{}, runForTest, .{ daemon_app, Options{
        .foreground = true,
        .idle_exit_seconds = 3600,
    } });
    defer thread.join();

    var budget: i32 = 15_000;
    while (budget > 0) : (budget -= 50) {
        if (Io.Dir.cwd().statFile(io, socket_path, .{})) |_| break else |_| {}
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }

    var conn = try TestConn.open(arena, io, socket_path);
    defer conn.close();
    var b: i32 = 15_000;
    try conn.hello(arena, &b);

    try conn.send(arena, .register, wire.Register{
        .worktree = base,
        .branch = "feature/pe-3-grandchild",
        .issue = "PE-3",
        .repo_root = base,
        .program = try standIn(arena, io, base, "#!/bin/sh\nsleep 30 &\nexec cat\n"),
        .argv = &.{},
        .env = &.{"TERM=dumb"},
        .cols = 80,
        .rows = 24,
    });
    const body = try wire.parse(wire.Registered, arena, try conn.recv(.registered, &b));

    var attach_conn = try TestConn.open(arena, io, socket_path);
    defer attach_conn.close();
    var ab: i32 = 15_000;
    try attach_conn.send(arena, .hello, wire.Hello{ .role = "attach", .pid = 0 });
    _ = try attach_conn.recv(.hello, &ab);
    attach_conn.dec.role = .attach;
    try attach_conn.send(arena, .attach, wire.Attach{
        .session_id = body.session_id,
        .cols = 80,
        .rows = 24,
        .replay = true,
    });
    _ = try attach_conn.recv(.attached, &ab);

    try attach_conn.raw(.input, "hello\n");
    var echoed: std.ArrayList(u8) = .empty;
    defer echoed.deinit(gpa);
    while (ab > 0) {
        const frame = try attach_conn.recv(.output, &ab);
        try echoed.appendSlice(gpa, frame.payload);
        if (std.mem.indexOf(u8, echoed.items, "hello") != null) break;
    }

    try attach_conn.raw(.input, &.{0x04});

    _ = attach_conn.recv(.exited, &ab) catch |err| {
        std.debug.print(
            "no `exited` frame after {d}ms, with a grandchild still holding the pty: {s}.\n" ++
                "SIGCHLD is the only signal left in this case — the pty stays open — " ++
                "so an attached client is stranded on a session that has ended.\n",
            .{ 15_000 - ab, @errorName(err) },
        );
        return err;
    };

    try conn.send(arena, .stop, wire.Stop{ .force = true });
}

test "a directory sitting on the socket path is a named error, not a panic" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_WATCH_DIR", base);

    const socket_path = watch_paths.socket(arena, &environ) catch |err| switch (err) {
        error.SocketPathTooLong => return error.SkipZigTest,
        else => return err,
    };
    try Io.Dir.cwd().createDirPath(io, socket_path);

    var out_buf: [1024]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out_w: Io.Writer = .fixed(&out_buf);
    var err_w: Io.Writer = .fixed(&err_buf);
    const app: app_mod.App = .{
        .gpa = arena,
        .io = io,
        .environ = &environ,
        .ui = .{ .io = io, .out = &out_w, .err = &err_w },
    };

    try testing.expectError(BindError.SocketPathOccupied, bind(app, .{}));
}
