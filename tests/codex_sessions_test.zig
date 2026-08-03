const std = @import("std");
const codex_projects = @import("codex_projects");

test "AC4 Codex sessions are retained by default and removal stays inside the owning session root" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);
    const worktree = try std.fs.path.join(allocator, &.{ root, "worktree" });
    defer allocator.free(worktree);
    const outside_path = try std.fs.path.join(allocator, &.{ root, "outside-sentinel.jsonl" });
    defer allocator.free(outside_path);

    try tmp.dir.createDirPath(std.testing.io, "worktree");
    try tmp.dir.createDirPath(std.testing.io, "codex-home/sessions/2026/08/03/nested");
    try writeRollout(
        allocator,
        tmp.dir,
        "codex-home/sessions/2026/08/03/nested/inside-session.jsonl",
        "inside-session",
        worktree,
    );
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "outside-sentinel.jsonl",
        .data = "must survive rejected removal\n",
    });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("LCC_CODEX_HOME", codex_home);

    var catalog = try codex_projects.scan(allocator, &env);
    defer catalog.deinit();
    const entry = catalog.findByIdentity("codex:inside-session").?;

    try std.testing.expectEqual(@as(usize, 1), catalog.entries.len);
    try std.testing.expectEqualStrings("codex:inside-session", entry.identity);
    try std.testing.expectEqualStrings("inside-session", entry.session_id);
    try std.testing.expectEqualStrings(worktree, entry.cwd);
    try std.testing.expect(!entry.archived);
    try tmp.dir.access(
        std.testing.io,
        "codex-home/sessions/2026/08/03/nested/inside-session.jsonl",
        .{},
    );

    try std.testing.expectError(
        error.PathOutsideSessionRoot,
        codex_projects.removeRollout(entry.session_root, outside_path),
    );
    try tmp.dir.access(std.testing.io, "outside-sentinel.jsonl", .{});

    try entry.remove();
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(
            std.testing.io,
            "codex-home/sessions/2026/08/03/nested/inside-session.jsonl",
            .{},
        ),
    );
    try tmp.dir.access(std.testing.io, "outside-sentinel.jsonl", .{});
}

test "AC5 orphan discovery distinguishes live and missing cwd across active and archived roots" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);
    const active_live_cwd = try std.fs.path.join(allocator, &.{ root, "active-live" });
    defer allocator.free(active_live_cwd);
    const archived_live_cwd = try std.fs.path.join(allocator, &.{ root, "archived-live" });
    defer allocator.free(archived_live_cwd);
    const active_missing_cwd = try std.fs.path.join(allocator, &.{ root, "active-missing" });
    defer allocator.free(active_missing_cwd);
    const archived_missing_cwd = try std.fs.path.join(allocator, &.{ root, "archived-missing" });
    defer allocator.free(archived_missing_cwd);

    try tmp.dir.createDirPath(std.testing.io, "active-live");
    try tmp.dir.createDirPath(std.testing.io, "archived-live");
    try tmp.dir.createDirPath(std.testing.io, "codex-home/sessions/deep/active");
    try tmp.dir.createDirPath(std.testing.io, "codex-home/archived_sessions/deep/archived");
    try writeRollout(
        allocator,
        tmp.dir,
        "codex-home/sessions/deep/active/live.jsonl",
        "active-live-session",
        active_live_cwd,
    );
    try writeRollout(
        allocator,
        tmp.dir,
        "codex-home/sessions/deep/active/missing.jsonl",
        "active-missing-session",
        active_missing_cwd,
    );
    try writeRollout(
        allocator,
        tmp.dir,
        "codex-home/archived_sessions/deep/archived/live.jsonl",
        "archived-live-session",
        archived_live_cwd,
    );
    try writeRollout(
        allocator,
        tmp.dir,
        "codex-home/archived_sessions/deep/archived/missing.jsonl",
        "archived-missing-session",
        archived_missing_cwd,
    );

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("LCC_CODEX_HOME", codex_home);

    var catalog = try codex_projects.scan(allocator, &env);
    defer catalog.deinit();
    const orphans = try catalog.orphans(allocator);
    defer allocator.free(orphans);

    try std.testing.expectEqual(@as(usize, 4), catalog.entries.len);
    try std.testing.expectEqual(@as(usize, 2), orphans.len);
    try std.testing.expect(!containsIdentity(orphans, "codex:active-live-session"));
    try std.testing.expect(!containsIdentity(orphans, "codex:archived-live-session"));
    try std.testing.expect(containsIdentity(orphans, "codex:active-missing-session"));
    try std.testing.expect(containsIdentity(orphans, "codex:archived-missing-session"));

    const active_missing = catalog.findByIdentity("codex:active-missing-session").?;
    const archived_missing = catalog.findByIdentity("codex:archived-missing-session").?;
    try std.testing.expect(!active_missing.archived);
    try std.testing.expect(archived_missing.archived);
    try std.testing.expectEqualStrings(active_missing_cwd, active_missing.cwd);
    try std.testing.expectEqualStrings(archived_missing_cwd, archived_missing.cwd);
}

test "a rollout far larger than the metadata prefix is still attributed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);
    const worktree = try std.fs.path.join(allocator, &.{ root, "worktree" });
    defer allocator.free(worktree);

    try tmp.dir.createDirPath(std.testing.io, "worktree");
    try tmp.dir.createDirPath(std.testing.io, "codex-home/sessions/2026/08/03");

    // A worked-in session is megabytes of turns behind a metadata line of a few
    // KB. Discovery reads a bounded prefix, so the bulk must not matter — and it
    // must not be read to find out.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    const meta = try std.fmt.allocPrint(allocator,
        \\{{"timestamp":"2026-08-03T10:00:00Z","type":"session_meta","payload":{{"id":"huge-session","cwd":"{s}"}}}}
        \\
    , .{worktree});
    defer allocator.free(meta);
    try body.appendSlice(allocator, meta);
    while (body.items.len < 512 * 1024) {
        try body.appendSlice(allocator,
            \\{"timestamp":"2026-08-03T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"filler"}}
            \\
        );
    }
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "codex-home/sessions/2026/08/03/huge.jsonl",
        .data = body.items,
    });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("LCC_CODEX_HOME", codex_home);

    var catalog = try codex_projects.scan(allocator, &env);
    defer catalog.deinit();

    try std.testing.expectEqual(@as(usize, 1), catalog.entries.len);
    try std.testing.expectEqualStrings(worktree, catalog.findByIdentity("codex:huge-session").?.cwd);
}

test "a second scan answers from what the first one recorded" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);
    const worktree = try std.fs.path.join(allocator, &.{ root, "worktree" });
    defer allocator.free(worktree);

    try tmp.dir.createDirPath(std.testing.io, "worktree");
    try tmp.dir.createDirPath(std.testing.io, "codex-home/sessions/2026/08/03");
    const rollout = "codex-home/sessions/2026/08/03/cached.jsonl";
    try writeRollout(allocator, tmp.dir, rollout, "cached-session", worktree);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("LCC_CODEX_HOME", codex_home);

    {
        var first = try codex_projects.scan(allocator, &env);
        defer first.deinit();
        try std.testing.expectEqualStrings(worktree, first.findByIdentity("codex:cached-session").?.cwd);
    }

    // Contents replaced with something that records nothing, the path left alone.
    // A scan that still reports the session is a scan that did not re-read the
    // file — which is the whole point, and is sound because the real thing cannot
    // happen: `session_meta` is written once before any turn, a rollout is only
    // appended to afterwards, and its name carries a start timestamp and a uuid
    // that are never reused.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = rollout, .data = "not a rollout\n" });

    var second = try codex_projects.scan(allocator, &env);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.entries.len);
    try std.testing.expectEqualStrings(worktree, second.findByIdentity("codex:cached-session").?.cwd);

    // And a rollout that is gone stays gone, rather than living on in the cache.
    try tmp.dir.deleteFile(std.testing.io, rollout);
    try writeRollout(allocator, tmp.dir, "codex-home/sessions/2026/08/03/fresh.jsonl", "fresh-session", worktree);
    var third = try codex_projects.scan(allocator, &env);
    defer third.deinit();
    try std.testing.expectEqual(@as(usize, 1), third.entries.len);
    try std.testing.expectEqualStrings("codex:fresh-session", third.entries[0].identity);
}

fn writeRollout(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    sub_path: []const u8,
    session_id: []const u8,
    cwd: []const u8,
) !void {
    const data = try std.fmt.allocPrint(allocator,
        \\{{"timestamp":"2026-08-03T10:00:00Z","type":"session_meta","payload":{{"id":"{s}","cwd":"{s}"}}}}
        \\{{"timestamp":"2026-08-03T10:00:01Z","type":"turn_context","payload":{{"model":"gpt-5.4"}}}}
    , .{ session_id, cwd });
    defer allocator.free(data);
    try dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
}

fn containsIdentity(entries: anytype, expected: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.identity, expected)) return true;
    }
    return false;
}
