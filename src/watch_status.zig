//! What a session's status is, given what its hooks have reported.
//!
//! A pure transition function over `watch_hooks.Event`, plus one time-based
//! safety net. It replaced a pattern table matched against stripped pty output;
//! the reasoning for that is in `watch_hooks.zig`.
//!
//! The daemon owns `exited` — `waitpid` answers it, not a hook, because a
//! process that died in a way that skipped `SessionEnd` still died.
//!
//! Plan mode is *projected* here rather than applied. It is a mode, not a
//! transition: nothing fires when a plan is approved — the next hook that
//! carries a `permission_mode` simply reports a different one. Modelling it as
//! a state would put a "which mode am I in" question inside `apply` and a
//! "does this decay" question inside `decay`, to describe something neither of
//! them drives. So the session keeps its lifecycle status, carries plan mode
//! beside it, and `present` decides what the two of them add up to.

const std = @import("std");
const sessions = @import("sessions.zig");
const watch_hooks = @import("watch_hooks.zig");

pub const Status = sessions.Status;
pub const Event = watch_hooks.Event;

/// How long a session may sit in `active` with nothing further reported before
/// the dashboard stops believing the turn is still moving.
///
/// A backstop for the hook that never arrived — a handler that failed, a
/// `--settings` that did not reach the session, a Claude Code killed mid-turn.
/// Generous, because a long tool call is ordinary and giving up on a session
/// that is genuinely working is worse than showing it busy a little too long.
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
/// Silence resolves to `waiting`, never to `idle`. `idle` is a positive claim —
/// "the turn finished, come back whenever" — and the only thing that licenses it
/// is a `Stop`. What this function actually knows is that a turn was in flight
/// and nothing has been reported about it for a quarter of an hour, which is the
/// opposite of finished: either the turn is wedged, or it is blocked on
/// something whose notification never reached the daemon. Both want a person,
/// and `waiting` is how a row says so.
///
/// This was `idle`, and the cost of that was the whole point of the dashboard:
/// the one session that had stopped and needed looking at was painted the same
/// dim `○ idle` as every session that had finished cleanly, so it read as the
/// row you could safely ignore.
///
/// Only `active` and `starting` decay. `waiting` has nowhere further to go — a
/// permission prompt left unanswered overnight is still a permission prompt. And
/// `idle` must not move: a session that reported `Stop` really is finished, and
/// ageing it into `waiting` would claim attention for every row already dealt
/// with, which is the same signal-destroying move in the other direction.
pub fn decay(current: Status, seconds_since_event: i64) Status {
    // A clock that moved backwards reads as no time passed, never as a very
    // long time — the same clamp `remote_cache.fresh` applies.
    const elapsed = @max(0, seconds_since_event);
    return switch (current) {
        .active, .starting => if (elapsed > active_decay_seconds) .waiting else current,
        else => current,
    };
}

/// The status a session should be shown as, from its last event and when it
/// arrived. `now` is a parameter so this stays pure and its tests use literals.
pub fn resolve(current: Status, last_event_at: i64, now: i64) Status {
    return decay(current, now - last_event_at);
}

/// The lifecycle status and plan mode, combined into the one thing a row shows.
///
/// Only `active` and `idle` give way. The rest outrank plan mode, each for its
/// own reason:
///
/// `waiting` because it is the only status that means "go here now", and the
/// moment plan mode matters most — the approval prompt at the end of a plan —
/// *is* a permission prompt. Showing `plan` there would replace the signal the
/// dashboard exists for with a restatement of something the user already knows.
///
/// `exited` and `orphan` because they are facts about the process and the
/// worktree rather than about what the agent is doing, and `unknown` because it
/// means nothing on disk can be believed — including this.
///
/// `starting` because it means the child has not produced a byte yet, which
/// plan mode does not contradict; it lasts under a second, and its own decay
/// runs off the lifecycle field either way.
pub fn present(current: Status, plan: bool) Status {
    if (!plan) return current;
    return switch (current) {
        .active, .idle => .plan,
        .starting, .waiting, .exited, .orphan, .unknown, .plan => current,
    };
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

test "a turn that went silent asks for a person, rather than claiming it finished" {
    // The backstop for a hook that never arrived — a failed handler, or a
    // --settings that did not reach the session.
    try testing.expectEqual(Status.active, decay(.active, active_decay_seconds));
    try testing.expectEqual(Status.waiting, decay(.active, active_decay_seconds + 1));
    try testing.expectEqual(Status.waiting, decay(.starting, active_decay_seconds + 1));

    // Stated as the thing it must never be, because that is the bug: silence
    // means lcc lost track of a turn that had not ended, and `idle` means one
    // that had. Sent there, the single row that needed opening was painted the
    // same dim circle as every row that needed nothing.
    try testing.expect(decay(.active, active_decay_seconds + 1) != .idle);

    // A permission prompt left overnight is still a permission prompt. Ageing
    // it away would hide the one state the user has to act on, and would do it
    // precisely when they have been away longest.
    try testing.expectEqual(Status.waiting, decay(.waiting, active_decay_seconds * 100));
    // And the other direction is just as destructive: a session that really did
    // report `Stop` is finished, and letting it age into `waiting` would light
    // up every row the user has already dealt with.
    try testing.expectEqual(Status.idle, decay(.idle, active_decay_seconds * 100));
    // Nothing resurrects a dead session either.
    try testing.expectEqual(Status.exited, decay(.exited, active_decay_seconds * 100));
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
    try testing.expectEqual(Status.waiting, resolve(.active, 1_000, 1_000 + active_decay_seconds + 1));
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
        // Nor `plan`, which is derived rather than reported. Routing an event
        // to it here would compile and would put a mode into the lifecycle
        // field, where the decay and the `exited` guard would then have to
        // reason about it — the thing `present` exists to avoid.
        try testing.expect(status != .plan);
    }
}

test "plan mode replaces working, and never replaces being blocked" {
    // The two that give way. `lcc start` launches every session in plan mode,
    // so "a turn is in flight" is nearly always true and nearly never the thing
    // worth a column; "has this been approved to touch files" is.
    try testing.expectEqual(Status.plan, present(.active, true));
    try testing.expectEqual(Status.plan, present(.idle, true));

    // The one that must not. `waiting` is the only status meaning "go here
    // now", and the approval prompt at the end of a plan is a permission
    // prompt — precisely where showing `plan` would trade the signal the
    // dashboard exists for against a restatement of what the user just did.
    try testing.expectEqual(Status.waiting, present(.waiting, true));

    // Facts about the process and the worktree, not about what the agent is
    // doing. A dead session in plan mode is dead, and one whose worktree was
    // deleted is still the row most worth seeing.
    try testing.expectEqual(Status.exited, present(.exited, true));
    try testing.expectEqual(Status.orphan, present(.orphan, true));
    // `unknown` means nothing on disk can be believed, and that includes the
    // mode the same file reported.
    try testing.expectEqual(Status.unknown, present(.unknown, true));
    // And the child has not spoken yet, which plan mode does not contradict.
    try testing.expectEqual(Status.starting, present(.starting, true));
}

test "without plan mode, present changes nothing at all" {
    // The property that lets every existing caller keep its behaviour: for a
    // session that is not planning this is the identity, so nothing about the
    // other six statuses moved when `plan` was added.
    for ([_]Status{ .starting, .active, .waiting, .idle, .plan, .exited, .orphan, .unknown }) |status| {
        try testing.expectEqual(status, present(status, false));
    }
}
