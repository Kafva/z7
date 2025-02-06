const std = @import("std");

// TODO: Importing `.version` from build.zig.zon should work in future zig
// versions: https://github.com/ziglang/zig/pull/20271
const version = "0.0.0";

pub fn build(b: *std.Build) void {
    // Let the user choose the build target
    const target = b.standardTargetOptions(.{});
    // Let the user choose optimziation level
    const optimize = b.standardOptimizeOption(.{});
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    // main ////////////////////////////////////////////////////////////////////
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

    // tests ///////////////////////////////////////////////////////////////////
    const tests = b.addTest(.{
        .name = "z7-test",
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests_run = b.addRunArtifact(tests);
    const tests_install = b.addInstallArtifact(tests, .{});
    const tests_step = b.step("test", "Run unit tests");

    tests_run.step.dependOn(&tests_install.step);
    tests_step.dependOn(&tests_run.step);
}
