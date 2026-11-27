# Keep the pending cache update in step with its queued build

Status: needs-triage
Blocked by: none

Source: [the query edit clear order ticket](../../query-edit-clear-order/issues/01-clear-before-the-maintenance-steps-of-a-query-edit.md), section "CodeRabbit round 2", item 2 and the follow-up list.

## Problem

After a fold toggle or some Buffer Search actions, the cache stays over its budget. Also the focused File gets no File Enrichment.
The user sees a File without syntax colors and without its enriched content.
The view recovers only when the focus changes, a search lease ends, or a new Session publishes.

## What is known about the cause

The evidence comes from a read of `src/tui/presentation.zig` on `main`. No test reproduces it yet.

1. `queueCacheBuild` queues a `.cache_update` build and sets `Published.pending_cache_update` to its request ID.
2. `queueAcceptedDisclosure` removes each queued `build_buffer_disclosure` command whose kind is not `.input`, `.view`, `.enrichment`, `.draft_save`, or `.draft_mutation`.
   So it also removes a queued `.cache_update` build.
   It does not set `pending_cache_update` to null.
3. Three paths set `pending_cache_update` to null.
   The first is the landing of a `.cache_update` build in `acceptViewBuild`.
   The second is `retryContentBuild`, when its requeue of a stale `.cache_update` build fails.
   The third is a new Session.
   The removed build never lands, so it reaches neither of the first two paths.
4. `ensureFocusedRange` returns early while `pending_cache_update` is not null.
   It stages a cache build again only when the focus differs from `pending_cache_focus`.
   So with the same focus, it stages nothing, calls no `focusAdmitted`, and queues no File Enrichment of the active File.
5. `stageReleasedSearchLeases` stages a cache build when `pending_cache_update` is not null.
   So the end of a search lease also recovers.

`discardQueuedBufferSearchScans` keeps `.cache_update` builds in its list of kinds.
`queueAcceptedDisclosure` has a different list, so the two lists diverge.
These functions call `queueAcceptedDisclosure`:

- `cancelBufferSearch`
- `queueQueryClearDisclosure`
- `retryAcceptedDisclosure`
- `openBufferSearchOccurrence`
- `clearBufferSearchActive`
- `toggleDisclosure`, with a `.general` build

`toggleDisclosure` runs when the user opens or closes a fold, so the fault is not only a Buffer Search fault.

The fault is reachable only when a `.cache_update` build is still in the command queue at such a call.
The command queue issues one build at a time, so a running build keeps the next build queued.
Triage must confirm this order with a test.

The same filter also removes a queued `.review_destination` build and a queued `.card_destination` build.
`review_search.destination_pending` and `pending_card_destination` then stay set.
Nobody traced whether an input can reach that state.

## Proposal

Give each kind of a queued build one owner for its removal and its pending marker.
One option is a helper that removes a queued build and also resets the marker of its kind.
An exhaustive switch on `DisclosureBuild.Kind` in that helper makes a new kind fail to compile until it names its marker.
A smaller option is to keep `.cache_update` in the filter of `queueAcceptedDisclosure`, as `discardQueuedBufferSearchScans` does.
With that option, the queued build stays.
So `pending_cache_update` stays correct.
With the same focus, the next `ensureFocusedRange` then returns without new work.
That is correct, because the kept build does the work.
The `correct` skill prefers the first option, because it makes the divergence of the two lists impossible.

A correct fix leaves one of two states after the action:

- `pending_cache_update` holds a request ID.
  A `.cache_update` build with that `cache_request_id` is in the command queue.
  The smaller option keeps the old build and its request ID.
  A helper that removes the build and at once queues a new build through `queueCacheBuild` gives a new request ID.
- `pending_cache_update` is null.
  The helper option without a new build gives this state.
  Then the next `ensure_focused_enrichment` stages a cache build or queues a File Enrichment of the active File.

In each state, File Enrichment of the active File must start after the queued builds land. A stale build that queues again counts as queued until its retry lands.

Open question: does the removal of a `.review_destination` or `.card_destination` build stall its path too?

## Acceptance criteria

- [ ] A red test through `Presentation.dispatch`, "M21 kernel a disclosure build keeps the queued cache update of the focus check", fails on `main`.
  The test queues a cache update while another build runs.
  Then it runs an action that calls `queueAcceptedDisclosure`, such as a fold toggle.
  The test accepts each state of the proposal.
  After the action, `pending_cache_update` must be null, or a request ID that a queued `.cache_update` build carries.
  Then the test lands the queued builds and their retries.
  After that, `pending_cache_update` must be null.
  With the same focus, the test then sends `ensure_focused_enrichment` at most two times.
  After each input, it lands the builds that the input queues.
  One of these inputs must queue a File Enrichment of the active File.
- [ ] The test passes after the fix.
- [ ] The open question has an answer in this ticket, with a test for each kind that stalls.
- [ ] `zig build test` exits with 0.
