# Keep a Picker error through a cache update

Status: needs-triage
Blocked by: none

## Problem

Commit `e60b43c0` stopped a File Enrichment build from clearing an unrelated action error, such as an unread `picker_load_failed`. An enrichment build now clears only an error that `setByFileEnrichment` names.

The success path of a Buffer build in `src/tui/presentation.zig` still has this branch:

```zig
if (job.kind != .enrichment) {
    self.action_error = null;
} else if (!EnrichedFile.allSpeculative(job.enrichments.items)) {
```

A `.cache_update` build takes the first branch. A cache update also runs beside other work, because a lease release or a focus check queues it. So a cache update that completes while `picker_load_failed` shows can clear that message before the user reads it.

This finding is unverified. No test reproduces it. The `ocr-review` control review of `e60b43c0` reported it. Ticket [02 of the Open Code Review evaluation](../../open-code-review/issues/02-evaluate-the-review-rules-on-ten-bug-fixes.md) records the run.

## Proposal

- Write a test that shows `picker_load_failed`, completes a `.cache_update` build, and expects the message to stay.
- If the test fails, decide which build kinds the user starts and which run in the background. Only a build that the user starts can clear an unrelated action error.

## Acceptance criteria

- [ ] A test decides whether a completed cache update clears `picker_load_failed`.
- [ ] If the message is cleared, a background build no longer clears an unrelated action error, and the test passes.
- [ ] `zig build test` passes.
