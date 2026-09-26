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

    const benchmark_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/comptime_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    benchmark_module.addImport("compiler", b.createModule(.{
        .root_source_file = b.path("src/benchmark_deps.zig"),
    }));
    const benchmark = b.addExecutable(.{ .name = "comptime_benchmark", .root_module = benchmark_module });
    const benchmark_step = b.step("benchmark", "Run the compile-time execution benchmark");
    benchmark_step.dependOn(&b.addRunArtifact(benchmark).step);

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
    const selected_test_source = b.option([]const u8, "test-source", "Run only tests from this source file");
    var has_matching_source = selected_test_source == null;
    for (test_sources) |source| {
        if (selected_test_source) |selected| {
            if (!std.mem.eql(u8, selected, source)) continue;
            has_matching_source = true;
        }
        const test_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
        });
        test_module.addImport("standard_library", standard_library);
        test_module.addImport("test_sources", test_sources_module);
        const test_binary = b.addTest(.{ .root_module = test_module });
        const run_test = b.addRunArtifact(test_binary);
        const workdir = b.addWriteFiles();
        _ = workdir.add(".test-suite", source);
        run_test.setCwd(workdir.getDirectory());
        test_step.dependOn(&run_test.step);
    }
    if (!has_matching_source) test_step.dependOn(&b.addFail(b.fmt("unknown test source: {s}", .{selected_test_source.?})).step);
}
