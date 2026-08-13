const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zig-cov coverage (see zig-cov README): zig-gate --cov passes these
    const coverage = b.option(bool, "coverage", "Enable zig-cov") orelse false;
    const cov_rt = b.option([]const u8, "coverage-rt", "zig-cov-rt path") orelse null;

    // Sole dependency: zg — Unicode 16 text/width/graphemes.
    const zg = b.dependency("zg", .{});

    // skript — the Lisp runtime embedded by examples/skript_repl.zig
    // (path dep, build.zig.zon). `enable_libffi = false` keeps the build
    // lean: the REPL does not use FFI. skript's own build fetches its
    // tracy dependency unconditionally (expected — the client is disabled
    // by skript's `enable_tracy` default).
    const skript_dep = b.dependency("skript", .{
        .target = target,
        .optimize = optimize,
        .enable_libffi = false,
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
    if (b.args) |args| run_cmd.addArgs(args);
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
        if (b.args) |args| run_example_cmd.addArgs(args);
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
    if (b.args) |args| run_skript_repl_cmd.addArgs(args);
    run_skript_repl_step.dependOn(&run_skript_repl_cmd.step);

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
}
