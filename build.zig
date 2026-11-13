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
        .optimize = .debug,
    });
    precompiler_module.addImport("standard_library", standard_library);
    const precompiler = b.addExecutable(.{ .name = "precompile-std", .root_module = precompiler_module, .use_llvm = false });
    const precompile = b.addRunArtifact(precompiler);
    const standard_bundle = precompile.addOutputFileArg("std.chimera-artifact");
    root_module.addAnonymousImport("standard_bundle", .{ .root_source_file = standard_bundle });

    const compiler = b.addExecutable(.{
        .name = "chimera",
        .root_module = root_module,
        .use_llvm = use_llvm,
    });
    compiler.incremental = false;
    compiler.build_id = .sha1;
    b.installArtifact(compiler);

    const run = b.addRunArtifact(compiler);
    run.addPassthruArgs();
    const run_step = b.step("run", "Compile and run a Chimera program");
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
        .{ .name = "history_benchmark", .source = "benchmarks/history_benchmark.zig", .step = "history-benchmark", .description = "Measure versioned end-to-end compiler workloads", .optimize = .fast, .bundled_std = true },
        .{ .name = "provenance_benchmark", .source = "benchmarks/provenance_benchmark.zig", .step = "provenance-benchmark", .description = "Measure result-correlated mutation provenance", .optimize = .fast, .bundled_std = true },
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
        const benchmark_run = b.addRunArtifact(executable);
        if (std.mem.eql(u8, benchmark.name, "history_benchmark") or std.mem.eql(u8, benchmark.name, "provenance_benchmark")) {
            benchmark_run.addPassthruArgs();
        }
        b.step(benchmark.step, benchmark.description).dependOn(&benchmark_run.step);
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
        "tests/query_engine_test.zig",
        "tests/query_test.zig",
        "tests/codegen_test.zig",
        "tests/language_test.zig",
        "tests/callable_test.zig",
        "tests/shared_context_test.zig",
        "tests/logging_test.zig",
        "tests/operation_test.zig",
        "tests/numeric_test.zig",
        "tests/optimizer_test.zig",
        "tests/match_test.zig",
        "tests/membership_test.zig",
        "tests/binding_test.zig",
        "tests/flow_typing_test.zig",
        "tests/overload_test.zig",
        "tests/query_disk_cache_test.zig",
        "tests/query_artifact_test.zig",
        "tests/array_test.zig",
        "tests/collection_test.zig",
        "tests/sort_test.zig",
        "tests/iteration_test.zig",
        "tests/list_test.zig",
        "tests/tuple_test.zig",
        "tests/reference_test.zig",
        "tests/text_test.zig",
        "tests/files_test.zig",
        "tests/panic_test.zig",
        "tests/converter_test.zig",
        "tests/nominal_variant_test.zig",
        "tests/comptime_interpreter_test.zig",
    };
    var matched_sources: usize = 0;
    for (test_sources) |source| {
        if (selected_test_source == null) {
            if (test_filter) |filter| {
                var visited: std.StringHashMapUnmanaged(void) = .empty;
                defer visited.deinit(b.allocator);
                if (!(testSourceMatches(b, source, filter, &visited) catch @panic("unable to discover filtered tests"))) continue;
            }
        }
        matched_sources += 1;
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
    if (matched_sources == 0) {
        std.log.err("no test sources match '{s}'", .{test_filter.?});
        std.process.exit(1);
    }
}

fn testSourceMatches(b: *std.Build, source: []const u8, filter: []const u8, visited: *std.StringHashMapUnmanaged(void)) anyerror!bool {
    const path = try std.fs.path.resolve(b.allocator, &.{source});
    const entry = try visited.getOrPut(b.allocator, path);
    if (entry.found_existing) return false;
    b.dependOnFileContents(b.path(path));
    const file = try b.root.openFile(b.graph.io, path, .{});
    defer file.close(b.graph.io);
    var reader = file.reader(b.graph.io, &.{});
    const contents = try reader.interface.allocRemainingAlignedSentinel(b.allocator, .unlimited, .of(u8), 0);
    defer b.allocator.free(contents);
    if (try testDeclarationsMatch(b.allocator, contents, source, filter)) return true;
    var tokenizer = std.zig.Tokenizer.init(contents);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return false;
        if (token.tag != .builtin or !std.mem.eql(u8, contents[token.loc.start..token.loc.end], "@import")) continue;
        if (tokenizer.next().tag != .l_paren) continue;
        const argument = tokenizer.next();
        if (argument.tag != .string_literal) continue;
        const import_path = try std.zig.string_literal.parseAlloc(b.allocator, contents[argument.loc.start..argument.loc.end]);
        defer b.allocator.free(import_path);
        if (!std.mem.endsWith(u8, import_path, ".zig")) continue;
        const imported_source = try std.fs.path.resolve(b.allocator, &.{ std.fs.path.dirname(path) orelse ".", import_path });
        if (try testSourceMatches(b, imported_source, filter, visited)) return true;
    }
}

fn testDeclarationsMatch(allocator: std.mem.Allocator, contents: [:0]const u8, source: []const u8, filter: []const u8) !bool {
    const namespace = try allocator.dupe(u8, source[0 .. source.len - ".zig".len]);
    defer allocator.free(namespace);
    std.mem.replaceScalar(u8, namespace, '/', '.');
    var tokenizer = std.zig.Tokenizer.init(contents);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return false;
        if (token.tag == .invalid) return true;
        if (token.tag != .keyword_test) continue;
        const name_token = tokenizer.next();
        if (name_token.tag != .string_literal and name_token.tag != .identifier) continue;
        const spelling = contents[name_token.loc.start..name_token.loc.end];
        const name = if (name_token.tag == .string_literal or std.mem.startsWith(u8, spelling, "@\""))
            try std.zig.string_literal.parseAlloc(allocator, if (spelling[0] == '@') spelling[1..] else spelling)
        else
            try allocator.dupe(u8, spelling);
        defer allocator.free(name);
        const qualified_name = try allocator.print("{s}.test.{s}", .{ namespace, name });
        defer allocator.free(qualified_name);
        if (std.mem.indexOf(u8, qualified_name, filter) != null) return true;
    }
}

test "filtered test discovery reads Zig names rather than comments or fixtures" {
    const allocator = std.testing.allocator;
    const source =
        \\// test "comment only" {}
        \\const fixture = "test \"fixture only\" {}";
        \\test "selected \x6eame" {}
        \\test identifier {}
        \\test @"quoted identifier" {}
    ;
    try std.testing.expect(try testDeclarationsMatch(allocator, source, "tests/example_test.zig", "selected name"));
    try std.testing.expect(try testDeclarationsMatch(allocator, source, "tests/example_test.zig", "example_test.test.selected"));
    try std.testing.expect(try testDeclarationsMatch(allocator, source, "tests/example_test.zig", "test.identifier"));
    try std.testing.expect(try testDeclarationsMatch(allocator, source, "tests/example_test.zig", "quoted identifier"));
    try std.testing.expect(!(try testDeclarationsMatch(allocator, source, "tests/example_test.zig", "comment only")));
    try std.testing.expect(!(try testDeclarationsMatch(allocator, source, "tests/example_test.zig", "fixture only")));
}
