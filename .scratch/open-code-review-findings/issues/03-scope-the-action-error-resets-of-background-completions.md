# Scope the action error resets of background completions

Status: needs-triage
Blocked by: none

## Problem

A completion of background work can clear an action error that the user has not read yet, such as `picker_load_failed`. Commit `e60b43c0` fixed this for File Enrichment builds. Ticket [02](02-keep-a-picker-error-through-a-cache-update.md) fixed it for cache updates and for the focus check that starts a File Enrichment.

An audit of the `self.action_error = null` sites in `src/tui/presentation.zig` found more completions that clear every action error. The audit read the code and ran no tests:

- The Submission completions: `post_draft_completed`, `recovery_checked`, `duplicate_checked`, and `submission_wait_completed`. A Submission runs for a long time, and the user can work while it runs. Each posted Draft clears the shown error.
- The comment edit, comment delete, and reviewer verdict completions.
- `session_prepared`, which also runs for the reconciliation after a comment edit, a delete, a verdict, or a Submission.
- `clipboard_completed` and a successful `pull_requests_loaded`. The audit marked these as guesses.

The audit also found background completions that overwrite an unread error with a new error. That is a separate class.

## Proposal

- For each completion, write a test that shows an unrelated error, completes the work, and expects the error to stay.
- Decide for each completion which errors its path can set, and clear only those. The File Enrichment path names its errors in `setByFileEnrichment`.
- When the decision is the same for all completions, move it into one structure that a new completion must use. Then move the `CODING_STANDARDS.md` section into the rule in `docs/rules/tui-state.md`.

## Acceptance criteria

- [ ] Each completion in the list has a test that decides whether it clears an unrelated action error.
- [ ] No completion of background work clears an error that its own path cannot set.
- [ ] `zig build test` passes.
