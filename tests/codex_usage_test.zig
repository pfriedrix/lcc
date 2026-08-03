const std = @import("std");
const sessions = @import("sessions");

const Counts = sessions.Counts;
const Session = sessions.Session;
const Usage = sessions.Usage;
const ModelUsage = std.meta.Elem(@FieldType(Usage, "models"));
const Stamp = std.meta.Elem(@FieldType(Usage, "stamps"));

test "AC1 Codex rollout is attributed to its worktree with delta-based model usage" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const worktree = try std.fs.path.join(allocator, &.{ root, "wanted-worktree" });
    defer allocator.free(worktree);
    const other_worktree = try std.fs.path.join(allocator, &.{ root, "other-worktree" });
    defer allocator.free(other_worktree);
    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);

    try tmp.dir.createDirPath(std.testing.io, "wanted-worktree");
    try tmp.dir.createDirPath(std.testing.io, "other-worktree");
    try tmp.dir.createDirPath(std.testing.io, "codex-home/sessions/2026/08/03");

    const rollout = try rolloutWithReset(allocator, worktree);
    defer allocator.free(rollout);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "codex-home/sessions/2026/08/03/rollout-2026-08-03T10-00-00-session-a.jsonl",
        .data = rollout,
    });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("LCC_CODEX_HOME", codex_home);

    var scanner = try sessions.Scanner.init(allocator, &env);
    defer scanner.deinit();
    var snapshot = try scanner.scan(.cold);
    defer snapshot.deinit();

    const wanted = snapshot.usageForWorktree(worktree);
    const other = snapshot.usageForWorktree(other_worktree);

    try expectCounts(.{
        .messages = 2,
        .input = 139,
        .output = 27,
        .cache_write_5m = 0,
        .cache_write_1h = 0,
        .cache_read = 36,
        .cost_usd = 0,
    }, wanted.counts);
    try std.testing.expectEqual(@as(usize, 1), wanted.sessions);
    try std.testing.expectEqualStrings("2026-08-03T10:00:07Z", wanted.last.?);
    try std.testing.expectEqual(@as(usize, 4), wanted.stamps.len);
    try std.testing.expectEqual(@as(usize, 2), wanted.models.len);
    try std.testing.expectEqualStrings("gpt-5.4", wanted.models[0].name);
    try expectCounts(.{
        .messages = 2,
        .input = 120,
        .output = 20,
        .cache_write_5m = 0,
        .cache_write_1h = 0,
        .cache_read = 30,
        .cost_usd = 0,
    }, wanted.models[0].counts);
    try std.testing.expectEqualStrings("gpt-5.5", wanted.models[1].name);
    try expectCounts(.{
        .messages = 0,
        .input = 19,
        .output = 7,
        .cache_write_5m = 0,
        .cache_write_1h = 0,
        .cache_read = 6,
        .cost_usd = 0,
    }, wanted.models[1].counts);
    try expectCounts(.{}, other.counts);
    try std.testing.expectEqual(@as(usize, 0), other.sessions);
}

test "AC2 worktree usage combines provider-qualified Claude and Codex sessions" {
    const allocator = std.testing.allocator;
    const worktree = "/repo/shared-worktree";
    var claude_models: [1]ModelUsage = undefined;
    var claude_stamps: [1]Stamp = undefined;
    var codex_models: [1]ModelUsage = undefined;
    var codex_stamps: [1]Stamp = undefined;
    const claude = Session{ .claude = .{
        .session_id = "same-raw-id",
        .path = "/claude/projects/shared/same-raw-id.jsonl",
        .cwd = worktree,
        .archived = false,
        .usage = usage(
            .{
                .messages = 3,
                .input = 40,
                .output = 5,
                .cache_write_5m = 7,
                .cache_write_1h = 11,
                .cache_read = 13,
                .cost_usd = 1.25,
            },
            "claude-sonnet-4-5",
            "2026-08-03T09:00:00Z",
            &claude_models,
            &claude_stamps,
        ),
    } };
    const codex = Session{ .codex = .{
        .session_id = "same-raw-id",
        .rollout_path = "/codex/sessions/2026/08/03/same-raw-id.jsonl",
        .session_root = "/codex/sessions",
        .cwd = worktree,
        .archived = false,
        .usage = usage(
            .{
                .messages = 2,
                .input = 60,
                .output = 9,
                .cache_read = 17,
            },
            "gpt-5.4",
            "2026-08-03T10:00:00Z",
            &codex_models,
            &codex_stamps,
        ),
    } };

    var merged = try sessions.merge(allocator, &.{claude}, &.{codex});
    defer merged.deinit();
    const total = merged.usageForWorktree(worktree);
    const matched = merged.sessionsForWorktree(worktree);

    try expectCounts(.{
        .messages = 5,
        .input = 100,
        .output = 14,
        .cache_write_5m = 7,
        .cache_write_1h = 11,
        .cache_read = 30,
        .cost_usd = 1.25,
    }, total.counts);
    try std.testing.expectEqual(@as(usize, 2), total.sessions);
    try std.testing.expectEqual(@as(usize, 2), matched.len);
    try std.testing.expectEqualStrings("claude:same-raw-id", matched[0].identity());
    try std.testing.expectEqualStrings("codex:same-raw-id", matched[1].identity());
    try std.testing.expectEqual(@as(usize, 2), total.models.len);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", total.models[0].name);
    try std.testing.expectEqualStrings("gpt-5.4", total.models[1].name);
}

test "AC3 cached scan invalidates a changed Codex rollout and equals a cold combined scan" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const worktree = try std.fs.path.join(allocator, &.{ root, "shared-worktree" });
    defer allocator.free(worktree);
    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);

    try tmp.dir.createDirPath(std.testing.io, "shared-worktree");
    try tmp.dir.createDirPath(std.testing.io, "codex-home/sessions/2026/08/03");

    const initial = try rolloutBeforeChange(allocator, worktree);
    defer allocator.free(initial);
    const changed = try rolloutAfterChange(allocator, worktree);
    defer allocator.free(changed);
    const rollout_path = "codex-home/sessions/2026/08/03/rollout-2026-08-03T10-00-00-session-cache.jsonl";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = rollout_path, .data = initial });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("LCC_CODEX_HOME", codex_home);

    var cached_scanner = try sessions.Scanner.init(allocator, &env);
    defer cached_scanner.deinit();
    var priming = try cached_scanner.scan(.cold);
    priming.deinit();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = rollout_path, .data = changed });

    var cached_codex = try cached_scanner.scan(.cached);
    defer cached_codex.deinit();
    var cold_scanner = try sessions.Scanner.init(allocator, &env);
    defer cold_scanner.deinit();
    var cold_codex = try cold_scanner.scan(.cold);
    defer cold_codex.deinit();

    var claude_models: [1]ModelUsage = undefined;
    var claude_stamps: [1]Stamp = undefined;
    const claude = Session{ .claude = .{
        .session_id = "claude-cache-peer",
        .path = "/claude/projects/shared/claude-cache-peer.jsonl",
        .cwd = worktree,
        .archived = false,
        .usage = usage(
            .{
                .messages = 1,
                .input = 5,
                .output = 2,
                .cache_write_5m = 3,
                .cache_write_1h = 4,
                .cache_read = 6,
                .cost_usd = 0.5,
            },
            "claude-sonnet-4-5",
            "2026-08-03T09:30:00Z",
            &claude_models,
            &claude_stamps,
        ),
    } };

    var cached_combined = try sessions.merge(allocator, &.{claude}, cached_codex.all());
    defer cached_combined.deinit();
    var cold_combined = try sessions.merge(allocator, &.{claude}, cold_codex.all());
    defer cold_combined.deinit();

    const cached = cached_combined.usageForWorktree(worktree);
    const cold = cold_combined.usageForWorktree(worktree);

    try expectUsageEqual(cold, cached);
    try expectCounts(.{
        .messages = 3,
        .input = 65,
        .output = 14,
        .cache_write_5m = 3,
        .cache_write_1h = 4,
        .cache_read = 26,
        .cost_usd = 0.5,
    }, cached.counts);
    try std.testing.expectEqual(@as(usize, 2), cached.sessions);
    try std.testing.expectEqualStrings("2026-08-03T10:00:04Z", cached.last.?);
    try std.testing.expectEqual(@as(usize, 2), cached.models.len);
    try std.testing.expectEqual(@as(usize, 2), cached.stamps.len);

    const cached_sessions = cached_combined.sessionsForWorktree(worktree);
    const cold_sessions = cold_combined.sessionsForWorktree(worktree);
    try std.testing.expectEqual(@as(usize, 2), cached_sessions.len);
    try std.testing.expectEqual(@as(usize, 2), cold_sessions.len);
    try std.testing.expectEqualStrings(cold_sessions[0].identity(), cached_sessions[0].identity());
    try std.testing.expectEqualStrings(cold_sessions[1].identity(), cached_sessions[1].identity());
}

fn usage(
    counts: Counts,
    model: []const u8,
    last: []const u8,
    model_storage: *[1]ModelUsage,
    stamp_storage: *[1]Stamp,
) Usage {
    model_storage.* = .{.{ .name = model, .counts = counts }};
    stamp_storage.* = .{last};
    return .{
        .counts = counts,
        .sessions = 1,
        .last = last,
        .models = model_storage,
        .stamps = stamp_storage,
    };
}

fn expectCounts(expected: Counts, actual: Counts) !void {
    try std.testing.expectEqual(expected.messages, actual.messages);
    try std.testing.expectEqual(expected.input, actual.input);
    try std.testing.expectEqual(expected.output, actual.output);
    try std.testing.expectEqual(expected.cache_write_5m, actual.cache_write_5m);
    try std.testing.expectEqual(expected.cache_write_1h, actual.cache_write_1h);
    try std.testing.expectEqual(expected.cache_read, actual.cache_read);
    try std.testing.expectEqual(expected.cost_usd, actual.cost_usd);
}

fn expectUsageEqual(expected: Usage, actual: Usage) !void {
    try expectCounts(expected.counts, actual.counts);
    try std.testing.expectEqual(expected.sessions, actual.sessions);
    try std.testing.expectEqualStrings(expected.last.?, actual.last.?);
    try std.testing.expectEqual(expected.models.len, actual.models.len);
    for (expected.models, actual.models) |expected_model, actual_model| {
        try std.testing.expectEqualStrings(expected_model.name, actual_model.name);
        try expectCounts(expected_model.counts, actual_model.counts);
    }
    try std.testing.expectEqual(expected.stamps.len, actual.stamps.len);
    for (expected.stamps, actual.stamps) |expected_stamp, actual_stamp| {
        try std.testing.expectEqualStrings(expected_stamp, actual_stamp);
    }
}

fn rolloutWithReset(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"timestamp":"2026-08-03T10:00:00Z","type":"session_meta","payload":{{"id":"session-a","cwd":"{s}"}}}}
        \\{{"timestamp":"2026-08-03T10:00:01Z","type":"turn_context","payload":{{"model":"gpt-5.4"}}}}
        \\{{"timestamp":"2026-08-03T10:00:02Z","type":"event_msg","payload":{{"type":"user_message","message":"first"}}}}
        \\{{"timestamp":"2026-08-03T10:00:03Z","type":"event_msg","payload":{{"type":"agent_message","message":"reply"}}}}
        \\{{"timestamp":"2026-08-03T10:00:04Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}}}}}
        \\{{"timestamp":"2026-08-03T10:00:05Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":150,"cached_input_tokens":30,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":170}}}}}}}}
        \\{{"timestamp":"2026-08-03T10:00:06Z","type":"turn_context","payload":{{"model":"gpt-5.5"}}}}
        \\{{"timestamp":"2026-08-03T10:00:06Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":170,"cached_input_tokens":35,"output_tokens":25,"reasoning_output_tokens":0,"total_tokens":195}}}}}}}}
        \\{{"timestamp":"2026-08-03T10:00:07Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":5,"cached_input_tokens":1,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":7}}}}}}}}
    , .{cwd});
}

fn rolloutBeforeChange(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"timestamp":"2026-08-03T10:00:00Z","type":"session_meta","payload":{{"id":"session-cache","cwd":"{s}"}}}}
        \\{{"timestamp":"2026-08-03T10:00:01Z","type":"turn_context","payload":{{"model":"gpt-5.4"}}}}
        \\{{"timestamp":"2026-08-03T10:00:02Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":50,"cached_input_tokens":10,"output_tokens":8,"reasoning_output_tokens":0,"total_tokens":58}}}}}}}}
    , .{cwd});
}

fn rolloutAfterChange(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"timestamp":"2026-08-03T10:00:00Z","type":"session_meta","payload":{{"id":"session-cache","cwd":"{s}"}}}}
        \\{{"timestamp":"2026-08-03T10:00:01Z","type":"turn_context","payload":{{"model":"gpt-5.4"}}}}
        \\{{"timestamp":"2026-08-03T10:00:02Z","type":"event_msg","payload":{{"type":"user_message","message":"first"}}}}
        \\{{"timestamp":"2026-08-03T10:00:03Z","type":"event_msg","payload":{{"type":"agent_message","message":"reply"}}}}
        \\{{"timestamp":"2026-08-03T10:00:04Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":80,"cached_input_tokens":20,"output_tokens":12,"reasoning_output_tokens":0,"total_tokens":92}}}}}}}}
    , .{cwd});
}
