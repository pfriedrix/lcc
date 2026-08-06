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
const ansi = @import("ansi.zig");
const app_mod = @import("app.zig");
const term = @import("term.zig");
const sessions_mod = @import("sessions.zig");
const watch_bar = @import("watch_bar.zig");
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

/// `\` — the key itself, once a terminal has stopped sending it as a byte.
const backslash = '\\';
/// The control code Ctrl-\ produces, which some terminals report in place of
/// the key when asked for a modified-key sequence.
const backslash_ctrl_code = 0x1c;

/// Where the detach key falls in a read, if it is there at all.
///
/// Three encodings, because Claude Code turns on two protocols that change how
/// the terminal reports a modified key, and both of those bytes pass straight
/// through lcc to the real terminal:
///
///   0x1c                  the legacy control code
///   CSI 92 ; <mods> u     kitty keyboard protocol — `CSI > 1 u`
///   CSI 27 ; <mods> ; N ~ xterm modifyOtherKeys=2 — `CSI > 4 ; 2 m`
///
/// Scanning for the byte alone was enough against `/bin/cat`, which enables
/// neither, and would have silently failed against the program this exists for
/// — leaving someone inside a session with no way back and a status bar
/// claiming otherwise.
///
/// Pure, so the one thing that can strand a user is testable without a terminal.
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

/// Whether a CSI body (everything after `ESC [`) is a modified backslash.
///
/// Only the ctrl bit is required: a terminal that folds shift or meta into the
/// same report should still detach rather than send the sequence to the agent,
/// which would do nothing with it either way.
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
            // Any other byte either ends the sequence as something else, or is
            // not part of one at all. Either way it is not a detach.
            else => return false,
        }
    }
    return false;
}

fn matches(final: u8, params: []const u32) bool {
    if (params.len < 2) return false;
    // Modifiers are reported as 1 + a bitmask, and ctrl is bit 2 (value 4).
    const ctrl = ((params[1] -| 1) & 4) != 0;
    if (!ctrl) return false;
    return switch (final) {
        // kitty: the keysym comes first.
        'u' => params[0] == backslash or params[0] == backslash_ctrl_code,
        // modifyOtherKeys: `27 ; mods ; keysym ~`.
        '~' => params[0] == 27 and params.len >= 3 and
            (params[2] == backslash or params[2] == backslash_ctrl_code),
        else => false,
    };
}

pub const Options = struct {
    session_id: []const u8,
    /// Replay the scrollback so the screen is repainted on arrival, rather than
    /// staying blank until the agent next prints.
    replay: bool = true,
    /// Reserve the bottom row for the status bar. The way back out is written
    /// there, so turning it off is opting out of the only durable reminder.
    status_bar: bool = true,
    /// Drawn on the reserved row beside the keys.
    peers: []const sessions_mod.Session = &.{},
};

/// Tees every byte in both directions to a file, for diagnosing a terminal that
/// is not the one lcc was developed against.
///
/// Keys are encoded by the *terminal*, and Claude Code turns on two protocols
/// that change that encoding. A pty in a test harness implements neither, so a
/// key that misbehaves under Ghostty or iTerm cannot be reproduced by reasoning
/// about it — only by reading what actually arrived.
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
    // Hex, because the interesting bytes are escapes and control codes that a
    // text dump would either hide or mangle.
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

    // Ordered so the terminal is always handed back intact, whatever happens:
    // restore the modes lcc set, then undo the ones the *child* set — the
    // program that would normally clean those up is still running, on purpose.
    defer {
        var exit_buf: [512]u8 = undefined;
        var out_writer: Io.File.Writer = .init(.stdout(), app.io, &exit_buf);
        watch_bar.release(&out_writer.interface);
        term.sanitize(&out_writer.interface);
        out_writer.interface.flush() catch {};
        terminal.restore();
        conn.close(app.io);
    }

    var bar_buf: [512]u8 = undefined;
    var out_buf: [8192]u8 = undefined;
    var bar_writer: Io.File.Writer = .init(.stdout(), app.io, &out_buf);
    var replay_filter: ansi.ModeFilter = .{};
    var filtered: [wire.max_payload + 64]u8 = undefined;

    // One row shorter than the terminal: the child lays out against what it is
    // told, so reserving a row means telling it the smaller number.
    const child_rows = childRows(size.rows, opts.status_bar);
    if (opts.status_bar) {
        watch_bar.reserve(&bar_writer.interface, size.rows);
        bar_writer.interface.flush() catch {};
    }

    try conn.sendControl(app.gpa, .attach, wire.Attach{
        .session_id = opts.session_id,
        .cols = size.cols,
        .rows = child_rows,
        .replay = opts.replay,
    });

    const sock = conn.stream.socket.handle;
    var in_buf: [4096]u8 = undefined;
    var peers = opts.peers;
    var peers_at: i64 = 0;

    while (true) {
        // Re-queried every iteration rather than driven by SIGWINCH, matching
        // `prompt.zig`. No handler to install, and no signal to miss.
        const now_size = terminal.size();
        if (now_size.rows != size.rows or now_size.cols != size.cols) {
            size = now_size;
            conn.sendControl(app.gpa, .resize, wire.Resize{
                .cols = size.cols,
                .rows = childRows(size.rows, opts.status_bar),
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
            note(dump, app.io, "key", chunk);
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
                // Scrollback, not live output. The child's terminal setup is
                // in there — replaying `CSI > 1 u` pushes a second level onto
                // the keyboard stack, after which the child and the terminal
                // disagree about how keys are encoded and its pickers stop
                // seeing Enter while the mouse keeps working.
                .replay => {
                    const kept = replay_filter.filter(frame.payload, &filtered);
                    note(dump, app.io, "replay", kept);
                    paintBar(app, &bar_writer, &bar_buf, opts, &peers, &peers_at, size);
                    writeAll(chunk_stdout, kept);
                },
                .output => {
                    note(dump, app.io, "out", frame.payload);
                    paintBar(app, &bar_writer, &bar_buf, opts, &peers, &peers_at, size);
                    writeAll(chunk_stdout, frame.payload);
                },
                .exited => return .ended,
                else => {},
            };
        }
    }
}

/// Repaint the reserved row, immediately before the caller writes the child's
/// own output.
///
/// The order is the point. The child's bytes follow within microseconds and
/// carry its own cursor positioning, so the cursor is never left sitting in the
/// bar — and nothing here has to know, save, or guess where it was. While the
/// child is silent this is not called at all: nothing has changed, and a row
/// nobody has disturbed does not need repainting.
fn paintBar(
    app: app_mod.App,
    writer: *Io.File.Writer,
    buf: []u8,
    opts: Options,
    peers: *[]const sessions_mod.Session,
    peers_at: *i64,
    size: term.Size,
) void {
    if (!opts.status_bar) return;
    const at = app_mod.nowSeconds(app.io);
    // Reasserted unconditionally rather than only when the child was seen to
    // reclaim it. Claude Code emits a bare `CSI r` early, and anything else it
    // runs may do the same — six bytes on every burst is cheaper than a scanner
    // whose only job is to decide whether to send them.
    watch_bar.reserve(&writer.interface, size.rows);
    // A snapshot is a socket round trip, so it is refreshed on its own slow
    // clock rather than on every burst of output.
    if (at - peers_at.* >= 2) {
        if (watch_client.snapshot(app) catch null) |fresh| peers.* = fresh;
        peers_at.* = at;
    }
    watch_bar.draw(
        &writer.interface,
        size.rows,
        // One column short: filling the last cell leaves the terminal poised
        // to wrap, and what happens then is the emulator's decision, not ours.
        watch_bar.compose(buf, peers.*, opts.session_id, size.cols -| 1),
    );
}

/// What the child is told the terminal is. One row is kept back for the bar,
/// and a terminal too short to spare one keeps all of them.
fn childRows(rows: u16, status_bar: bool) u16 {
    if (!status_bar or rows < 3) return rows;
    return rows - 1;
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

test "the detach key is found in every encoding a terminal may send it as" {
    // The legacy byte, which is all `/bin/cat` ever produces.
    try testing.expectEqual(@as(usize, 0), detachAt(&.{detach_key}).?);

    // kitty keyboard protocol, which Claude Code turns on with `CSI > 1 u`.
    try testing.expectEqual(@as(usize, 0), detachAt("\x1b[92;5u").?);
    try testing.expectEqual(@as(usize, 4), detachAt("abcd\x1b[92;5u").?);
    // Some report the control code rather than the key.
    try testing.expect(detachAt("\x1b[28;5u") != null);
    // Shift or meta folded in alongside ctrl still counts.
    try testing.expect(detachAt("\x1b[92;7u") != null);

    // xterm modifyOtherKeys=2, which it turns on with `CSI > 4 ; 2 m`.
    try testing.expect(detachAt("\x1b[27;5;92~") != null);
    try testing.expect(detachAt("\x1b[27;5;28~") != null);

    // Without ctrl it is a plain backslash and belongs to the agent.
    try testing.expect(detachAt("\x1b[92;1u") == null);
    try testing.expect(detachAt("\x1b[27;1;92~") == null);
    // A different key with ctrl is not a detach either.
    try testing.expect(detachAt("\x1b[99;5u") == null);
    try testing.expect(detachAt("\x1b[27;5;99~") == null);
}

test "ordinary output and other escapes are not mistaken for it" {
    try testing.expect(detachAt("hello") == null);
    try testing.expectEqual(@as(usize, 3), detachAt("abc\x1cdef").?);
    try testing.expectEqual(@as(usize, 5), detachAt("hello\x1c").?);
    try testing.expect(detachAt("") == null);

    // Arrow keys, function keys and a bare Esc all reach the agent untouched.
    for ([_][]const u8{ "\x1b[A", "\x1b[B", "\x1b", "\x1b[1;5C", "\x1b[200~pasted\x1b[201~" }) |seq| {
        try testing.expect(detachAt(seq) == null);
    }
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

test "the child is told one row less, unless there is none to spare" {
    try testing.expectEqual(@as(u16, 39), childRows(40, true));
    // Opted out: the child gets the whole screen.
    try testing.expectEqual(@as(u16, 40), childRows(40, false));
    // Too short to give a row away — taking one here would leave almost nothing
    // to render into, which looks like a hang rather than a small window.
    try testing.expectEqual(@as(u16, 2), childRows(2, true));
    try testing.expectEqual(@as(u16, 1), childRows(1, true));
}

test "Ctrl-C is not the detach key" {
    // It has to keep reaching the agent: interrupting a turn is the first thing
    // anyone reaches for, and a detach there would look like a crash.
    try testing.expect(detachAt(&.{0x03}) == null);
    try testing.expect(detach_key != 0x03);
}
