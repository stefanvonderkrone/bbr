# Scope the action error resets of background completions

Status: resolved
Blocked by: none

## Problem

A completion of background work can clear an action error that the user has not read yet, such as `picker_load_failed`. Commit `e60b43c0` fixed this for File Enrichment builds. Ticket [02](02-keep-a-picker-error-through-a-cache-update.md) fixed it for cache updates and for the focus check that starts a File Enrichment.

An audit of the `self.action_error = null` sites in `src/tui/presentation.zig` found more completions that clear every action error. Triage confirmed each case with a test:

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

- [x] Each completion in the list has a test that decides whether it clears an unrelated action error.
- [x] No completion of background work clears an error that its own path cannot set.
- [x] `zig build test` passes.

## Completion

- `0d50e05f` adds ten failing tests to the Review recovery suite, one for each completion in the table. It also adds two tests that pass: a successful POST and a successful Comment delete clear an error of their own path. Before the fix, `zig build test-review-recovery` reported `47/57 tests passed (10 failed)`. Nine failures reported `expected .picker_load_failed, found .action_refused`, and the Picker test reported `expected .submission_launch_failed, found .action_refused`.
- `aae34d5d` gives each shown error an origin. `Presentation.action_error` holds a `ShownError`, the `ActionError` and its `ErrorOrigin`. `showError` and `clearError` take the origin. `clearError(.user)` clears any error, and every other origin clears only its own errors. `DisclosureBuild.Kind.errorOrigin` maps each build kind with an exhaustive switch. A script rewrote 349 writes: 218 in user handlers with `.user`, and 131 in completions or in their shared helpers with a path origin. Each origin comes from a call graph of the `dispatch` arms. Five helpers that user handlers and completions share take the origin as a parameter. `setByFileEnrichment` and `clearFileEnrichmentError` are deleted. The clipboard completion clears nothing, because its path shows no error.
- `a169fe1f` adds `tools/check_action_errors.py`. The check fails on a write of `action_error` outside `showError` and `clearError`. With `self.action_error = null` back in the clipboard completion, the check printed `src/tui/presentation.zig:6857: writes action_error outside its helpers.` and exited with 1.
- With `.view` removed from the switch in `errorOrigin`, the build failed with `switch must handle all possibilities` and `unhandled enumeration value: 'view'`. A write such as `state.action_error = .buffer_build_failed` failed with `struct 'tui.presentation.ShownError' has no member named 'buffer_build_failed'`.
- With `clearError` changed to clear every error, `zig build test-review-recovery` reported `45/57 tests passed (12 failed)`.
- The rule "Background work keeps an unrelated action error" in `docs/rules/tui-state.md` states the origin rule. The section "Other background completions keep an unrelated action error" left `CODING_STANDARDS.md`. A new section, "Choose the origin of an action error", keeps the part that no check sees: a completion must pass its own origin, not `.user`.

- Review found that `retryReviewSearchQuery` now cleared every `.buffer` error, so it also cleared an unread build failure. `a26f6ce8` adds a test for this case. Before the fix, it failed with `expected buffer_build_failed, found null`. `e4d02628` adds the origin `.review_search` for the Review Search query, scan, and retry errors. After the fix, `zig build test-review-recovery` reported `59/59 tests passed`.
Known gaps, out of scope: an older completion can clear a newer error of the same origin. A completion can also replace an unread error with a new error.

Checks: `zig build test-review-recovery` gave `59/59 tests passed`. `zig build test` exited with 0 and gave `1719/1719 tests passed`. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, and `python3 tools/check_doc_symbols.py .` passed.

## Comments

> *This was generated by AI during triage.*

## Agent Brief

**Category:** bug
**Summary:** Record the origin of each action error, so that a completion clears only an error that its own path set.

**Current behavior:**
`Presentation.action_error` holds only an `ActionError` name. Many completions clear it with `self.action_error = null`, so they also clear an error that another path set before the user read it. The File Enrichment path guesses ownership from the name through `setByFileEnrichment`, which cannot tell apart two paths that set the same name, such as `buffer_build_failed`.

Triage confirmed the defect with one throwaway test per completion. Each test failed:

| Completion | Unrelated error and how it appears |
| --- | --- |
| `post_draft_completed` | `picker_load_failed`. The Submission Overlay accepts `p`, and the Picker load fails while the POST runs. |
| `recovery_checked` | `picker_load_failed`, the same way, while the source check runs. |
| `duplicate_checked` | `picker_load_failed`, the same way, while the duplicate check runs. |
| `submission_wait_completed` | `picker_load_failed`, the same way, during the retry wait. |
| `comment_edit_completed` | `picker_load_failed`. The user saves the edit, switches the Review, and the Picker load fails before the edit completes. |
| `comment_delete_completed` | `picker_load_failed`, the same way as the comment edit. |
| `reviewer_verdict_changed` | `picker_load_failed`, the same way as the comment edit. |
| `session_prepared` | `picker_load_failed`. The Picker load fails while a Reconciliation prepares its Candidate Session. |
| `clipboard_completed` | `picker_load_failed`. The Picker load fails before the yank completes. |
| `pull_requests_loaded` (success) | `submission_launch_failed`. A pending POST fails to launch while the Picker loads. |

Nine tests reported `expected .picker_load_failed, found .action_refused`, and the Picker test reported `expected .submission_launch_failed, found .action_refused`. `.action_refused` is the `orelse` fallback of the assertion, so each completion cleared the error. Use the setup of the tests named "Review recovery Picker error survives ..." and the helper `showTestPickerLoadFailure`.

**Desired behavior:**
- An action error carries its origin: the path that set it, such as the Picker, a Submission, a comment edit, the File Enrichment path, or a user action.
- A completion of background or asynchronous work clears the shown error only when the error has the origin of that completion.
- A user action, such as a key, a mouse action, or an Overlay action, still clears any shown error.
- Setting an error without an origin does not compile.
- The File Enrichment path keeps its behavior through the origin, and `setByFileEnrichment` is deleted.

**Key interfaces:**
- `Presentation.action_error`: it holds the error and its origin. Choose the type, for example a struct of `ActionError` and an origin enum.
- `projection().action_error`: the Projection, the adapter, and the paint code still read only the `ActionError`. Keep that interface unless a reader needs the origin.
- The origin enum: one value per path that sets or clears an error. An exhaustive `switch` decides what each path clears.
- `clearFileEnrichmentError` and `setByFileEnrichment`: replace them with the origin rule.

**Acceptance criteria:**
- [x] Each of the ten completions has a test in the Review recovery suite that shows the unrelated error, completes the work successfully, and expects the error to stay.
- [x] Each completion still clears an error of its own origin. Tests show this for the Submission, the File Enrichment path, and one comment mutation.
- [x] The existing "Review recovery Picker error survives ..." tests and "Review recovery a completed cache update clears a failed build of its own path" pass.
- [x] A site that sets an action error without an origin does not compile.
- [x] The section "Other background completions keep an unrelated action error" leaves `CODING_STANDARDS.md`. The rule "Background work keeps an unrelated action error" in `docs/rules/tui-state.md` states the origin rule, and its Enforcement paragraph names the mechanism that fails.
- [x] `zig build test` passes, and so do `zig fmt --check src build.zig tests` and `python3 tools/check_agent_docs.py`.

**Out of scope:**
- A background completion that replaces an unread error with a new error. That is a separate defect class.
- A change to the text or the paint of a status message.
- A change to which errors exist.
