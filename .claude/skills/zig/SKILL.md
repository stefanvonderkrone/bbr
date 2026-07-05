---
name: zig
description: Working in Zig 0.16.0 without repeating known mistakes. Use when writing, reviewing, or reasoning about Zig code, build.zig(.zon), stdlib APIs (std.Io, std.http, allocators), or when tempted to recall a Zig API from memory.
---

# Zig 0.16.0

Zig's stdlib churns hard between minor versions. Training-time knowledge of Zig is **stale and
untrustworthy**. This skill is the discipline and the accumulated corrections that keep Zig work
from repeating past mistakes. The version-pinned API catalog bbr relies on lives in
[`ZIG.md`](../../../ZIG.md) at the repo root — this skill is the *process*; that file is the *facts*.

## The one rule that prevents most mistakes

**Never assert a Zig stdlib API from memory. Read it from the installed stdlib source first.**

- stdlib root: `/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std` (confirm with `zig version` and
  `zig env`). When you claim a function signature, field, or type, cite it as `file:line` you
  actually opened — not what you remember the API to be.
- If you're about to write `std.something(...)` without having opened its source this session,
  stop and grep the stdlib. The API has probably changed.
- `zig build` / `zig build test` is the ground truth. A design that compiles in your head does
  not compile. Run it.

## Known corrections (mistakes already made — do not repeat)

- **`main` takes `std.process.Init`; env vars come from it, not `getEnvVarOwned`.** 0.16 removed
  `std.process.getEnvVarOwned`. Write `pub fn main(init: std.process.Init) !void` and the runtime
  hands you `init.gpa`, `init.arena`, `init.io`, `init.environ_map` (`*Environ.Map`, use
  `.get("KEY")`), and `init.minimal.args` (`.iterate()`). **`init.io` is already backed by
  `std.Io.Threaded`** — don't build your own for the default runtime.
- **`std.http.Client.fetch` returns only the status; the body is streamed to a writer.** Pass
  `.response_writer = &aw.writer` with `aw: std.Io.Writer.Allocating = .init(alloc)`, then
  `aw.toOwnedSlice()`. The client is a plain struct: `.{ .allocator = gpa, .io = io }`. Classify
  with `status.class()`.
- **`std.ArrayList(T)` is the UNMANAGED list; its methods take `gpa`.** Confirmed in the installed
  stdlib: `std.zig:49` defines `ArrayList(T) = array_list.Aligned(T, null)`, and `Aligned`
  (`array_list.zig:570`) is the unmanaged struct. So: init `var list: std.ArrayList(T) = .empty;`
  (default `.{}` deprecated), then `list.append(gpa, item)`, `list.deinit(gpa)`,
  `list.toOwnedSlice(gpa)`. The managed variant with `gpa`-free methods is `array_list.Managed(T)`;
  `ArrayListUnmanaged` is now a deprecated alias *to* `ArrayList`.
- **You can't read env vars inside a `test` block.** The env API flows through `Init`/`Io` and the
  test runner hands tests neither (`Environ.Block.global` is wasi/freestanding-only). Keep tests
  hermetic (fakes + `@embedFile` fixtures); put credential/network work in an executable step that
  reads `Init.environ_map` in `main`.
- **Concurrency is `std.Io` / `std.Io.Threaded`, NOT `std.Thread.Pool`.** 0.16 centralizes I/O and
  concurrency behind the `std.Io` interface. `std.http.Client` has an `io: Io` field and *requires*
  an `Io`, so you do not hand-roll a thread pool for network work. Build one `std.Io.Threaded`
  runtime; spawn via its `Io` vtable (`async`/`concurrent`/`groupAsync`). (Originally proposed a
  `Thread.Pool` — wrong.)
- **Writergate: `std.Io.Reader` / `std.Io.Writer` are non-generic, vtable-based, and carry their
  own buffer.** The old generic `std.io.Reader`/`Writer` are gone. You hand the interface a `[]u8`;
  formatting goes through `writer.print(...)`. Take `*std.Io.Reader`, not a concrete stream type.
- **`ArenaAllocator.reset` takes a `ResetMode` union**, not a bool:
  `union(enum){ free_all, retain_capacity, /* shrink-to-N */ }`. `reset(.retain_capacity)` keeps
  backing pages — the cheap-reuse path for buffer-scoped arenas.

## Idioms that are correct here (not hacks)

- **The `ptr + *const VTable` type-erased interface is idiomatic Zig** — it's exactly how
  `std.mem.Allocator`, `std.Io`, and `std.Io.Reader/Writer` are built. bbr's seams (`HttpClient`,
  `PendingReviewStore`, `Highlighter`) copy this pattern deliberately.
- **`std.testing.allocator` detects leaks per test** — pair every `alloc` with `defer free`, and
  lean on it: domain tests use the seams' fakes so they need no network, disk, or C toolchain.
- **Pin exact dependency commits in `build.zig.zon`** (`url` + `hash`, `minimum_zig_version`).
  libvaxis uses lazy deps (`b.lazyDependency`). No floating refs.

## Keep this skill and ZIG.md current

When a Zig mistake, surprise, or newly-verified API fact surfaces during work:
1. If it's a version-pinned API fact bbr depends on → add/update the relevant section in
   [`ZIG.md`](../../../ZIG.md) and its re-verification checklist.
2. If it's a recurring mistake or a durable "do it this way" lesson → add a bullet under **Known
   corrections** or **Idioms** here, phrased as the rule to follow next time.

Both files assume the installed toolchain. On a Zig upgrade, re-verify every API fact against the
new stdlib (ZIG.md has the checklist) before trusting anything below.
