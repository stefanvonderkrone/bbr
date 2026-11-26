# Record a failed File Enrichment queue in the Review Search acquisition

Status: resolved
Blocked by: none

Source: [ticket 01](01-keep-the-session-after-a-failed-focus-check-staging.md).

## Problem

`pumpReviewSearchAcquisition` in `src/tui/presentation.zig` queues the File Enrichment of the Files that an open Review Search must read. It catches a failed `queueFileEnrichment` in two places. Each catch sets `action_error` to `out_of_memory` and writes no record. So the failure has no record, and it replaces a message that shows, such as `file_enrichment_launch_failed` from the completion that started the pump.

The acquisition is maintenance. The File stays pending and unacquired, so a later pump queues it again. Ticket 01 states the rule for the focus check: a failed queue or staging of maintenance work has exactly one record and never overwrites or clears another message. The acquisition must follow the same rule.

A successful queue in the pump also ends with `self.action_error = null`, so it clears the message of the completion that started the pump. This is the case of [ticket 02](02-keep-the-shown-message-after-a-focus-check-file-enrichment.md) at a second site.

## Proposal

Queue the File Enrichment of maintenance work through one helper for the focus check and the acquisition. The helper records a failure once as `.file_enrichment`, `.prepare`, shows `out_of_memory` only when no message shows, and keeps the shown message after a success. The cache staging and the File Enrichment helper share the record handler, so the rule is in one place. Search for other sites of the same class and list them.

## Acceptance criteria

- [x] A test through the Presentation interface fails the acquisition queue after a `file_enrichment_launch_failed` completion. It expects one `report_diagnostic` record and the `file_enrichment_launch_failed` message. The test fails before the fix.
- [x] A test through the Presentation interface expects the `file_enrichment_launch_failed` message to stay after a successful acquisition queue. The test fails before the fix.
- [x] The rule is stated once in `CODING_STANDARDS.md` or `docs/rules/`.
- [x] Other sites of the class are fixed here or listed in a comment.
- [x] `zig build test` exits 0, `zig fmt --check src build.zig tests` passes, and `python3 tools/check_agent_docs.py` passes.

## Comments

### 2026-11-21 other sites

A search for `action_error = .out_of_memory` in `src/tui/presentation.zig` found 74 sites without a record next to them. Most are the outcome of an input that the user gave, so they are not maintenance work. This change fixes one more site, because the fix is the same few lines:

- `retryReviewSearchQuery`. A failed retry kept the `out_of_memory` message of `replaceReviewSearchQuery`, so it replaced a message of an earlier input of the same event. The retry now restores a shown message after a failure too. The failure already had one record. The red test is "M21 kernel Review Search keeps another message of the same event when a reopened query retry fails". It failed with `expected .buffer_search_invalid_query, found .out_of_memory`.

These sites stay open. Each needs a decision or a repro that costs more than a few lines:

- `retryContentBuild`, `.cache_update`. A stale cache update that cannot stage again sets `pending_cache_update` to null, shows `out_of_memory` over any message, and writes no record. The focus check stages again, so it is maintenance work. A test that makes the cache update stale through a `resize` did not reach this path, because the completion took another branch and cleared `action_error`. A repro needs a stale cache update that reaches the retry.
- The success of a cache update commit in `acceptBufferDisclosure` sets `action_error` to null. That completion is maintenance work too, so it can clear a message of an earlier input.
- `queueFileEnrichment` shows `action_refused` when a path or a commit is too long. For maintenance work this replaces a shown message after each event, because the File stays pending. It is a refusal, not a failure, so this change keeps it.
- `retryViewBuild`, `retryAcceptedDisclosure`, `retryStaleBufferDisclosure`, `republishPostedParent`, and `dropEnrichments` show `out_of_memory` without a record. They drop the pending work of a user input, so no later check does it again. They are not maintenance work by the rule. Whether each failure needs a record is a separate question.
- `openReviewSearch` pumps the acquisition and then sets `action_error` to null. A failed pump at the open now writes its record, but the open clears its `out_of_memory` message. This clear is older than this change.
- `openReviewSearchOccurrence` asks the acquisition to queue the File of a pending source. Before this change, that queue cleared an earlier message. Now the earlier message stays until the next input clears it. No test reads this case.

### 2026-11-21 follow-up of the open sites

- `openReviewSearchOccurrence`. The operator decided that opening a hit is a user action, so it clears an older message. The action now clears the message before it pumps the acquisition for a hit in an evicted File. Red test: "M21 kernel opening a Review Search hit in an evicted File clears an older message" failed with `expected null, found .buffer_search_invalid_query`. Commits `0048eb56` and `fc7a0c37`.
- `retryContentBuild`, `.cache_update`. A test reaches it: a File hold changes the cache revision after the worker built the update, so the completion retries it. The retry now fails through `failMaintenance`. Red test: "M21 kernel stale cache update retry failure records once and keeps the shown message" failed with `TestExpectedRecord`. Commits `ec6c30cc` and `49a9df59`.
- The cache update commit in `acceptBufferDisclosure` no longer clears the shown message. Red test: "M21 kernel cache update commit keeps the shown message" failed with `expected .action_refused, found null`. Same commits. The 2026-11-23 merge of main drops this change and the test. On main a cache update commit clears only an error of the File Enrichment path. "Review recovery Picker error survives a completed cache update" checks the same keep, and "Review recovery a completed cache update clears a failed build of its own path" checks the clear.
- The five retries of a user input record each failure once. [Ticket 04](04-record-a-failed-retry-of-a-user-input.md) has the evidence.
- These sites stay open: `queueFileEnrichment` shows `action_refused` for maintenance work, and `openReviewSearch` clears the `out_of_memory` message of a failed pump at the open. The `.draft_save` and `.draft_mutation` retries in `retryContentBuild` show `out_of_memory` without a record, as the retries of ticket 04 did.

## Completion

2026-11-21, branch `focus-check-staging-failure`.

- `pumpReviewSearchAcquisition` queues through `queueMaintenanceFileEnrichment` at both sites. A failure records once as `.file_enrichment`, `.prepare`, shows `out_of_memory` only when no message shows, and stops the pump. A success keeps the shown message.
- `failMaintenance` writes the record and the message of a failure. `stageCacheBuild` and `queueMaintenanceFileEnrichment` call it, so the handler is in one place. `tools/check_diagnostics.py` accepts it, because each catch uses its capture and returns a literal or nothing after the record.
- `retryReviewSearchQuery` keeps a shown message after a failed retry.
- `CODING_STANDARDS.md` states the rule once in "Maintenance work keeps the shown message", and it lists the sites.
- Red proof: "M21 kernel Review Search acquisition queue keeps the shown message" failed with `expected .file_enrichment_launch_failed, found null`. "M21 kernel Review Search acquisition queue failure records once and keeps the shown message" failed with `expected .file_enrichment_launch_failed, found .out_of_memory`. Both pass now.
- Commits: `5be3dd40` (red tests), `f8e47310` (fix), `73e89eea` (red retry test), `344546c6` (retry fix), and the standard commit after them.
- Checks: `zig build test` exit 0, `zig fmt --check src build.zig tests` exit 0, `python3 tools/check_diagnostics.py` exit 0, `python3 tools/check_agent_docs.py` exit 0.

### 2026-11-21 review

The Standards and Spec reviews found no hard violation and no missing criterion. The review commit fixes the standard: a cache staging writes no message when it succeeds, and the query retry records through `replaceReviewSearchQuery`, not `failMaintenance`. Maintenance work is now a term in `src/tui/GLOSSARY.md`. Three judgement calls stay open. The restore of the shown message has two forms, in `retryReviewSearchQuery` and `queueMaintenanceFileEnrichment`, because they read different pending signals. A success clears every `out_of_memory` message, also one that a user input showed earlier in the same event, as in PR #36. The tests drive `dispatch`, `takeCommand`, and `projection`, but they also drop the command capacity, so that the queue allocates, as earlier tests do.
