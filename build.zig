const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public library module; consumers import it as `@import("unityz")`.
    const lib = b.addModule("unityz", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
    });

    // The vendored Unity crunch decompressor (ZLIB license): a C++ static
    // library exposing `unitycrunch_unpack` / `unitycrunch_free`, linked
    // into the library so crunched ETC2/DXT textures decode.
    const crunch_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "unitycrunch",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    crunch_lib.root_module.addCSourceFile(.{
        .file = b.path("src/vendor/unitycrunch_shim.cpp"),
        .flags = &.{ "-DNDEBUG" },
    });
    lib.linkLibrary(crunch_lib);

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

    // Each source module carries its own unit tests; imported modules are
    // not analyzed by the lib root, so register every module file as its
    // own test root.
    for ([_][]const u8{
        "src/streams.zig",
        "src/container.zig",
        "src/webfile.zig",
        "src/lz4.zig",
        "src/bundle.zig",
        "src/typetree.zig",
        "src/serialized.zig",
        "src/value.zig",
        "src/object_reader.zig",
        "src/classes.zig",
        "src/texture.zig",
        "src/png.zig",
        "src/fsb5.zig",
        "src/object_writer.zig",
        "src/serialized_writer.zig",
    }) |module_path| {
        const module = b.createModule(.{
            .root_source_file = b.path(module_path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        module.linkLibrary(crunch_lib);
        const module_tests = b.addTest(.{ .root_module = module });
        const run_module_tests = b.addRunArtifact(module_tests);
        test_step.dependOn(&run_module_tests.step);
    }

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);
}
