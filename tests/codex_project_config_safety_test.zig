const std = @import("std");
const codex_project_config = @import("codex_project_config");

test "Codex config bootstrap rejects a .codex symlink that resolves outside the target worktree" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const source_root = try std.fs.path.join(allocator, &.{ root, "source-repo" });
    defer allocator.free(source_root);
    const target_root = try std.fs.path.join(allocator, &.{ root, "target-worktree" });
    defer allocator.free(target_root);

    try tmp.dir.createDirPath(std.testing.io, "source-repo/.codex");
    try tmp.dir.createDirPath(std.testing.io, "target-worktree");
    try tmp.dir.createDirPath(std.testing.io, "outside-codex");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "source-repo/.codex/config.toml",
        .data = "model = \"gpt-5.4\"\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "outside-codex/config.toml",
        .data = "must remain outside and unchanged\n",
    });
    try tmp.dir.symLink(
        std.testing.io,
        "../outside-codex",
        "target-worktree/.codex",
        .{},
    );

    try expectPathOutsideTarget(
        codex_project_config.bootstrap(allocator, .{
            .source_root = source_root,
            .target_root = target_root,
            .link_patterns = &.{".env.example"},
            .project_config = .copy,
        }),
        tmp.dir,
        allocator,
    );
}

fn expectPathOutsideTarget(result: anytype, dir: std.Io.Dir, allocator: std.mem.Allocator) !void {
    const maybe_operation = result catch |err| {
        try expectOutsideSentinel(dir, allocator);
        try std.testing.expectEqual(error.PathOutsideTarget, err);
        return;
    };
    try expectOutsideSentinel(dir, allocator);
    var operation = maybe_operation orelse {
        std.debug.print("expected error.PathOutsideTarget, found bootstrap success without an operation\n", .{});
        return error.UnexpectedBootstrapSuccess;
    };
    defer operation.deinit();
    std.debug.print(
        "expected error.PathOutsideTarget, found bootstrap success with status={s}\n",
        .{@tagName(operation.status)},
    );
    return error.UnexpectedBootstrapSuccess;
}

fn expectOutsideSentinel(dir: std.Io.Dir, allocator: std.mem.Allocator) !void {
    const outside_after = try dir.readFileAlloc(
        std.testing.io,
        "outside-codex/config.toml",
        allocator,
        .limited(16 * 1024),
    );
    defer allocator.free(outside_after);
    try std.testing.expectEqualStrings("must remain outside and unchanged\n", outside_after);
}
