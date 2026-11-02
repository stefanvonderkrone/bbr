# 15: Decide lazy preparation of BuiltInGrammar queries

Status: resolved
Blocked by: none
Spec: [M27 spec](../SPEC.md)

## Problem

M27 makes bbr larger and makes it start later.
The review of 2026-10-31 records these costs as finding M27-5.
The SPEC puts lazy query preparation out of scope, so the operator must decide.
The agent that fixed the review findings did not change this behavior.

## Measured costs

The values come from [binary-size.md](../binary-size.md), measured by ticket 12 on an Apple M5 Pro.

| Value | Before M27 | After M27 |
| --- | --- | --- |
| `zig-out/bin/bbr`, ReleaseSafe | 12,980,144 bytes (13 MB) | 57,526,080 bytes (57.5 MB) |
| `zig-out/bin/bbr`, Debug | 38,096,224 bytes | 87,445,520 bytes |
| `vendors/` in the source tree | not measured | 277 MB |
| `TreeSitterHighlighter.init`, ReleaseSafe, median | 28.3 ms | 422.2 ms |
| Clean ReleaseSafe build, wall time, median of 3 | 64.45 s | 66.90 s |

- `src/main.zig` calls `TreeSitterHighlighter.init` before `app.run`.
- So every TUI start waits about 0.39 s more before the first frame.
- Reviewer B measured 450 ms for `init` in a ReleaseSafe test.
- `ts_query_new` in the tree-sitter runtime uses almost all of the `init` time.
- C++, Swift, and C# use 48% of the time.
- The M27 tests also pay this cost. `zig build test-builtin-grammars` runs about 115 s on one core in Debug.
  Most of its tests call `TreeSitterHighlighter.init`. This cause is an inference.

## Options

1. Keep the current behavior. Every start prepares all 29 queries. This option needs no change.
2. Prepare each Grammar on first use. Use one flag for each Grammar, guarded for the highlight workers.
   Keep one test that prepares every query, so CI still finds an invalid query.
   The first highlight of each new Grammar then waits up to 80 ms (C++).
3. Prepare all queries on a background thread after the first frame.
   A highlight request waits until its Grammar is ready.
4. Drop or replace the slowest Grammars. This option changes the M27 brief.

Option 2 changes the AGENTS.md row "Every BuiltInGrammar loads its highlight query and its injection query at startup".
It also changes the SPEC "Out of Scope" list.
The binary size and the `vendors/` size do not change with options 1 to 3.

## Comments

The agent recommends no option, because the decision changes the approved SPEC.
The review named no cheap fix for `init` time that keeps every design decision.

On 2026-11-02, the operator chose lazy loading.
The agent takes option 2 because it is the lazy option that this ticket describes.
Option 3 also defers the work, but it still prepares every query in each session.
So the triage state went from `needs-triage` to `ready-for-agent`, and the agent claimed the ticket.
Option 2 does not change the binary size or the `vendors/` size, so these costs stay open.

## Completion

The agent implemented option 2 on 2026-11-02.

- `TreeSitterHighlighter.init` takes an `Io` and prepares no query.
- `BuiltInPackages.get` prepares a BuiltInGrammar on its first use, as a host or as an Injection.
  One `std.Io.Mutex` guards the slots, because highlight workers share them.
- A failed preparation returns its error for that highlight and keeps no entry.
  The next use tries again. The caller's failure path for a highlight error does not change.
- An invalid query reports its diagnostic and fails the highlight, as the UserGrammar load does.
  Before this change, it stopped bbr at startup.
- The test "M27 grammar every BuiltInGrammar loads its queries" prepares every query, so CI still finds an invalid query.

New tests in `src/highlight/tree_sitter_highlighter.zig`:

- "M27 lazy init prepares no BuiltInGrammar query" failed on the old code with `error.OutOfMemory`.
- "M27 lazy every BuiltInGrammar fixture highlights as after eager preparation" compares every fixture with eager preparation.
  It also checks that the fixtures use all 29 BuiltInGrammars.
- "M27 lazy a failed preparation fails only that highlight and the next use succeeds" fails each allocation of the HTML preparation in turn.
- "M27 lazy concurrent first uses of one BuiltInGrammar give the eager output" runs 4 concurrent first uses of C++.

`tools/check_guard_mutations.py` has the new mutations `m27-lazy-reuse` and `m27-lazy-init`. Both are caught.
No mutation covers the mutex, because a test cannot detect a data race in a deterministic way.

Measurements are in [binary-size.md](../binary-size.md#lazy-preparation-ticket-15).
`init` went from 423 ms to below 1 µs in ReleaseSafe.
The first use of C++ now takes 87 ms, and the first use of Swift or C# takes 64 ms.

Still open:

- The binary size (57.5 MB in ReleaseSafe) and the `vendors/` size (277 MB). Option 2 does not change them.
- An invalid-query diagnostic during the TUI goes to `std.log`, as for a UserGrammar. Only a broken build can show it, because CI prepares every query.

Checks:

- `zig build test --summary all`: 32/32 steps, 1515/1515 tests passed.
- `zig build test-builtin-grammars`: 99/99 tests passed in about 31 s. It took 126 s before.
- `zig fmt --check build.zig src tests`: exit code 0.
- `python3 tools/check_agent_docs.py`: pass.
- `python3 tools/check_guard_mutations.py`: 10 mutations caught, baseline passes.
