const std = @import("std");
const codex_project_config = @import("codex_project_config");

const project_config =
    \\[mcp_servers.project_only]
    \\command = "project-server"
    \\
;

test "Codex MCP discovery reports a repo-local config but never the Codex home config environ resolves to" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const repo_root = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(repo_root);
    const repo_codex = try std.fs.path.join(allocator, &.{ root, "repo", ".codex" });
    defer allocator.free(repo_codex);
    const other_home = try std.fs.path.join(allocator, &.{ root, "other-home" });
    defer allocator.free(other_home);

    try tmp.dir.createDirPath(std.testing.io, "repo/.codex");
    try tmp.dir.createDirPath(std.testing.io, "other-home");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.codex/config.toml",
        .data = project_config,
    });
    // An existing global config, so the comparison is a real one between two
    // resolved files rather than a lookup that failed to resolve either.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "other-home/config.toml",
        .data =
        \\[mcp_servers.global_only]
        \\command = "must-not-be-reported"
        \\
        ,
    });

    var elsewhere = std.process.Environ.Map.init(allocator);
    defer elsewhere.deinit();
    try elsewhere.put("HOME", root);
    try elsewhere.put("CODEX_HOME", other_home);

    var same_file = std.process.Environ.Map.init(allocator);
    defer same_file.deinit();
    try same_file.put("HOME", root);
    try same_file.put("CODEX_HOME", repo_codex);

    // A Codex home that is somewhere else: the repo's config is the project's.
    var carried = (try codex_project_config.discoverMcp(
        allocator,
        repo_root,
        &elsewhere,
    )).?;
    defer carried.deinit();

    // The same repo config, now also being the file Codex loads by itself. Nothing
    // is carried, because carrying it would double-count what the agent reads.
    const native = try codex_project_config.discoverMcp(
        allocator,
        repo_root,
        &same_file,
    );

    try std.testing.expectEqual(@as(usize, 1), carried.names.len);
    try std.testing.expectEqualStrings("project_only", carried.names[0]);
    try std.testing.expect(!containsName(carried.names, "global_only"));
    try std.testing.expect(native == null);
}

test "Codex MCP discovery resolves the home comparison through a symlinked .codex" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const repo_root = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(repo_root);
    const shared_codex = try std.fs.path.join(allocator, &.{ root, "shared-codex" });
    defer allocator.free(shared_codex);

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.createDirPath(std.testing.io, "shared-codex");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "shared-codex/config.toml",
        .data = project_config,
    });
    try tmp.dir.symLink(std.testing.io, "../shared-codex", "repo/.codex", .{});

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("CODEX_HOME", shared_codex);

    // repo/.codex/config.toml and $CODEX_HOME/config.toml are one file reached by
    // two paths, which only a canonical comparison catches.
    const native = try codex_project_config.discoverMcp(allocator, repo_root, &env);
    try std.testing.expect(native == null);
}

fn containsName(names: []const []const u8, expected: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, expected)) return true;
    }
    return false;
}
