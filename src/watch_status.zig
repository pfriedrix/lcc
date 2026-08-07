const std = @import("std");
const sessions = @import("sessions.zig");
const watch_hooks = @import("watch_hooks.zig");

pub const Status = sessions.Status;
pub const Event = watch_hooks.Event;

pub const active_decay_seconds: i64 = 15 * 60;

pub fn apply(current: Status, event: Event) Status {
    if (current == .exited) return .exited;
    return switch (event) {
        .waiting => .waiting,
        .active => .active,
        .idle => .idle,
        .ended => .exited,
    };
}

pub fn decay(current: Status, seconds_since_event: i64) Status {
    const elapsed = @max(0, seconds_since_event);
    return switch (current) {
        .active, .starting => if (elapsed > active_decay_seconds) .waiting else current,
        else => current,
    };
}

pub fn resolve(current: Status, last_event_at: i64, now: i64) Status {
    return decay(current, now - last_event_at);
}

pub fn present(current: Status, plan: bool) Status {
    if (!plan) return current;
    return switch (current) {
        .active, .idle => .plan,
        .starting, .waiting, .exited, .unknown, .plan => current,
    };
}

const testing = std.testing;

test "a reported event replaces the status, whatever it was" {
    try testing.expectEqual(Status.waiting, apply(.active, .waiting));
    try testing.expectEqual(Status.active, apply(.waiting, .active));
    try testing.expectEqual(Status.idle, apply(.active, .idle));
    try testing.expectEqual(Status.active, apply(.idle, .active));
    try testing.expectEqual(Status.active, apply(.starting, .active));
}

test "exited is terminal, so a late hook cannot resurrect a dead session" {
    for ([_]Event{ .waiting, .active, .idle, .ended }) |event| {
        try testing.expectEqual(Status.exited, apply(.exited, event));
    }
}

test "SessionEnd reports exited without waiting for the reap" {
    try testing.expectEqual(Status.exited, apply(.active, .ended));
    try testing.expectEqual(Status.exited, apply(.waiting, .ended));
}

test "a turn that went silent asks for a person, rather than claiming it finished" {
    try testing.expectEqual(Status.active, decay(.active, active_decay_seconds));
    try testing.expectEqual(Status.waiting, decay(.active, active_decay_seconds + 1));
    try testing.expectEqual(Status.waiting, decay(.starting, active_decay_seconds + 1));

    try testing.expect(decay(.active, active_decay_seconds + 1) != .idle);

    try testing.expectEqual(Status.waiting, decay(.waiting, active_decay_seconds * 100));
    try testing.expectEqual(Status.idle, decay(.idle, active_decay_seconds * 100));
    try testing.expectEqual(Status.exited, decay(.exited, active_decay_seconds * 100));
}

test "a clock that moved backwards is not a very long silence" {
    try testing.expectEqual(Status.active, decay(.active, -active_decay_seconds * 10));
    try testing.expectEqual(Status.active, resolve(.active, 2_000, 1_000));
}

test "resolve is decay expressed against a wall clock" {
    try testing.expectEqual(Status.active, resolve(.active, 1_000, 1_000 + active_decay_seconds));
    try testing.expectEqual(Status.waiting, resolve(.active, 1_000, 1_000 + active_decay_seconds + 1));
    try testing.expectEqual(Status.waiting, resolve(.waiting, 1_000, 1_000 + 86_400));
}

test "every hook event maps to a status a session can actually be in" {
    for ([_]Event{ .waiting, .active, .idle, .ended }) |event| {
        const status = apply(.starting, event);
        try testing.expect(status != .unknown);
        try testing.expect(status != .plan);
    }
}

test "plan mode replaces working, and never replaces being blocked" {
    try testing.expectEqual(Status.plan, present(.active, true));
    try testing.expectEqual(Status.plan, present(.idle, true));

    try testing.expectEqual(Status.waiting, present(.waiting, true));

    try testing.expectEqual(Status.exited, present(.exited, true));
    try testing.expectEqual(Status.unknown, present(.unknown, true));
    try testing.expectEqual(Status.starting, present(.starting, true));
}

test "without plan mode, present changes nothing at all" {
    for ([_]Status{ .starting, .active, .waiting, .idle, .plan, .exited, .unknown }) |status| {
        try testing.expectEqual(status, present(status, false));
    }
}
