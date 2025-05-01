const std = @import("std");

// TODO: Importing `.version` from build.zig.zon should work in future zig
// versions: 
//  https://github.com/ziglang/zig/pull/20271 [OK]
//  https://github.com/ziglang/zig/issues/22775
const version = "0.0.0";

fn run_exe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options: *std.Build.Step.Options,
) void {
    const exe = b.addExecutable(.{
        .name = "z7",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addOptions("build_options", build_options);

    // Create a `zig build run` target
    const exe_run = b.addRunArtifact(exe);
    // Install `z7` binary into standard binary path with `zig install`
    const exe_install = b.addInstallArtifact(exe, .{});
    // Add targets to the `zig build --help` menu
    const exe_step = b.step("run", "Run the app");

    // exe_step [depends on] exe_run [depends on] exe_install
    exe_step.dependOn(&exe_run.step);
    exe_run.step.dependOn(&exe_install.step);

    // Support passing arguments to `zig build *** -- arg1 ...`
    if (b.args) |args| {
        exe_run.addArgs(args);
    }
}

fn build_release(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    build_options: *std.Build.Step.Options,
) void {
    const exe = b.addExecutable(.{
        .name = "z7",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    exe.root_module.addOptions("build_options", build_options);

    // Install `z7` binary into standard binary path with `zig install`
    const exe_install = b.addInstallArtifact(exe, .{});
    // Add targets to the `zig build --help` menu
    const exe_step = b.step("release", "Optimized release build");

    exe_step.dependOn(&exe_install.step);
}

fn build_tests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options: *std.Build.Step.Options,
) void {
    // Support overriding the test file via `zig build test -- <file>`
    var root_source_file: []const u8 = "tests/test.zig";
    if (b.args) |args| {
        for (args) |arg| {
            if (!std.mem.eql(u8, "--", arg)) {
                root_source_file = arg;
            }
            break;
        }
    }

    // Create a module of the src/ folder
    const z7_module = b.createModule(.{
        .root_source_file = b.path("src/root_test.zig"),
    });
    z7_module.addOptions("build_options", build_options);

    const tests = b.addTest(.{
        .name = "z7-test",
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });

    // Build reference implementation library for testing
    // There is a reference implementation in zig stdlib but we use this
    const go_out = "tests/out";
    const go_lib = go_out ++ "/libflate.so";

    const go_args = [_][]const u8{
        "go",
        "build",
        "-buildmode=c-shared",
        "-o",
        go_lib,
        "tests/go/flate.go",
    };
    std.fs.cwd().makeDir(go_out) catch {};
    const go_run = b.addSystemCommand(&go_args);

    tests.root_module.addImport("z7", z7_module);
    tests.addLibraryPath(.{ .cwd_relative = go_out });
    tests.linkSystemLibrary("flate");
    tests.addIncludePath(.{ .cwd_relative = go_out });

    switch (target.result.os.tag) {
        .macos => {
            // XXX: `.addLibraryPath(...) + .linkSystemLibrary(...)` does not
            // work properly on macOS, the linker only searches in /System paths
            // and the cwd(?). HACK: workaround, create a symLink at cwd...
            std.fs.cwd().symLink(go_lib, "./libflate.so", .{}) catch {};
        },
        else => {
            tests.linkLibC();
        },
    }

    // Just *build* the unit tests, we want to run them separately, not with
    // `.addRunArtifact()`, running the tests directly from `zig build` can
    // obscure some important output, e.g.
    //   1/1 FAIL (NoSpaceLeft)
    const tests_install = b.addInstallArtifact(tests, .{});
    const tests_step = b.step("test", "Build unit tests");

    tests.step.dependOn(&go_run.step);
    tests_step.dependOn(&tests_install.step);
}

pub fn build(b: *std.Build) void {
    // Let the user choose the build target
    const target = b.standardTargetOptions(.{});

    // Let the user choose optimization level
    const optimize = b.standardOptimizeOption(.{});

    // Configure build options
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const debug_opt = b.option(bool, "debug", "Print debug logs") orelse false;
    build_options.addOption(bool, "debug", debug_opt);

    const trace_opt = b.option(bool, "trace", "Print detailed debug logs") orelse false;
    build_options.addOption(bool, "trace", trace_opt);

    const quiet_opt = b.option(bool, "quiet", "Quiet test result output") orelse false;
    build_options.addOption(bool, "quiet", quiet_opt);

    run_exe(b, target, optimize, build_options);
    build_tests(b, target, optimize, build_options);
    build_release(b, target, build_options);
}
