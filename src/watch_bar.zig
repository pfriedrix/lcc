//! The one row an attached session cannot reach: what it says, and the scroll
//! region that reserves it.
//!
//! Not an overlay drawn on top of the child's rows. That approach loses: Claude
//! Code repaints its bottom UI many times a second while streaming and would
//! clobber anything drawn there within a frame or two. Instead the child is
//! told the terminal is one row shorter and a scroll region keeps its output
//! inside those rows, so the last line is somewhere it physically cannot write.
//! That is how tmux does it, and it is why there is no flicker to manage.
//!
//! The row exists mainly to answer a question the attach path cannot otherwise
//! answer: **how do I get back?** `^\` is undiscoverable, and a hint printed
//! before passthrough scrolls away within seconds — after which the user is
//! inside Claude Code with no visible way out and no reason to think there is
//! one. A line the child cannot overwrite is the only place that stays put.

const std = @import("std");
const Io = std.Io;
const sessions = @import("sessions.zig");
const term = @import("term.zig");
const ui = @import("ui.zig");
const watch_table = @import("watch_table.zig");

/// Reserve every row but the last for the child.
///
/// Must be re-issued whenever `ansi.Scanner` reports a scroll region going
/// past: Claude Code emits a bare `CSI r` as its second command, and a bar that
/// set this once at attach would lose the row immediately.
pub fn reserve(out: *Io.Writer, rows: u16) void {
    if (rows < 2) return;
    out.print(term.csi ++ "1;{d}r", .{rows - 1}) catch {};
}

/// Hand the whole screen back. `term.sanitize` also emits this, so a detach
/// that skips the bar entirely still cannot strand a scroll region.
pub fn release(out: *Io.Writer) void {
    out.writeAll(term.csi ++ "r") catch {};
}

/// Paint the reserved row without disturbing where the child left its cursor.
///
/// Save, jump outside the scroll region, draw, restore. The child's cursor
/// position is part of its rendering state — moving it and not putting it back
/// would corrupt the next thing it draws.
pub fn draw(out: *Io.Writer, rows: u16, text: []const u8) void {
    if (rows < 2) return;
    const p = ui.palette();
    // Reverse video across the whole row, so it reads as a bar rather than as a
    // line of output that happens to be at the bottom. `CSI K` after the text
    // extends the inverted background to the edge without padding with spaces,
    // which would have to be counted against the width.
    // `CSI 2K` with reverse video already on paints the whole row, so the
    // background reaches the edge without the text having to. Nothing is
    // written after it — a second erase once the cursor sits in the last
    // column is where the trailing characters were going.
    out.print("\x1b7" ++ term.csi ++ "{d};1H" ++ term.csi ++ "7m" ++ term.csi ++ "2K", .{rows}) catch {};
    out.writeAll(text) catch {};
    out.writeAll(p.reset) catch {};
    out.writeAll("\x1b8") catch {};
    out.flush() catch {};
}

/// The key, which is the reason the row exists.
///
/// One binding and nothing else. It briefly also said `^C→agent`, meaning
/// "Ctrl-C still reaches Claude Code" — but on a row of keybindings everything
/// reads as a key you press, so it looked like a third shortcut whose effect
/// nobody could guess. A reassurance that has to be decoded is worse than the
/// doubt it was answering.
pub const keys = "^\\ dashboard";

/// The glyph for a session on the bar.
///
/// The attached one is a *filled* ring rather than the same glyph with a marker
/// beside it. A separate `*` sat outside the circle and read as punctuation;
/// filling the shape says "you are here" in the same place the eye is already
/// looking. Colour still carries the status, so nothing is lost by spending the
/// shape on selection.
fn barGlyph(session: sessions.Session, attached: bool) []const u8 {
    if (!attached) return watch_table.glyph(session.parsedStatus());
    return "◉";
}

/// What the row says: the sessions, numbered, then the keys.
///
/// Truncated from the left-hand end — the session list is the part that can be
/// cut, because the keys are the part someone is looking for when they read it.
pub fn compose(
    buf: []u8,
    list: []const sessions.Session,
    current_id: []const u8,
    cols: usize,
) []const u8 {
    // Display width, not `keys.len`: the separators are `·` and `→`, which are
    // two and three bytes. Budgeting in bytes reserves more room than the text
    // occupies and leaves the bar short of the width it was asked for.
    const keys_width = ui.displayWidth(keys);
    if (cols < keys_width + 2) return term.truncate(keys, cols);

    var w: Io.Writer = .fixed(buf);
    const budget = cols - keys_width - 2;
    var used: usize = 0;

    const p = ui.palette();
    var shown: usize = 0;
    for (list) |s| {
        // A finished session is not somewhere you can go. It lingers in the
        // registry for a few minutes so the dashboard can say what became of
        // it, but on a switcher it is a number that does nothing — and when a
        // worktree has been restarted it sits there as a second entry with the
        // same name as the live one.
        if (s.parsedStatus() == .exited) continue;
        const label = s.issue orelse s.branch;
        const attached = std.mem.eql(u8, s.id, current_id);
        const glyph = barGlyph(s, attached);
        // glyph + one space + label + one trailing space. Counting a column
        // that is not printed leaves the row short of the width it padded for,
        // and the right-aligned keys lose their last characters.
        const cost = ui.displayWidth(glyph) + 1 + ui.displayWidth(label) + 1;
        if (used + cost > budget) break;
        shown += 1;
        // No numbers. They were a key you could press, and there is no such
        // key — the bar was advertising a switch that does not exist.
        //
        // Colour on the glyph alone. Painting the label too made a whole entry
        // one colour, which reads as an alert rather than as a status, and
        // with several sessions the row becomes competing signals instead of a
        // list.
        w.print("{s}{s}{s} {s}{s}{s} ", .{
            watch_table.paint(s.parsedStatus(), p),
            glyph,
            p.reset,
            if (attached) p.bold else p.dim,
            label,
            p.reset,
        }) catch break;
        used += cost;
    }

    // Right-aligned keys, so they sit in the same place whatever the list does.
    const pad = cols - used - keys_width;
    w.splatByteAll(' ', pad) catch {};
    w.writeAll(p.dim) catch {};
    w.writeAll(keys) catch {};
    w.writeAll(p.reset) catch {};
    return w.buffered();
}

const testing = std.testing;

fn testSessions() []const sessions.Session {
    const S = struct {
        const list = [_]sessions.Session{
            .{ .id = "s-1", .issue = "PE-256", .branch = "feature/a", .status = "waiting" },
            .{ .id = "s-2", .issue = "PE-270", .branch = "feature/b", .status = "active" },
            .{ .id = "s-3", .issue = null, .branch = "feature/c", .status = "idle" },
            // Restarted: the finished one lingers in the registry beside the
            // live one, under the same name.
            .{ .id = "s-4", .issue = "PE-256", .branch = "feature/a", .status = "exited" },
        };
    };
    return &S.list;
}

test "a finished session is not offered as somewhere to go" {
    var buf: [512]u8 = undefined;
    ui.setColor(false);
    const out = compose(&buf, testSessions(), "s-1", 100);
    // PE-256 appears once — the live one — not twice with its own corpse.
    var count: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, out, at, "PE-256")) |found| : (at = found + 1) count += 1;
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expect(std.mem.indexOf(u8, out, "✗") == null);
}

test "the row reserves every line but the last" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    reserve(&w, 40);
    // Rows 1..39 belong to the child; row 40 is ours and it cannot scroll into
    // it, which is the whole mechanism.
    try testing.expectEqualStrings(term.csi ++ "1;39r", w.buffered());
}

test "a terminal too short for a bar gets no scroll region at all" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    // `CSI 1;0r` would be a degenerate region, and a one-row terminal has no
    // room to give up. Better to render nothing than to wedge the session.
    reserve(&w, 1);
    try testing.expectEqual(@as(usize, 0), w.end);
    draw(&w, 1, "anything");
    try testing.expectEqual(@as(usize, 0), w.end);
}

test "drawing restores the cursor the child left behind" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    ui.setColor(false);
    draw(&w, 24, "hello");
    const out = w.buffered();

    // Save first and restore last: the cursor position is part of the child's
    // rendering state, and leaving it moved corrupts whatever it draws next.
    try testing.expect(std.mem.startsWith(u8, out, "\x1b7"));
    try testing.expect(std.mem.endsWith(u8, out, "\x1b8"));
    // Jump to the reserved row and clear it before writing, or yesterday's
    // longer text shows through behind today's.
    try testing.expect(std.mem.indexOf(u8, out, term.csi ++ "24;1H") != null);
    try testing.expect(std.mem.indexOf(u8, out, term.csi ++ "2K") != null);
}

test "the keys are always present, and the session list is what gets cut" {
    var buf: [512]u8 = undefined;
    ui.setColor(false);

    const wide = compose(&buf, testSessions(), "s-1", 100);
    try testing.expect(std.mem.indexOf(u8, wide, keys) != null);
    try testing.expect(std.mem.indexOf(u8, wide, "PE-256") != null);
    try testing.expect(std.mem.indexOf(u8, wide, "PE-270") != null);
    try testing.expectEqual(@as(usize, 100), ui.displayWidth(wide));

    // Narrow: sessions fall off, the way back does not. Someone reading this row
    // is looking for the way out, not for a roster.
    var narrow_buf: [512]u8 = undefined;
    const narrow = compose(&narrow_buf, testSessions(), "s-1", 30);
    try testing.expect(std.mem.indexOf(u8, narrow, keys) != null);
    try testing.expect(ui.displayWidth(narrow) <= 30);

    // Narrower than the keys themselves: keep what fits rather than wrapping,
    // since a wrapped bar would scroll the child's output.
    var tiny_buf: [512]u8 = undefined;
    const tiny = compose(&tiny_buf, testSessions(), "s-1", 10);
    try testing.expect(ui.displayWidth(tiny) <= 10);
}

test "the attached session is marked, the others are not" {
    var buf: [512]u8 = undefined;
    ui.setColor(false);
    const out = compose(&buf, testSessions(), "s-2", 100);

    // The attached session's ring is filled; the others keep their status
    // glyph. A marker beside the circle read as punctuation — filling the shape
    // says "you are here" where the eye is already looking.
    try testing.expect(std.mem.indexOf(u8, out, "◉ PE-270") != null);
    try testing.expect(std.mem.indexOf(u8, out, "● PE-256") != null);
    try testing.expect(std.mem.indexOf(u8, out, "*") == null);

    // No numbers: they read as keys you could press, and there is none.
    try testing.expect(std.mem.indexOf(u8, out, "1 ") == null);
    try testing.expect(std.mem.indexOf(u8, out, "2 ") == null);
}

test "a bar never exceeds the width it was given" {
    ui.setColor(false);
    // Overflowing wraps, and a wrapped bar scrolls the child's screen — the one
    // failure mode that corrupts the session rather than just looking wrong.
    for ([_]usize{ 200, 120, 80, 60, 40, 30, 24, 12, 8, 4 }) |cols| {
        var buf: [1024]u8 = undefined;
        const out = compose(&buf, testSessions(), "s-1", cols);
        if (ui.displayWidth(out) > cols) {
            std.debug.print("at {d} cols the bar is {d} wide: \"{s}\"\n", .{ cols, ui.displayWidth(out), out });
            return error.TestExpectedEqual;
        }
    }
}
