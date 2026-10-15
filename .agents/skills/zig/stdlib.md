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
