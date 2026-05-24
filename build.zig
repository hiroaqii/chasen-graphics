const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("chasen_graphics", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const chasen_dep = b.lazyDependency("chasen", .{
        .target = target,
        .optimize = optimize,
    });

    const check_chasen_adapter_step = b.step("check-chasen-adapter", "Build the optional Chasen terminal image adapter");
    if (chasen_dep) |dep| {
        const chasen_adapter_mod = b.addModule("chasen_graphics_chasen", .{
            .root_source_file = b.path("src/chasen_adapter.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "chasen", .module = dep.module("chasen") },
                .{ .name = "chasen_graphics", .module = mod },
            },
        });

        const chasen_adapter_tests = b.addTest(.{
            .root_module = chasen_adapter_mod,
        });
        const run_chasen_adapter_tests = b.addRunArtifact(chasen_adapter_tests);
        check_chasen_adapter_step.dependOn(&run_chasen_adapter_tests.step);

        const terminal_image_example = b.addExecutable(.{
            .name = "terminal-image",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/terminal_image/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "chasen", .module = dep.module("chasen") },
                    .{ .name = "chasen_graphics_chasen", .module = chasen_adapter_mod },
                },
            }),
        });

        const check_terminal_image_step = b.step("check-terminal-image", "Build the terminal image example");
        check_terminal_image_step.dependOn(&terminal_image_example.step);

        const run_terminal_image = b.addRunArtifact(terminal_image_example);
        const run_terminal_image_step = b.step("run-terminal-image", "Run the terminal image example");
        run_terminal_image_step.dependOn(&run_terminal_image.step);
    }

    const zigimg_dep = b.lazyDependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const check_zigimg_adapter_step = b.step("check-zigimg-adapter", "Build the optional zigimg image decode adapter");
    if (zigimg_dep) |dep| {
        const zigimg_adapter_mod = b.addModule("chasen_graphics_zigimg", .{
            .root_source_file = b.path("src/zigimg_adapter.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "chasen_graphics", .module = mod },
                .{ .name = "zigimg", .module = dep.module("zigimg") },
            },
        });

        const zigimg_adapter_tests = b.addTest(.{
            .root_module = zigimg_adapter_mod,
        });
        const run_zigimg_adapter_tests = b.addRunArtifact(zigimg_adapter_tests);
        check_zigimg_adapter_step.dependOn(&run_zigimg_adapter_tests.step);
    }

    const braille_mask_example = b.addExecutable(.{
        .name = "braille-mask",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/braille_mask.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "chasen_graphics", .module = mod },
            },
        }),
    });

    const run_braille_mask_example = b.addRunArtifact(braille_mask_example);
    const run_braille_mask_step = b.step("run-braille-mask", "Run the Braille dot mask example");
    run_braille_mask_step.dependOn(&run_braille_mask_example.step);
}
