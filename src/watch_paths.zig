//! Where the session daemon's files live — and the 103 bytes macOS really
//! gives the first of them.
//!
//! One override, `LCC_WATCH_DIR`, moves the socket, the lock and the hook
//! settings together. Tests need all three isolated at once, and the
//! alternative — moving `HOME` — moves the login Keychain with it, which is
//! where the Linear token lives.

const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");

pub const Error = error{SocketPathTooLong} || std.mem.Allocator.Error || error{NoHomeDirectory};

/// Darwin's `sockaddr_un.path` is `[104]u8` (`std/c.zig`), and the path needs a
/// NUL inside it.
///
/// std will not enforce this. `Io.net.UnixAddress.max_len` is 108 — Linux's
/// number, applied to every non-Windows target — and `init` only rejects past
/// that. `Threaded.addressUnixToPosix` then takes `path_len = a.path.len`
/// *unclamped* and `@memcpy`s into the 104-byte field. So a path of 105 to 108
/// bytes passes every check std makes and writes off the end of the struct:
/// a bounds panic in Debug, a silent stack write in the ReleaseFast build lcc
/// ships. Reachable in practice with a long `$HOME` or a deep `LCC_WATCH_DIR`.
pub const sun_path_max = 104;
pub const socket_path_max = sun_path_max - 1;

pub fn checkSocketPath(path: []const u8) error{SocketPathTooLong}!void {
    if (path.len > socket_path_max) return error.SocketPathTooLong;
}

/// `LCC_WATCH_DIR`, else `~/.config/lcc`. Config rather than cache: the pids in
/// here are the only record of what was running if the daemon dies.
pub fn dir(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("LCC_WATCH_DIR")) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) return gpa.dupe(u8, override);
    }
    return config.dir(gpa, environ);
}

/// The unix socket clients connect to. Checked against `socket_path_max` here,
/// because this is the last place that can turn it into an error rather than a
/// memory write.
pub fn socket(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) Error![]const u8 {
    const base = try dir(gpa, environ);
    const path = try std.fs.path.join(gpa, &.{ base, "daemon.sock" });
    try checkSocketPath(path);
    return path;
}

/// Held exclusively by the daemon for its whole life. Both the single-instance
/// guard and the liveness probe: if the lock can be taken, the daemon that
/// owned the socket beside it is gone and the socket is stale.
pub fn lock(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    const base = try dir(gpa, environ);
    return std.fs.path.join(gpa, &.{ base, "daemon.lock" });
}

/// The settings file passed to `claude --settings`, carrying nothing but lcc's
/// hooks. Written once at daemon start — its contents do not vary per session.
pub fn hooks(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    const base = try dir(gpa, environ);
    return std.fs.path.join(gpa, &.{ base, "hooks.json" });
}

/// Where a detached daemon's stdout and stderr go. Cache rather than config:
/// a log is regenerable, and `usage.json` and `remote.json` set the precedent.
/// Without it a daemon that dies during startup is invisible — no terminal, no
/// message, and a client that can only report that nothing answered.
pub fn logFile(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("LCC_WATCH_DIR")) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) return std.fs.path.join(gpa, &.{ override, "daemon.log" });
    }
    // Fails the same way when HOME is unset, before the unwrap below.
    _ = try config.dir(gpa, environ);
    const home = environ.get("HOME").?;
    return std.fs.path.join(gpa, &.{ home, ".cache", "lcc", "daemon.log" });
}

test "a socket path past Darwin's sun_path is refused here, because std will not" {
    // 103 is the last length that leaves room for the NUL.
    const ok = "a" ** socket_path_max;
    try checkSocketPath(ok);

    // 104 fits the field but not the terminator; 108 is what
    // `Io.net.UnixAddress.init` still accepts. Everything in between reaches an
    // unclamped @memcpy into a 104-byte array inside std — a stack write, not
    // an error return. If this ever stops failing, re-read
    // `Threaded.addressUnixToPosix` before assuming std started clamping.
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

    // One variable, every runtime file — so a test can isolate the daemon
    // without moving HOME, which would move the login Keychain with it.
    try std.testing.expectEqualStrings("/tmp/lcc-test/daemon.sock", try socket(arena, &environ));
    try std.testing.expectEqualStrings("/tmp/lcc-test/daemon.lock", try lock(arena, &environ));
    try std.testing.expectEqualStrings("/tmp/lcc-test/hooks.json", try hooks(arena, &environ));
    // The log follows the override too, rather than escaping to the real cache
    // directory and leaving a test's output in the user's home.
    try std.testing.expectEqualStrings("/tmp/lcc-test/daemon.log", try logFile(arena, &environ));
}

test "an empty override is not an override" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `LCC_WATCH_DIR=` from a shell that exports it unset must fall through to
    // the real location, not resolve to "/daemon.sock". `repos.path`'s rule.
    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", "/home/someone");
    try environ.put("LCC_WATCH_DIR", "");
    try std.testing.expectEqualStrings("/home/someone/.config/lcc/daemon.sock", try socket(arena, &environ));

    // And whitespace is not a path either.
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

    // A log is regenerable and can be deleted at any time; the socket and lock
    // are not. `usage_cache` and `remote_cache` already draw this line.
    try std.testing.expectEqualStrings("/home/someone/.cache/lcc/daemon.log", try logFile(arena, &environ));
    try std.testing.expectEqualStrings("/home/someone/.config/lcc/daemon.sock", try socket(arena, &environ));
}

test "a missing HOME is an error, not a path relative to nowhere" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Without this the log would be built from an unwrapped null, and the
    // socket would resolve somewhere unpredictable rather than refusing.
    var environ: std.process.Environ.Map = .init(arena);
    try std.testing.expectError(error.NoHomeDirectory, socket(arena, &environ));
    try std.testing.expectError(error.NoHomeDirectory, logFile(arena, &environ));
}
