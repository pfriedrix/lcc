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
    // Keychain access goes through the modern SecItem* API, which speaks
    // CoreFoundation types.
    mod.linkFramework("CoreFoundation", .{});
    mod.linkFramework("Security", .{});

    const exe = b.addExecutable(.{
        .name = "lcc",
        .root_module = mod,
    });

    // The Keychain decides who may read the Linear token from the program's code
    // signature, and Zig's linker only ad-hoc signs — an identity that is nothing
    // but the hash of the binary. So every rebuild arrives at the Keychain as a
    // *changed* program, which re-asks for the login password and blocks until it is
    // answered. Signing with a real certificate, self-signed included, pins the
    // designated requirement to `identifier "lcc"` plus that certificate, and one
    // "Always Allow" then survives every later build.
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

    // A module of its own: reusing the executable's module made `zig build
    // test` reuse the executable's compilation and silently skip the tests.
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

    // The contract tests under `tests/` were authored against the module they pin
    // and import it by name — `@import("sessions")`, not a path — so each needs its
    // own test artifact with that one module wired in. Hanging them off the same
    // `test` step is the whole point: they are the only thing pinning the Codex
    // acceptance criteria, and reached solely through an ad-hoc `zig test --dep`
    // they were green in a transcript nobody re-runs.
    const contract_tests = [_]struct {
        file: []const u8,
        import: []const u8,
        source: []const u8,
    }{
        .{
            .file = "tests/codex_usage_test.zig",
            .import = "sessions",
            .source = "src/sessions.zig",
        },
        .{
            .file = "tests/codex_sessions_test.zig",
            .import = "codex_projects",
            .source = "src/codex_projects.zig",
        },
        .{
            .file = "tests/codex_project_config_test.zig",
            .import = "codex_project_config",
            .source = "src/codex_project_config.zig",
        },
        .{
            .file = "tests/codex_project_config_safety_test.zig",
            .import = "codex_project_config",
            .source = "src/codex_project_config.zig",
        },
        .{
            .file = "tests/codex_project_config_env_test.zig",
            .import = "codex_project_config",
            .source = "src/codex_project_config.zig",
        },
    };
    for (contract_tests) |contract| {
        const contract_mod = b.createModule(.{
            .root_source_file = b.path(contract.file),
            .target = target,
            .optimize = optimize,
        });
        contract_mod.addImport(contract.import, b.createModule(.{
            .root_source_file = b.path(contract.source),
            .target = target,
            .optimize = optimize,
        }));
        const contract_test = b.addTest(.{ .root_module = contract_mod });
        test_step.dependOn(&b.addRunArtifact(contract_test).step);
    }
}

/// Which certificate to sign the installed binary with. Nothing has to be set up for
/// this: whatever the machine already has for code signing is what gets used, since
/// *which* certificate it is does not matter — only that it stays the same between
/// builds. `lcc-dev` first for anyone who made one on purpose, then an Apple
/// Development certificate, which a machine that builds apps already has.
///
/// `-Dsign=<identity>` overrides, `-Dsign=none` opts out, `LCC_CODESIGN_IDENTITY`
/// does the same from the environment. Finding nothing is not an error — the build
/// then leaves the linker's ad-hoc signature alone.
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
        // Named out loud rather than picked silently: the signature is what the
        // Keychain recognises lcc by, so it should never be a surprise.
        std.log.info("signing lcc with \"{s}\"", .{found});
        return found;
    }
    return null;
}

/// The certificate name out of `security find-identity` output — the quoted common
/// name on the first line mentioning `needle`. Lines look like:
/// `  1) A1B2C3… "Apple Development: Someone (TEAMID)"`.
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
