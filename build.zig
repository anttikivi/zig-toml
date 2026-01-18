const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const mod = b.addModule("toml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run all of the tests");
    test_step.dependOn(&run_mod_tests.step);

    // Formatting tasks

    const fmt_include_paths = &.{"."};

    {
        const step = b.step("fmt", "Modify source files in place to have conforming formatting");
        step.dependOn(&b.addFmt(.{ .paths = fmt_include_paths }).step);
    }

    {
        const step = b.step("test-fmt", "Check source files having conforming formatting");
        step.dependOn(&b.addFmt(.{ .paths = fmt_include_paths, .check = true }).step);
        test_step.dependOn(step);
    }
}
