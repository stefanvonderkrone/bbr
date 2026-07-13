Status: ready-for-agent

# Edit, re-anchor, and delete Drafts

## What to build

Let the reviewer repair locally owned Drafts directly from the rendered Pending Review. A Draft can be opened with its existing body in the Composer, assigned a replacement Anchor from the current cursor or Selection, or deleted after confirmation. Persist every accepted mutation so it survives Session replacement and restart.

This is also the repair path when recovery refuses to resume a SubmissionRun because the PullRequest's SourceCommit changed. A Draft participating in an active SubmissionRun is immutable until that run becomes terminal.

## Acceptance criteria

- [ ] A reviewer can edit the body of a Comment, Reply, or Suggestion Draft and the same local Draft identity and parent relationship are preserved.
- [ ] A reviewer can replace a root Draft's Anchor from a valid current cursor or Selection; mixed-side, cross-File, gap-spanning, and old-side Suggestion selections retain the existing refusal rules.
- [ ] Editing or re-anchoring a failed Draft returns it to `draft`; a Draft in an active SubmissionRun cannot be mutated.
- [ ] A recovered `submitting` Draft cannot be edited, re-anchored, or deleted until read-only Duplicate-guard reconciliation confirms whether Bitbucket already owns it.
- [ ] If automatic reconciliation cannot resolve a recovered `submitting` Draft, the reviewer can link it to an author-owned Bitbucket Comment, explicitly confirm that it was not published, or decide later; only the first two choices resolve the ambiguity.
- [ ] An unresolved recovered `submitting` Draft uses a distinct amber/orange background and an explicit `outcome unknown - resolve before editing` label; confirmed failures retain the red failure treatment, and meaning never depends on color alone.
- [ ] A reviewer can delete a Draft after confirmation, and deleting a parent Draft also deletes all of its Draft reply-descendants.
- [ ] Mutations update the PendingReviewStore before the visible Buffer is rebuilt; persistence failure leaves the published Presentation state unchanged and surfaces the error.
- [ ] Deterministic tests cover body editing, re-anchoring, failed-state reset, cascading deletion, active-run refusal, persistence failure, and Session replacement/reload.

## Blocked by

None - can start immediately.

## Comments
