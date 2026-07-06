# Zig 0.16.0 — Feature Notes for bbr

Tracks the Zig features and stdlib APIs **bbr** relies on, pinned to the currently installed
toolchain. Zig's std churns hard between minor versions, so when you bump Zig, re-verify each
section against the new stdlib and update this file.

- **Installed:** `zig 0.16.0` (`/opt/homebrew/bin/zig`, Cellar `0.16.0_1`)
- **stdlib root:** `/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std`
- **libvaxis:** `main` (v0.6.0) — `minimum_zig_version = "0.16.0"` ✓
- All API facts below were read from the installed stdlib source, not from memory.
- Companion: the [`zig` skill](.claude/skills/zig/SKILL.md) holds the *process* (verify-don't-recall
  discipline + recurring corrections). Keep both current — see this file's re-verification checklist
  and the skill's "Keep this skill and ZIG.md current" section.

---

## 1. "Writergate": `std.Io.Reader` / `std.Io.Writer`

0.16 replaced the old generic `std.io.Reader`/`Writer` with **non-generic, vtable-based**
interfaces that carry their own buffer:

- `std.Io.Reader` — `std/Io/Reader.zig`
- `std.Io.Writer` — `std/Io/Writer.zig`

Implications for us:
- Buffers are explicit; you hand the interface a `[]u8` and it manages fill/drain.
- Formatting goes through `writer.print(...)`; there is no more `anytype`-generic stream.
- Anything wrapping I/O (our diff parser reading a `RawDiff`, JSON decoding) targets these
  interfaces. Prefer taking a `*std.Io.Reader` over a concrete stream.

## 2. `std.Io` and concurrency — `std.Io.Threaded`

0.16 centralizes I/O and concurrency behind the **`std.Io`** interface (`std/Io.zig`). The
concrete runtime we use is **`std.Io.Threaded`** (`std/Io/Threaded.zig`):

```zig
var threaded: std.Io.Threaded = .init(gpa, .{});   // async_limit defaults to cpu_count-1
const io: std.Io = threaded.io();
```

- `Threaded.init(gpa, options)` builds a threaded runtime; `async_limit` defaults to
  `cpu_count - 1` (falls back gracefully if the CPU count can't be read).
- Concurrent work is spawned through the `Io` vtable (`async` / `concurrent` / `groupAsync`),
  which the `Threaded` runtime schedules onto its worker threads.

**Design consequence (supersedes an earlier note):** `std.http.Client` *requires* an `Io`
(it has an `io: Io` field), so we do **not** hand-roll a `std.Thread.Pool`. Instead
`std.Io.Threaded` is the background runtime; the vaxis event loop stays on the main thread and
network results are marshalled back to it as custom events. UI state is still mutated only on
the main thread; the Epoch token still guards against stale results.

**Concrete async pattern (M4, verified against a running TUI):**
- `std.Io.concurrent(fn, args_tuple)` returns `std.Io.Future(Ret)` (or `ConcurrencyUnavailable`).
  The **args tuple is copied by value** into the task — a `[]const u8` copies only the slice
  header, so pass a fixed `[N]u8` for strings whose backing you don't control, or ensure the
  pointee outlives the task. `future.await(io)` (mutating; takes `*Future`) reclaims the task;
  **await every future before tearing down any state a worker still touches** (e.g. a vaxis
  loop's event queue), or a late `postEvent` hits freed memory.
- `vaxis.Loop(T)` is generic over **your own** event union: add a variant (`load_done: …`) and
  post it from a worker thread with `loop.postEvent(...)`. The tty reader thread only posts
  variants whose field names it recognises (it guards with `@hasField`), so custom variants are
  yours alone. A `union(enum)` with every case handled must **not** carry an `else =>` prong
  (compile error: "unreachable else prong").
- **No `std.heap.ThreadSafeAllocator` in this 0.16 build.** Don't share one allocator across
  threads: give worker threads the stateless `std.heap.page_allocator` and keep the main
  allocator (gpa) main-thread-only. Hand ownership across the thread boundary via the event.
- Shelling out: `std.process.run(gpa, io, .{ .argv, .cwd })` → `RunResult{ term, stdout, stderr }`
  (caller owns stdout/stderr). `Term` is `union(enum){ exited: u8, signal, stopped, unknown }`;
  `Cwd` is `union(enum){ inherit, dir: Io.Dir, path: []const u8 }`.

## 2.5 Process entry: `main(init)` and reading the environment

**Verified by building bbr's M0.** 0.16 changed how a program starts and how it reads env vars.

- **`main` can take a `std.process.Init`** (or `Init.Minimal`). The runtime constructs and hands
  you everything:
  ```zig
  pub fn main(init: std.process.Init) !void {
      const gpa = init.gpa;            // thread-safe GPA (leak-checked in debug)
      const io = init.io;              // Io backed by std.Io.Threaded — already built for you
      const arena = init.arena;        // *std.heap.ArenaAllocator, process-lifetime
      const env = init.environ_map;    // *std.process.Environ.Map
      var it = init.minimal.args.iterate(); // Args iterator; first item is exe name
  }
  ```
  **Consequence:** for the default runtime you do **not** construct `std.Io.Threaded` yourself —
  `init.io` already is one. (Build your own only to override `async_limit` etc.)
- **`std.process.getEnvVarOwned` is GONE.** Read env vars from the map: `env.get("KEY") ?[]const u8`
  (borrows for process lifetime; no free). `Environ.Map` also has `.contains`. `Map.get` asserts the
  key is valid (no `=`/NUL). In tests, build one with `std.process.Environ.Map.init(alloc)` + `.put`.

## 3. `std.http.Client` (`std/http/Client.zig`)

- **It's a plain struct**, not an `init()` — construct with a literal:
  `var c: std.http.Client = .{ .allocator = gpa, .io = io };` then `defer c.deinit()`.
- **Request API:** `client.request(method: http.Method, uri: Uri, options: RequestOptions) !Request`
  (line 1681). Convenience: `client.fetch(FetchOptions) !FetchResult` (line 1801).
- **`fetch` returns only `{ status: http.Status }`** — the body is *not* returned. To capture it,
  pass `.response_writer = &aw.writer` where `aw` is a `std.Io.Writer.Allocating` (`.init(alloc)`,
  then `aw.toOwnedSlice()` / `aw.written()`). Set `.method`, `.payload`, `.extra_headers`
  (`[]const http.Header`), and `.location = .{ .url = "…" }`. Classify with `status.class()` →
  `enum { informational, success, redirect, client_error, server_error }`.
- **`initDefaultProxies(&client, arena, environ_map)`** takes the `*const Environ.Map` directly —
  pairs cleanly with `init.environ_map`.
- **TLS** is built in (own `ca_bundle`); no external OpenSSL needed.
- **Proxy support** (see also `docs/adr/0003`):
  - Fields `http_proxy: ?*Proxy` / `https_proxy: ?*Proxy`.
  - `initDefaultProxies(arena, environ_map)` auto-reads `http_proxy`/`HTTP_PROXY`/`all_proxy`/
    `ALL_PROXY` and the `https_*` equivalents (line ~1318).
  - `Proxy = struct { protocol, host: HostName, authorization: ?[]const u8, port: u16, supports_connect: bool }`
    — so **CONNECT tunneling** and **Basic-auth proxies** are supported.
  - **Not supported:** `NO_PROXY`/`no_proxy` exclusion lists; NTLM/Kerberos proxy auth;
    TLS-intercepting proxies (would need the corporate root added to `ca_bundle`).
- We wrap all of this behind our `HttpClient` seam so callers never see the std shape.

## 4. Allocators — arenas & the vtable idiom

- **`std.mem.Allocator`** is itself a `ptr + vtable` type-erased interface. This is the exact
  pattern our seams (`HttpClient`, `PendingReviewStore`, `Highlighter`) copy — idiomatic, not a hack.
- **`std.heap.ArenaAllocator`** (`std/heap/ArenaAllocator.zig`):
  - `init(child_allocator)`; `allocator()` returns the `Allocator` interface.
  - `reset(mode: ResetMode) bool` where `ResetMode = union(enum){ free_all, retain_capacity, /* shrink-to-N */ }`.
  - **`reset(.retain_capacity)`** keeps the backing pages — this is what makes our
    buffer-scoped arena cheap to reuse on file switch (§11 of the design doc).
- **`std.heap.GeneralPurposeAllocator`** (or `c_allocator` when we link C) backs the global tier
  and provides leak detection in debug builds.

## 5. Build system (`build.zig` / `build.zig.zon`)

- `b.standardTargetOptions(.{})` / `b.standardOptimizeOption(.{})`.
- Modules: `b.addModule` / `b.createModule(.{ .root_source_file, .imports })`;
  wire deps with `mod.addImport("vaxis", dep.module("vaxis"))`.
- Dependencies declared in `build.zig.zon` with `url` + `hash`; consumed via
  `b.dependency(name, .{})` or `b.lazyDependency(name, .{})` (libvaxis uses lazy deps).
- `minimum_zig_version` in `build.zig.zon` guards the toolchain.
- Pin exact dependency commits (libvaxis `main`, zf) — no floating refs.
- **A source file may belong to only one module.** If a file in the exe module (`root`)
  `@import`s a file that the `bbr` module already owns (e.g. `../http/fake_client.zig`), the
  compiler errors `file exists in modules 'bbr' and 'root'`. Reach shared decls **through the
  module's public API** (`bbr.http.Canned`), never by direct path. This bites most often in
  cross-module *test* code pulling a fixture/helper from the library.

## 6. Testing

- `test "name" { ... }` blocks compiled and run by `zig build test`; `std.testing`
  (`expect`, `expectEqual`, `expectEqualStrings`, `expectError`).
- `std.testing.allocator` detects leaks per test — pair every `alloc` with `defer free`.
- Our TDD relies on the seams' **fakes** (FakeHttpClient, in-memory store, plain highlighter)
  so domain tests need no network, disk, or C toolchain.
- **You can't cleanly read env vars inside a `test` block in 0.16.** The env API flows through
  `Init`/`Io`, and the test runner hands tests neither; `Environ.Block.global` exists only on
  wasi/freestanding, not posix. So keep `test` blocks **hermetic** (fakes + `@embedFile` fixtures)
  and put anything that needs real credentials in an executable step instead (bbr uses
  `zig build check`, which reads `Init.environ_map` in `main`).
- **Test discovery follows `_ = @import(...)` chains from the test-root file's own `test` blocks —
  NOT normal references.** `zig build test` on a module compiles code reachable from the root, but
  only *runs* `test` blocks in files reached by a chain of `test { _ = @import("child.zig"); }`
  starting in the root file. **Merely `@import`ing a file and calling its functions pulls its code
  but silently drops its tests.** bbr's exe root is `src/main.zig`; it calls `app.run` but that did
  **not** run any `src/tui/*` tests until `main.zig` gained `test { _ = @import("tui/app.zig"); }`
  (which then chains to render/theme/nav). This silently hid a real rendering bug — always confirm
  the per-step test **count** goes up (`--summary all`), not just that the suite is green.
- **A replaying fake + a client that follows `next` links = infinite loop.** `FakeHttpClient`
  returns the *same* body on every `send` unless given a scripted `responses` sequence. If that
  body carries a pagination `next` URL, a client that loops until `next` is absent never
  terminates — it re-fetches the same page forever. The hang shows up as a `zig build test` that
  never returns; `ps` reveals the `.../test --listen=-` **binary** (not the compiler) stuck for
  minutes. Fix the *fixture*: either drive pages with a `responses` sequence (last page has no
  `next`) or use a single-page body with no `next`. When a `zig build test` hangs, run
  `zig test src/root.zig` directly under a `sleep N; kill` guard — it prints `N/M name...` live so
  you see exactly which test wedged, without the build system's `--listen` protocol in the way.
- **Never `pkill -9` a running `zig build`** — it can orphan the cache manager mid-write and leave
  later builds blocking on the lock. Prefer letting it finish or time out; if you must kill, target
  the specific PIDs and verify the cache still builds afterward.

## 7. libvaxis (TUI) — 0.16 integration facts

**Verified by building bbr's M0** against pinned commit `ca781b3` (`vaxis-0.6.0`).

- **`vaxis.init(io, alloc, env_map, opts)`** takes the runtime `Io` and a `*std.process.Environ.Map`
  — pass `init.io` and `init.environ_map` straight through. `opts` is `.{}` for defaults.
- **Everything writes to a `*std.Io.Writer`.** Get it from the tty:
  `var tty = try vaxis.Tty.init(io, &buf); const w = tty.writer();` (a `[]u8` write buffer you own).
  `vx.deinit(alloc, w)`, `enterAltScreen(w)`, `render(w)`, `resize(alloc, w, ws)` all take it.
- **Event loop:** `var loop: vaxis.Loop(vaxis.Event) = .init(io, &tty, &vx); try loop.start();`
  then `loop.nextEvent()`. Using `vaxis.Event` as the loop's type guarantees every field the loop
  posts unconditionally (`focus_in`, `mouse`, …) exists. A custom event union must be a **superset**
  of `vaxis.Event`'s field names.
- **Keys:** `key.matches('q', .{})`, `key.matches('c', .{ .ctrl = true })`.
- **Cells borrow text.** `Cell.Character.grapheme` is `[]const u8`; text handed to `printSegment`
  must stay valid until `render()`. Keep per-line buffers in scope across the whole draw+render, or
  reuse one buffer and you'll corrupt earlier cells.
- Module wiring: `b.dependency("vaxis", .{...}).module("vaxis")`; the core `bbr` module stays
  vaxis-free so its tests need no TUI.
- **Headless rendering for tests (no tty):** `vaxis.Screen.init(alloc, .{ .rows, .cols, .x_pixel,
  .y_pixel })` allocates a cell buffer; build a detached root `vaxis.Window` literal over it
  (`.{ .x_off=0, .y_off=0, .parent_x_off=0, .parent_y_off=0, .width=screen.width,
  .height=screen.height, .screen=&screen }`) — the same shape `Vaxis.window()` returns. Draw with
  `printSegment`/`writeCell`/`fill`, then assert with `win.readCell(col, row) ?Cell` (inspect
  `.style.bg`/`.fg`, `.char.grapheme`). `Window.print` uses only free functions (grapheme iterator +
  `wcwidth` table), so no `Vaxis.init` is needed. This is how M2 asserts diff band colors hermetically.
- **`vaxis.Cell.Color.rgbFromUint(0xRRGGBB)`** builds an rgb `Color`; `Color` is a
  `union(enum){ default, index: u8, rgb: [3]u8 }`, so `std.meta.eql` / `== .default` compare cleanly
  in assertions. Cell text passed to `printSegment` is borrowed until `render`, so per-frame synthesized
  text (line-number gutter) must come from an arena that outlives the render/readCell — reset it *after*.

---

## Re-verification checklist (on any Zig upgrade)
- [ ] `std.process.Init` shape (`gpa`/`arena`/`io`/`environ_map`/`minimal.args`) unchanged?
- [ ] `Environ.Map.get`/`.put` and `main(init)` entry still the way to read env?
- [ ] `std.http.Client` still a plain struct; `fetch` still body-via-`response_writer`?
- [ ] `std.Io.Writer.Allocating` (`init`/`toOwnedSlice`/`written`) unchanged?
- [ ] `std.http.Client.request` / `fetch` signatures unchanged?
- [ ] `initDefaultProxies` + `Proxy` struct shape unchanged?
- [ ] `std.Io.Threaded.init` options (esp. `async_limit`) unchanged?
- [ ] `ArenaAllocator.ResetMode` variants unchanged?
- [ ] `std.Io.Reader`/`Writer` method surface we use unchanged?
- [ ] libvaxis still builds against the new toolchain; re-pin its commit.
