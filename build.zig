const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = optimize == .fast;
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

    const precompiler_module = b.createModule(.{
        .root_source_file = b.path("src/precompile_std.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    });
    precompiler_module.addImport("standard_library", standard_library);
    const precompiler = b.addExecutable(.{ .name = "precompile-std", .root_module = precompiler_module });
    const precompile = b.addRunArtifact(precompiler);
    const standard_bundle = precompile.addOutputFileArg("std.chi-artifact");
    root_module.addAnonymousImport("standard_bundle", .{ .root_source_file = standard_bundle });

    const compiler = b.addExecutable(.{
        .name = "chi",
        .root_module = root_module,
        .use_llvm = use_llvm,
    });
    compiler.incremental = true;
    compiler.build_id = .sha1;
    b.installArtifact(compiler);

    const run = b.addRunArtifact(compiler);
    run.addPassthruArgs();
    const run_step = b.step("run", "Compile and run a Chi program");
    run_step.dependOn(&run.step);

    const benchmark_compiler = b.createModule(.{
        .root_source_file = b.path("src/benchmark_deps.zig"),
    });
    benchmark_compiler.addImport("standard_library", standard_library);
    for ([_]struct { name: []const u8, source: []const u8, step: []const u8, description: []const u8, optimize: ?std.builtin.OptimizeMode = null, bundled_std: bool = false }{
        .{ .name = "comptime_benchmark", .source = "benchmarks/comptime_benchmark.zig", .step = "benchmark", .description = "Run the compile-time execution benchmark" },
        .{ .name = "flow_benchmark", .source = "benchmarks/flow_benchmark.zig", .step = "flow-benchmark", .description = "Measure typing snapshots and lifetime tables" },
        .{ .name = "conversion_benchmark", .source = "benchmarks/conversion_benchmark.zig", .step = "conversion-benchmark", .description = "Measure converter discovery and repeated matching" },
        .{ .name = "std_benchmark", .source = "benchmarks/std_benchmark.zig", .step = "std-benchmark", .description = "Compare fresh compilation with source and precompiled std", .bundled_std = true },
        .{ .name = "prelude_benchmark", .source = "benchmarks/prelude_benchmark.zig", .step = "test-prelude-performance", .description = "Check cold prelude loading and scalar compilation budgets", .optimize = .fast },
        .{ .name = "prelude_debug_benchmark", .source = "benchmarks/prelude_benchmark.zig", .step = "test-prelude-debug-performance", .description = "Check cold Debug prelude loading and scalar compilation budgets", .optimize = .debug },
    }) |benchmark| {
        const benchmark_optimize = benchmark.optimize orelse optimize;
        const benchmark_module = b.createModule(.{
            .root_source_file = b.path(benchmark.source),
            .target = target,
            .optimize = benchmark_optimize,
        });
        benchmark_module.addImport("compiler", benchmark_compiler);
        if (benchmark.bundled_std)
            benchmark_module.addAnonymousImport("standard_bundle", .{ .root_source_file = standard_bundle });
        const executable = b.addExecutable(.{ .name = benchmark.name, .root_module = benchmark_module, .use_llvm = benchmark_optimize == .fast });
        b.step(benchmark.step, benchmark.description).dependOn(&b.addRunArtifact(executable).step);
    }

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
    test_sources_module.addAnonymousImport("standard_bundle", .{ .root_source_file = standard_bundle });
    const selected_test_source = b.option([]const u8, "test-source", "Run only tests from this source file");
    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const test_sources: []const []const u8 = if (selected_test_source) |source| &.{source} else &.{
        "test_sources.zig",
        "tests/query_test.zig",
        "tests/codegen_test.zig",
        "tests/modules_test.zig",
        "tests/match_test.zig",
        "tests/overload_test.zig",
        "tests/query_disk_cache_test.zig",
        "tests/query_artifact_test.zig",
        "tests/array_test.zig",
        "tests/collection_test.zig",
        "tests/iteration_test.zig",
        "tests/list_test.zig",
        "tests/tuple_test.zig",
        "tests/reference_test.zig",
        "tests/text_test.zig",
        "tests/panic_test.zig",
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
        if (std.mem.eql(u8, source, "test_sources.zig"))
            test_module.addAnonymousImport("standard_bundle", .{ .root_source_file = standard_bundle });
        const test_binary = b.addTest(.{ .root_module = test_module, .filters = if (test_filter) |filter| &.{filter} else &.{}, .use_llvm = use_llvm });
        // Disk-cache tests identify the compiler image without hashing the whole binary.
        test_binary.build_id = .sha1;
        const run_test = b.addRunArtifact(test_binary);
        run_test.setCwd(test_binary.getEmittedBin().dirname());
        test_step.dependOn(&run_test.step);
    }
}
