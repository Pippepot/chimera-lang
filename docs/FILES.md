# `std.files` API plan

File and path operations for Linux x86-64. Whole-file helpers handle everyday
tasks; `File` supports incremental I/O; `Path` supports composing and reusing paths.

```chi
import std.files as files
import std.files.{Path}

const text = files.read_text("notes.txt")?
print(text)
files.write_text("copy.txt", text)?

var log = files.open("app.log", files.OpenMode.append)?
log.write_text("started\n")?

for child in Path("assets").list_dir()? -> print(child)
```

## Whole-file operations

| Function | Successful result |
| --- | --- |
| `read_text(path)` | Complete UTF-8 contents as `String` |
| `read_bytes(path)` | Complete contents as `List(byte)` |
| `write_text(path, text)` | `unit`; create or truncate and write all text |
| `write_bytes(path, bytes)` | `unit`; create or truncate and write all bytes |

Reads grow storage until EOF. Allocation and container-size failures return
`AllocationError`. Text uses UTF-8 with exact newline preservation.
Each helper opens and closes its file.

## Paths

`Path(text)` and `Path(bytes)` create owned, copyable path values. `PathView` is
the borrowed counterpart. Filesystem functions take `PathView`; direct public
converters accept `Path`, `StaticString`, `String`, `StringView`, and `BytesView`.

Both path types provide the whole-file and filesystem methods listed here.
Methods forward to the shared module-level implementation.

| Path operation | Result |
| --- | --- |
| `join(child)` | Owned `Path`; an absolute child supplies the resulting path |
| `parent()` | Borrowed `PathView`; a root keeps its root, a bare filename has parent `.` |
| `name()` | Final component as borrowed `BytesView` |
| `suffix()` | Last extension as borrowed `BytesView`, including its dot; empty when absent or for `.profile` |
| `as_bytes()` | Borrowed native bytes |
| `as_text()` | `StringView | Utf8Error` |

Paths preserve native filename bytes. Printing renders text directly and escapes
invalid UTF-8 bytes. Construction, copying, and joining follow `String`'s ordinary
allocation policy; `clone()` provides recoverable copying.

Path equality compares native bytes. Components use `BytesView` equality;
`validate_utf8()` produces a text view when needed. Byte-view equality and direct
`StringView`-to-`BytesView` conversion belong in [std.text](../std/text.chi).

Relative paths resolve against the working directory when an operation runs.
`cwd()` returns an owned path to that directory. The OS resolves `.` and `..`
and symbolic links. Empty paths and embedded NUL return `FileError` at the
filesystem boundary. Path values keep their spelling across filesystem changes.

## Open files

`open(path)` opens an existing file for reading. `open(path, mode)` accepts a
typed `OpenMode`. Both return an owned `File`; path methods provide the same calls.

| Preset | Behavior |
| --- | --- |
| `OpenMode.read` | Read an existing file |
| `OpenMode.write` | Create or truncate for writing |
| `OpenMode.append` | Create or append for writing |
| `OpenMode.read_write` | Read and write an existing file |
| `OpenMode.create_new` | Atomically create a new file for writing |

`OpenMode` is a copyable settings value with independent fields:

| Field | Type / values |
| --- | --- |
| `access` | `FileAccess.read`, `FileAccess.write`, `FileAccess.read_write` |
| `creation` | `CreationPolicy.existing`, `CreationPolicy.create_if_missing`, `CreationPolicy.create_new` |
| `append` | `bool`; writes use OS append placement |
| `truncate` | `bool`; opening clears existing contents |
| `permissions` | POSIX permission bits as `u32`, filtered by umask; presets use `0o666` |

Presets provide the common combinations. A caller can copy and adjust one:

```chi
var mode = files.OpenMode.read_write
mode.creation = files.CreationPolicy.create_new
var database = files.open("new.db", mode)?
```

`open` validates compound constraints before OS calls: append and truncation
require write access, and permissions fit `0o7777`. Permissions apply to newly
created files. Exclusive creation atomically fails when an entry exists.
Access checks on subsequent operations are enforced by the OS.

| File method | Successful result |
| --- | --- |
| `read_text()` | Remaining contents as UTF-8 `String` |
| `read_bytes()` | Remaining contents as `List(byte)` |
| `read_bytes(count)` | Up to `count` bytes, stopping at that count or EOF |
| `read_bytes(mut destination, count)` | Append one transfer to `List(byte)`; return its count |
| `write_text(text)`, `write_bytes(bytes)` | `unit` after writing the complete input |
| `write_once(bytes)` | Count from one potentially short transfer |
| `seek(from)` | New position specified by `SeekFrom` |
| `position()` | Current position |
| `set_length(length)` | `unit` after resizing |
| `metadata()` | `Metadata` snapshot |
| `sync()` | `unit` after synchronizing data and metadata |
| `close()` | `unit` after consuming and closing the file |

Reads, writes, seeking, and resizing borrow the file mutably. Counts use `int`;
positions and lengths use `u64`.

The destination-taking read follows [std.io](../std/io.chi): one potentially short
transfer appends to the initialized prefix. Allocating reads grow with the data
and stop at the requested count or EOF. Zero-length reads return immediately;
zero progress on a nonempty read means EOF. Negative counts return
`AllocationError.invalid_layout`.

Reads and writes retry interrupted transfers. Complete writes may issue several
OS writes and fail on zero progress. Multi-transfer methods accumulate
`IoError.progress` across the call. Failure preserves initialized destination
bytes and completed external effects.

Seeking uses a typed value with the appropriate numeric payload:

```chi
pub static SeekFrom = .Start: u64 | .Current: i64 | .End: i64

_ = file.seek(files.SeekFrom.Start{0})?
_ = file.seek(files.SeekFrom.End{-8})?
```

Seeking before zero, offsets outside the target range, and operations on
non-seekable handles return `FileError`. Seeking changes the position;
`set_length` changes the file's length. `sync()` requests persistence of file data
and metadata.

## Filesystem operations

The following module functions also have methods on `Path` and `PathView`:

| Function | Successful result / effect |
| --- | --- |
| `exists(path)` | Whether the target exists |
| `is_file(path)`, `is_dir(path)` | Whether the target has that kind |
| `metadata(path)` | Target metadata |
| `symlink_metadata(path)` | Metadata for the directory entry itself |
| `list_dir(path)` | `List(Path)` containing child paths |
| `mkdir(path)` | Create one directory |
| `mkdir_all(path)` | Create missing parents; an existing directory succeeds |
| `remove_file(path)` | Unlink a file or symbolic link |
| `remove_dir(path)` | Remove an empty directory |
| `rename(source, destination)` | Atomically move the entry, replacing a compatible destination |

Existence and kind queries follow symbolic links. Missing targets, missing path
components, and a non-directory intermediate component return `false`.
`is_file` recognizes regular files; `is_dir` recognizes directories. Other OS
failures propagate. Cross-filesystem rename returns `FileError`. Directories are
created with `0o777` filtered by umask.

`list_dir()` returns owned paths joined to the requested parent. Enumeration skips
`.` and `..` and reflects filesystem order and concurrent changes. The returned
list can be traversed with ordinary collection iteration.

`Metadata` contains kind, byte size, permissions, access time, and modification
time. Times use signed Unix seconds and normalized nanoseconds.

## Errors and cleanup

Functions return ordinary marked-error alternatives: `FileError` for filesystem
operations, existing `IoError` for byte transfers, `AllocationError` for storage,
and `Utf8Error` for text decoding. `FileError` carries a stable kind and optional
native cause; `IoError` retains completed-byte progress. For example,
`read_text(path)` returns
`String | FileError | IoError | AllocationError | Utf8Error`.

`File` is movable and single-owner, with atomic close-on-exec acquisition.
Automatic destruction closes it and panics on failure. Explicit
`close(deinit self) unit | FileError` consumes the file on either outcome.
Linux close is attempted once. Whole-file helpers return a close error after a
successful operation; simultaneous operation and close failures panic.

## Implementation sequence

1. **Foundation:** path values/views, converters and byte-view comparisons,
   typed opening settings, source registration, errors, closing, and
   language-reference contracts.
2. **File I/O:** whole-file helpers, counted reads, reusable-buffer reads, complete
   writes, positioning, resizing, and synchronization.
3. **Paths and directories:** lexical helpers, queries, namespace changes, and
   directory listing.
4. **Qualification:** ownership, failure paths, evaluator diagnostics, incremental
   recomputation, persistent reuse, and source/bundled-library parity.

Tests exercise the examples above, EOF and short I/O, UTF-8 boundaries, path
conversions and borrowed-view lifetimes, arbitrary filename bytes, missing and
inaccessible entries, creation races, directory listing, close failures, and
ordinary allocation failures. Runtime tests use isolated temporary directories.

Library policy lives in Chimera; private externs provide OS operations through
the existing [compiler boundaries](ARCHITECTURE.md). Reached compile-time I/O
produces an unavailable-execution diagnostic. Verification follows
[COMPILER.md](COMPILER.md#verify).

The two module-level `open` overloads use generic path-argument wrappers
constrained to `PathView`-compatible inputs. Each forwards to one `PathView`
implementation. Other module functions accept `PathView` directly. This follows
the language's overload-selection and converter rules.

Acceptance cases include default read opening, append, exclusive creation,
in-place writes, read/write creation, read/write append, invalid opening
combinations, absolute and relative seeking, component comparisons, reusable
destination buffers, and a file outliving its input path storage.

## Reference APIs

- Mojo [Path](https://mojolang.org/docs/std/pathlib/path/Path/): whole-file methods,
  path composition, queries, and directory listing.
- Mojo [open](https://mojolang.org/docs/std/io/file/open/) and
  [FileHandle](https://mojolang.org/docs/std/io/file/FileHandle/): read-to-EOF
  defaults, counted reads, and complete writes.
- Rust [Path](https://doc.rust-lang.org/std/path/struct.Path.html): borrowed native
  path views and owned path values.
- Rust [OpenOptions](https://doc.rust-lang.org/std/fs/struct.OpenOptions.html):
  independent access, creation, append, and truncation settings.
- Rust [SeekFrom](https://doc.rust-lang.org/std/io/enum.SeekFrom.html): absolute
  positions and signed relative offsets.
