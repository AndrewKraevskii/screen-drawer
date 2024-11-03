const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const no_bin = b.option(bool, "no-bin", "Don't emit binary file") orelse false;
    const tracy_enable = b.option(bool, "tracy_enable", "Enable profiling") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "tracy_enable", tracy_enable);

    const tracy = b.dependency("zig-tracy", .{
        .target = target,
        .optimize = optimize,
        .tracy_enable = tracy_enable,
    });

    const raylib_dep = b.dependency("raylib-zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylib_dep.module("raylib");
    const raygui = raylib_dep.module("raygui");
    const raylib_artifact = raylib_dep.artifact("raylib");

    const exe = b.addExecutable(.{
        .name = "screen_drawer",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .use_llvm = false,
        .use_lld = false,
    });

    exe.root_module.addOptions("options", options);
    exe.linkLibrary(raylib_artifact);
    exe.root_module.addImport("raylib", raylib);
    exe.root_module.addImport("raygui", raygui);
    exe.root_module.addImport("tracy", tracy.module("tracy"));
    exe.linkLibrary(tracy.artifact("tracy"));
    exe.linkLibCpp();

    if (no_bin) {
        b.getInstallStep().dependOn(&exe.step);
    } else {
        b.installArtifact(exe);
    }
    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const check_step = b.step("check", "Just check if compiles without producing binary");
    check_step.dependOn(&exe.step);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_unit_tests.linkLibrary(raylib_artifact);
    exe_unit_tests.root_module.addImport("raylib", raylib);
    exe_unit_tests.root_module.addImport("raygui", raygui);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
