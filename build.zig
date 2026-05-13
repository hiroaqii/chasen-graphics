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
