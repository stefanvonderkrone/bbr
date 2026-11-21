# Record a failed retry of a user input once

Status: resolved
Blocked by: none

Source: [ticket 03](03-record-a-failed-review-search-acquisition-queue.md), its comment lists these sites.

## Problem

A completion that finds its build stale queues the build again. When that retry cannot allocate, these sites drop the pending work, show `out_of_memory`, and write no record:

- `retryViewBuild`, which queues a view build again.
- `retryAcceptedDisclosure`, which queues a Buffer Search opening or an accepted disclosure again.
- `retryStaleBufferDisclosure`, which queues a Buffer Search scan again.
- `republishPostedParent`, which rebuilds the disclosure inputs and queues a view build after a Reply parent posts.
- `dropEnrichments`, which drops the results of an enrichment build that cannot queue. One of its three callers records the failure, and two do not.

The dropped work belongs to a user input, so no later check does it again. So these sites are not maintenance work. But each failure needs exactly one record, by [A failure has one record](../../../docs/rules/diagnostics.md#a-failure-has-one-record) and [ADR-0014](../../../docs/adr/0014-a-failure-is-recorded-once-and-error-reported-marks-it.md).

## Proposal

Give each failure one record through one helper beside `failMaintenance`. The failure of a user input is the outcome of that input, so the helper shows `out_of_memory` also when another message shows. `dropEnrichments` keeps its message rule, because a speculative result is not a user input. It records the failure itself, and its caller that records today stops.

## Acceptance criteria

- [x] A test through the Presentation interface fails each retry site and expects exactly one `report_diagnostic` record and the `out_of_memory` message. Each test fails before the fix.
- [x] Each failure at the five sites has exactly one record.
- [x] The rule is stated once in `CODING_STANDARDS.md` or `docs/rules/`.
- [x] `zig build test` exits 0, `zig fmt --check src build.zig tests` passes, and `python3 tools/check_agent_docs.py` passes.

## Comments

### 2026-11-21 sites with no injected failure

`search.Query.init` in `retryStaleBufferDisclosure` and `DisclosureInputs.create` in `republishPostedParent` allocate from `std.heap.page_allocator`, so no test fails them. Their `OutOfMemory` prongs call `failDroppedInput` too.

The `.draft_save` and `.draft_mutation` retries in `retryContentBuild` show `out_of_memory` without a record in the same way. This ticket does not change them.

## Completion

2026-11-21, branch `focus-check-staging-failure`.

- `failDroppedInput` records the cause once as `.completion`, `.admission` and shows `out_of_memory`. `retryViewBuild`, `retryAcceptedDisclosure`, `retryStaleBufferDisclosure`, and `republishPostedParent` call it.
- `dropEnrichments` records each failure itself, and the caller in `queueEnrichments` that recorded before it no longer does. A speculative result still keeps the shown message.
- The message rule: the failure of a user input is the outcome of that input, so it replaces another message. `CODING_STANDARDS.md` states it once in "A dropped user input shows its failure".
- Red proof: seven tests failed with `TestExpectedRecord`. They are the "M21 kernel failed ... records the dropped input once" tests for the view retry, the accepted disclosure retry, the Buffer Search opening retry, the stale Buffer Search retry, and the posted parent rebuild, and the "M21 kernel failed enrichment snapshot/merge records its dropped results once" tests. "M21 kernel failed enrichment queue records its dropped results once" passed before the fix, because that caller already recorded. All pass now.
- Commits: `79909151` (red tests) and `468d0ef4` (fix).
- Checks: `zig build test` exit 0, `zig fmt --check src build.zig tests` exit 0, `python3 tools/check_diagnostics.py` exit 0, `python3 tools/check_agent_docs.py` exit 0.
