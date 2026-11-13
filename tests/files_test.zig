const std = @import("std");
const sources = @import("test_sources");
const Fixture = sources.SourceFixture;

test "file paths preserve native bytes and lexical components with evaluator parity" {
    try Fixture.expectParity(
        \\import std.files.{Path, PathView}
        \\func run() int
        \\    const path = Path("assets/image.png")
        \\    if path.name() <> BytesView("image.png") -> return 1
        \\    if path.suffix() <> BytesView(".png") -> return 2
        \\    if path.parent() <> PathView("assets") -> return 3
        \\    const joined = path.parent().join("other.txt")
        \\    if joined <> PathView("assets/other.txt") -> return 4
        \\    const copied = joined
        \\    if copied <> joined -> return 5
        \\    if Path("/").parent() <> PathView("/") -> return 6
        \\    if Path("file").parent() <> PathView(".") -> return 7
        \\    if Path(".profile").suffix().byte_length() <> 0 or Path("..").suffix().byte_length() <> 0 -> return 8
        \\    if Path("a").join("/b") <> PathView("/b") -> return 9
        \\    return 42
    , 42);
}

fn expectFilesystem(template: []const u8) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source = try sources.renderTemplate(std.testing.allocator, template, .{ .root = root });
    defer std.testing.allocator.free(source);
    try Fixture.expectSourceExit(source, 42);
}

test "files whole-file helpers streaming positions resizing synchronization and metadata" {
    try expectFilesystem(
        \\import std.files as files
        \\import std.files.{Path, PathView, FileError, SeekFrom}
        \\func run() int | FileError | AllocationError | IoError | Utf8Error
        \\    const root = Path("$root")
        \\    const path = root.join("text")
        \\    _ = path.write_text("hé\r\n\0world")?
        \\    if path.read_text()? <> "hé\r\n\0world" -> return 1
        \\    if not path.exists()? or not path.is_file()? or path.is_dir()? -> return 2
        \\    var file = files.open(path, files.OpenMode.read_write)?
        \\    if file.position()? <> 0 -> return 3
        \\    if file.seek(SeekFrom.Start{5})? <> 5 -> return 4
        \\    if file.read_text()? <> "\0world" -> return 5
        \\    _ = file.seek(SeekFrom.End{-5})?
        \\    _ = file.write_text("WORLD")?
        \\    _ = file.seek(SeekFrom.Current{-5})?
        \\    var bytes: List(byte) = []
        \\    if file.read_bytes(bytes, 2)? <> 2 or bytes.bytes() <> BytesView("WO") -> return 6
        \\    const tail = file.read_bytes(100)?
        \\    if tail.bytes() <> BytesView("RLD") -> return 7
        \\    if file.read_bytes(1)?.len() <> 0 -> return 8
        \\    _ = file.set_length(5)?
        \\    _ = file.sync()?
        \\    const info = file.metadata()?
        \\    if info.byte_size <> 5 or not (info.kind is files.FileKind.file) -> return 9
        \\    if info.access_time.nanoseconds >= 1000000000 or info.modification_time.nanoseconds >= 1000000000 -> return 10
        \\    _ = file.close()?
        \\    if path.read_text()? <> "hé\r\n" -> return 11
        \\    const stat = files.metadata(path)?
        \\    if stat.byte_size <> 5 -> return 12
        \\    return 42
        \\const result = run()
        \\if result is int -> exit(result)
        \\if result is FileError -> print(result.cause)
        \\exit(90)
    );
}

test "files open modes preserve independent access creation append and truncation settings" {
    try expectFilesystem(
        \\import std.files as files
        \\import std.files.{Path, FileError}
        \\func run() int | FileError | AllocationError | IoError | Utf8Error
        \\    const root = Path("$root")
        \\    const path = root.join("created")
        \\    var mode = files.OpenMode.read_write
        \\    mode.creation = files.CreationPolicy.create_new
        \\    mode.permissions = 0o600
        \\    var file = path.open(mode)?
        \\    _ = file.write_text("first")?
        \\    _ = file.close()?
        \\    const exclusive = path.open(files.OpenMode.create_new)
        \\    if not (exclusive is FileError) -> return 1
        \\    if not (exclusive.kind is files.FileErrorKind.already_exists) -> return 2
        \\    if path.metadata()?.permissions <> 0o600 -> return 3
        \\    var appended = path.open(files.OpenMode.append)?
        \\    _ = appended.seek(files.SeekFrom.Start{0})?
        \\    _ = appended.write_text(" second")?
        \\    _ = appended.close()?
        \\    if path.read_text()? <> "first second" -> return 4
        \\    mode.creation = files.CreationPolicy.existing
        \\    mode.append = true
        \\    var both = path.open(mode)?
        \\    if both.read_bytes(5)?.bytes() <> BytesView("first") -> return 5
        \\    _ = both.write_text("!")?
        \\    _ = both.close()?
        \\    if path.read_text()? <> "first second!" -> return 6
        \\    var readonly = path.open()?
        \\    if not (readonly.write_text("bad") is IoError) -> return 7
        \\    _ = readonly.close()?
        \\    mode = files.OpenMode.read
        \\    mode.append = true
        \\    const invalid = path.open(mode)
        \\    if not (invalid is FileError) -> return 8
        \\    if not (invalid.kind is files.FileErrorKind.invalid_options) -> return 9
        \\    mode = files.OpenMode.write
        \\    mode.permissions = 0o10000
        \\    if not (path.open(mode) is FileError) -> return 10
        \\    var truncated = path.open(files.OpenMode.write)?
        \\    _ = truncated.close()?
        \\    if path.metadata()?.byte_size <> 0 -> return 11
        \\    return 42
        \\const result = run()
        \\if result is int -> exit(result)
        \\if result is FileError -> print(result.cause)
        \\exit(90)
    );
}

test "files directories creation queries enumeration rename and removal" {
    try expectFilesystem(
        \\import std.files as files
        \\import std.files.{Path, FileError}
        \\func run() int | FileError | AllocationError | IoError | Utf8Error
        \\    const root = Path("$root")
        \\    const nested = root.join("a/b/c")
        \\    _ = nested.mkdir_all()?
        \\    _ = nested.mkdir_all()?
        \\    if not nested.is_dir()? or nested.is_file()? -> return 1
        \\    const a = nested.join("one")
        \\    const b = nested.join("two")
        \\    _ = a.write_text("1")?
        \\    _ = b.write_text("2")?
        \\    const children = nested.list_dir()?
        \\    if children.len() <> 2 -> return 2
        \\    var seen = 0
        \\    for child in children
        \\        if child == a -> seen += 1
        \\        if child == b -> seen += 2
        \\    if seen <> 3 -> return 3
        \\    const c = nested.join("three")
        \\    _ = a.rename(c)?
        \\    if a.exists()? or not c.exists()? -> return 4
        \\    _ = c.rename(b)?
        \\    if b.read_text()? <> "1" -> return 5
        \\    if nested.remove_dir() is unit -> return 6
        \\    _ = b.remove_file()?
        \\    _ = nested.remove_dir()?
        \\    if nested.exists()? -> return 7
        \\    const missing = root.join("absent/file")
        \\    if missing.exists()? or missing.is_dir()? or missing.is_file()? -> return 8
        \\    if root.join("a/b").metadata()?.byte_size == 0 -> return 9
        \\    const current = files.cwd()?
        \\    if current.as_bytes().byte_length() == 0 -> return 10
        \\    return 42
        \\const result = run()
        \\if result is int -> exit(result)
        \\if result is FileError -> print(result.cause)
        \\exit(90)
    );
}

test "file paths preserve non-UTF8 names and format invalid bytes without losing valid text" {
    try Fixture.expectParity(
        \\import std.files.{Path, PathView}
        \\func run() int
        \\    const raw: Array(byte, 5) = [104, 195, 169, 255, 97]
        \\    const path = Path(BytesView.from_array(5, raw))
        \\    if not (path.as_text() is Utf8Error) -> return 1
        \\    if String(path) <> "hé\\xffa" -> return 2
        \\    if path.as_bytes() <> BytesView.from_array(5, raw) -> return 3
        \\    const view: StringView = "hé"
        \\    if BytesView(view) <> BytesView("hé") -> return 4
        \\    if Path(view) <> PathView("hé") -> return 5
        \\    return 42
    , 42);
}

test "file validation errors remain ordinary values and invalid options do not create files" {
    try expectFilesystem(
        \\import std.files as files
        \\import std.files.{Path, FileError}
        \\func run() int | FileError | AllocationError | IoError | Utf8Error
        \\    const empty = files.open("")
        \\    if not (empty is FileError) -> return 1
        \\    if not (empty.kind is files.FileErrorKind.invalid_path) or not (empty.cause is none) -> return 2
        \\    const nul = files.open("a\0b")
        \\    if not (nul is FileError) -> return 3
        \\    const path = Path("$root/new")
        \\    var mode = files.OpenMode.create_new
        \\    mode.permissions = 0o10000
        \\    if not (path.open(mode) is FileError) -> return 4
        \\    if path.exists()? -> return 5
        \\    const invalid: Array(byte, 1) = [255]
        \\    _ = path.write_bytes(BytesView.from_array(1, invalid))?
        \\    if not (path.read_text() is Utf8Error) -> return 6
        \\    var file = path.open()?
        \\    if not (file.read_bytes(-1) is AllocationError) -> return 7
        \\    if file.read_bytes(0)?.len() <> 0 or file.position()? <> 0 -> return 8
        \\    if not (file.seek(files.SeekFrom.Start{18446744073709551615}) is FileError) -> return 9
        \\    if not (file.seek(files.SeekFrom.Current{-1}) is FileError) -> return 10
        \\    if not (file.set_length(18446744073709551615) is FileError) -> return 11
        \\    _ = file.close()?
        \\    return 42
        \\const result = run()
        \\if result is int -> exit(result)
        \\if result is FileError -> print(result.cause)
        \\exit(90)
    );
}

test "file handles outlive temporary input paths and move without closing the descriptor" {
    try expectFilesystem(
        \\import std.files as files
        \\import std.files.{Path, File, FileError}
        \\func acquire() File | FileError | AllocationError
        \\    const path = Path("$root/data")
        \\    return files.open(path, files.OpenMode.write)
        \\func use(deinit file: File) unit | FileError | IoError
        \\    var owner = file^
        \\    _ = owner.write_text("kept")?
        \\    return owner.close()
        \\func run() int | FileError | AllocationError | IoError | Utf8Error
        \\    const file = acquire()?
        \\    _ = use(file^)?
        \\    if files.read_text("$root/data")? <> "kept" -> return 1
        \\    return 42
        \\const result = run()
        \\if result is int -> exit(result)
        \\if result is FileError -> print(result.cause)
        \\exit(90)
    );
}

test "filesystem effects are unavailable in the evaluator and unexecuted I/O stays dormant" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.files as files
        \\static result = files.exists(".")
        \\_ = result
    , .compile_time_unsupported_operation);
    try Fixture.expectSourceExit(
        \\import std.files as files
        \\func probe() int
        \\    if false -> _ = files.exists(".")
        \\    return 42
        \\exit(comptime -> probe())
    , 42);
}

test "file path views retain their owners and file methods require mutable access" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.files.{Path, PathView}
        \\func escape() PathView
        \\    const path = Path("a/b")
        \\    return path.parent()
        \\_ = escape()
    , .borrow_outlives_source);
    try Fixture.expectRejected(
        \\import std.files as files
        \\func copy_file() unit | files.FileError | AllocationError
        \\    const file = files.open(".")?
        \\    const copied = file
        \\    _ = copied
        \\copy_file()?
    );
}

test "file cleanup ignores errors consumes explicit closes once and preserves operation errors" {
    const fixture = try Fixture.init(
        \\import std.files as files
        \\func run() int | files.FileError | AllocationError
        \\    const automatic = files.open("/dev/null")?
        \\    _ = automatic.position()?
        \\    var explicit = files.open("/dev/null")?
        \\    const closed = explicit.close()
        \\    if not (closed is files.FileError) -> return 1
        \\    if not (closed.cause is int) or closed.cause <> 4 -> return 2
        \\    const successful_read = files.read_bytes("/dev/null")
        \\    if not (successful_read is files.FileError) -> return 3
        \\    if not (successful_read.cause is int) or successful_read.cause <> 4 -> return 4
        \\    const failed_read = files.read_bytes(".")
        \\    if not (failed_read is IoError) -> return 5
        \\    if failed_read.cause <> 21 -> return 6
        \\    return 42
        \\const result = run()
        \\if result is int -> exit(result)
        \\exit(90)
    );
    defer fixture.deinit();
    const original = @import("standard_library").source("files.chi");
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, original, "extern func files_close(descriptor: int) i64",
        \\func files_close(descriptor: int) i64
        \\    _ = streams.write_text(streams.stderr, "c")
        \\    return -4
        \\import std.io as streams
    );
    defer std.testing.allocator.free(changed);
    const file = (try fixture.db.input(sources.queries.StandardFile, @backingInt(@import("standard_library").File.files))).*;
    try fixture.db.setInput(sources.queries.SourceText, file, changed);
    const result = try fixture.runIo("");
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);
    try std.testing.expectEqualStrings("cccc", result.stderr);
}

test "files grow read storage preserve arbitrary bytes and own directory entry paths" {
    try expectFilesystem(
        \\import std.files as files
        \\import std.files.{Path, PathView, FileError}
        \\func run() int | FileError | AllocationError | IoError | Utf8Error
        \\    const root = Path("$root")
        \\    const raw: Array(byte, 3) = [97, 255, 98]
        \\    const path = root.join(PathView(BytesView.from_array(3, raw)))
        \\    var bytes = List(byte).new(16387)?
        \\    for index in 0..16387 -> _ = bytes.append(wrap(byte, index % 251))?
        \\    _ = path.write_bytes(bytes.bytes())?
        \\    const loaded = path.read_bytes()?
        \\    if loaded.bytes() <> bytes.bytes() -> return 1
        \\    var reader = path.open()?
        \\    if reader.read_bytes(9000)?.bytes() <> bytes.bytes()[0..9000] -> return 2
        \\    if reader.read_bytes()?.bytes() <> bytes.bytes()[9000..] -> return 3
        \\    _ = reader.close()?
        \\    const entries = root.list_dir()?
        \\    if entries.len() <> 1 or entries[0] <> path -> return 4
        \\    if not (entries[0].as_text() is Utf8Error) -> return 5
        \\    return 42
        \\const result = run()
        \\if result is int -> exit(result)
        \\if result is FileError -> print(result.cause)
        \\exit(90)
    );
}

test "file allocation failures release path copies and preserve fallible construction" {
    try Fixture.expectParity(
        \\import std.files.{Path, PathView}
        \\import std.memory.{Allocator, AllocationLayout, RawBlock, root_allocator}
        \\struct Tracker
        \\    upstream: Allocator
        \\    calls: int
        \\    releases: int
        \\    refuse: bool
        \\    pub func allocate(mut self: Tracker, layout: AllocationLayout) RawBlock | AllocationError
        \\        self.calls += 1
        \\        if self.refuse -> return AllocationError.budget
        \\        return self.upstream.allocate(layout)
        \\    pub func deallocate(mut self: Tracker, deinit block: RawBlock)
        \\        self.releases += 1
        \\        self.upstream.deallocate(block^)
        \\func exercise(ref tracker: Tracker) int
        \\    with context.allocator = Allocator.from(Tracker, tracker)
        \\        const path = Path("a/b")
        \\        const copied = path
        \\        if copied <> PathView("a/b") -> return 1
        \\        tracker.refuse = true
        \\        const refused = path.clone()
        \\        if not (refused is AllocationError) -> return 2
        \\        if path <> PathView("a/b") -> return 3
        \\    return 42
        \\func run() int
        \\    var tracker = Tracker{upstream = root_allocator(), calls = 0, releases = 0, refuse = false}
        \\    const status = exercise(tracker)
        \\    if status <> 42 -> return status
        \\    if tracker.calls <> 3 or tracker.releases <> 2 -> return 4
        \\    return 42
    , 42);
}

test "files symlink metadata follows links while namespace removal unlinks only the entry" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = "abc" });
    try temporary.dir.symLink(std.testing.io, "target", "link", .{});
    try temporary.dir.symLink(std.testing.io, "missing", "dangling", .{});
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source = try sources.renderTemplate(std.testing.allocator,
        \\import std.files as files
        \\import std.files.{Path, FileError}
        \\func run() int | FileError | AllocationError | IoError | Utf8Error
        \\    const root = Path("$root")
        \\    const link = root.join("link")
        \\    const dangling = root.join("dangling")
        \\    if not (link.symlink_metadata()?.kind is files.FileKind.symlink) -> return 1
        \\    if not (link.metadata()?.kind is files.FileKind.file) -> return 2
        \\    if link.read_text()? <> "abc" -> return 3
        \\    if dangling.exists()? -> return 4
        \\    if not (dangling.symlink_metadata()?.kind is files.FileKind.symlink) -> return 5
        \\    _ = link.remove_file()?
        \\    if not root.join("target").exists()? -> return 6
        \\    if root.join("target/child").exists()? -> return 7
        \\    return 42
        \\const result = run()
        \\if result is int -> exit(result)
        \\exit(90)
    , .{ .root = root });
    defer std.testing.allocator.free(source);
    try Fixture.expectSourceExit(source, 42);
}

test "file owners in collections and repeated directory enumeration release all descriptors" {
    try Fixture.expectSourceExit(
        \\import std.files as files
        \\func acquire() unit | files.FileError | AllocationError
        \\    var owners = List(files.File).new(0)?
        \\    for _ in 0..32
        \\        const file = files.open("/dev/null")?
        \\        _ = owners.append(file^)?
        \\    return unit
        \\func run() int | files.FileError | AllocationError
        \\    const before = files.list_dir("/proc/self/fd")?.len()
        \\    for _ in 0..4 -> _ = acquire()?
        \\    const after = files.list_dir("/proc/self/fd")?.len()
        \\    if before <> after -> return 1
        \\    return 42
        \\const result = run()
        \\if result is int -> exit(result)
        \\exit(90)
    , 42);
}

test "file operations preserve OS failure causes and failed allocations do not create entries" {
    try expectFilesystem(
        \\import std.files as files
        \\import std.files.{Path, FileError}
        \\import std.memory.{Allocator, AllocationLayout, RawBlock}
        \\struct Refuse
        \\    pub func allocate(imm self: Refuse, layout: AllocationLayout) RawBlock | AllocationError -> AllocationError.budget
        \\    pub func deallocate(imm self: Refuse, deinit block: RawBlock) -> block.retire()
        \\func run() int | FileError | AllocationError | IoError | Utf8Error
        \\    const root = Path("$root")
        \\    const path = root.join("new")
        \\    const refuse = Refuse{}
        \\    with context.allocator = Allocator.from(Refuse, refuse)
        \\        const denied = path.open(files.OpenMode.create_new)
        \\        if not (denied is AllocationError) -> return 1
        \\        const invalid = files.open("\0")
        \\        if not (invalid is FileError) -> return 2
        \\    if path.exists()? -> return 3
        \\    const too_long = root.join("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz")
        \\    const failure = too_long.open(files.OpenMode.create_new)
        \\    if not (failure is FileError) -> return 4
        \\    if not (failure.kind is files.FileErrorKind.name_too_long) -> return 5
        \\    const bad = root.join("new\0/child")
        \\    if not (bad.mkdir_all() is FileError) -> return 6
        \\    if path.exists()? -> return 7
        \\    return 42
        \\const result = run()
        \\if result is int -> exit(result)
        \\exit(90)
    );
}

test "filesystem bundled functions refresh after standard library source edits" {
    const fixture = try Fixture.init(
        \\import std.files as files
        \\func run() int | files.FileError | AllocationError
        \\    const file = files.open("/dev/null")?
        \\    return 42 + wrap(int, file.position()?)
        \\const result = run()
        \\if result is int -> exit(result)
        \\exit(90)
    );
    defer fixture.deinit();
    const loader = try sources.standard_bundle_loader.install(fixture.db, sources.standard_bundle);
    try fixture.expectExit(0, 42);
    try std.testing.expect(loader.stats().functions > 0);
    const original = @import("standard_library").source("files.chi");
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, original, "return wrap(u64, result)", "return wrap(u64, result) + 1");
    defer std.testing.allocator.free(changed);
    const file = (try fixture.db.input(sources.queries.StandardFile, @backingInt(@import("standard_library").File.files))).*;
    try fixture.db.setInput(sources.queries.SourceText, file, changed);
    try fixture.expectExit(0, 43);
    try fixture.db.setInput(sources.queries.SourceText, file, original);
    try fixture.expectExit(0, 42);
}

test "filesystem extern signature validation rejects incorrect native storage shapes" {
    const fixture = try Fixture.init(
        \\import std.files as files
        \\_ = files.metadata(".")
    );
    defer fixture.deinit();
    const original = @import("standard_library").source("files.chi");
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, original, "mut buffer: Array(u64, 18)", "mut buffer: Array(u64, 17)");
    defer std.testing.allocator.free(changed);
    const file = (try fixture.db.input(sources.queries.StandardFile, @backingInt(@import("standard_library").File.files))).*;
    try fixture.db.setInput(sources.queries.SourceText, file, changed);
    try fixture.expectDiagnostic(file, .invalid_external_signature);
    try fixture.db.setInput(sources.queries.SourceText, file, original);
    try fixture.expectExit(0, 0);
}

test "file byte reads preserve initialized data on failure and reject seeking on a pipe" {
    const fixture = try Fixture.init(
        \\import std.files as files
        \\func run() int | files.FileError | AllocationError | IoError | Utf8Error
        \\    var directory = files.open(".")?
        \\    var bytes: List(byte) = [1, 2]
        \\    const failed = directory.read_bytes(bytes, 10)
        \\    if not (failed is IoError) -> return 1
        \\    if bytes.len() <> 2 or bytes[0] <> 1 or bytes[1] <> 2 -> return 2
        \\    if directory.read_bytes(bytes, 0)? <> 0 -> return 3
        \\    _ = directory.close()?
        \\    var pipe = files.open("/dev/stdin")?
        \\    const seek = pipe.seek(files.SeekFrom.Start{0})
        \\    if not (seek is files.FileError) -> return 4
        \\    if not (seek.kind is files.FileErrorKind.not_seekable) -> return 5
        \\    if pipe.read_text()? <> "pipe input" -> return 6
        \\    _ = pipe.close()?
        \\    return 42
        \\const result = run()
        \\if result is int -> exit(result)
        \\exit(90)
    );
    defer fixture.deinit();
    const result = try fixture.runIo("pipe input");
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);
}

test "file opening accepts every public path conversion without borrowing the input" {
    try expectFilesystem(
        \\import std.files as files
        \\import std.files.{Path, PathView, File, FileError}
        \\func run() int | FileError | AllocationError | IoError
        \\    const literal: StaticString = "$root/input"
        \\    _ = files.write_text(literal, "input")?
        \\    const text = String(literal)
        \\    const view = text.view()
        \\    const bytes = view.as_bytes()
        \\    const path = Path(bytes)
        \\    const path_view = path.view()
        \\    if not (files.open(literal) is File) -> return 1
        \\    if not (files.open(text) is File) -> return 2
        \\    if not (files.open(view) is File) -> return 3
        \\    if not (files.open(bytes) is File) -> return 4
        \\    if not (files.open(path) is File) -> return 5
        \\    if not (files.open(path_view) is File) -> return 6
        \\    var mode = files.OpenMode.read_write
        \\    mode.creation = files.CreationPolicy.create_if_missing
        \\    var created = files.open("$root/created", mode)?
        \\    if created.write_once("once")? <> 4 -> return 7
        \\    _ = created.close()?
        \\    return 42
        \\const result = run()
        \\if result is int -> exit(result)
        \\exit(90)
    );
}

test "exclusive file creation elects exactly one owner across competing processes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source = try sources.renderTemplate(std.testing.allocator,
        \\import std.files as files
        \\const result = files.open("$root/exclusive", files.OpenMode.create_new)
        \\if result is files.File -> exit(42)
        \\if result is files.FileError
        \\    if result.kind is files.FileErrorKind.already_exists -> exit(43)
        \\exit(90)
    , .{ .root = root });
    defer std.testing.allocator.free(source);
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    const executable = try fixture.executable(0);
    var program = try sources.runtime.prepareProgram(std.testing.io, std.testing.allocator, executable.bytes);
    defer program.deinit(std.testing.io);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "prog") catch {};
    var first = try std.process.spawn(std.testing.io, .{ .argv = &.{program.path}, .stdout = .ignore, .stderr = .ignore });
    defer first.kill(std.testing.io);
    var second = try std.process.spawn(std.testing.io, .{ .argv = &.{program.path}, .stdout = .ignore, .stderr = .ignore });
    defer second.kill(std.testing.io);
    const a = try first.wait(std.testing.io);
    const b = try second.wait(std.testing.io);
    try std.testing.expect((a == .exited and b == .exited) and ((a.exited == 42 and b.exited == 43) or (a.exited == 43 and b.exited == 42)));
}

test "file reads distinguish EOF at the storage limit from an oversized stream" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source = try sources.renderTemplate(std.testing.allocator,
        \\import std.files as files
        \\func run() int | files.FileError | AllocationError | IoError
        \\    var bytes = List(byte).filled(65, 4096)?
        \\    _ = files.write_bytes("$root/data", bytes.bytes())?
        \\    if files.read_bytes("$root/data")?.len() <> 4096 -> return 1
        \\    _ = bytes.append(66)?
        \\    _ = files.write_bytes("$root/data", bytes.bytes())?
        \\    var file = files.open("$root/data")?
        \\    const oversized = file.read_bytes()
        \\    if not (oversized is AllocationError) -> return 2
        \\    if file.position()? <> 4097 -> return 3
        \\    _ = file.seek(files.SeekFrom.Start{0})?
        \\    if file.read_bytes(4096)?.len() <> 4096 -> return 4
        \\    if file.position()? <> 4096 -> return 5
        \\    _ = file.close()?
        \\    return 42
        \\const result = run()
        \\if result is int -> exit(result)
        \\exit(90)
    , .{ .root = root });
    defer std.testing.allocator.free(source);
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    const original = @import("standard_library").source("files.chi");
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, original, "read_file(self.descriptor, 2147483647, false)", "read_file(self.descriptor, 4096, false)");
    defer std.testing.allocator.free(changed);
    const file = (try fixture.db.input(sources.queries.StandardFile, @backingInt(@import("standard_library").File.files))).*;
    try fixture.db.setInput(sources.queries.SourceText, file, changed);
    try fixture.expectExit(0, 42);
}
