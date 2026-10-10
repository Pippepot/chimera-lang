const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .fast or optimize == .small,
    });
    const standard_library = b.createModule(.{
        .root_source_file = b.path("std/library.zig"),
    });
    root_module.addImport("standard_library", standard_library);

    const compiler = b.addExecutable(.{
        .name = "chi",
        .root_module = root_module,
    });
    compiler.incremental = true;
    compiler.build_id = .sha1;
    b.installArtifact(compiler);

    const run = b.addRunArtifact(compiler);
    run.addPassthruArgs();
    const run_step = b.step("run", "Compile and run a Chi program");
    run_step.dependOn(&run.step);

    const benchmark_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/comptime_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    const benchmark_compiler = b.createModule(.{
        .root_source_file = b.path("src/benchmark_deps.zig"),
    });
    benchmark_compiler.addImport("standard_library", standard_library);
    benchmark_module.addImport("compiler", benchmark_compiler);
    const benchmark = b.addExecutable(.{ .name = "comptime_benchmark", .root_module = benchmark_module });
    const benchmark_step = b.step("benchmark", "Run the compile-time execution benchmark");
    benchmark_step.dependOn(&b.addRunArtifact(benchmark).step);

    const flow_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/flow_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    flow_module.addImport("compiler", benchmark_compiler);
    const flow_benchmark = b.addExecutable(.{ .name = "flow_benchmark", .root_module = flow_module });
    b.step("flow-benchmark", "Measure typing snapshots and lifetime tables").dependOn(&b.addRunArtifact(flow_benchmark).step);

    const test_step = b.step("test", "Run compiler tests (allocation-failure sweeps are opt-in)");
    const test_options = b.addOptions();
    test_options.addOption(bool, "allocation_failures", b.option(bool, "allocation-failures", "Include exhaustive allocation-failure tests") orelse false);
    const test_options_module = test_options.createModule();
    const test_sources_module = b.createModule(.{
        .root_source_file = b.path("test_sources.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_sources_module.addImport("standard_library", standard_library);
    test_sources_module.addImport("test_options", test_options_module);
    const selected_test_source = b.option([]const u8, "test-source", "Run only tests from this source file");
    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const test_sources: []const []const u8 = if (selected_test_source) |source| &.{source} else &.{
        "test_sources.zig",
        "tests/query_test.zig",
        "tests/codegen_test.zig",
        "tests/modules_test.zig",
        "tests/query_disk_cache_test.zig",
        "tests/array_test.zig",
        "tests/converter_test.zig",
        "tests/comptime_interpreter_test.zig",
    };
    for (test_sources) |source| {
        const test_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
        });
        test_module.addImport("standard_library", standard_library);
        test_module.addImport("test_sources", test_sources_module);
        test_module.addImport("test_options", test_options_module);
        const test_binary = b.addTest(.{ .root_module = test_module, .filters = if (test_filter) |filter| &.{filter} else &.{} });
        // Disk-cache tests identify the compiler image without hashing the whole binary.
        test_binary.build_id = .sha1;
        const run_test = b.addRunArtifact(test_binary);
        run_test.setCwd(test_binary.getEmittedBin().dirname());
        test_step.dependOn(&run_test.step);
    }
}
