# Record a failed File Enrichment queue in the Review Search acquisition

Status: claimed
Claimed by: /Volumes/Work/t3-code/focus-check-staging-failure
Blocked by: none

Source: [ticket 01](01-keep-the-session-after-a-failed-focus-check-staging.md).

## Problem

`pumpReviewSearchAcquisition` in `src/tui/presentation.zig` queues the File Enrichment of the Files that an open Review Search must read. It catches a failed `queueFileEnrichment` in two places. Each catch sets `action_error` to `out_of_memory` and writes no record. So the failure has no record, and it replaces a message that shows, such as `file_enrichment_launch_failed` from the completion that started the pump.

The acquisition is maintenance. The File stays pending and unacquired, so a later pump queues it again. Ticket 01 states the rule for the focus check: a failed queue or staging of maintenance work has exactly one record and never overwrites or clears another message. The acquisition must follow the same rule.

A successful queue in the pump also ends with `self.action_error = null`, so it clears the message of the completion that started the pump. This is the case of [ticket 02](02-keep-the-shown-message-after-a-focus-check-file-enrichment.md) at a second site.

## Proposal

Queue the File Enrichment of maintenance work through one helper for the focus check and the acquisition. The helper records a failure once as `.file_enrichment`, `.prepare`, shows `out_of_memory` only when no message shows, and keeps the shown message after a success. The cache staging and the File Enrichment helper share the record handler, so the rule is in one place. Search for other sites of the same class and list them.

## Acceptance criteria

- [ ] A test through the Presentation interface fails the acquisition queue after a `file_enrichment_launch_failed` completion. It expects one `report_diagnostic` record and the `file_enrichment_launch_failed` message. The test fails before the fix.
- [ ] A test through the Presentation interface expects the `file_enrichment_launch_failed` message to stay after a successful acquisition queue. The test fails before the fix.
- [ ] The rule is stated once in `CODING_STANDARDS.md` or `docs/rules/`.
- [ ] Other sites of the class are fixed here or listed in a comment.
- [ ] `zig build test` exits 0, `zig fmt --check src build.zig tests` passes, and `python3 tools/check_agent_docs.py` passes.
