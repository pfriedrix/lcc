//! Raw passthrough of one session's bytes, and handing the terminal back the
//! way it was found.
//!
//! This is the one place lcc writes to stdout without going through `app.ui`,
//! and it has to be: the bytes belong to Claude Code, not to lcc, and framing
//! them through a logging vocabulary would corrupt them. It is also the one
//! place that reads a file descriptor without threading `Io` — `prompt.zig`
//! already reads stdin with `std.posix.read`, and 0.16 offers no readiness
//! primitive that would let a single task wait on stdin and a socket together.
//! Blocking on one while the other has bytes is precisely what this loop exists
//! to avoid.
//!
//! Everything that is not the pump — connecting, the registry, the snapshot —
//! still goes through `Io` and through `app.ui`.

const std = @import("std");
const Io = std.Io;
const app_mod = @import("app.zig");
const term = @import("term.zig");
const watch_client = @import("watch_client.zig");
const wire = @import("wire.zig");

/// Ctrl-\ .
///
/// `ISIG` is off in raw mode, so it arrives as a plain byte rather than
/// SIGQUIT, and Claude Code binds nothing to it. Ctrl-C is deliberately not
/// used: it has to keep reaching the agent, which is the first thing anyone
/// tries when a turn goes wrong.
pub const detach_key: u8 = 0x1c;

pub const Outcome = enum {
    /// The user asked to come back.
    detached,
    /// The child exited while attached.
    ended,
    /// The daemon went away underneath us.
    daemon_gone,
};

/// Where the detach key falls in a read, if it is there at all.
///
/// Pure, so the one thing that can strand a user inside a session is testable
/// without a terminal.
pub fn detachAt(bytes: []const u8) ?usize {
    return std.mem.indexOfScalar(u8, bytes, detach_key);
}

pub const Options = struct {
    session_id: []const u8,
    /// Replay the scrollback so the screen is repainted on arrival, rather than
    /// staying blank until the agent next prints.
    replay: bool = true,
};

pub fn run(app: app_mod.App, opts: Options) !Outcome {
    const terminal = try term.Terminal.enterRaw();
    var size = terminal.size();

    var conn = (try watch_client.connectExisting(app, .attach)) orelse return .daemon_gone;

    // Ordered so the terminal is always handed back intact, whatever happens:
    // restore the modes lcc set, then undo the ones the *child* set — the
    // program that would normally clean those up is still running, on purpose.
    defer {
        var out_buf: [512]u8 = undefined;
        var out_writer: Io.File.Writer = .init(.stdout(), app.io, &out_buf);
        term.sanitize(&out_writer.interface);
        out_writer.interface.flush() catch {};
        terminal.restore();
        conn.close(app.io);
    }

    try conn.sendControl(app.gpa, .attach, wire.Attach{
        .session_id = opts.session_id,
        .cols = size.cols,
        .rows = size.rows,
        .replay = opts.replay,
    });

    const sock = conn.stream.socket.handle;
    var in_buf: [4096]u8 = undefined;

    while (true) {
        // Re-queried every iteration rather than driven by SIGWINCH, matching
        // `prompt.zig`. No handler to install, and no signal to miss.
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
        // A short timeout only so a resize is noticed promptly; nothing else
        // depends on it firing.
        _ = std.posix.poll(&fds, 200) catch continue;

        if (fds[0].revents & std.posix.POLL.IN != 0) {
            const n = std.posix.read(terminal.fd, &in_buf) catch 0;
            if (n == 0) return .detached;
            const chunk = in_buf[0..n];
            if (detachAt(chunk)) |at| {
                // Anything typed before the key is still meant for the agent,
                // and dropping it would silently lose a keystroke.
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
                // Straight to the terminal, unexamined. These bytes are Claude
                // Code's own rendering and anything that reinterpreted them
                // would corrupt the screen.
                .output => writeAll(chunk_stdout, frame.payload),
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
        // `Io.Threaded` installs a SIGPIPE handler, so a closed stdout is an
        // error return rather than a killed process — but it carries no
        // SA_RESTART, so EINTR is ours to retry.
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        return;
    }
}

const testing = std.testing;

test "the detach key is found wherever it falls, and nowhere it does not" {
    try testing.expect(detachAt("hello") == null);
    try testing.expectEqual(@as(usize, 0), detachAt(&.{detach_key}).?);
    try testing.expectEqual(@as(usize, 3), detachAt("abc\x1cdef").?);
    try testing.expectEqual(@as(usize, 5), detachAt("hello\x1c").?);
    try testing.expect(detachAt("") == null);
}

test "a UTF-8 continuation byte can never be mistaken for the detach key" {
    // 0x1c is below 0x80, and every byte of a multi-byte UTF-8 sequence is at
    // or above it. So typing a non-ASCII character can never detach — worth
    // asserting rather than reasoning about once, since the failure would be a
    // session that drops out from under someone mid-word.
    const cyrillic = "Привіт";
    try testing.expect(detachAt(cyrillic) == null);
    for (cyrillic) |byte| try testing.expect(byte != detach_key);

    const emoji = "🚀 працює";
    try testing.expect(detachAt(emoji) == null);
}

test "Ctrl-C is not the detach key" {
    // It has to keep reaching the agent: interrupting a turn is the first thing
    // anyone reaches for, and a detach there would look like a crash.
    try testing.expect(detachAt(&.{0x03}) == null);
    try testing.expect(detach_key != 0x03);
}
