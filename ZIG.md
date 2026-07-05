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

## 3. `std.http.Client` (`std/http/Client.zig`)

- Constructed with an allocator and an `Io`; `io: Io` field at line 30.
- **Request API:** `client.request(method: http.Method, uri: Uri, options: RequestOptions) !Request`
  (line 1681). Convenience: `client.fetch(FetchOptions) !FetchResult` (line 1801).
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

## 6. Testing

- `test "name" { ... }` blocks compiled and run by `zig build test`; `std.testing`
  (`expect`, `expectEqual`, `expectEqualStrings`, `expectError`).
- `std.testing.allocator` detects leaks per test — pair every `alloc` with `defer free`.
- Our TDD relies on the seams' **fakes** (FakeHttpClient, in-memory store, plain highlighter)
  so domain tests need no network, disk, or C toolchain.

---

## Re-verification checklist (on any Zig upgrade)
- [ ] `std.http.Client.request` / `fetch` signatures unchanged?
- [ ] `initDefaultProxies` + `Proxy` struct shape unchanged?
- [ ] `std.Io.Threaded.init` options (esp. `async_limit`) unchanged?
- [ ] `ArenaAllocator.ResetMode` variants unchanged?
- [ ] `std.Io.Reader`/`Writer` method surface we use unchanged?
- [ ] libvaxis still builds against the new toolchain; re-pin its commit.
