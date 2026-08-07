const std = @import("std");
const Io = std.Io;
const ansi = @import("ansi.zig");
const app_mod = @import("app.zig");
const term = @import("term.zig");
const watch_client = @import("watch_client.zig");
const wire = @import("wire.zig");

pub const detach_key: u8 = 0x1c;

pub const Outcome = enum {
    detached,
    ended,
    daemon_gone,
};

const backslash = '\\';
const backslash_ctrl_code = 0x1c;

pub fn detachAt(bytes: []const u8) ?usize {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == detach_key) return i;
        if (bytes[i] != 0x1b) continue;
        if (i + 2 >= bytes.len or bytes[i + 1] != '[') continue;
        if (csiDetach(bytes[i + 2 ..])) return i;
    }
    return null;
}

fn csiDetach(body: []const u8) bool {
    var params: [4]u32 = .{ 0, 0, 0, 0 };
    var count: usize = 0;
    var value: u32 = 0;
    var seen_digit = false;

    for (body) |byte| {
        switch (byte) {
            '0'...'9' => {
                value = value *| 10 +| (byte - '0');
                seen_digit = true;
            },
            ';' => {
                if (count < params.len) params[count] = value;
                count += 1;
                value = 0;
                seen_digit = false;
            },
            'u', '~' => {
                if (count < params.len) params[count] = value;
                count += 1;
                if (!seen_digit and count < 2) return false;
                return matches(byte, params[0..@min(count, params.len)]);
            },
            else => return false,
        }
    }
    return false;
}

fn matches(final: u8, params: []const u32) bool {
    if (params.len < 2) return false;
    const ctrl = ((params[1] -| 1) & 4) != 0;
    if (!ctrl) return false;
    return switch (final) {
        'u' => params[0] == backslash or params[0] == backslash_ctrl_code,
        '~' => params[0] == 27 and params.len >= 3 and
            (params[2] == backslash or params[2] == backslash_ctrl_code),
        else => false,
    };
}

pub const Options = struct {
    session_id: []const u8,
    replay: bool = true,
};

fn openDump(app: app_mod.App) ?Io.File {
    const path = app.environ.get("LCC_WATCH_DUMP") orelse return null;
    if (path.len == 0) return null;
    return Io.Dir.cwd().createFile(app.io, path, .{ .truncate = false }) catch null;
}

fn note(dump: ?Io.File, io: Io, comptime label: []const u8, bytes: []const u8) void {
    const file = dump orelse return;
    var buf: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "\n[{s} {d}] ", .{ label, bytes.len }) catch return;
    var w = file.writer(io, &.{});
    w.interface.writeAll(head) catch {};
    for (bytes) |byte| {
        const pair = std.fmt.bufPrint(&buf, "{x:0>2} ", .{byte}) catch continue;
        w.interface.writeAll(pair) catch {};
    }
    w.interface.flush() catch {};
}

pub fn run(app: app_mod.App, opts: Options) !Outcome {
    const dump = openDump(app);
    defer if (dump) |f| f.close(app.io);
    const terminal = try term.Terminal.enterRaw();
    var size = terminal.size();

    var conn = (try watch_client.connectExisting(app, .attach)) orelse return .daemon_gone;

    defer {
        var exit_buf: [512]u8 = undefined;
        var out_writer: Io.File.Writer = .init(.stdout(), app.io, &exit_buf);
        term.sanitize(&out_writer.interface);
        out_writer.interface.flush() catch {};
        terminal.restore();
        conn.close(app.io);
    }

    var replay_filter: ansi.ModeFilter = .{};
    var filtered: [wire.max_payload + 64]u8 = undefined;

    try conn.sendControl(app.gpa, .attach, wire.Attach{
        .session_id = opts.session_id,
        .cols = size.cols,
        .rows = size.rows,
        .replay = opts.replay,
    });

    const sock = conn.stream.socket.handle;
    var in_buf: [4096]u8 = undefined;

    while (true) {
        const now_size = terminal.size();
        if (now_size.rows != size.rows or now_size.cols != size.cols) {
            size = now_size;
            conn.sendControl(app.gpa, .resize, wire.Resize{
                .cols = size.cols,
                .rows = size.rows,
            }) catch return .daemon_gone;
        }

        var fds = [_]std.posix.pollfd{
            .{ .fd = terminal.fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = sock, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&fds, 200) catch continue;

        if (fds[0].revents & std.posix.POLL.IN != 0) {
            const n = std.posix.read(terminal.fd, &in_buf) catch 0;
            if (n == 0) return .detached;
            const chunk = in_buf[0..n];
            note(dump, app.io, "key", chunk);
            if (detachAt(chunk)) |at| {
                if (at > 0) conn.send(app.gpa, .input, chunk[0..at]) catch {};
                return .detached;
            }
            conn.send(app.gpa, .input, chunk) catch return .daemon_gone;
        }

        if (fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
            const room = conn.dec.writable();
            const n = std.c.read(sock, room.ptr, room.len);
            if (n <= 0) return .daemon_gone;
            conn.dec.commit(@intCast(n));

            while (conn.dec.next() catch return .daemon_gone) |frame| switch (frame.type) {
                .replay => {
                    const kept = replay_filter.filter(frame.payload, &filtered);
                    note(dump, app.io, "replay", kept);
                    writeAll(chunk_stdout, kept);
                },
                .output => {
                    note(dump, app.io, "out", frame.payload);
                    writeAll(chunk_stdout, frame.payload);
                },
                .exited => return .ended,
                else => {},
            };
        }
    }
}

const chunk_stdout: std.posix.fd_t = 1;

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + sent, bytes.len - sent);
        if (n > 0) {
            sent += @intCast(n);
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        return;
    }
}

const testing = std.testing;

test "the detach key is found in every encoding a terminal may send it as" {
    try testing.expectEqual(@as(usize, 0), detachAt(&.{detach_key}).?);

    try testing.expectEqual(@as(usize, 0), detachAt("\x1b[92;5u").?);
    try testing.expectEqual(@as(usize, 4), detachAt("abcd\x1b[92;5u").?);
    try testing.expect(detachAt("\x1b[28;5u") != null);
    try testing.expect(detachAt("\x1b[92;7u") != null);

    try testing.expect(detachAt("\x1b[27;5;92~") != null);
    try testing.expect(detachAt("\x1b[27;5;28~") != null);

    try testing.expect(detachAt("\x1b[92;1u") == null);
    try testing.expect(detachAt("\x1b[27;1;92~") == null);
    try testing.expect(detachAt("\x1b[99;5u") == null);
    try testing.expect(detachAt("\x1b[27;5;99~") == null);
}

test "ordinary output and other escapes are not mistaken for it" {
    try testing.expect(detachAt("hello") == null);
    try testing.expectEqual(@as(usize, 3), detachAt("abc\x1cdef").?);
    try testing.expectEqual(@as(usize, 5), detachAt("hello\x1c").?);
    try testing.expect(detachAt("") == null);

    for ([_][]const u8{ "\x1b[A", "\x1b[B", "\x1b", "\x1b[1;5C", "\x1b[200~pasted\x1b[201~" }) |seq| {
        try testing.expect(detachAt(seq) == null);
    }
}

test "a UTF-8 continuation byte can never be mistaken for the detach key" {
    const cyrillic = "Привіт";
    try testing.expect(detachAt(cyrillic) == null);
    for (cyrillic) |byte| try testing.expect(byte != detach_key);

    const emoji = "🚀 працює";
    try testing.expect(detachAt(emoji) == null);
}

test "Ctrl-C is not the detach key" {
    try testing.expect(detachAt(&.{0x03}) == null);
    try testing.expect(detach_key != 0x03);
}
