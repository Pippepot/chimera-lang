const std = @import("std");
const test_sources = @import("test_sources");
const SourceFixture = test_sources.SourceFixture;

test "logging severity conveniences deliver their level and message in both engines" {
    try SourceFixture.expectParity(
        \\import std.logging.{Logger, LogLevel, enabled}
        \\import std.logging as logging
        \\struct Probe
        \\    pub func emit(imm self: Probe, level: LogLevel, imm message: StringView) unit -> unit
        \\func severity(log_level: LogLevel) int
        \\    const probe = Probe{}
        \\    if not enabled(Logger.from(Probe, probe, LogLevel.debug), log_level) -> return 1
        \\    if not enabled(Logger.from(Probe, probe, LogLevel.info), log_level) -> return 2
        \\    if not enabled(Logger.from(Probe, probe, LogLevel.warning), log_level) -> return 3
        \\    if not enabled(Logger.from(Probe, probe, LogLevel.error), log_level) -> return 4
        \\    return 5
        \\struct Backend
        \\    calls: int
        \\    levels: int
        \\    valid: bool
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit
        \\        const number = severity(level)
        \\        self.calls += 1
        \\        self.levels = self.levels * 10 + number
        \\        self.valid = self.valid and message.byte_length() == number
        \\func run() int
        \\    var backend = Backend{calls = 0, levels = 0, valid = true}
        \\    with context.logger = Logger.from(Backend, backend, LogLevel.trace)
        \\        if not (logging.trace("t") is unit) -> return 90
        \\        if not (logging.debug("de") is unit) -> return 91
        \\        if not (logging.info("inf") is unit) -> return 92
        \\        if not (logging.warning("warn") is unit) -> return 93
        \\        if not (logging.error("error") is unit) -> return 94
        \\    if backend.calls <> 5 or backend.levels <> 12345 or not backend.valid -> return 95
        \\    return 42
    , 42);
}

test "logging severity conveniences filter dispatch without suppressing arguments in both engines" {
    try SourceFixture.expectParity(
        \\import std.logging.{Logger, LogLevel}
        \\import std.logging as logging
        \\struct Backend
        \\    calls: int
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit
        \\        self.calls += 1
        \\func build_message(mut built: int) StringView
        \\    built += 1
        \\    return "built"
        \\func exercise(mut built: int) bool
        \\    if not (logging.trace(build_message(built)) is unit) -> return false
        \\    if not (logging.debug(build_message(built)) is unit) -> return false
        \\    if not (logging.info(build_message(built)) is unit) -> return false
        \\    if not (logging.warning(build_message(built)) is unit) -> return false
        \\    return logging.error(build_message(built)) is unit
        \\func run() int
        \\    var backend = Backend{calls = 0}
        \\    var built = 0
        \\    with context.logger = Logger.from(Backend, backend, LogLevel.info)
        \\        if not exercise(built) -> return 90
        \\    if built <> 5 or backend.calls <> 3 -> return 91
        \\    with context.logger = Logger.from(Backend, backend, LogLevel.off)
        \\        if not exercise(built) -> return 92
        \\    if built <> 10 or backend.calls <> 3 -> return 93
        \\    return 42
    , 42);
}

test "logging severity conveniences forward marked failures and recover in both engines" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll(
        \\import std.logging.{Logger, LogLevel}
        \\import std.logging as logging
        \\import std.memory.{AllocationError}
        \\import std.io.{IoError}
        \\struct Backend
        \\    calls: int
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit | AllocationError | IoError
        \\        self.calls += 1
        \\        if self.calls % 3 == 1 -> return AllocationError.budget
        \\        if self.calls % 3 == 2 -> return IoError{cause = 11, progress = 23}
        \\        return unit
        \\func run() int
        \\    var backend = Backend{calls = 0}
        \\    with context.logger = Logger.from(Backend, backend, LogLevel.trace)
        \\
    );
    for ([_][]const u8{ "trace", "debug", "info", "warning", "error" }) |severity| {
        try source.writer.print(
            \\        const {s}_allocation = logging.{s}("allocation")
            \\        if not ({s}_allocation is AllocationError) -> return 90
            \\        if {s}_allocation.reason <> AllocationError.budget.reason -> return 91
            \\        const {s}_io = logging.{s}("io")
            \\        if not ({s}_io is IoError) -> return 92
            \\        if {s}_io.cause <> 11 or {s}_io.progress <> 23 -> return 93
            \\        if not (logging.{s}("recovered") is unit) -> return 94
            \\
        , .{ severity, severity, severity, severity, severity, severity, severity, severity, severity, severity });
    }
    try source.writer.writeAll(
        \\    if backend.calls <> 15 -> return 95
        \\    return 42
    );
    try SourceFixture.expectParity(source.written(), 42);
}

test "logging severity conveniences use native root stderr and evaluator root no-op" {
    const source =
        \\import std.logging as logging
        \\func run() int
        \\    if not (logging.trace("visible trace") is unit) -> return 90
        \\    if not (logging.debug("visible debug") is unit) -> return 91
        \\    if not (logging.info("visible info") is unit) -> return 92
        \\    if not (logging.warning("visible warning") is unit) -> return 93
        \\    if not (logging.error("visible error") is unit) -> return 94
        \\    return 42
    ;
    for ([_][]const u8{ "exit(run())", "exit(comptime -> run())" }, 0..) |entry, index| {
        const program_source = try std.testing.allocator.print("{s}\n{s}", .{ source, entry });
        defer std.testing.allocator.free(program_source);
        const fixture = try SourceFixture.init(program_source);
        defer fixture.deinit();
        const result = try fixture.runIo("");
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expectEqualStrings(if (index == 0) "trace: visible trace\ndebug: visible debug\ninfo: visible info\nwarning: visible warning\nerror: visible error\n" else "", result.stderr);
    }
}

fn runWithStderr(source: []const u8, stderr: std.Io.File) !std.process.Child.Term {
    const fixture = try SourceFixture.init(source);
    defer fixture.deinit();
    const executable = try fixture.executable(0);
    var program = try test_sources.runtime.prepareProgram(std.testing.io, std.testing.allocator, executable.bytes);
    defer program.deinit(std.testing.io);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "prog") catch {};
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{program.path},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .{ .file = stderr },
    });
    defer child.kill(std.testing.io);
    return child.wait(std.testing.io);
}

test "root logging borrows allocated messages without calling a refusing allocator" {
    const source =
        \\import std.logging as logging
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError}
        \\struct Refusal
        \\    calls: int
        \\    pub func allocate(mut self: Refusal, layout: AllocationLayout) RawBlock | AllocationError
        \\        self.calls += 1
        \\        return AllocationError.budget
        \\    pub func deallocate(imm self: Refusal, deinit block: RawBlock)
        \\        panic "refusing allocator has no storage to release"
        \\func run() int
        \\    var message = "borrowed\0text"
        \\    message.append("!") catch -> return 90
        \\    var refusal = Refusal{calls = 0}
        \\    with context.allocator = Allocator.from(Refusal, refusal)
        \\        if not (logging.info(message.view()) is unit) -> return 91
        \\    return refusal.calls + 42
    ;
    for ([_][]const u8{ "exit(run())", "exit(comptime -> run())" }, 0..) |entry, index| {
        const program_source = try std.testing.allocator.print("{s}\n{s}", .{ source, entry });
        defer std.testing.allocator.free(program_source);
        const fixture = try SourceFixture.init(program_source);
        defer fixture.deinit();
        const result = try fixture.runIo("");
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expectEqualStrings(if (index == 0) "info: borrowed\x00text!\n" else "", result.stderr);
    }
}

test "root logging returns IoError for a real broken stderr pipe without SIGPIPE termination" {
    var descriptors: [2]std.os.linux.fd_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe2(&descriptors, .{ .CLOEXEC = true })));
    (std.Io.File{ .handle = descriptors[0], .flags = .{ .nonblocking = false } }).close(std.testing.io);
    const stderr: std.Io.File = .{ .handle = descriptors[1], .flags = .{ .nonblocking = false } };
    defer stderr.close(std.testing.io);
    const term = try runWithStderr(
        \\import std.logging as logging
        \\import std.io.{IoError}
        \\func run() int
        \\    const first = logging.info("broken pipe")
        \\    if not (first is IoError) -> return 90
        \\    if first.cause <> 32 or first.progress <> 0 -> return 91
        \\    const second = logging.error("still broken")
        \\    if not (second is IoError) -> return 92
        \\    if second.cause <> 32 or second.progress <> 0 -> return 93
        \\    return 42
        \\exit(run())
    , stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, term);
}

test "root logging nonblocking stderr errors count prefix partial message and newline progress" {
    const prefix = "info: ";
    const Stage = enum { prefix, message, newline };
    for ([_]Stage{ .prefix, .message, .newline }) |stage| {
        var descriptors: [2]std.os.linux.fd_t = undefined;
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe2(&descriptors, .{ .CLOEXEC = true, .NONBLOCK = true })));
        const reader: std.Io.File = .{ .handle = descriptors[0], .flags = .{ .nonblocking = true } };
        defer reader.close(std.testing.io);
        const stderr: std.Io.File = .{ .handle = descriptors[1], .flags = .{ .nonblocking = true } };
        defer stderr.close(std.testing.io);
        // A single pipe page makes partial delivery deterministic. The newline
        // fails after the prefix and message exactly fill the pipe.
        const capacity = std.os.linux.fcntl(stderr.handle, std.os.linux.F.SETPIPE_SZ, 1);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(capacity));
        try std.testing.expect(capacity > prefix.len);
        const message_length: usize = switch (stage) {
            .prefix => 1,
            .message => 3 * capacity - prefix.len,
            .newline => capacity - prefix.len,
        };
        const message = try std.testing.allocator.alloc(u8, message_length);
        defer std.testing.allocator.free(message);
        @memset(message, 'm');
        const expected = try std.testing.allocator.alloc(u8, capacity);
        defer std.testing.allocator.free(expected);
        if (stage == .prefix) {
            @memset(expected, 'x');
            const filled = std.os.linux.write(stderr.handle, expected.ptr, expected.len);
            try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(filled));
            try std.testing.expectEqual(capacity, filled);
        } else {
            @memcpy(expected[0..prefix.len], prefix);
            @memset(expected[prefix.len..], 'm');
        }
        const source = try std.testing.allocator.print(
            \\import std.logging as logging
            \\import std.io.{{IoError}}
            \\func run() int
            \\    const result = logging.info("{s}")
            \\    if not (result is IoError) -> return 90
            \\    if result.cause <> 11 -> return 91
            \\    if result.progress <> {d} -> return 92
            \\    return 42
            \\exit(run())
        , .{ message, switch (stage) {
            .prefix => @as(usize, 0),
            .message => capacity,
            .newline => capacity,
        } });
        defer std.testing.allocator.free(source);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, try runWithStderr(source, stderr));
        const delivered = try std.testing.allocator.alloc(u8, expected.len);
        defer std.testing.allocator.free(delivered);
        var offset: usize = 0;
        while (offset < delivered.len) {
            const count = std.os.linux.read(reader.handle, delivered[offset..].ptr, delivered.len - offset);
            try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(count));
            try std.testing.expect(count > 0);
            offset += count;
        }
        try std.testing.expectEqualSlices(u8, expected, delivered);
        var extra: [1]u8 = undefined;
        try std.testing.expectEqual(std.os.linux.E.AGAIN, std.os.linux.errno(std.os.linux.read(reader.handle, &extra, extra.len)));
    }
}
