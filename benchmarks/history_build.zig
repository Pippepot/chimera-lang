const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const bundled = b.option(bool, "bundled-std", "Use this revision's precompiled standard library") orelse false;
    const standard_library = b.createModule(.{ .root_source_file = b.path("std/library.zig") });
    const compiler = b.createModule(.{
        .root_source_file = b.path("src/.history_compiler.zig"),
        .target = target,
        .optimize = .fast,
    });
    compiler.addImport("standard_library", standard_library);
    const driver = b.createModule(.{
        .root_source_file = b.path("benchmarks/history_benchmark.zig"),
        .target = target,
        .optimize = .fast,
    });
    driver.addImport("compiler", compiler);
    if (bundled) {
        const precompiler_module = b.createModule(.{
            .root_source_file = b.path("src/precompile_std.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        });
        precompiler_module.addImport("standard_library", standard_library);
        const precompiler = b.addExecutable(.{ .name = "history-precompile-std", .root_module = precompiler_module });
        const precompile = b.addRunArtifact(precompiler);
        const bundle = precompile.addOutputFileArg("std.chimera-artifact");
        driver.addAnonymousImport("standard_bundle", .{ .root_source_file = bundle });
    }
    const executable = b.addExecutable(.{ .name = "history_benchmark", .root_module = driver, .use_llvm = true });
    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("history-benchmark", "Measure the fixed history suite against this compiler").dependOn(&run.step);
}
