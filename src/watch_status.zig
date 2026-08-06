//! What a session's status is, given what its hooks have reported.
//!
//! A pure transition function over `watch_hooks.Event`, plus one time-based
//! safety net. It replaced a pattern table matched against stripped pty output;
//! the reasoning for that is in `watch_hooks.zig`.
//!
//! The daemon owns `exited` — `waitpid` answers it, not a hook, because a
//! process that died in a way that skipped `SessionEnd` still died.

const std = @import("std");
const sessions = @import("sessions.zig");
const watch_hooks = @import("watch_hooks.zig");

pub const Status = sessions.Status;
pub const Event = watch_hooks.Event;

/// How long a session may sit in `active` with nothing further reported before
/// it decays to `idle`.
///
/// A backstop for the hook that never arrived — a handler that failed, a
/// `--settings` that did not reach the session, a Claude Code killed mid-turn.
/// Generous, because a long tool call is ordinary and a session wrongly shown
/// as finished is worse than one shown as busy a little too long.
pub const active_decay_seconds: i64 = 15 * 60;

/// A single reported event applied to the status a session already had.
///
/// `exited` is terminal: a dead child cannot become busy again, and a late
/// hook arriving after the process is gone must not resurrect the row.
pub fn apply(current: Status, event: Event) Status {
    if (current == .exited) return .exited;
    return switch (event) {
        .waiting => .waiting,
        .active => .active,
        .idle => .idle,
        .ended => .exited,
    };
}

/// The status after `elapsed` seconds without a further event.
///
/// Only `active` and `starting` decay. `waiting` must not: a permission prompt
/// left unanswered overnight is still a permission prompt, and ageing it into
/// `idle` would hide the one state the user actually has to act on.
pub fn decay(current: Status, seconds_since_event: i64) Status {
    // A clock that moved backwards reads as no time passed, never as a very
    // long time — the same clamp `remote_cache.fresh` applies.
    const elapsed = @max(0, seconds_since_event);
    return switch (current) {
        .active, .starting => if (elapsed > active_decay_seconds) .idle else current,
        else => current,
    };
}

/// The status a session should be shown as, from its last event and when it
/// arrived. `now` is a parameter so this stays pure and its tests use literals.
pub fn resolve(current: Status, last_event_at: i64, now: i64) Status {
    return decay(current, now - last_event_at);
}

const testing = std.testing;

test "a reported event replaces the status, whatever it was" {
    // The whole point of using hooks: no precedence puzzle, no time window, no
    // guess. Claude Code said what happened, so that is the status.
    try testing.expectEqual(Status.waiting, apply(.active, .waiting));
    try testing.expectEqual(Status.active, apply(.waiting, .active));
    try testing.expectEqual(Status.idle, apply(.active, .idle));
    try testing.expectEqual(Status.active, apply(.idle, .active));
    try testing.expectEqual(Status.active, apply(.starting, .active));
}

test "exited is terminal, so a late hook cannot resurrect a dead session" {
    // Hooks are async and the child may already have been reaped when one
    // lands. Without this the dashboard would show a session as busy while its
    // process no longer exists.
    for ([_]Event{ .waiting, .active, .idle, .ended }) |event| {
        try testing.expectEqual(Status.exited, apply(.exited, event));
    }
}

test "SessionEnd reports exited without waiting for the reap" {
    try testing.expectEqual(Status.exited, apply(.active, .ended));
    try testing.expectEqual(Status.exited, apply(.waiting, .ended));
}

test "active decays to idle, but waiting never does" {
    // The backstop for a hook that never arrived — a failed handler, or a
    // --settings that did not reach the session.
    try testing.expectEqual(Status.active, decay(.active, active_decay_seconds));
    try testing.expectEqual(Status.idle, decay(.active, active_decay_seconds + 1));
    try testing.expectEqual(Status.idle, decay(.starting, active_decay_seconds + 1));

    // A permission prompt left overnight is still a permission prompt. Ageing
    // it away would hide the one state the user has to act on, and would do it
    // precisely when they have been away longest.
    try testing.expectEqual(Status.waiting, decay(.waiting, active_decay_seconds * 100));
    // And nothing resurrects a finished session.
    try testing.expectEqual(Status.exited, decay(.exited, active_decay_seconds * 100));
    try testing.expectEqual(Status.idle, decay(.idle, active_decay_seconds * 100));
}

test "a clock that moved backwards is not a very long silence" {
    // NTP can step the wall clock backwards. Read naively, `now - then` goes
    // negative and a comparison against the window would flip — this clamps it
    // to "no time has passed", which is the safe direction.
    try testing.expectEqual(Status.active, decay(.active, -active_decay_seconds * 10));
    try testing.expectEqual(Status.active, resolve(.active, 2_000, 1_000));
}

test "resolve is decay expressed against a wall clock" {
    try testing.expectEqual(Status.active, resolve(.active, 1_000, 1_000 + active_decay_seconds));
    try testing.expectEqual(Status.idle, resolve(.active, 1_000, 1_000 + active_decay_seconds + 1));
    try testing.expectEqual(Status.waiting, resolve(.waiting, 1_000, 1_000 + 86_400));
}

test "every hook event maps to a status a session can actually be in" {
    // Guards against adding an Event with nowhere to go: the switch in `apply`
    // is exhaustive, so a new variant fails to compile — but a variant mapped
    // to `unknown` or `orphan` would compile and be wrong, since neither is
    // something a running session reports about itself.
    for ([_]Event{ .waiting, .active, .idle, .ended }) |event| {
        const status = apply(.starting, event);
        try testing.expect(status != .unknown);
        try testing.expect(status != .orphan);
    }
}
