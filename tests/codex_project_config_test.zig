const std = @import("std");
const codex_project_config = @import("codex_project_config");

const project_config =
    \\model = "gpt-5.4"
    \\model_reasoning_effort = "high"
    \\
    \\[mcp_servers.standard]
    \\command = "standard-server"
    \\
    \\[mcp_servers."quoted server"]
    \\command = "quoted-server"
    \\
    \\["mcp_servers"."dotted.server"]
    \\command = "dotted-server"
    \\
;

test "AC6 repo-local Codex config reaches a new worktree independently of linkPatterns" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const source_root = try std.fs.path.join(allocator, &.{ root, "source-repo" });
    defer allocator.free(source_root);
    const target_root = try std.fs.path.join(allocator, &.{ root, "new-worktree" });
    defer allocator.free(target_root);
    const expected_source = try std.fs.path.join(
        allocator,
        &.{ source_root, ".codex", "config.toml" },
    );
    defer allocator.free(expected_source);
    const expected_target = try std.fs.path.join(
        allocator,
        &.{ target_root, ".codex", "config.toml" },
    );
    defer allocator.free(expected_target);

    try tmp.dir.makePath("source-repo/.codex");
    try tmp.dir.makePath("new-worktree");
    try tmp.dir.writeFile(.{
        .sub_path = "source-repo/.codex/config.toml",
        .data = project_config,
    });

    var operation = (try codex_project_config.bootstrap(allocator, .{
        .source_root = source_root,
        .target_root = target_root,
        .link_patterns = &.{ "README.md", ".env.example" },
        .project_config = .copy,
    })).?;
    defer operation.deinit();

    const source_after = try tmp.dir.readFileAlloc(
        allocator,
        "source-repo/.codex/config.toml",
        16 * 1024,
    );
    defer allocator.free(source_after);
    const target_bytes = try tmp.dir.readFileAlloc(
        allocator,
        "new-worktree/.codex/config.toml",
        16 * 1024,
    );
    defer allocator.free(target_bytes);

    try std.testing.expectEqualStrings(expected_source, operation.source);
    try std.testing.expectEqualStrings(".codex/config.toml", operation.rel);
    try std.testing.expectEqualStrings(expected_target, operation.target);
    try std.testing.expectEqual(.copied, operation.status);
    try std.testing.expectEqualStrings(project_config, target_bytes);
    try std.testing.expectEqualStrings(project_config, source_after);
}

test "AC7 Codex MCP report includes only repo-local names and is null only when absent or empty" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const repo_root = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(repo_root);
    const empty_repo_root = try std.fs.path.join(allocator, &.{ root, "empty-repo" });
    defer allocator.free(empty_repo_root);
    const absent_repo_root = try std.fs.path.join(allocator, &.{ root, "absent-repo" });
    defer allocator.free(absent_repo_root);
    const user_home = try std.fs.path.join(allocator, &.{ root, "user-home" });
    defer allocator.free(user_home);
    const expected_path = try std.fs.path.join(
        allocator,
        &.{ repo_root, ".codex", "config.toml" },
    );
    defer allocator.free(expected_path);

    try tmp.dir.makePath("repo/.codex");
    try tmp.dir.makePath("empty-repo/.codex");
    try tmp.dir.makePath("absent-repo");
    try tmp.dir.makePath("user-home/.codex");
    try tmp.dir.writeFile(.{
        .sub_path = "repo/.codex/config.toml",
        .data = project_config,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "empty-repo/.codex/config.toml",
        .data =
        \\model = "gpt-5.4"
        \\[mcp_servers]
        \\
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "user-home/.codex/config.toml",
        .data =
        \\[mcp_servers.global_only]
        \\command = "must-not-be-reported"
        \\
        ,
    });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", user_home);
    try env.put("CODEX_HOME", user_home);

    var carried = (try codex_project_config.discoverMcp(
        allocator,
        repo_root,
        &env,
    )).?;
    defer carried.deinit();
    const empty = try codex_project_config.discoverMcp(
        allocator,
        empty_repo_root,
        &env,
    );
    const absent = try codex_project_config.discoverMcp(
        allocator,
        absent_repo_root,
        &env,
    );

    const source_after = try tmp.dir.readFileAlloc(
        allocator,
        "repo/.codex/config.toml",
        16 * 1024,
    );
    defer allocator.free(source_after);

    try std.testing.expectEqualStrings(expected_path, carried.path);
    try std.testing.expectEqual(@as(usize, 3), carried.names.len);
    try std.testing.expect(containsName(carried.names, "standard"));
    try std.testing.expect(containsName(carried.names, "quoted server"));
    try std.testing.expect(containsName(carried.names, "dotted.server"));
    try std.testing.expect(!containsName(carried.names, "global_only"));
    try std.testing.expect(empty == null);
    try std.testing.expect(absent == null);
    try std.testing.expectEqualStrings(project_config, source_after);
}

fn containsName(names: []const []const u8, expected: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, expected)) return true;
    }
    return false;
}
