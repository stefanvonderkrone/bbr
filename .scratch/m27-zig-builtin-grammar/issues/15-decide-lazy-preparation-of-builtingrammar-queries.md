# 15: Decide lazy preparation of BuiltInGrammar queries

Status: needs-triage
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
