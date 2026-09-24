const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast or optimize == .ReleaseSmall,
    });
    const standard_library = b.createModule(.{
        .root_source_file = b.path("std/library.zig"),
    });
    root_module.addImport("standard_library", standard_library);

    const compiler = b.addExecutable(.{
        .name = "chi",
        .root_module = root_module,
    });
    compiler.build_id = .sha1;
    b.installArtifact(compiler);

    const run = b.addRunArtifact(compiler);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Compile and run a Chi program");
    run_step.dependOn(&run.step);

    const test_step = b.step("test", "Run all compiler tests");
    const test_sources_module = b.createModule(.{
        .root_source_file = b.path("test_sources.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_sources_module.addImport("standard_library", standard_library);
    const test_sources = [_][]const u8{
        "test_sources.zig",
        "src/diagnostics.zig",
        "src/runtime.zig",
        "tests/query_test.zig",
        "tests/codegen_test.zig",
        "src/main.zig",
        "src/modules.zig",
        "tests/modules_test.zig",
        "src/cache.zig",
        "src/query_disk_cache.zig",
    };
    var previous_test: ?*std.Build.Step = null;
    for (test_sources) |source| {
        const test_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
        });
        test_module.addImport("standard_library", standard_library);
        test_module.addImport("test_sources", test_sources_module);
        const test_binary = b.addTest(.{ .root_module = test_module });
        const run_test = b.addRunArtifact(test_binary);
        if (previous_test) |previous| run_test.step.dependOn(previous);
        test_step.dependOn(&run_test.step);
        previous_test = &run_test.step;
    }
}
