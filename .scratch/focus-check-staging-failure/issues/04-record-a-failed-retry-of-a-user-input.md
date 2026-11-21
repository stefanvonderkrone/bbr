# Record a failed retry of a user input once

Status: ready-for-agent
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

- [ ] A test through the Presentation interface fails each retry site and expects exactly one `report_diagnostic` record and the `out_of_memory` message. Each test fails before the fix.
- [ ] Each failure at the five sites has exactly one record.
- [ ] The rule is stated once in `CODING_STANDARDS.md` or `docs/rules/`.
- [ ] `zig build test` exits 0, `zig fmt --check src build.zig tests` passes, and `python3 tools/check_agent_docs.py` passes.

## Comments
