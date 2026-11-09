const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

test "scoped replacement restores nested targets and observes RHS writes" {
    try Fixture.expectParity(
        \\func replace(mut target: int) int
        \\    target = 7
        \\    return 10
        \\func run() int
        \\    var target = 1
        \\    var sum = 0
        \\    with target = replace(target)
        \\        sum += target
        \\        with target = 20
        \\            sum += target
        \\            target = 30
        \\        sum += target
        \\        target = 99
        \\    if target <> 7 -> return 90
        \\    return sum + 2
    , 42);
}

test "scoped replacement unwinds return break continue and error propagation" {
    try Fixture.expectParity(
        \\struct Failure
        \\    error = true
        \\func early(mut target: int) unit | Failure
        \\    with target = 10
        \\        with target = 20
        \\            return Failure{}
        \\func run() int
        \\    var target = 1
        \\    var sum = 0
        \\    var iteration = 0
        \\    loop
        \\        iteration += 1
        \\        with target = 10
        \\            if iteration == 1 -> continue
        \\            sum += target
        \\            break
        \\    if target <> 1 -> return 90
        \\    const result = early(target)
        \\    if not (result is Failure) or target <> 1 -> return 91
        \\    return sum + 32
    , 42);
}

test "explicit borrowed allocator factories preserve the original receiver and errors" {
    try Fixture.expectParity(
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\struct Tracker
        \\    calls: int
        \\    releases: int
        \\    upstream: Allocator
        \\    pub func allocate(mut self: Tracker, layout: AllocationLayout) RawBlock | AllocationError
        \\        self.calls += 1
        \\        if layout.byte_size == 19 -> return AllocationError.budget
        \\        return self.upstream.allocate(layout)
        \\    pub func deallocate(mut self: Tracker, deinit block: RawBlock)
        \\        self.releases += 1
        \\        self.upstream.deallocate(block^)
        \\func run() int
        \\    var provider = Tracker{calls = 0, releases = 0, upstream = root_allocator()}
        \\    const allocator = Allocator.from(Tracker, provider)
        \\    const copy = allocator
        \\    var block = copy.allocate(AllocationLayout{byte_size = 16, alignment = 8})
        \\    if block is AllocationError -> return 90
        \\    copy.deallocate(block^)
        \\    var refusal = allocator.allocate(AllocationLayout{byte_size = 19, alignment = 1})
        \\    if refusal is RawBlock
        \\        allocator.deallocate(refusal^)
        \\        return 91
        \\    if refusal.reason <> AllocationError.budget.reason -> return 92
        \\    return provider.calls + provider.releases + 39
    , 42);
}

test "allocation layouts preserve zero alignment and report size limits without compiler failures" {
    try Fixture.expectParity(
        \\import std.memory.{layout_for, type_layout, AllocationError}
        \\func bytes(count: int) int
        \\    const result = layout_for(int, count)
        \\    if result is AllocationError -> return result.reason
        \\    return result.byte_size
        \\func run() int
        \\    if bytes(-1) <> AllocationError.invalid_layout.reason -> return 90
        \\    if bytes(0) <> 0 or bytes(3) <> 12 -> return 91
        \\    if bytes(536870911) <> 2147483644 -> return 92
        \\    if bytes(536870912) <> AllocationError.size_limit.reason -> return 93
        \\    const empty = layout_for(Array(int, 536870912), 0)
        \\    if empty is AllocationError -> return 94
        \\    if empty.byte_size <> 0 or empty.alignment <> type_layout(int).alignment -> return 95
        \\    const oversized = layout_for(Array(int, 2147483647), 1)
        \\    if not (oversized is AllocationError) -> return 96
        \\    if oversized.reason <> AllocationError.size_limit.reason -> return 97
        \\    const negative = layout_for(Array(int, 2147483647), -1)
        \\    if not (negative is AllocationError) -> return 98
        \\    if negative.reason <> AllocationError.invalid_layout.reason -> return 99
        \\    const zero = layout_for(unit, 2147483647)
        \\    if zero is AllocationError -> return 100
        \\    if zero.byte_size <> 0 or zero.alignment <> 1 -> return 101
        \\    return 42
    , 42);
    for ([_][]const u8{
        "import std.memory.{type_layout}\n_ = type_layout(Array(int, 536870912))",
        "import std.memory.{type_layout}\n_ = type_layout(Array(int, 2147483647))",
    }) |source| try Fixture.expectAnySourceDiagnostic(source, .type_layout_too_large);
    try Fixture.expectAnySourceDiagnostic("import std.memory.{type_layout}\n_ = type_layout(type)", .compile_time_only_type);
}

test "explicit logger filtering and borrowed backends work in both engines" {
    try Fixture.expectParity(
        \\import std.logging.{Logger, LogLevel, emit}
        \\import std.logging as logging
        \\struct Backend
        \\    delivered: int
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit
        \\        self.delivered += message.byte_length()
        \\func run() int
        \\    var backend = Backend{delivered = 0}
        \\    const logger = Logger.from(Backend, backend, LogLevel.info)
        \\    if not (emit(logger, LogLevel.debug, "disabled") is unit) -> return 90
        \\    if backend.delivered <> 0 -> return 91
        \\    if not (emit(logger, LogLevel.info, "hello!") is unit) -> return 92
        \\    return backend.delivered + 36
    , 42);
}

test "explicit typed allocations retain their provider across growth and release" {
    try Fixture.expectParity(
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator, allocate_with, unsafe_initialize, unsafe_borrow, deallocate}
        \\struct Tracker
        \\    calls: int
        \\    releases: int
        \\    upstream: Allocator
        \\    pub func allocate(mut self: Tracker, layout: AllocationLayout) RawBlock | AllocationError
        \\        self.calls += 1
        \\        if layout.byte_size == 20 -> return AllocationError.budget
        \\        return self.upstream.allocate(layout)
        \\    pub func deallocate(mut self: Tracker, deinit block: RawBlock)
        \\        self.releases += 1
        \\        self.upstream.deallocate(block^)
        \\func exercise() int | AllocationError
        \\    var tracker = Tracker{calls = 0, releases = 0, upstream = root_allocator()}
        \\    const provider = Allocator.from(Tracker, tracker)
        \\    var storage = allocate_with(int, provider, 1)?
        \\    unsafe_initialize(int, storage, 0, 42)
        \\    const value = unsafe_borrow(int, storage, 0)
        \\    deallocate(int, storage^)
        \\    var list = List(int).new_with(provider, 0)?
        \\    _ = list.append(value)?
        \\    const before = list.capacity()
        \\    const refused = list.reserve(5)
        \\    if not (refused is AllocationError) -> return 91
        \\    if list.len() <> 1 or list[0] <> 42 or list.capacity() <> before -> return 92
        \\    _ = list.reserve(8)?
        \\    _ = list
        \\    if tracker.calls <> 5 or tracker.releases <> 4 -> return 93
        \\    return value
        \\func run() int
        \\    const result = exercise()
        \\    if result is AllocationError -> return 90
        \\    return result
    , 42);
}

test "raw zero byte storage keeps its logical layout and is released once" {
    try Fixture.expectParity(
        \\import std.memory.{root_allocator, AllocationLayout, AllocationError}
        \\func exercise() int | AllocationError
        \\    const provider = root_allocator()
        \\    var block = provider.allocate(AllocationLayout{byte_size = 0, alignment = 8})?
        \\    const size = block.size()
        \\    provider.deallocate(block^)
        \\    return size + 42
        \\func run() int
        \\    const result = exercise()
        \\    if result is AllocationError -> return 90
        \\    return result
    , 42);
}

test "typed adoption reads initialized bytes and keeps raw aliases coherent" {
    try Fixture.expectParity(
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, allocate_with, unsafe_borrow, unsafe_initialize, deallocate}
        \\struct Buffer
        \\    bytes: List(byte)
        \\    pub func allocate(mut self: Buffer, layout: AllocationLayout) RawBlock | AllocationError
        \\        var bytes = self.bytes.span()
        \\        return RawBlock.unsafe_from_span(bytes, layout)
        \\    pub func deallocate(mut self: Buffer, deinit block: RawBlock) -> block.retire()
        \\func exercise() int | AllocationError
        \\    var buffer = Buffer{bytes = [42, 0, 0, 0, 0, 0, 0, 0]}
        \\    const provider = Allocator.from(Buffer, buffer)
        \\    var storage = allocate_with(int, provider, 1)?
        \\    var result = if unsafe_borrow(int, storage, 0) == 42 -> 42 else 90
        \\    unsafe_initialize(int, storage, 0, 16909060)
        \\    if buffer.bytes[0] <> 4 or buffer.bytes[3] <> 1 -> result = 91
        \\    buffer.bytes[0] = 42
        \\    if unsafe_borrow(int, storage, 0) <> 16909098 -> result = 92
        \\    deallocate(int, storage^)
        \\    return result
        \\func run() int
        \\    const result = exercise()
        \\    if result is AllocationError -> return 93
        \\    return result
    , 42);
}

test "aggregate adoption shares bytes across nested provider views" {
    try Fixture.expectParity(
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, allocate_with, unsafe_borrow, unsafe_initialize, deallocate}
        \\struct Pair
        \\    copy = trivial
        \\    first: int
        \\    second: int
        \\struct Buffer
        \\    bytes: List(byte)
        \\    pub func allocate(mut self: Buffer, layout: AllocationLayout) RawBlock | AllocationError
        \\        var bytes = self.bytes.span()
        \\        return RawBlock.unsafe_from_span(bytes, layout)
        \\    pub func deallocate(mut self: Buffer, deinit block: RawBlock) -> block.retire()
        \\func exercise() int | AllocationError
        \\    var buffer = Buffer{bytes = [19, 0, 0, 0, 23, 0, 0, 0]}
        \\    const provider = Allocator.from(Buffer, buffer)
        \\    var storage = allocate_with(Pair, provider, 1)?
        \\    var result = unsafe_borrow(Pair, storage, 0).first + unsafe_borrow(Pair, storage, 0).second
        \\    unsafe_initialize(Pair, storage, 0, Pair{first = 20, second = 22})
        \\    if buffer.bytes[0] <> 20 or buffer.bytes[4] <> 22 -> result = 90
        \\    buffer.bytes[0] = 21
        \\    if unsafe_borrow(Pair, storage, 0).first <> 21 -> result = 91
        \\    deallocate(Pair, storage^)
        \\    return result
        \\func run() int
        \\    const result = exercise()
        \\    if result is AllocationError -> return 92
        \\    return result
    , 42);
}

test "variant adoption shares tags and payload bytes" {
    try Fixture.expectParity(
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, allocate_with, unsafe_borrow, unsafe_initialize, deallocate}
        \\struct Buffer
        \\    bytes: List(byte)
        \\    pub func allocate(mut self: Buffer, layout: AllocationLayout) RawBlock | AllocationError
        \\        var bytes = self.bytes.span()
        \\        return RawBlock.unsafe_from_span(bytes, layout)
        \\    pub func deallocate(mut self: Buffer, deinit block: RawBlock) -> block.retire()
        \\func exercise() int | AllocationError
        \\    var buffer = Buffer{bytes = [0, 0, 0, 0, 0, 0, 0, 0]}
        \\    const provider = Allocator.from(Buffer, buffer)
        \\    var storage = allocate_with(int | none, provider, 1)?
        \\    unsafe_initialize(int | none, storage, 0, 19)
        \\    buffer.bytes[4] = 42
        \\    const value = unsafe_borrow(int | none, storage, 0)
        \\    var result = if value is int -> value else 90
        \\    unsafe_initialize(int | none, storage, 0, none)
        \\    if not (unsafe_borrow(int | none, storage, 0) is none) -> result = 91
        \\    deallocate(int | none, storage^)
        \\    return result
        \\func run() int
        \\    const result = exercise()
        \\    if result is AllocationError -> return 92
        \\    return result
    , 42);
}

test "logger factories reject storing a synchronous message borrow" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.logging.{Logger, LogLevel}
        \\struct Backend
        \\    saved: StringView
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit
        \\        self.saved = message
        \\func run()
        \\    var backend = Backend{saved = "initial"}
        \\    const logger = Logger.from(Backend, backend, LogLevel.info)
        \\    _ = logger
        \\run()
    , .service_protocol_incompatible);
}

test "checked logger dispatch detects a changing recursive backend" {
    const source =
        \\import std.logging.{Logger, LogLevel, emit}
        \\import std.logging as logging
        \\import std.memory.{AllocationError}
        \\import std.io.{IoError}
        \\struct Backend
        \\    calls: int
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit | AllocationError | IoError
        \\        self.calls += 1
        \\        const logger = Logger.from(Backend, self, LogLevel.info)
        \\        return logging.emit(logger, level, message)
        \\func run() int
        \\    var backend = Backend{calls = 0}
        \\    const logger = Logger.from(Backend, backend, LogLevel.info)
        \\    _ = emit(logger, LogLevel.info, "cycle")
        \\    return 90
    ;
    const std = @import("std");
    const native = try std.testing.allocator.print("{s}\nexit(run())", .{source});
    defer std.testing.allocator.free(native);
    try Fixture.expectSourceExit(native, 134);
    const interpreted = try std.testing.allocator.print("{s}\nexit(comptime -> run())", .{source});
    defer std.testing.allocator.free(interpreted);
    try Fixture.expectAnySourceDiagnostic(interpreted, .compile_time_panic);
}

test "unchecked logger dispatch permits deliberate bounded recursion" {
    try Fixture.expectParity(
        \\import std.logging.{Logger, LogLevel, emit}
        \\import std.logging as logging
        \\import std.memory.{AllocationError}
        \\import std.io.{IoError}
        \\struct Backend
        \\    calls: int
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit | AllocationError | IoError
        \\        self.calls += 1
        \\        if self.calls >= 3 -> return unit
        \\        const logger = Logger.from_unchecked(Backend, self, LogLevel.info)
        \\        return logging.emit(logger, level, message)
        \\func run() int
        \\    var backend = Backend{calls = 0}
        \\    const logger = Logger.from_unchecked(Backend, backend, LogLevel.info)
        \\    if not (emit(logger, LogLevel.info, "recursive") is unit) -> return 90
        \\    return backend.calls + 39
    , 42);
}

test "checked logger errors remove the active service entry" {
    try Fixture.expectParity(
        \\import std.logging.{Logger, LogLevel, emit}
        \\import std.logging as logging
        \\import std.memory.{AllocationError}
        \\struct Backend
        \\    calls: int
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) AllocationError
        \\        self.calls += 1
        \\        return AllocationError.budget
        \\func run() int
        \\    var backend = Backend{calls = 0}
        \\    const logger = Logger.from(Backend, backend, LogLevel.info)
        \\    if not (emit(logger, LogLevel.info, "first") is AllocationError) -> return 90
        \\    if not (emit(logger, LogLevel.info, "second") is AllocationError) -> return 91
        \\    return backend.calls + 40
    , 42);
}

test "registered contexts restore independent borrowed handles across aliases and calls" {
    try Fixture.expectParity(
        \\import std.context as ambient
        \\import std.logging.{Logger, LogLevel, emit, enabled}
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\struct Backend
        \\    delivered: int
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit
        \\        self.delivered += message.byte_length()
        \\struct Tracker
        \\    calls: int
        \\    upstream: Allocator
        \\    pub func allocate(mut self: Tracker, layout: AllocationLayout) RawBlock | AllocationError
        \\        self.calls += 1
        \\        return self.upstream.allocate(layout)
        \\    pub func deallocate(imm self: Tracker, deinit block: RawBlock) unit -> self.upstream.deallocate(block^)
        \\func selected() Logger -> context.logger
        \\func enabled_now() bool -> enabled(context.logger, LogLevel.info)
        \\func run() int
        \\    var first = Backend{delivered = 0}
        \\    var second = Backend{delivered = 0}
        \\    var tracker = Tracker{calls = 0, upstream = root_allocator()}
        \\    with ambient.logger = Logger.from(Backend, first, LogLevel.info)
        \\        const saved = selected()
        \\        with context.allocator = Allocator.from(Tracker, tracker)
        \\            if not enabled_now() -> return 90
        \\            var block = context.allocator.allocate(AllocationLayout{byte_size = 0, alignment = 1})
        \\            if block is AllocationError -> return 91
        \\            context.allocator.deallocate(block^)
        \\            with context.logger = Logger.from(Backend, second, LogLevel.warning)
        \\                if enabled_now() -> return 92
        \\                _ = emit(context.logger, LogLevel.warning, "hi")
        \\                _ = emit(saved, LogLevel.info, "saved")
        \\            if not enabled_now() -> return 93
        \\            _ = emit(context.logger, LogLevel.info, "more")
        \\    return first.delivered + second.delivered + tracker.calls + 30
    , 42);
}

test "context scope keeps otherwise unused backend alive through body cleanup" {
    try Fixture.expectParity(
        \\import std.logging.{Logger, LogLevel, emit}
        \\struct Backend
        \\    delivered: int
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit
        \\        self.delivered += 1
        \\struct Resource
        \\    drop = func(deinit self: Resource)
        \\        _ = emit(context.logger, LogLevel.info, "cleanup")
        \\func exercise(mut backend: Backend) unit
        \\    with context.logger = Logger.from(Backend, backend, LogLevel.info)
        \\        const resource = Resource{}
        \\        return unit
        \\func run() int
        \\    var backend = Backend{delivered = 0}
        \\    exercise(backend)
        \\    return backend.delivered + 41
    , 42);
}

test "returning selected context rejects a local backend" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.logging.{Logger, LogLevel}
        \\struct Backend
        \\    pub func emit(imm self: Backend, level: LogLevel, imm message: StringView) unit -> unit
        \\func selected() Logger -> context.logger
        \\func escape() Logger
        \\    var backend = Backend{}
        \\    with context.logger = Logger.from(Backend, backend, LogLevel.info)
        \\        return selected()
        \\_ = escape()
    , .borrow_outlives_source);
}

test "context binding storage cannot be assigned or borrowed" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.logging.{noop_logger}
        \\context.logger = noop_logger()
    , .assignment_to_immutable);
}

test "context constructors retain original providers while resources grow elsewhere" {
    try Fixture.expectParity(
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\struct Tracker
        \\    calls: int
        \\    releases: int
        \\    upstream: Allocator
        \\    pub func allocate(mut self: Tracker, layout: AllocationLayout) RawBlock | AllocationError
        \\        self.calls += 1
        \\        return self.upstream.allocate(layout)
        \\    pub func deallocate(mut self: Tracker, deinit block: RawBlock) unit
        \\        self.releases += 1
        \\        self.upstream.deallocate(block^)
        \\func create(mut provider: Tracker) List(int) | AllocationError
        \\    with context.allocator = Allocator.from(Tracker, provider)
        \\        return List(int).new(0)
        \\func exercise(mut first: Tracker, mut second: Tracker) unit | AllocationError
        \\    var list = create(first)?
        \\    with context.allocator = Allocator.from(Tracker, second)
        \\        _ = list.append(42)?
        \\        _ = list.reserve(8)?
        \\        if list[0] <> 42 -> panic "lost element"
        \\    return unit
        \\func run() int
        \\    var first = Tracker{calls = 0, releases = 0, upstream = root_allocator()}
        \\    var second = Tracker{calls = 0, releases = 0, upstream = root_allocator()}
        \\    if exercise(first, second) is AllocationError -> return 90
        \\    if first.calls <> 3 or first.releases <> 3 or second.calls <> 0 or second.releases <> 0 -> return 91
        \\    return 42
    , 42);
}

test "zero argument contextual allocation cannot escape a local provider" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\struct Tracker
        \\    upstream: Allocator
        \\    pub func allocate(imm self: Tracker, layout: AllocationLayout) RawBlock | AllocationError -> self.upstream.allocate(layout)
        \\    pub func deallocate(imm self: Tracker, deinit block: RawBlock) unit -> self.upstream.deallocate(block^)
        \\func create() List(int) | AllocationError -> List(int).new(0)
        \\func escape() List(int) | AllocationError
        \\    var tracker = Tracker{upstream = root_allocator()}
        \\    with context.allocator = Allocator.from(Tracker, tracker)
        \\        return create()
        \\_ = escape()
    , .borrow_outlives_source);
}

test "deferred initializers select the context where they are forced" {
    try Fixture.expectParity(
        \\import std.logging.{Logger, LogLevel, log}
        \\struct Backend
        \\    delivered: int
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit -> self.delivered += 1
        \\func noisy() int
        \\    _ = log(LogLevel.info, "forced")
        \\    return 42
        \\func force(init value: int, imm logger: Logger) int
        \\    with context.logger = logger
        \\        return value
        \\func run() int
        \\    var first = Backend{delivered = 0}
        \\    var second = Backend{delivered = 0}
        \\    with context.logger = Logger.from(Backend, first, LogLevel.info)
        \\        const result = force(noisy(), Logger.from(Backend, second, LogLevel.info))
        \\        if first.delivered <> 0 or second.delivered <> 1 -> return 90
        \\        return result
    , 42);
}

test "callable invocation selects later context and explicit snapshots retain earlier logger" {
    try Fixture.expectParity(
        \\import std.logging.{Logger, LogLevel, log}
        \\import std.logging as logging
        \\struct Backend
        \\    delivered: int
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit -> self.delivered += 1
        \\func invoke(imm callback: func() unit) unit -> callback()
        \\func log_current() unit
        \\    _ = log(LogLevel.info, "current")
        \\func emit_saved(imm logger: Logger) unit
        \\    _ = logging.emit(logger, LogLevel.info, "saved")
        \\func run() int
        \\    var first = Backend{delivered = 0}
        \\    var second = Backend{delivered = 0}
        \\    with context.logger = Logger.from(Backend, first, LogLevel.info)
        \\        const saved = context.logger
        \\        const contextual = () => log_current()
        \\        const snapshot = () => emit_saved(saved)
        \\        with context.logger = Logger.from(Backend, second, LogLevel.info)
        \\            invoke(contextual)
        \\            invoke(snapshot)
        \\    if first.delivered <> 1 or second.delivered <> 1 -> return 90
        \\    return 42
    , 42);
}

test "arena adopted typed storage and raw backing share refinement identity" {
    const source =
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, allocate_with, unsafe_initialize, unsafe_borrow, deallocate}
        \\struct First
        \\    pub value: int
        \\struct Second
        \\    pub value: int
        \\struct Arena
        \\    bytes: Array(byte, 8)
        \\    pub func allocate(mut self: Arena, layout: AllocationLayout) RawBlock | AllocationError
        \\        var view = self.bytes.span()
        \\        return RawBlock.unsafe_from_span(view, layout)
        \\    pub func deallocate(imm self: Arena, deinit block: RawBlock) unit -> block.retire()
        \\func exercise() int | AllocationError
        \\    var arena = Arena{bytes = [0, 0, 0, 0, 0, 0, 0, 0]}
        \\    const provider = Allocator.from(Arena, arena)
        \\    var storage = allocate_with(First | Second, provider, 1)?
        \\    unsafe_initialize(First | Second, storage, 0, First{value = 42})
        \\    ref selected = unsafe_borrow(First | Second, storage, 0)
        \\    var answer = 0
        \\    if selected is First
        \\        arena.bytes[0] = 1
        \\        answer = selected.value
        \\    deallocate(First | Second, storage^)
        \\    return answer
        \\_ = exercise()
    ;
    const std = @import("std");
    const without_write = try std.mem.replaceOwned(u8, std.testing.allocator, source, "arena.bytes[0] = 1", "_ = arena.bytes[0]");
    defer std.testing.allocator.free(without_write);
    const positive = try std.mem.replaceOwned(u8, std.testing.allocator, without_write, "_ = exercise()", "func run() int\n    const result = exercise()\n    if result is AllocationError -> return 90\n    return result");
    defer std.testing.allocator.free(positive);
    try Fixture.expectParity(positive, 42);
    try Fixture.expectAnySourceDiagnostic(source, .field_access_not_struct);
}

test "logger owned message copies retain the allocation provider in mutated backend state" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\import std.logging.{Logger, LogLevel, log}
        \\struct Tracker
        \\    upstream: Allocator
        \\    pub func allocate(imm self: Tracker, layout: AllocationLayout) RawBlock | AllocationError -> self.upstream.allocate(layout)
        \\    pub func deallocate(imm self: Tracker, deinit block: RawBlock) unit -> self.upstream.deallocate(block^)
        \\struct Backend
        \\    saved: String
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit | AllocationError
        \\        var message_copy = String.empty()
        \\        _ = message_copy.append(message)?
        \\        self.saved = message_copy^
        \\        return unit
        \\func escape() String
        \\    var tracker = Tracker{upstream = root_allocator()}
        \\    var backend = Backend{saved = String.empty()}
        \\    with context.allocator = Allocator.from(Tracker, tracker)
        \\        with context.logger = Logger.from(Backend, backend, LogLevel.info)
        \\            _ = log(LogLevel.info, "owned copy")
        \\    return backend.saved^
        \\_ = escape()
    , .borrow_outlives_source);
}

test "logger accepts an owned message copy whose provider survives the backend" {
    try Fixture.expectParity(
        \\import std.memory.{AllocationError}
        \\import std.logging.{Logger, LogLevel, log}
        \\struct Backend
        \\    saved: String
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit | AllocationError
        \\        var message_copy = String.empty()
        \\        _ = message_copy.append(message)?
        \\        self.saved = message_copy^
        \\        return unit
        \\func copied() String
        \\    var backend = Backend{saved = String.empty()}
        \\    with context.logger = Logger.from(Backend, backend, LogLevel.info)
        \\        _ = log(LogLevel.info, "owned copy")
        \\    return backend.saved^
        \\func run() int -> copied().byte_length() + 32
    , 42);
}

test "forcing an initializer cannot export storage backed by a callee local provider" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\struct Tracker
        \\    upstream: Allocator
        \\    pub func allocate(imm self: Tracker, layout: AllocationLayout) RawBlock | AllocationError -> self.upstream.allocate(layout)
        \\    pub func deallocate(imm self: Tracker, deinit block: RawBlock) -> self.upstream.deallocate(block^)
        \\func force(init pending: List(int) | AllocationError) List(int) | AllocationError
        \\    var tracker = Tracker{upstream = root_allocator()}
        \\    with context.allocator = Allocator.from(Tracker, tracker)
        \\        return pending
        \\_ = force(List(int).new(0))
    , .borrow_outlives_source);
}

test "nonallocating deferred text does not capture an unrelated contextual provider" {
    try Fixture.expectParity(
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\struct Tracker
        \\    upstream: Allocator
        \\    pub func allocate(imm self: Tracker, layout: AllocationLayout) RawBlock | AllocationError -> self.upstream.allocate(layout)
        \\    pub func deallocate(imm self: Tracker, deinit block: RawBlock) -> self.upstream.deallocate(block^)
        \\func make() Box(String) | AllocationError
        \\    var tracker = Tracker{upstream = root_allocator()}
        \\    with context.allocator = Allocator.from(Tracker, tracker)
        \\        return Box(String).new_with(root_allocator(), "permanent")
        \\func run() int
        \\    const result = make()
        \\    if result is AllocationError -> return 90
        \\    return result.borrow().byte_length() + 33
    , 42);
}

test "owning callable copies select separate providers and retain their release authority" {
    try Fixture.expectParity(
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\import std.callables.{erase, clone}
        \\struct Tracker
        \\    calls: int
        \\    releases: int
        \\    upstream: Allocator
        \\    pub func allocate(mut self: Tracker, layout: AllocationLayout) RawBlock | AllocationError
        \\        self.calls += 1
        \\        return self.upstream.allocate(layout)
        \\    pub func deallocate(mut self: Tracker, deinit block: RawBlock)
        \\        self.releases += 1
        \\        self.upstream.deallocate(block^)
        \\func make(offset: int) (func(int) int) | AllocationError -> erase(func(int) int, (value) => value + offset)
        \\func exercise() int | AllocationError
        \\    var first = Tracker{calls = 0, releases = 0, upstream = root_allocator()}
        \\    var second = Tracker{calls = 0, releases = 0, upstream = root_allocator()}
        \\    var original: (func(int) int) | AllocationError = AllocationError.refused
        \\    with context.allocator = Allocator.from(Tracker, first)
        \\        _ = original = make(20)
        \\    if original is AllocationError -> return original
        \\    with context.allocator = Allocator.from(Tracker, second)
        \\        const copied = clone(original)?
        \\        if copied(22) <> 42 -> return 90
        \\        _ = copied
        \\    if second.calls <> 1 or second.releases <> 1 -> return 91
        \\    if original(22) <> 42 -> return 92
        \\    _ = original
        \\    if first.calls <> 1 or first.releases <> 1 -> return 93
        \\    return 42
        \\func run() int
        \\    const result = exercise()
        \\    if result is AllocationError -> return 94
        \\    return result
    , 42);
}

test "owning closure cannot escape the local provider that reserved its environment" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\struct Tracker
        \\    upstream: Allocator
        \\    pub func allocate(imm self: Tracker, layout: AllocationLayout) RawBlock | AllocationError -> self.upstream.allocate(layout)
        \\    pub func deallocate(imm self: Tracker, deinit block: RawBlock) -> self.upstream.deallocate(block^)
        \\func escape(offset: int) func(int) int
        \\    var tracker = Tracker{upstream = root_allocator()}
        \\    with context.allocator = Allocator.from(Tracker, tracker)
        \\        return (value) => value + offset
        \\_ = escape(20)
    , .borrow_outlives_source);
}

test "contextual logger cleanup and restoration cover ordinary early exits and RHS failure" {
    try Fixture.expectParity(
        \\import std.logging.{Logger, LogLevel, log}
        \\struct Failure
        \\    error = true
        \\struct Backend
        \\    events: int
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit
        \\        self.events += message.byte_length()
        \\struct Cleanup
        \\    marker: int
        \\    drop = func(deinit self: Cleanup)
        \\        _ = log(LogLevel.info, "z")
        \\func fail() unit | Failure -> Failure{}
        \\func rhs() Logger | Failure -> Failure{}
        \\func leave(ref inner: Backend, mode: int) unit | Failure
        \\    for iteration in 0..2
        \\        with context.logger = Logger.from(Backend, inner, LogLevel.info)
        \\            var cleanup = Cleanup{marker = iteration}
        \\            if mode == 0 -> return unit
        \\            if mode == 1 -> return Failure{}
        \\            if mode == 2 and iteration == 0 -> continue
        \\            if mode == 3 -> break
        \\            if mode == 4 -> _ = fail()?
        \\            _ = cleanup
        \\            break
        \\    return unit
        \\func reject_rhs() unit | Failure
        \\    with context.logger = rhs()?
        \\        panic "unreachable replacement body"
        \\    return unit
        \\func run() int
        \\    var outer = Backend{events = 0}
        \\    var inner = Backend{events = 0}
        \\    with context.logger = Logger.from(Backend, outer, LogLevel.info)
        \\        for mode in 0..6
        \\            _ = leave(inner, mode)
        \\            _ = log(LogLevel.info, "x")
        \\        if not (reject_rhs() is Failure) -> return 90
        \\    if inner.events <> 7 or outer.events <> 6 -> return 91
        \\    return inner.events + outer.events + 29
    , 42);
}

test "logger factory rejects message retention through an unknown nested callback" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.logging.{Logger, LogLevel}
        \\struct Sink
        \\    saved: StringView
        \\    pub func save(mut self: Sink, imm message: StringView) unit -> self.saved = message
        \\struct Backend
        \\    callback: func(imm StringView) unit
        \\    pub func emit(imm self: Backend, level: LogLevel, imm message: StringView) unit -> self.callback(message)
        \\func run()
        \\    var sink = Sink{saved = ""}
        \\    var backend = Backend{callback = sink.save}
        \\    _ = Logger.from(Backend, backend, LogLevel.info)
        \\run()
    , .service_protocol_incompatible);
}

test "service mutation replay preserves a helper's internal allocator override" {
    const source =
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\import std.logging.{Logger, LogLevel, log}
        \\struct Tracker
        \\    upstream: Allocator
        \\    pub func allocate(imm self: Tracker, layout: AllocationLayout) RawBlock | AllocationError -> self.upstream.allocate(layout)
        \\    pub func deallocate(imm self: Tracker, deinit block: RawBlock) unit -> self.upstream.deallocate(block^)
        \\struct Backend
        \\    saved: String
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit | AllocationError
        \\        var owned = String.empty()
        \\        _ = owned.append(message)?
        \\        self.saved = owned^
        \\        return unit
        \\func helper() unit
        \\    var tracker = Tracker{upstream = root_allocator()}
        \\    with context.allocator = Allocator.from(Tracker, tracker)
        \\        _ = log(LogLevel.info, "owned")
        \\func escape() String
        \\    var backend = Backend{saved = String.empty()}
        \\    with context.logger = Logger.from(Backend, backend, LogLevel.info)
        \\        helper()
        \\    return backend.saved^
        \\_ = escape()
    ;
    try Fixture.expectAnySourceDiagnostic(source, .borrow_outlives_source);
    const std = @import("std");
    const nonretaining = try std.mem.replaceOwned(u8, std.testing.allocator, source, "self.saved = owned^", "_ = owned");
    defer std.testing.allocator.free(nonretaining);
    try Fixture.expectSourceExit(nonretaining, 0);
}

test "disabled logging preserves message construction and marked errors leave the service guard" {
    try Fixture.expectParity(
        \\import std.logging.{Logger, LogLevel, log}
        \\import std.memory.{AllocationError}
        \\import std.io.{IoError}
        \\struct Backend
        \\    calls: int
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit | AllocationError | IoError
        \\        self.calls += 1
        \\        if self.calls == 1 -> return AllocationError.budget
        \\        if self.calls == 2 -> return IoError{cause = 19, progress = 23}
        \\        return unit
        \\func build_message(mut calls: int) StringView
        \\    calls += 1
        \\    return "message"
        \\func run() int
        \\    var backend = Backend{calls = 0}
        \\    var built = 0
        \\    with context.logger = Logger.from(Backend, backend, LogLevel.off)
        \\        _ = log(LogLevel.info, build_message(built))
        \\    if built <> 1 or backend.calls <> 0 -> return 90
        \\    with context.logger = Logger.from(Backend, backend, LogLevel.info)
        \\        const first = log(LogLevel.info, "one")
        \\        if not (first is AllocationError) -> return 91
        \\        if first.reason <> AllocationError.budget.reason -> return 92
        \\        const second = log(LogLevel.info, "two")
        \\        if not (second is IoError) -> return 93
        \\        if second.cause <> 19 or second.progress <> 23 -> return 94
        \\        if not (log(LogLevel.info, "three") is unit) -> return 95
        \\    return backend.calls + built + 38
    , 42);
}

test "checked allocator logger cycles are detected from either service entry" {
    const source =
        \\import std.logging.{Logger, LogLevel, log}
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\import std.io.{IoError}
        \\struct Tracker
        \\    upstream: Allocator
        \\    pub func allocate(imm self: Tracker, layout: AllocationLayout) RawBlock | AllocationError
        \\        _ = log(LogLevel.info, "allocation")
        \\        return self.upstream.allocate(layout)
        \\    pub func deallocate(imm self: Tracker, deinit block: RawBlock) unit -> self.upstream.deallocate(block^)
        \\struct Backend
        \\    calls: int
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit | AllocationError
        \\        self.calls += 1
        \\        const value = List(int).new(0)?
        \\        _ = value
        \\        return unit
        \\func run() int
        \\    var tracker = Tracker{upstream = root_allocator()}
        \\    var backend = Backend{calls = 0}
        \\    with context.allocator = Allocator.from(Tracker, tracker)
        \\        with context.logger = Logger.from(Backend, backend, LogLevel.info)
        \\            _ = log(LogLevel.info, "entry")
        \\    return 90
    ;
    const std = @import("std");
    for ([_][]const u8{ source, try std.mem.replaceOwned(u8, std.testing.allocator, source, "_ = log(LogLevel.info, \"entry\")", "_ = List(int).new(0)") }, 0..) |candidate, index| {
        defer if (index != 0) std.testing.allocator.free(candidate);
        const native = try std.testing.allocator.print("{s}\nexit(run())", .{candidate});
        defer std.testing.allocator.free(native);
        try Fixture.expectSourceExit(native, 134);
        const interpreted = try std.testing.allocator.print("{s}\nexit(comptime -> run())", .{candidate});
        defer std.testing.allocator.free(interpreted);
        try Fixture.expectAnySourceDiagnostic(interpreted, .compile_time_panic);
    }
}

test "logger wrappers forward to distinct captured upstream backends" {
    try Fixture.expectParity(
        \\import std.logging.{Logger, LogLevel, log}
        \\import std.logging as logging
        \\import std.memory.{AllocationError}
        \\import std.io.{IoError}
        \\struct Backend
        \\    calls: int
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit -> self.calls += 1
        \\struct Wrapper
        \\    upstream: Logger
        \\    pub func emit(imm self: Wrapper, level: LogLevel, imm message: StringView) unit | AllocationError | IoError -> logging.emit(self.upstream, level, message)
        \\func run() int
        \\    var backend = Backend{calls = 0}
        \\    var wrapper = Wrapper{upstream = Logger.from(Backend, backend, LogLevel.info)}
        \\    with context.logger = Logger.from(Wrapper, wrapper, LogLevel.info)
        \\        if not (log(LogLevel.info, "forward") is unit) -> return 90
        \\    return backend.calls + 41
    , 42);
}

test "root native logging writes stderr independently of stdout and evaluator logging has no host output" {
    const std = @import("std");
    const source =
        \\import std.logging.{LogLevel, log, noop_logger}
        \\_ = log(LogLevel.debug, "hidden")
        \\_ = log(LogLevel.info, "visible")
        \\with context.logger = noop_logger()
        \\    print("stdout")
    ;
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    const result = try fixture.runIo("");
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("stdout\n", result.stdout);
    try std.testing.expectEqualStrings("info: visible\n", result.stderr);
    const interpreted = try Fixture.init(
        \\import std.logging.{LogLevel, log, enabled}
        \\func evaluate() int
        \\    if enabled(context.logger, LogLevel.error) -> exit(90)
        \\    if not (log(LogLevel.error, "no host output") is unit) -> exit(91)
        \\    return 42
        \\static result = comptime -> evaluate()
        \\exit(result)
    );
    defer interpreted.deinit();
    const evaluated = try interpreted.runIo("");
    defer std.testing.allocator.free(evaluated.stdout);
    defer std.testing.allocator.free(evaluated.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, evaluated.term);
    try std.testing.expectEqualStrings("", evaluated.stdout);
    try std.testing.expectEqualStrings("", evaluated.stderr);
}

test "forced initializer mutations use forcing bindings and preserve explicit service snapshots" {
    const source =
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\import std.logging.{Logger, LogLevel, log, noop_logger}
        \\import std.logging as logging
        \\struct Tracker
        \\    upstream: Allocator
        \\    pub func allocate(imm self: Tracker, layout: AllocationLayout) RawBlock | AllocationError -> self.upstream.allocate(layout)
        \\    pub func deallocate(imm self: Tracker, deinit block: RawBlock) unit -> self.upstream.deallocate(block^)
        \\struct Backend
        \\    saved: String
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit | AllocationError
        \\        var owned = String.empty()
        \\        _ = owned.append(message)?
        \\        self.saved = owned^
        \\        return unit
        \\func force(init pending: int) int
        \\    var tracker = Tracker{upstream = root_allocator()}
        \\    with context.allocator = Allocator.from(Tracker, tracker)
        \\        return pending
        \\func produce() int
        \\    _ = log(LogLevel.info, "owned")
        \\    return 42
        \\func escape() String
        \\    var backend = Backend{saved = String.empty()}
        \\    with context.logger = Logger.from(Backend, backend, LogLevel.info)
        \\        _ = force(produce())
        \\    return backend.saved^
        \\_ = escape()
    ;
    try Fixture.expectAnySourceDiagnostic(source, .borrow_outlives_source);
}

test "cleanup mutation retains the logger's selected allocation provider" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\import std.logging.{Logger, LogLevel, log}
        \\struct Tracker
        \\    upstream: Allocator
        \\    pub func allocate(imm self: Tracker, layout: AllocationLayout) RawBlock | AllocationError -> self.upstream.allocate(layout)
        \\    pub func deallocate(imm self: Tracker, deinit block: RawBlock) unit -> self.upstream.deallocate(block^)
        \\struct Backend
        \\    saved: String
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit | AllocationError
        \\        var owned = String.empty()
        \\        _ = owned.append(message)?
        \\        self.saved = owned^
        \\        return unit
        \\struct Dropper
        \\    marker: int
        \\    drop = func(deinit self: Dropper)
        \\        _ = log(LogLevel.info, "owned")
        \\func helper() unit
        \\    var tracker = Tracker{upstream = root_allocator()}
        \\    with context.allocator = Allocator.from(Tracker, tracker)
        \\        var value = Dropper{marker = 0}
        \\        _ = value
        \\func escape() String
        \\    var backend = Backend{saved = String.empty()}
        \\    with context.logger = Logger.from(Backend, backend, LogLevel.info)
        \\        helper()
        \\    return backend.saved^
        \\_ = escape()
    , .borrow_outlives_source);
}

test "opaque owning callable hooks preserve contextual backend mutations and nonowning conditions" {
    const std = @import("std");
    const template =
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\import std.logging.{Logger, LogLevel, log}
        \\import std.callables.{clone}
        \\struct Tracker
        \\    upstream: Allocator
        \\    pub func allocate(imm self: Tracker, layout: AllocationLayout) RawBlock | AllocationError -> self.upstream.allocate(layout)
        \\    pub func deallocate(imm self: Tracker, deinit block: RawBlock) unit -> self.upstream.deallocate(block^)
        \\struct Backend
        \\    saved: String
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit | AllocationError
        \\        var owned = String.empty()
        \\        _ = owned.append(message)?
        \\        self.saved = owned^
        \\        return unit
        \\struct Capture
        \\    value: int
        \\    $HOOK
        \\struct Provider
        \\    value: int
        \\    func read(imm self: Provider) int -> self.value
        \\func opaque($MODE callback: func() int) unit
        \\    var tracker = Tracker{upstream = root_allocator()}
        \\    with context.allocator = Allocator.from(Tracker, tracker)
        \\        $OPERATION
        \\func escape() String
        \\    $INITIALIZATION
        \\    var backend = Backend{saved = String.empty()}
        \\    with context.logger = Logger.from(Backend, backend, LogLevel.info)
        \\        opaque($ARGUMENT)
        \\    return backend.saved^
        \\_ = escape()
    ;
    const cases = [_]struct { hook: []const u8, mode: []const u8, operation: []const u8, argument: []const u8 }{
        .{ .hook = "copy = func(imm self: Capture) Capture\n        _ = log(LogLevel.info, \"copied\")\n        return Capture{value = self.value}", .mode = "imm", .operation = "const copied = clone(callback)\n        _ = copied", .argument = "callback" },
        .{ .hook = "copy = fieldwise\n    drop = func(deinit self: Capture)\n        _ = log(LogLevel.info, \"dropped\")", .mode = "var", .operation = "_ = callback", .argument = "callback^" },
    };
    for (cases) |case| {
        const source = try test_sources.renderTemplate(std.testing.allocator, template, .{ .HOOK = case.hook, .MODE = case.mode, .OPERATION = case.operation, .ARGUMENT = case.argument, .INITIALIZATION = "const capture = Capture{value = 42}\n    const callback: func() int = () => capture.value" });
        defer std.testing.allocator.free(source);
        try Fixture.expectAnySourceDiagnostic(source, .borrow_outlives_source);
        const nonretaining = try std.mem.replaceOwned(u8, std.testing.allocator, source, "self.saved = owned^", "_ = owned");
        defer std.testing.allocator.free(nonretaining);
        try Fixture.expectSourceExit(nonretaining, 0);
        const nonowning = try std.mem.replaceOwned(u8, std.testing.allocator, source, "const capture = Capture{value = 42}\n    const callback: func() int = () => capture.value", "const provider = Provider{value = 42}\n    const callback: func() int = provider.read");
        defer std.testing.allocator.free(nonowning);
        try Fixture.expectSourceExit(nonowning, 0);
        if (std.mem.eql(u8, case.mode, "imm")) {
            const nested_template = try std.mem.replaceOwned(u8, std.testing.allocator, template, "func opaque($MODE callback: func() int) unit", "struct Callbacks\n    callback: func() int\nstruct Holder\n    callbacks: Callbacks\nfunc opaque($MODE holder: Holder) unit");
            defer std.testing.allocator.free(nested_template);
            const nested = try test_sources.renderTemplate(std.testing.allocator, nested_template, .{ .HOOK = case.hook, .MODE = case.mode, .OPERATION = "const copied = clone(holder.callbacks.callback)\n        _ = copied", .ARGUMENT = "Holder{callbacks = Callbacks{callback = callback}}", .INITIALIZATION = "const capture = Capture{value = 42}\n    const callback: func() int = () => capture.value" });
            defer std.testing.allocator.free(nested);
            try Fixture.expectAnySourceDiagnostic(nested, .borrow_outlives_source);
            const nested_nonowning = try std.mem.replaceOwned(u8, std.testing.allocator, nested, "const capture = Capture{value = 42}\n    const callback: func() int = () => capture.value", "const provider = Provider{value = 42}\n    const callback: func() int = provider.read");
            defer std.testing.allocator.free(nested_nonowning);
            try Fixture.expectSourceExit(nested_nonowning, 0);
        }
    }
}

test "nested initializer forwarding preserves captured logger snapshots after capture pruning" {
    const source =
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\import std.logging.{Logger, LogLevel, emit, noop_logger}
        \\struct Tracker
        \\    upstream: Allocator
        \\    pub func allocate(imm self: Tracker, layout: AllocationLayout) RawBlock | AllocationError -> self.upstream.allocate(layout)
        \\    pub func deallocate(imm self: Tracker, deinit block: RawBlock) unit -> self.upstream.deallocate(block^)
        \\struct Backend
        \\    saved: String
        \\    pub func emit(mut self: Backend, level: LogLevel, imm message: StringView) unit | AllocationError
        \\        var owned = String.empty()
        \\        _ = owned.append(message)?
        \\        self.saved = owned^
        \\        return unit
        \\func force(init pending: int) int
        \\    var tracker = Tracker{upstream = root_allocator()}
        \\    with context.allocator = Allocator.from(Tracker, tracker)
        \\        with context.logger = noop_logger()
        \\            return pending
        \\func forward(init pending: int) int -> force(pending)
        \\func produce(imm saved: Logger) int
        \\    _ = emit(saved, LogLevel.info, "owned")
        \\    return 42
        \\func escape(unused: int) String
        \\    var backend = Backend{saved = String.empty()}
        \\    const saved = Logger.from(Backend, backend, LogLevel.info)
        \\    _ = forward(produce(saved))
        \\    return backend.saved^
        \\_ = escape(0)
    ;
    try Fixture.expectAnySourceDiagnostic(source, .borrow_outlives_source);
    const std = @import("std");
    const nonretaining = try std.mem.replaceOwned(u8, std.testing.allocator, source, "self.saved = owned^", "_ = owned");
    defer std.testing.allocator.free(nonretaining);
    try Fixture.expectSourceExit(nonretaining, 0);
}

test "arena backing replacement waits for dependent cleanup while counter writes preserve storage" {
    const source =
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\struct Arena
        \\    bytes: List(byte)
        \\    counter: int
        \\    pub func allocate(mut self: Arena, layout: AllocationLayout) RawBlock | AllocationError
        \\        self.counter += 1
        \\        var view = self.bytes.span()
        \\        return RawBlock.unsafe_from_span(view, layout)
        \\    pub func deallocate(mut self: Arena, deinit block: RawBlock) unit
        \\        self.counter += 1
        \\        block.retire()
        \\    func reset(mut self: Arena) unit | AllocationError
        \\        self.bytes = List(byte).filled(0, 8)?
        \\        return unit
        \\func exercise() int | AllocationError
        \\    var arena = Arena{bytes = List(byte).filled(0, 8)?, counter = 0}
        \\    const provider = Allocator.from(Arena, arena)
        \\    var values = List(int).new_with(provider, 1)?
        \\    _ = values.append(42)?
        \\    arena.counter += 1
        \\    _ = arena.reset()?
        \\    _ = values
        \\    return arena.counter + 39
        \\func run() int
        \\    const result = exercise()
        \\    if result is AllocationError -> return 90
        \\    return result
    ;
    const std = @import("std");
    const negative = try std.mem.concat(std.testing.allocator, u8, &.{ source, "\n_ = run()" });
    defer std.testing.allocator.free(negative);
    try Fixture.expectAnySourceDiagnostic(negative, .borrow_outlives_source);
    const positive = try std.mem.replaceOwned(u8, std.testing.allocator, source, "_ = arena.reset()?\n    _ = values", "_ = values\n    _ = arena.reset()?");
    defer std.testing.allocator.free(positive);
    try Fixture.expectParity(positive, 42);
}

test "callable reservation refusal precedes deferred capture construction and copying" {
    try Fixture.expectParity(
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
        \\import std.callables.{erase, clone}
        \\struct Refuser
        \\    pub func allocate(imm self: Refuser, layout: AllocationLayout) RawBlock | AllocationError -> AllocationError.budget
        \\    pub func deallocate(imm self: Refuser, deinit block: RawBlock) unit -> block.retire()
        \\struct Capture
        \\    ref copies: int
        \\    value: int
        \\    copy = func(imm self: Capture) Capture
        \\        self.copies += 1
        \\        return Capture{copies = self.copies, value = self.value}
        \\func run() int
        \\    var copies = 0
        \\    var refuser = Refuser{}
        \\    const capture = Capture{copies = copies, value = 42}
        \\    const original: func() int = () => capture.value
        \\    const before = copies
        \\    with context.allocator = Allocator.from(Refuser, refuser)
        \\        const refused = erase(func() int, () => capture.value)
        \\        if not (refused is AllocationError) or refused.reason <> AllocationError.budget.reason -> return 90
        \\        const copied = clone(original)
        \\        if not (copied is AllocationError) or copied.reason <> AllocationError.budget.reason -> return 91
        \\    if copies <> before -> return 92
        \\    return original()
    , 42);
}

test "destructor backing replacement follows the same last-use boundary as explicit reset" {
    const source =
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError}
        \\struct Arena
        \\    bytes: List(byte)
        \\    releases: int
        \\    pub func allocate(mut self: Arena, layout: AllocationLayout) RawBlock | AllocationError
        \\        var bytes = self.bytes.span()
        \\        return RawBlock.unsafe_from_span(bytes, layout)
        \\    pub func deallocate(mut self: Arena, deinit block: RawBlock)
        \\        self.releases += 1
        \\        block.retire()
        \\struct Reset
        \\    arena: Ref(Arena)
        \\    drop = func(deinit self: Reset)
        \\        self.arena.value.bytes = List(byte).filled(0, 8) catch -> panic "reset failed"
        \\func exercise() int | AllocationError
        \\    var arena = Arena{bytes = List(byte).filled(0, 8)?, releases = 0}
        \\    var values = List(int).new_with(Allocator.from(Arena, arena), 1)?
        \\    _ = values.append(42)?
        \\    const reset = Reset{arena = Ref.from(arena)}
        \\    _ = reset
        \\    _ = values
        \\    return arena.releases + 41
        \\func run() int
        \\    const result = exercise()
        \\    if result is AllocationError -> return 90
        \\    return result
    ;
    const std = @import("std");
    const negative = try std.mem.concat(std.testing.allocator, u8, &.{ source, "\n_ = run()" });
    defer std.testing.allocator.free(negative);
    try Fixture.expectAnySourceDiagnostic(negative, .borrow_outlives_source);
    const positive = try std.mem.replaceOwned(u8, std.testing.allocator, source, "_ = reset\n    _ = values", "_ = values\n    _ = reset");
    defer std.testing.allocator.free(positive);
    try Fixture.expectParity(positive, 42);
}

const recursive_provider_source =
    \\import std.memory.{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}
    \\struct Tracker
    \\    upstream: Allocator
    \\    allocations: int
    \\    releases: int
    \\    pub func allocate(mut self: Tracker, layout: AllocationLayout) RawBlock | AllocationError
    \\        self.allocations += 1
    \\        return self.upstream.allocate(layout)
    \\    pub func deallocate(mut self: Tracker, deinit block: RawBlock)
    \\        self.releases += 1
    \\        self.upstream.deallocate(block^)
    \\func construct(depth: int, imm provider: Allocator) List(int) | AllocationError
    \\    if depth > 0 -> return construct(depth - 1, provider)
    \\    return List(int).new_with(provider, 1)
    \\
;

test "recursive allocation forwarding retains provider lifetime and writable backend authority" {
    try Fixture.expectParity(recursive_provider_source ++
        \\func exercise() int | AllocationError
        \\    var tracker = Tracker{upstream = root_allocator(), allocations = 0, releases = 0}
        \\    var values = construct(2, Allocator.from(Tracker, tracker))?
        \\    _ = values.append(42)?
        \\    if values[0] <> 42 -> return 90
        \\    _ = values
        \\    return tracker.allocations + tracker.releases + 40
        \\func run() int
        \\    const result = exercise()
        \\    if result is AllocationError -> return 91
        \\    return result
    , 42);
    try Fixture.expectAnySourceDiagnostic(recursive_provider_source ++
        \\func escape() List(int) | AllocationError
        \\    var tracker = Tracker{upstream = root_allocator(), allocations = 0, releases = 0}
        \\    return construct(2, Allocator.from(Tracker, tracker))
        \\_ = escape()
    , .borrow_outlives_source);
}

test "loop provider forwarding preserves outer authority and rejects iteration-local retention" {
    try Fixture.expectParity(recursive_provider_source ++
        \\func exercise() int | AllocationError
        \\    var tracker = Tracker{upstream = root_allocator(), allocations = 0, releases = 0}
        \\    const provider = Allocator.from(Tracker, tracker)
        \\    var values = List(int).new(0)?
        \\    var index = 0
        \\    loop
        \\        index += 1
        \\        values = construct(1, provider)?
        \\        _ = values.append(20 + index)?
        \\        if index == 2 -> break
        \\    if values[0] <> 22 -> return 90
        \\    _ = values
        \\    return tracker.allocations + tracker.releases + 38
        \\func run() int
        \\    const result = exercise()
        \\    if result is AllocationError -> return 91
        \\    return result
    , 42);
    try Fixture.expectAnySourceDiagnostic(recursive_provider_source ++
        \\func escape() List(int) | AllocationError
        \\    var values = List(int).new(0)?
        \\    var index = 0
        \\    loop
        \\        var tracker = Tracker{upstream = root_allocator(), allocations = 0, releases = 0}
        \\        values = construct(1, Allocator.from(Tracker, tracker))?
        \\        index += 1
        \\        if index == 2 -> break
        \\    return values^
        \\_ = escape()
    , .borrow_outlives_source);
}
