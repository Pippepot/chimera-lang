const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const standard_library = b.createModule(.{
        .root_source_file = b.path("std/library.zig"),
    });
    root_module.addImport("standard_library", standard_library);

    const compiler = b.addExecutable(.{
        .name = "chi",
        .root_module = root_module,
    });
    b.installArtifact(compiler);

    const run = b.addRunArtifact(compiler);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Compile and run a Chi program");
    run_step.dependOn(&run.step);
}
