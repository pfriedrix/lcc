const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.linkFramework("CoreFoundation", .{});
    mod.linkFramework("Security", .{});

    const exe = b.addExecutable(.{
        .name = "lcc",
        .root_module = mod,
    });

    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);
    if (signIdentity(b)) |identity| {
        const sign = b.addSystemCommand(&.{
            "codesign",
            "--force",
            "--sign",
            identity,
            "--identifier",
            exe.name,
            b.getInstallPath(.bin, exe.name),
        });
        sign.step.dependOn(&install_exe.step);
        b.getInstallStep().dependOn(&sign.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run lcc");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.linkFramework("CoreFoundation", .{});
    test_mod.linkFramework("Security", .{});

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn signIdentity(b: *std.Build) ?[]const u8 {
    const option = b.option(
        []const u8,
        "sign",
        "codesign identity for the installed binary, which keeps the Keychain ACL " ++
            "stable across rebuilds (default: whatever code-signing certificate this " ++
            "machine has, 'none' to opt out)",
    );
    if (option) |explicit| {
        return if (std.mem.eql(u8, explicit, "none")) null else explicit;
    }

    if (b.graph.environ_map.get("LCC_CODESIGN_IDENTITY")) |from_env| {
        if (from_env.len > 0) return from_env;
    }

    var code: u8 = 0;
    const identities = b.runAllowFail(
        &.{ "security", "find-identity", "-v", "-p", "codesigning" },
        &code,
        .ignore,
    ) catch return null;

    for ([_][]const u8{ "lcc-dev", "Apple Development:" }) |preferred| {
        const found = commonNameContaining(identities, preferred) orelse continue;
        std.log.info("signing lcc with \"{s}\"", .{found});
        return found;
    }
    return null;
}

fn commonNameContaining(identities: []const u8, needle: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, identities, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) == null) continue;
        const open = std.mem.indexOfScalar(u8, line, '"') orelse continue;
        const rest = line[open + 1 ..];
        const close = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        if (close > 0) return rest[0..close];
    }
    return null;
}
