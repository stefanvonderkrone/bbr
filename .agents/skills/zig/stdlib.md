# Standard library corrections

These notes record verified Zig 0.16.0 behavior. Recheck the installed source before using an API.

## Process initialization

`main` takes `std.process.Init`.
Use its `gpa`, `arena`, `io`, `environ_map`, and `minimal.args` fields.
Read environment values through `init.environ_map.get("KEY")`.
Zig 0.16 removed `std.process.getEnvVarOwned`.
The default runtime already backs `init.io` with `std.Io.Threaded`.

## Collections and writers

`std.ArrayList(T)` is unmanaged. Its methods take the allocator.
Initialize it with `.empty`, then use `append(gpa, item)`, `deinit(gpa)`, and `toOwnedSlice(gpa)`.
The managed variant is `array_list.Managed(T)`.
`ArrayListUnmanaged` is a deprecated alias for `ArrayList`.

An unmanaged `std.ArrayList(u8)` has no `.writer()`.
Use `list.print(gpa, fmt, args)` or `list.appendSlice(gpa, bytes)`.

`std.Io.Reader` and `std.Io.Writer` are non-generic interfaces with vtables and caller-supplied buffers.
Use `*std.Io.Reader` at the interface boundary.
Format through `writer.print(...)`.

## Reads, paths, and child processes

`std.Io.Dir.readFileAlloc` uses an exclusive limit.
For an inclusive maximum, pass `.limited(max_bytes + 1)`.
The API text-file tests cover exactly 1 MiB and one byte more.

A blocking open of a FIFO waits until a writer appears.
`std.Io.Dir.openFile` and `readFileAlloc` set `O_NONBLOCK` only with a lock and `lock_nonblocking`.
A separate `statFile` before the open leaves a race.
To read a path that a user controls, open it with `std.posix.openat` and `.NONBLOCK = true`.
Wrap the descriptor as `std.Io.File`, then check `file.stat(io)` for `.kind == .file` before the read.
`src/config_source.zig` (`Snapshot.readRegular`) shows the pattern.

`error.ReadFailed` from a `std.Io.File.Reader` interface hides the cause.
The cause is in the `err` field of the `File.Reader`. Return `reader.err.?`, not `ReadFailed`.

`std.Io.Dir` has no `realpathAlloc` in Zig 0.16.
`std.testing.tmpDir(.{})` exposes `dir`, `parent_dir`, and `sub_path`.
For a C API path, build `.zig-cache/tmp/{s}/pending.db` from `tmp.sub_path`.
Use `std.fmt.allocPrintSentinel(a, fmt, args, 0)` for a NUL-terminated path.
`allocPrintZ` is removed.

`std.process.run(gpa, io, .{ .argv, .cwd })` returns `RunResult` with `term`, `stdout`, and `stderr`.
`Term` is a tagged union. `Cwd` accepts `inherit`, `dir`, or `path`.

## Names and arenas

Integer type names such as `i2` and `u3` are reserved.
Use names such as `oi` and `ni` for indexes.

`ArenaAllocator.reset` takes `free_all`, `retain_capacity`, or `retain_with_limit` through its `ResetMode` union.
Use a byte limit for reused Buffer and frame arenas.
A `false` result means shrinking failed. The arena remains usable with its old memory released.
