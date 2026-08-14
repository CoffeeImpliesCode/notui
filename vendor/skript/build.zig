const std = @import("std");
// Vendored emcc build helpers (build_web.zig) — imported locally, NOT from
// the zemscripten dependency, so build.zig never comptime-imports a
// possibly-absent lazy dep.
const web_tools = @import("build_web.zig");

const platform = @import("src/platform.zig");
const builtin = @import("builtin");
// const zlinter = @import("zlinter");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const cli_enabled = b.option(
        bool,
        "cli",
        "Build the highlighted native CLI and CLI-dependent test gate",
    ) orelse true;
    const grammar_path_option = b.option(
        []const u8,
        "tree-sitter-skript-path",
        "Tree-sitter Skript checkout (absolute or relative to this package)",
    ) orelse "../tree-sitter-skript";
    // `zig build test` keeps the CLI/API gate by default. Use `-Dcli=false`
    // with `test-unit` or `check` for a library-only package consumer.

    // zig-cov instrumentation (https://github.com/ericsssan/zcov):
    // `zig-cov test` passes these options; without them the build is unchanged.
    const coverage = b.option(bool, "coverage", "Instrument tests with zig-cov") orelse false;
    const coverage_rt = b.option([]const u8, "coverage-rt", "Path to zig-cov-rt.o") orelse null;

    // const fehler = b.dependency("fehler", .{ .target = target, .optimize = optimize });
    // const aro = b.dependency("aro", .{ .target = target, .optimize = optimize });
    const zigzag = b.dependency("zigzag", .{ .target = target, .optimize = optimize });

    const options = b.addOptions();

    const tracy = b.dependency("tracy", .{ .target = target, .optimize = optimize });
    const tracy_enabled = b.option(bool, "enable_tracy", "Enable the Tracy profiler") orelse false;
    options.addOption(bool, "tracy_enabled", tracy_enabled);

    const libffi_allowed = platform.ffiSupported(target.result) and !builtin.is_test;
    const libffi_enabled = b.option(bool, "enable_libffi", "Enable libffi bindings") orelse libffi_allowed;
    options.addOption(bool, "ffi_enabled", libffi_enabled);

    const pf = b.addModule(
        "platform",
        .{ .root_source_file = b.path("src/platform.zig"), .target = target, .imports = &.{} },
    );

    const mod = b.addModule("skript", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "platform", .module = pf },
            .{ .name = "options", .module = options.createModule() },
            .{ .name = "tracy", .module = tracy.module("tracy") },
            .{ .name = "tracy_impl", .module = if (tracy_enabled)
                tracy.module("tracy_impl_enabled")
            else
                tracy.module("tracy_impl_disabled") },
        },
    });

    const lib = b.addLibrary(.{
        .name = "libskript",
        .root_module = mod,
    });
    lib.use_llvm = true;
    b.installArtifact(lib);

    // REPL syntax highlighting is CLI-only. The grammar source and query are
    // lazy inputs of the CLI build, so library, test-compile, and cross-target
    // consumers do not inspect the sibling checkout unless they build `exe`.
    const exe: ?*std.Build.Step.Compile = if (cli_enabled) blk: {
        const grammar_root = if (std.fs.path.isAbsolute(grammar_path_option))
            grammar_path_option
        else
            b.pathFromRoot(grammar_path_option);
        const parser_path = b.pathJoin(&.{ grammar_root, "src/parser.c" });
        const grammar_include_path = b.pathJoin(&.{ grammar_root, "src" });
        const scm_path = b.pathJoin(&.{ grammar_root, "queries/highlights.scm" });

        const ts_grammar = b.addLibrary(.{
            .name = "tree-sitter-skript",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        ts_grammar.root_module.addCSourceFile(.{
            .file = .{ .cwd_relative = parser_path },
            .flags = &.{"-std=c11"},
        });
        ts_grammar.root_module.addIncludePath(.{ .cwd_relative = grammar_include_path });

        // @embedFile cannot reach outside the package root. Keep the source
        // query beside a generated module in one WriteFiles step. The copy is
        // resolved only if this module is compiled.
        const query_files = b.addWriteFiles();
        _ = query_files.addCopyFile(.{ .cwd_relative = scm_path }, "highlights.scm");
        const query_module_source = query_files.add(
            "highlights.zig",
            "pub const highlights_scm = @embedFile(\"highlights.scm\");\n",
        );
        const scm_module = b.createModule(.{
            .root_source_file = query_module_source,
        });

        const cli_exe = b.addExecutable(.{
            .name = "skript",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "skript", .module = mod },
                    .{ .name = "zigzag", .module = zigzag.module("zigzag") },
                    .{ .name = "tracy", .module = tracy.module("tracy") },
                    .{ .name = "highlight_query", .module = scm_module },
                },
            }),
        });
        cli_exe.root_module.linkLibrary(ts_grammar);

        // Resolve the tree-sitter runtime from the current environment rather
        // than baking a Nix store path into the executable.
        if (b.graph.environ_map.get("LD_LIBRARY_PATH")) |library_path| {
            var directories = std.mem.splitScalar(u8, library_path, ':');
            while (directories.next()) |directory| {
                if (directory.len == 0) continue;
                const probe = std.fmt.allocPrint(
                    b.allocator,
                    "{s}/libtree-sitter.so",
                    .{directory},
                ) catch continue;
                std.Io.Dir.cwd().access(b.graph.io, probe, .{}) catch continue;
                cli_exe.root_module.addRPath(.{ .cwd_relative = directory });
                break;
            }
        }
        cli_exe.root_module.linkSystemLibrary("tree-sitter", .{ .needed = true });
        if (tracy_enabled) {
            cli_exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_enabled"));
        } else {
            cli_exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_disabled"));
        }
        // Tracy stack capture and symbolication require LLVM-emitted debug
        // information; the native backend's DWARF is incomplete.
        cli_exe.use_llvm = true;
        b.installArtifact(cli_exe);
        break :blk cli_exe;
    } else null;

    const bench_exe = b.addExecutable(.{
        .name = "skript-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "skript", .module = mod },
            },
        }),
    });
    b.installArtifact(bench_exe);

    // Lazily resolved: libffi's build.zig panics on targets without assembly
    // support, so only materialize the dependency when the gate says the
    // target supports FFI. `null` (not yet fetched / unavailable) means the
    // wiring is skipped — the gate already decided.
    if (platform.ffiSupported(target.result) and libffi_enabled) {
        if (b.lazyDependency("libffi", .{ .target = target, .optimize = optimize, .linkage = .static })) |ffi_dep| {
            mod.addImport("ffi", ffi_dep.module("ffi"));
            mod.linkLibrary(ffi_dep.artifact("ffi"));
        }
    }

    const run_step = b.step("run", "Run the app");
    if (exe) |cli_exe| {
        const run_cmd = b.addRunArtifact(cli_exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    } else {
        const missing_cli = b.addFail(
            "`run` requires the CLI; remove -Dcli=false or build the library only",
        );
        run_step.dependOn(&missing_cli.step);
    }

    // Test module clone: instrumentation must never land on `mod` itself
    // (shared with lib/exe/bench/test_exe) — that would link zig-cov-rt.o
    // twice in one test binary ("duplicate symbol: zig_cov_ctor").
    const mod_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "platform", .module = pf },
            .{ .name = "options", .module = options.createModule() },
            .{ .name = "tracy", .module = tracy.module("tracy") },
            .{ .name = "tracy_impl", .module = if (tracy_enabled)
                tracy.module("tracy_impl_enabled")
            else
                tracy.module("tracy_impl_disabled") },
        },
    });
    if (platform.ffiSupported(target.result) and libffi_enabled) {
        if (b.lazyDependency("libffi", .{ .target = target, .optimize = optimize, .linkage = .static })) |ffi_dep| {
            mod_tests_mod.addImport("ffi", ffi_dep.module("ffi"));
            mod_tests_mod.linkLibrary(ffi_dep.artifact("ffi"));
        }
    }

    const mod_tests = b.addTest(.{
        .root_module = mod_tests_mod,
    });
    if (coverage) instrument(mod_tests, coverage_rt);
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Library-only consumers can run this step without configuring a CLI or
    // requiring a sibling grammar checkout.
    const test_unit_step = b.step("test-unit", "Run library unit tests");
    test_unit_step.dependOn(&run_mod_tests.step);

    const test_step = b.step("test", "Run unit, API, demo, and parity tests");
    test_step.dependOn(&run_mod_tests.step);
    if (target.query.isNative()) {
        if (exe) |cli_exe| {
            const api_run = b.addSystemCommand(&.{ "bash", "test/api/run.sh" });
            api_run.setCwd(b.path("."));
            api_run.addArtifactArg(cli_exe);
            test_step.dependOn(&api_run.step);
        } else {
            const missing_cli = b.addFail(
                "`test` requires the CLI; use `test-unit` for library-only tests",
            );
            test_step.dependOn(&missing_cli.step);
        }
    }

    const test_name = try std.fmt.allocPrint(b.allocator, "skript-test-{s}-{s}{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
        if (target.result.abi.isAndroid()) "-android" else "",
    });
    const test_exe = b.addTest(.{
        .name = test_name,
        .root_module = mod,
    });

    b.installArtifact(test_exe);
    const test_install = b.addInstallArtifact(test_exe, .{});
    const test_compile_step = b.step("test-compile", "compile test binary");
    test_compile_step.dependOn(&test_install.step);

    // Run tests directly, bypassing zig's slow --listen=- IPC protocol (~3.5x faster).
    const test_fast = b.step("test-fast", "Run tests directly (compiles then runs, no IPC overhead)");
    const run_fast = b.addSystemCommand(&.{
        b.getInstallPath(.bin, test_install.dest_sub_path),
    });
    run_fast.step.dependOn(&test_install.step);
    test_fast.dependOn(&run_fast.step);

    // ZLS build-on-save: re-define compile artifacts but never install them.
    // Zig adds -fno-emit-bin, skipping LLVM codegen — fast diagnostics on save.
    const check_lib = b.addTest(.{
        .name = "skript-check-lib",
        .root_module = mod,
    });
    const check_step = b.step("check", "Check if skript compiles");
    check_step.dependOn(&check_lib.step);
    if (exe) |cli_exe| {
        const check_exe = b.addExecutable(.{
            .name = "skript-check-exe",
            .root_module = cli_exe.root_module,
        });
        check_step.dependOn(&check_exe.step);
    }

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // Emscripten web build — OPTIONAL and lazy.
    // `zig build web`: compiles the language core + a minimal web entry
    // (src/web.zig) for wasm32-emscripten and links it with emcc into
    // zig-out/web/ (skript.js + skript.wasm + index.html). emcc comes from
    // the devenv's `emscripten` package; the vendored zemscripten package
    // resolves it from PATH at build time (no emsdk checkout involved).
    //
    // zemscripten is declared `.lazy = true` in build.zig.zon and is NOT
    // shipped in .paths, so consumers of skript never have it. This whole
    // section is gated on the lazy dep being available: a consumer (or any
    // build without third_party/zemscripten) skips it entirely and never
    // resolves or imports zemscripten — the Emscripten/emcc toolchain is
    // required only in a full checkout when `zig build web` is requested.
    // tree-sitter, tracy and libffi are REPL-native concerns and stay out
    // of the web module tree (ffi is additionally auto-gated by
    // platform.ffiSupported for the wasm target).
    //
    // Gate on the vendored path's presence rather than b.lazyImport/lazyDependency:
    // a missing lazy *path* dep neither returns null nor reports !available —
    // it just lacks a build.zig, so lazyImport hits a @compileError. Probing the
    // path instead keeps consumers (which don't ship third_party/zemscripten,
    // see .paths) from ever reaching the emscripten toolchain code below.
    const web_supported = blk: {
        std.Io.Dir.cwd().access(b.graph.io, "third_party/zemscripten/build.zig", .{}) catch break :blk false;
        break :blk true;
    };
    if (web_supported) {
        const ze = b.lazyDependency("zemscripten", .{}).?;

        const web_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .emscripten });
        const web_pf = b.addModule("platform", .{
            .root_source_file = b.path("src/platform.zig"),
            .target = web_target,
            .imports = &.{},
        });
        const web_skript = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = web_target,
            .optimize = optimize,
            .link_libc = true, // emscripten: std.posix.system falls back to std.c
            // (the generic wasm arm lacks getrandom/IOV_MAX); std.c has
            // emscripten arms for both.
            .imports = &.{
                .{ .name = "platform", .module = web_pf },
                .{ .name = "options", .module = options.createModule() },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = if (tracy_enabled)
                    tracy.module("tracy_impl_enabled")
                else
                    tracy.module("tracy_impl_disabled") },
            },
        });
        const zigzag_web = b.dependency("zigzag", .{ .target = web_target, .optimize = optimize });
        const emscripten_zig_lib = web_tools.prepareEmscriptenZigLib(b);
        const web_lib = b.addLibrary(.{
            .name = "skript-web",
            .zig_lib_dir = emscripten_zig_lib,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/web.zig"),
                .target = web_target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "skript", .module = web_skript },
                    .{ .name = "zigzag", .module = zigzag_web.module("zigzag") },
                    .{ .name = "zemscripten", .module = ze.module("root") },
                },
            }),
        });

        // The static lib must carry the target's compiler_rt: the runtime uses
        // f16 (tensor halfs), whose soft-float helpers (__addhf3 & co.) only
        // exist in zig's compiler_rt, not in emcc's libc.
        web_lib.bundle_compiler_rt = true;

        const emcc_flags = web_tools.emccDefaultFlags(b.allocator, .{ .optimize = optimize, .fsanitize = false });
        var emcc_settings = web_tools.emccDefaultSettings(b.allocator, .{
            .optimize = optimize,
            .emsdk_allocator = .emmalloc,
        });
        try emcc_settings.put("ALLOW_MEMORY_GROWTH", "1");
        try emcc_settings.put("MODULARIZE", "1");
        try emcc_settings.put("EXPORT_NAME", "createSkript");
        // Resolve the zigzag output import through Emscripten's JS library
        // mechanism. The generated function forwards to the host callback
        // supplied in the Module object by web/worker.js.
        const host_js_source =
            \\addToLibrary({
            \\  jsWrite: function(ptr, len) {
            \\    Module["skriptWrite"](ptr, len);
            \\  },
            \\});
        ;
        const host_js = b.addWriteFiles().add("zigzag-host.js", host_js_source);
        // The prelude eval recurses deeply; emscripten's default 64 KiB stack
        // overflows into a wasm trap.
        try emcc_settings.put("STACK_SIZE", "1048576");
        // SAFE_HEAP / STACK_OVERFLOW_CHECK stay at the emcc Debug defaults (1)
        // like the reference zemscripten builds. The web entry allocates through
        // emcc's malloc (c_allocator backing), which advances the sbrk break the
        // SAFE_HEAP guard checks — so the Debug checks are consistent and active.

        const emcc_output = web_tools.emccStep(b, &.{}, &.{web_lib}, .{
            .optimize = optimize,
            .flags = emcc_flags,
            .settings = emcc_settings,
            .js_library_path = host_js,
            .wasm_file_name = "skript.wasm",
            .out_file_name = "skript.js",
            .install_dir = .{ .custom = "web" },
        });
        const source_index = b.path("web/index.html");
        const source_worker = b.path("web/worker.js");
        const revisioned_index = web_tools.webAssetIndex(
            b,
            emcc_output.javascript,
            emcc_output.wasm.?,
            source_worker,
            source_index,
        );
        const install_index = b.addInstallFile(revisioned_index, "web/index.html");
        const install_worker = b.addInstallFile(source_worker, "web/worker.js");
        const web_step = b.step("web", "Build the Emscripten web app (requires emcc from the devenv)");
        web_step.dependOn(emcc_output.install_step);
        web_step.dependOn(&install_index.step);
        web_step.dependOn(&install_worker.step);
    }
}

/// Apply zig-cov instrumentation to a test binary:
///   * use_llvm: coverage instrumentation is only emitted by the LLVM backend
///   * fuzz: emits inline 8-bit counters and the PC table zig-cov reads
///   * link_libc: the runtime writes its .zcov from a libc atexit handler
fn instrument(compile: *std.Build.Step.Compile, rt_path: ?[]const u8) void {
    compile.use_llvm = true;
    compile.root_module.fuzz = true;
    compile.root_module.link_libc = true;
    if (rt_path) |p| compile.root_module.addObjectFile(.{ .cwd_relative = p });
}
