const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");

pub const Error = error{SocketPathTooLong} || std.mem.Allocator.Error || error{NoHomeDirectory};

pub const sun_path_max = 104;
pub const socket_path_max = sun_path_max - 1;

pub fn checkSocketPath(path: []const u8) error{SocketPathTooLong}!void {
    if (path.len > socket_path_max) return error.SocketPathTooLong;
}

pub fn dir(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("LCC_WATCH_DIR")) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) return gpa.dupe(u8, override);
    }
    return config.dir(gpa, environ);
}

pub fn socket(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) Error![]const u8 {
    const base = try dir(gpa, environ);
    const path = try std.fs.path.join(gpa, &.{ base, "daemon.sock" });
    try checkSocketPath(path);
    return path;
}

pub fn lock(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    const base = try dir(gpa, environ);
    return std.fs.path.join(gpa, &.{ base, "daemon.lock" });
}

pub fn hooksFor(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    session_id: []const u8,
) ![]const u8 {
    const base = try dir(gpa, environ);
    const name = try std.fmt.allocPrint(gpa, "hooks-{s}.json", .{session_id});
    return std.fs.path.join(gpa, &.{ base, name });
}

pub const state_prefix = "state-";
pub const state_suffix = ".json";

pub fn stateFor(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    claude_session_id: []const u8,
) ![]const u8 {
    const base = try dir(gpa, environ);
    const name = try std.fmt.allocPrint(gpa, state_prefix ++ "{s}" ++ state_suffix, .{claude_session_id});
    return std.fs.path.join(gpa, &.{ base, name });
}

pub fn stateName(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, state_prefix)) return null;
    if (!std.mem.endsWith(u8, name, state_suffix)) return null;
    const id = name[state_prefix.len .. name.len - state_suffix.len];
    return if (id.len == 0) null else id;
}

pub fn logFile(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("LCC_WATCH_DIR")) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) return std.fs.path.join(gpa, &.{ override, "daemon.log" });
    }
    _ = try config.dir(gpa, environ);
    const home = environ.get("HOME").?;
    return std.fs.path.join(gpa, &.{ home, ".cache", "lcc", "daemon.log" });
}

test "a socket path past Darwin's sun_path is refused here, because std will not" {
    const ok = "a" ** socket_path_max;
    try checkSocketPath(ok);

    try std.testing.expectError(error.SocketPathTooLong, checkSocketPath("a" ** (socket_path_max + 1)));
    try std.testing.expectError(error.SocketPathTooLong, checkSocketPath("a" ** 108));
}

test "LCC_WATCH_DIR moves the socket, the lock and the hooks together" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_WATCH_DIR", "/tmp/lcc-test");

    try std.testing.expectEqualStrings("/tmp/lcc-test/daemon.sock", try socket(arena, &environ));
    try std.testing.expectEqualStrings("/tmp/lcc-test/daemon.lock", try lock(arena, &environ));
    try std.testing.expectEqualStrings("/tmp/lcc-test/daemon.log", try logFile(arena, &environ));
}

test "each session gets a settings file of its own, named for it" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_WATCH_DIR", "/tmp/lcc-test");

    try std.testing.expectEqualStrings(
        "/tmp/lcc-test/hooks-s-00000001.json",
        try hooksFor(arena, &environ, "s-00000001"),
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        try hooksFor(arena, &environ, "s-00000001"),
        try hooksFor(arena, &environ, "s-00000002"),
    ));
}

test "a session's recovered state is filed under Claude Code's id, not the one lcc reissues" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("LCC_WATCH_DIR", "/tmp/lcc-test");

    const uuid = "529ae132-1fc2-4cbd-a909-585f29f46f62";
    try std.testing.expectEqualStrings(
        "/tmp/lcc-test/state-" ++ uuid ++ ".json",
        try stateFor(arena, &environ, uuid),
    );

    const first = try stateFor(arena, &environ, "s-00000001");
    const hooks = try hooksFor(arena, &environ, "s-00000001");
    if (std.mem.eql(u8, first, hooks)) {
        std.debug.print(
            "the state file and the hook settings collide on one name: writing a status " ++
                "report would overwrite the settings the session was launched with.\n",
            .{},
        );
        return error.TestUnexpectedResult;
    }
}

test "a state file names the session it came from, and nothing else in the directory does" {
    try std.testing.expectEqualStrings("abc-123", stateName("state-abc-123.json").?);

    try std.testing.expect(stateName("state-.json") == null);
    try std.testing.expect(stateName("hooks-s-00000001.json") == null);
    try std.testing.expect(stateName("sessions.json") == null);
    try std.testing.expect(stateName("daemon.sock") == null);
    try std.testing.expect(stateName("state-abc-123.json.tmp") == null);
}

test "an empty override is not an override" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", "/home/someone");
    try environ.put("LCC_WATCH_DIR", "");
    try std.testing.expectEqualStrings("/home/someone/.config/lcc/daemon.sock", try socket(arena, &environ));

    try environ.put("LCC_WATCH_DIR", "   ");
    try std.testing.expectEqualStrings("/home/someone/.config/lcc/daemon.sock", try socket(arena, &environ));
}

test "the log lands in the cache directory, apart from the state" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", "/home/someone");

    try std.testing.expectEqualStrings("/home/someone/.cache/lcc/daemon.log", try logFile(arena, &environ));
    try std.testing.expectEqualStrings("/home/someone/.config/lcc/daemon.sock", try socket(arena, &environ));
}

test "a missing HOME is an error, not a path relative to nowhere" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(arena);
    try std.testing.expectError(error.NoHomeDirectory, socket(arena, &environ));
    try std.testing.expectError(error.NoHomeDirectory, logFile(arena, &environ));
}
