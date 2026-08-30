const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public library module; consumers import it as `@import("unityz")`.
    const lib = b.addModule("unityz", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
    });

    // CLI, linking the library module.
    const exe = b.addExecutable(.{
        .name = "unityz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "unityz", .module = lib },
            },
        }),
    });
    b.installArtifact(exe);

    // `zig build run` — runs the CLI (args after `--` are passed through).
    const run_step = b.step("run", "Run the CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — library tests and CLI tests.
    const test_step = b.step("test", "Run all tests");

    const lib_tests = b.addTest(.{ .root_module = lib });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);
}
