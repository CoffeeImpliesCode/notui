const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Sole dependency: zg — Unicode 16 text/width/graphemes.
    const zg = b.dependency("zg", .{});

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
    }

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
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
