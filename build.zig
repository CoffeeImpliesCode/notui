//! Package graph for six native Zig modules, the toolkit executable, and usage examples.
//! `check` compiles consumer/test paths; `test` executes toolkit, REPL, and formula tests.
//! `docs` emits each registered root under `docs/<module>`. Examples are not library roots.
const std = @import("std");

/// Register the consumer modules and named build, check, test, example, and docs steps.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zig-cov coverage (see zig-cov README): zig-gate --cov passes these
    const coverage = b.option(bool, "coverage", "Enable zig-cov") orelse false;
    const cov_rt = b.option([]const u8, "coverage-rt", "zig-cov-rt path") orelse null;

    // Library dependency: zg — Unicode 18 text/width/graphemes. The only
    // one the `notui` module itself imports (src/width.zig is the single
    // seam).
    const zg = b.dependency("zg", .{});

    // skript — the Lisp runtime embedded by examples/skript_repl.zig.
    // VENDORED at vendor/skript (path dep, build.zig.zon): the repo
    // carries its own copy, so there is no sibling checkout to keep in
    // sync. Example-only — the `notui` module never imports it.
    // `enable_libffi = false` keeps the build lean: the REPL does not use
    // FFI. skript's own build fetches its tracy dependency
    // unconditionally (expected — the client is disabled by skript's
    // `enable_tracy` default).
    const skript_dep = b.dependency("skript", .{
        .target = target,
        .optimize = optimize,
        .enable_libffi = false,
        .cli = false,
    });

    // ── vendored ztex (vendor/ztex) ──────────────────────
    // Vendored formula modules are supported consumer routes. Their implementation lives
    // in this package; the terminal rasterizer remains an example, not a seventh module.
    const ztex_atom = b.addModule("ztex.atom", .{
        .root_source_file = b.path("vendor/ztex/src/atom.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ztex_parse = b.addModule("ztex.parse", .{
        .root_source_file = b.path("vendor/ztex/src/parse/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztex.atom", .module = ztex_atom },
            .{ .name = "zg", .module = zg.module("zg") },
        },
    });
    const ztex_layout = b.addModule("ztex.layout", .{
        .root_source_file = b.path("vendor/ztex/src/layout/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztex.atom", .module = ztex_atom },
            .{ .name = "zg", .module = zg.module("zg") },
            .{ .name = "DisplayWidth", .module = zg.module("DisplayWidth") },
            .{ .name = "Graphemes", .module = zg.module("Graphemes") },
        },
    });
    const ztex_svg = b.addModule("ztex.svg", .{
        .root_source_file = b.path("vendor/ztex/src/svg.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztex.layout", .module = ztex_layout },
        },
    });
    const ztex = b.addModule("ztex", .{
        .root_source_file = b.path("vendor/ztex/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztex.atom", .module = ztex_atom },
            .{ .name = "ztex.parse", .module = ztex_parse },
            .{ .name = "ztex.layout", .module = ztex_layout },
            .{ .name = "ztex.svg", .module = ztex_svg },
        },
    });

    // ── notui module ──────────────────────────
    const mod = b.addModule("notui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zg", .module = zg.module("zg") },
            .{ .name = "DisplayWidth", .module = zg.module("DisplayWidth") },
            .{ .name = "Graphemes", .module = zg.module("Graphemes") },
        },
    });

    // ── notui executable ──────────────────────────
    const exe = b.addExecutable(.{
        .name = "notui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "notui", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run notui");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    // ── examples ──────────────────────────
    // One executable + install + `run-example-*` step per recipe
    // (plan T7.1). Each example imports the notui module with the same
    // zg trio wiring as the library module.
    const examples = .{
        .{ .name = "spinner", .file = "examples/spinner.zig" },
        .{ .name = "prompt", .file = "examples/prompt.zig" },
        .{ .name = "statusline", .file = "examples/statusline.zig" },
        .{ .name = "framework_counter", .file = "examples/framework_counter.zig" },
        .{ .name = "kitty_image", .file = "examples/kitty_image.zig" },
        .{ .name = "kitty_image_showcase", .file = "examples/kitty_image_showcase.zig" },
        .{ .name = "bounded_smoke", .file = "examples/bounded_smoke.zig" },
        .{ .name = "agent_demo", .file = "examples/agent_demo.zig" },
    };
    inline for (examples) |ex| {
        const example_exe = b.addExecutable(.{
            .name = "example-" ++ ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "notui", .module = mod },
                    .{ .name = "zg", .module = zg.module("zg") },
                    .{ .name = "DisplayWidth", .module = zg.module("DisplayWidth") },
                    .{ .name = "Graphemes", .module = zg.module("Graphemes") },
                },
            }),
        });
        b.installArtifact(example_exe);

        const run_example_step = b.step(
            "run-example-" ++ ex.name,
            "Run the " ++ ex.name ++ " example",
        );
        const run_example_cmd = b.addRunArtifact(example_exe);
        run_example_cmd.step.dependOn(b.getInstallStep());
        run_example_cmd.addPassthruArgs();
        run_example_step.dependOn(&run_example_cmd.step);

        // The framework counter demo is also reachable via the shorter
        // `run-framework-counter` name (the batch acceptance step); the
        // tuple entry above already wires `run-example-framework_counter`.
        if (std.mem.eql(u8, ex.name, "framework_counter")) {
            const run_framework_counter_step = b.step(
                "run-framework-counter",
                "Run the framework counter example",
            );
            run_framework_counter_step.dependOn(&run_example_cmd.step);
        }

        // The kitty image demo is also reachable via the shorter
        // `run-kitty-image` name (the batch acceptance step); the tuple
        // entry above already wires `run-example-kitty_image`.
        if (std.mem.eql(u8, ex.name, "kitty_image")) {
            const run_kitty_image_step = b.step(
                "run-kitty-image",
                "Run the kitty image example",
            );
            run_kitty_image_step.dependOn(&run_example_cmd.step);
        }

        // The kitty showcase demo is also reachable via the shorter
        // `run-kitty-image-showcase` name (the batch acceptance step);
        // the tuple entry above already wires `run-example-kitty_image_showcase`.
        if (std.mem.eql(u8, ex.name, "kitty_image_showcase")) {
            const run_kitty_image_showcase_step = b.step(
                "run-kitty-image-showcase",
                "Run the kitty image showcase example",
            );
            run_kitty_image_showcase_step.dependOn(&run_example_cmd.step);
        }

        // The bounded-region smoke fixture is also reachable via the
        // shorter `run-bounded-smoke` name; the tuple entry above already
        // wires `run-example-bounded_smoke`.
        if (std.mem.eql(u8, ex.name, "bounded_smoke")) {
            const run_bounded_smoke_step = b.step(
                "run-bounded-smoke",
                "Run the bounded-region smoke fixture",
            );
            run_bounded_smoke_step.dependOn(&run_example_cmd.step);
        }
    }

    // ── skript REPL example ──────────────────────────
    // Embeds the skript runtime (worker-thread eval, fd-capture of the
    // form's stdout/stderr, base-ui Spinner status). Needs `link_libc`
    // for the capture extern block (skript contract §6); the skript
    // module carries its own internal imports (platform/options/tracy).
    const skript_repl = b.addExecutable(.{
        .name = "example-skript-repl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/skript_repl.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "notui", .module = mod },
                .{ .name = "zg", .module = zg.module("zg") },
                .{ .name = "DisplayWidth", .module = zg.module("DisplayWidth") },
                .{ .name = "Graphemes", .module = zg.module("Graphemes") },
                .{ .name = "skript", .module = skript_dep.module("skript") },
            },
        }),
    });
    b.installArtifact(skript_repl);

    const run_skript_repl_step = b.step(
        "run-skript-repl",
        "Run the skript REPL example",
    );
    const run_skript_repl_cmd = b.addRunArtifact(skript_repl);
    run_skript_repl_cmd.step.dependOn(b.getInstallStep());
    run_skript_repl_cmd.addPassthruArgs();
    run_skript_repl_step.dependOn(&run_skript_repl_cmd.step);

    // ── formula TUI example ──────────────────────────
    // LaTeX → ztex draw list → SIMD coverage rasterizer → kitty
    // graphics. Imports the vendored ztex modules (facade + atom for
    // the CharStyle ↔ face mapping).
    const formula_tui = b.addExecutable(.{
        .name = "example-formula-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/formula_tui.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "notui", .module = mod },
                .{ .name = "zg", .module = zg.module("zg") },
                .{ .name = "DisplayWidth", .module = zg.module("DisplayWidth") },
                .{ .name = "Graphemes", .module = zg.module("Graphemes") },
                .{ .name = "ztex", .module = ztex },
                .{ .name = "ztex.atom", .module = ztex_atom },
                .{ .name = "ztex.parse", .module = ztex_parse },
                .{ .name = "ztex.layout", .module = ztex_layout },
                .{ .name = "ztex.svg", .module = ztex_svg },
            },
        }),
    });
    b.installArtifact(formula_tui);

    const run_formula_tui_step = b.step(
        "run-formula-tui",
        "Run the LaTeX formula TUI example",
    );
    const run_formula_tui_cmd = b.addRunArtifact(formula_tui);
    run_formula_tui_cmd.step.dependOn(b.getInstallStep());
    run_formula_tui_cmd.addPassthruArgs();
    run_formula_tui_step.dependOn(&run_formula_tui_cmd.step);

    // ── unit tests ──────────────────────────
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zg", .module = zg.module("zg") },
                .{ .name = "DisplayWidth", .module = zg.module("DisplayWidth") },
                .{ .name = "Graphemes", .module = zg.module("Graphemes") },
            },
        }),
    });
    if (coverage) {
        unit_tests.use_llvm = true; // required: only the LLVM backend emits sancov counters
        unit_tests.root_module.fuzz = true; // emits __sancov_cntrs + __sancov_pcs1
        unit_tests.root_module.link_libc = true; // atexit handler writes the .zcov
        if (cov_rt) |p| unit_tests.root_module.addObjectFile(.{ .cwd_relative = p });
    }
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const repl_tests = b.addTest(.{ .root_module = skript_repl.root_module });
    const run_repl_tests = b.addRunArtifact(repl_tests);
    test_step.dependOn(&run_repl_tests.step);
    const test_repl_step = b.step("test-repl", "Run REPL behavior regressions");
    test_repl_step.dependOn(&run_repl_tests.step);

    const formula_tests = b.addTest(.{ .root_module = ztex });
    const run_formula_tests = b.addRunArtifact(formula_tests);
    test_step.dependOn(&run_formula_tests.step);
    const test_formula_step = b.step("test-formula", "Run formula contract regressions");
    test_formula_step.dependOn(&run_formula_tests.step);

    const check_step = b.step("check", "Compile toolkit, REPL, and formula consumer paths");
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&repl_tests.step);
    check_step.dependOn(&formula_tests.step);

    // ── bench ──────────────────────────
    // The render-pipeline benchmark (ROADMAP F2): frame time p50/p99,
    // bytes per frame and allocations per frame for the static, streaming
    // and region-repaint cases. It is built at `bench_optimize`, which
    // defaults to ReleaseFast so the numbers measure the pipeline rather
    // than a Debug build; an explicit `-Doptimize` (or `--release=…`)
    // still wins. The whole compilation must be optimized, so the bench
    // gets its own `notui` module instance and its own zg dependency
    // instance, both at `bench_optimize`, wired exactly like `mod` below
    // (zg / DisplayWidth / Graphemes). The bench step runs the artifact
    // but does not install it.
    const bench_optimize: std.builtin.OptimizeMode = blk: {
        if (b.user_input_options.contains("optimize")) break :blk optimize;
        if (b.graph.release_mode != .off) break :blk optimize;
        break :blk .fast;
    };
    const bench_zg = b.dependency("zg", .{ .optimize = bench_optimize });
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{
            .{ .name = "zg", .module = bench_zg.module("zg") },
            .{ .name = "DisplayWidth", .module = bench_zg.module("DisplayWidth") },
            .{ .name = "Graphemes", .module = bench_zg.module("Graphemes") },
        },
    });
    const bench_exe = b.addExecutable(.{
        .name = "notui-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = bench_optimize,
            .imports = &.{
                .{ .name = "notui", .module = bench_mod },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the render-pipeline benchmark");
    bench_step.dependOn(&run_bench.step);

    const docs_step = b.step("docs", "Generate documentation for every registered module");
    inline for (.{
        .{ "notui", mod },
        .{ "ztex", ztex },
        .{ "ztex.atom", ztex_atom },
        .{ "ztex.parse", ztex_parse },
        .{ "ztex.layout", ztex_layout },
        .{ "ztex.svg", ztex_svg },
    }) |entry| {
        const library = b.addLibrary(.{ .name = entry[0], .root_module = entry[1] });
        const install_docs = b.addInstallDirectory(.{
            .source_dir = library.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs/" ++ entry[0],
        });
        docs_step.dependOn(&install_docs.step);
    }
}
