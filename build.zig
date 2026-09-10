const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public library module; consumers import it as `@import("unityz")`.
    const lib = b.addModule("unityz", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
    });
    // The version the library and `unityz --version` report comes from
    // build.zig.zon, the one place it is declared, so the two cannot drift.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    lib.addOptions("build_options", build_options);

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
        // This is the only translation unit in this library, and it is
        // hand-written, so its warnings are errors. Both exclusions cover
        // noise from the vendored
        // crn_decomp.h it includes, never the shim itself: an unused
        // parameter in a `scalar_type` template stub, and the sprintf /
        // vsprintf inside the decoder's own `crnd_assert` / `crnd_trace`
        // debug reporters.
        // `-fno-strict-aliasing` is the vendored decoder's own documented
        // build requirement, stated at the top of both crn_decomp.h and
        // crnlib.h. It is not advice about gcc alone: `crnd_new_array<T>`
        // stashes the element count as a `uint32` just below the `T*` it
        // returns and `crnd_delete_array<T>` reads it back the same way, so
        // for `crnd_new_array<uint16>` -- the huffman decode tables, on the
        // untrusted-CRN path -- the cookie is written and read through a
        // type unrelated to the object. clang has type-based alias analysis
        // on by default, and is free to sink that store past the element
        // constructors, which hands the delete a bogus count and a bogus
        // free offset. Optimization level does not gate it, so the flag has
        // to be here rather than tied to `optimize`.
        .flags = &.{
            "-DNDEBUG",
            "-fno-strict-aliasing",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-Wno-unused-parameter",
            "-Wno-deprecated-declarations",
        },
    });
    lib.linkLibrary(crunch_lib);

    // The vendored LZHAM decompressor (MIT-licensed) for UnityFS
    // block compression type 4. A C++ static library exposing `lzham_unpack`,
    // linked into the library so `bundle.zig` can decode LZHAM blocks.
    const lzham_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "unitylzham",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    // Compile the vendored C++ optimized regardless of the project's mode:
    // LZHAM's own assertions are tied to the `DEBUG` macro Zig defines for
    // the default Debug build, and its `-O0` debug path is not stable. An
    // optimized vendored lib decodes identically.
    lzham_lib.root_module.optimize = .ReleaseFast;
    // The vendored LZHAM decoder (MIT, per src/vendor/lzham/LICENSE.txt and
    // the grant at the end of lzham.h) compiles with the same
    // warnings-as-errors posture as the unitycrunch decoder above.
    // The single exclusion covers one vendored construct: the prefix-coding
    // table copy in `lzham_prefix_coding.h` memcpies a non-trivially
    // copyable type, which clang's `-Wnontrivial-memcall` (on via `-Wall`)
    // rejects. It is scoped to the three translation units that instantiate
    // that copy rather than applied across the vendored set: the other nine
    // compile clean with no exclusion at all, and blanketing them would
    // silence a future `nontrivial-memcall` introduced anywhere in the
    // decoder. The hand-written `lzham_shim.cpp` below is likewise unexcluded.
    lzham_lib.root_module.addIncludePath(b.path("src/vendor/lzham"));
    const lzham_flags = [_][]const u8{
        "-DNDEBUG",
        "-DLZHAM_NO_FAST_FILE",
        "-Wall",
        "-Wextra",
        "-Werror",
    };
    for ([_][]const u8{
        "src/vendor/lzham/lzham_assert.cpp",
        "src/vendor/lzham/lzham_checksum.cpp",
        "src/vendor/lzham/lzham_huffman_codes.cpp",
        "src/vendor/lzham/lzham_lzdecompbase.cpp",
        "src/vendor/lzham/lzham_mem.cpp",
        "src/vendor/lzham/lzham_platform.cpp",
        "src/vendor/lzham/lzham_polar_codes.cpp",
        "src/vendor/lzham/lzham_timer.cpp",
        "src/vendor/lzham/lzham_vector.cpp",
        "src/vendor/lzham/lzham_shim.cpp",
    }) |src| {
        lzham_lib.root_module.addCSourceFile(.{
            .file = b.path(src),
            .flags = &lzham_flags,
        });
    }
    // The three that instantiate the prefix-coding table copy.
    for ([_][]const u8{
        "src/vendor/lzham/lzham_lzdecomp.cpp",
        "src/vendor/lzham/lzham_prefix_coding.cpp",
        "src/vendor/lzham/lzham_symbol_codec.cpp",
    }) |src| {
        lzham_lib.root_module.addCSourceFile(.{
            .file = b.path(src),
            .flags = &(lzham_flags ++ [_][]const u8{"-Wno-nontrivial-memcall"}),
        });
    }
    lib.linkLibrary(lzham_lib);

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
    const module_paths = [_][]const u8{
        "src/streams.zig",
        "src/container.zig",
        "src/webfile.zig",
        "src/lz4.zig",
        "src/bundle.zig",
        "src/typetree.zig",
        "src/builtin_trees.zig",
        "src/serialized.zig",
        "src/value.zig",
        "src/object_reader.zig",
        "src/classes.zig",
        "src/shader.zig",
        "src/texture.zig",
        "src/png.zig",
        "src/tga.zig",
        "src/bmp.zig",
        "src/fsb5.zig",
        "src/audio.zig",
        "src/vorbis.zig",
        "src/wav.zig",
        "src/object_writer.zig",
        "src/serialized_writer.zig",
        "src/dotnet.zig",
        "src/managed_trees.zig",
    };

    // Zig analyzes `test` blocks only in a module's root file, so a module
    // missing from the list above has its tests silently skipped — green
    // suite, zero coverage, no diagnostic. The list is therefore checked
    // against src/ at configure time instead of by hand: a new top-level
    // module either joins `module_paths` or is named below with the reason
    // it has no tests of its own.
    const untested_modules = [_][]const u8{
        "lib.zig", // library test root, registered as lib_tests above
        "main.zig", // CLI test root, registered as exe_tests below
        "vorbis_headers_index.zig", // generated offset tables, no logic
    };
    const io = b.graph.io;
    var src_dir = b.build_root.handle.openDir(io, "src", .{ .iterate = true }) catch |err|
        std.debug.panic("cannot read src/ to check test roots: {t}", .{err});
    defer src_dir.close(io);
    var src_it = src_dir.iterate();
    while (src_it.next(io) catch |err|
        std.debug.panic("cannot read src/ to check test roots: {t}", .{err})) |entry|
    {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        var is_root = false;
        for (module_paths) |path| {
            if (std.mem.eql(u8, path["src/".len..], entry.name)) is_root = true;
        }
        for (untested_modules) |name| {
            if (std.mem.eql(u8, name, entry.name)) is_root = true;
        }
        if (!is_root) std.debug.panic(
            "src/{s} is not a test root: add it to module_paths in build.zig so " ++
                "`zig build test` runs its tests, or to untested_modules with a reason",
            .{entry.name},
        );
    }

    for (module_paths) |module_path| {
        const module = b.createModule(.{
            .root_source_file = b.path(module_path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        module.linkLibrary(crunch_lib);
        module.linkLibrary(lzham_lib);
        const module_tests = b.addTest(.{ .root_module = module });
        const run_module_tests = b.addRunArtifact(module_tests);
        test_step.dependOn(&run_module_tests.step);
    }

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);
}
