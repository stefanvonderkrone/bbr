# Correct the cache budget test comment

Status: needs-triage
Blocked by: none

## Problem

The test "M21 kernel Review Search source scans over the cache budget share their cache updates" in `src/tui/presentation.zig` has this comment:

```zig
// Each File holds about 1.2 MiB. The floor is between three and four
// Files, and an eighth of the Files is five.
```

Commit `3ae9b944` removed the File-count condition from `Storage.cachePressure` in `src/tui/file_enrichment.zig`. The far-over-budget limit now depends only on the budget and on `far_over_budget_floor`. So "an eighth of the Files" names a condition that no longer exists.

The `ocr-review` control review of `3ae9b944` found this comment. Ticket [02 of the Open Code Review evaluation](../../open-code-review/issues/02-evaluate-the-review-rules-on-ten-bug-fixes.md) records the run.

## Proposal

Rewrite the comment so that it explains the file count through the current limit, or delete the part about an eighth of the Files.

## Acceptance criteria

- [ ] The comment names no File-count condition.
- [ ] `zig build test` passes.
