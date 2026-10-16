# Runtime ownership corrections

## Concurrent work

Use `std.Io` and `std.Io.Threaded` for I/O and concurrency.
Use the Io vtable's `async`, `concurrent`, or `groupAsync` operations rather than `std.Thread.Pool`.

`std.Io.concurrent(fn, args)` copies the argument tuple by value.
A slice copies only its header. Pass owned data or keep its backing storage alive through the task.
The call returns `std.Io.Future(R)`. Reclaim the future with `future.await(io)`.
Await every future before destroying state that a worker can still access.

This toolchain has no `std.heap.ThreadSafeAllocator`.
Give workers `std.heap.page_allocator`, keep `gpa` on the main thread, and transfer ownership through events.

## HTTP clients

`std.http.Client.fetch` returns a status and streams the body to a writer.
Use an allocating writer through `.response_writer = &aw.writer`, then take `aw.toOwnedSlice()`.
The client takes `.allocator` and `.io`. Classify a status with `status.class()`.

Share the Client, not a Request.
Client requests are thread-safe, and the connection pool handles its own locks.
Use a thread-safe Client allocator.
Each worker owns and deinitializes its Request.
Await all workers before deinitializing the Client.
bbr uses one TUI-lifetime Client backed by `page_allocator` to reuse connections.

## Terminal cells and events

vaxis cells borrow their text until `render`.
Use static text for fixed glyphs and a per-frame arena for synthesized text.
Reset that arena after rendering.
A draw-loop stack buffer can make every row display the last value or invalid bytes.

`vaxis.Loop(T)` uses the application's event union.
Post worker completions through `loop.postEvent(...)`.
The terminal reader posts only variants that it recognizes through `@hasField` checks.
An exhaustive tagged-union switch must omit an `else` branch.

## C object lifetimes

An arbitrary integer converted to a function pointer can fail the alignment check.
This affects the `SQLITE_TRANSIENT` sentinel cast.
Use `null` for `SQLITE_STATIC` only when the bound bytes remain alive through `sqlite3_step` and statement finalization.

Destroy cached tree-sitter queries and runtime packages before closing their UserGrammar dynamic library.
Their language pointers depend on the loaded library.

## Interface convention

The `ptr` and `*const VTable` interface follows Zig's Allocator and Io interfaces.
bbr deliberately uses this convention for `HttpClient`, `PendingReviewStore`, and `Highlighter`.
