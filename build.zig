const std = @import("std");

const Options = struct {
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
};

pub fn build(b: *std.Build) void {
    const options: Options = .{
        .optimize = b.standardOptimizeOption(.{}),
        .target = b.standardTargetOptions(.{}),
    };

    // Add the library to the package's module set
    b.modules.put("toml", addTomlMod(b, options)) catch @panic("OOM");

    const test_step = b.step("test", "Run all of the tests");

    // Unit tests
    {
        const step = b.step("test-unit", "Run the unit tests");
        const tests = b.addTest(.{ .root_module = addTomlMod(b, options) });
        step.dependOn(&b.addRunArtifact(tests).step);
        test_step.dependOn(step);
    }

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

fn addTomlMod(b: *std.Build, opts: Options) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });

    return mod;
}
