# 02: Let a prepared Grammar highlight while another Grammar prepares

Status: needs-triage
Blocked by: none
Spec: [M33 brief](../brief.md)

## Problem

`BuiltInPackages` has one mutex for all BuiltInGrammars.
The first preparation of one Grammar holds that mutex.
Every other highlight waits for it, also a highlight with a Grammar that is already prepared.
Today the wait is the query preparation, up to about 80 ms for C++.
M33 makes the first use of a Grammar cost a download, a check, a load, and the query preparation.
With the current lock, one slow download stops highlighting of every language.

## Evidence

- One mutex guards all slots.
  `BuiltInPackages` has one `mutex` and an array of `slots` (`src/highlight/tree_sitter_highlighter.zig:42` to `:47`).
- `get` holds the mutex during the preparation.
  It calls `lockUncancelable`, defers the unlock, and calls `prepare` inside the lock (`src/highlight/tree_sitter_highlighter.zig:50` to `:56`).
  `prepare` calls `RuntimePackage.init`, which runs `ts_query_new` (`:66`).
  The M27 profile shows that `ts_query_new` uses almost all of that time (`.scratch/m27-zig-builtin-grammar/binary-size.md`, section on the `init` profile).
- A prepared Grammar takes the same lock.
  `get` locks before it reads the slot, so the fast path `if (slot.*) |*package| return package` also waits (`:51` to `:54`).
- Every highlight goes through `get`.
  `highlightBuiltIn` calls it for the File's Grammar (`:129`).
  `appendLayer` calls it for each injected Grammar during a highlight (`:350`).
- Several tasks highlight at once.
  The TUI runs `std.Io.Threaded` (`src/main.zig:2`), so tasks run on OS threads.
  Presentation queues up to 4 speculative File Enrichments (`max_speculative_enrichments`, `src/tui/presentation.zig:5739`) and the active File.
  Each File Enrichment starts two side tasks, one per side (`src/tui/file_enrichment.zig:270` and `:274`).
  So up to 10 side tasks can highlight at once.
  Code highlighting jobs use the same highlighter (`.highlight_code` in `src/tui/app.zig:1256`).
- The wait cannot be canceled.
  `lockUncancelable` ignores cancellation, so a task that waits for a download cannot stop when its File leaves the screen.

## Measurement

Measured on 2026-11-17 on an Apple M5 Pro, ReleaseFast, with a temporary `bbr-bench` case that is not committed.
Each run made 11 new `TreeSitterHighlighter` values and printed the medians. There were 3 runs.

| Value | Run 1 | Run 2 | Run 3 | Range of all samples |
| --- | --- | --- | --- | --- |
| First use of C++ (`a.cpp`, one line) | 78.5 ms | 78.2 ms | 78.1 ms | 77.2 to 94.9 ms |
| Highlight of a prepared Zig File, alone | 0.012 ms | 0.012 ms | 0.012 ms | 0.011 to 0.037 ms |
| Highlight of a prepared Zig File, started 5 ms after a C++ first use on another thread | 71.0 ms | 71.1 ms | 70.8 ms | 70.1 to 72.7 ms |

The Zig highlight waits about 6,000 times longer when a C++ preparation runs.
The wait is the C++ time minus the 5 ms delay and the thread start, so the mutex is the limit.
Without the mutex, the Zig highlight would take its 0.012 ms.
The case prepared Zig before each timed highlight, and the C++ preparation takes longer than 5 ms, so the timed highlight did not prepare a Grammar.
The fixtures are small, so the numbers show the lock, not the highlight cost of a real File.

## Proposed change

Give each slot its own once-state and keep the lookup of a prepared Grammar free of locks.

- Each slot has an atomic state: empty, preparing, or ready.
  A ready slot never changes or moves until `deinit`, as today.
- `get` reads the state with acquire order.
  A ready slot returns its package with no lock.
- An empty slot takes a lock of that slot only, checks the state again, prepares, and publishes `ready` with release order.
  A failed preparation leaves the slot empty, so the next use tries again, as M27 ticket 15 decided.
- Concurrent first uses of the same Grammar still wait for one preparation.
  First uses of different Grammars run in parallel.

A smaller change also works for today's code: a lock only for the slot lookup, with the preparation outside the lock.
But then two first uses of one Grammar prepare twice, and the second result must be freed.
For M33 that means two downloads of the same GrammarLibrary, so the per-slot once-state fits better.

## Open points for triage

- Ticket 01 decides where M33 waits for a GrammarLibrary.
  If the download runs inside `get`, the per-slot wait must be cancelable, or a canceled task holds its worker until the download ends.
  If a separate loader downloads and `get` only reads a ready GrammarLibrary, the wait in `get` stays at the query preparation.
- The rule table in `AGENTS.md` asks for a guard mutation entry for each guard that a ticket adds.
  A test that proves the change: a prepared Grammar highlights while the first preparation of another Grammar is blocked.
  The test needs a way to block one preparation, such as a test seam in `prepare`.
  The existing test "M27 lazy concurrent first uses of one BuiltInGrammar give the eager output" (`src/highlight/tree_sitter_highlighter.zig:1044`) must still pass.

## Comments
