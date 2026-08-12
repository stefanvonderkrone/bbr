# 03 — Edit Draft bodies atomically

**What to build:** Let a reviewer press `e` on a local Draft ReviewCard and edit the same Comment, Reply, or Suggestion through a typed-target, prefilled Composer. A successful edit persists before Presentation changes, while failure preserves the previous complete Frame and the reviewer’s attempted body.

**Blocked by:** 02 — Resume frozen SubmissionRuns safely.

**Status:** ready-for-agent

- [ ] Every ReviewCard row resolves to a typed local TempId or Bitbucket CommentId target; editing a Draft opens `Edit local Draft` with its editable content prefilled.
- [ ] Comment, Reply, and Suggestion edits preserve TempId, kind, parent relationship, CommentScope, Anchor, and AnchorSnapshot; Suggestion editing exposes replacement code while retaining fenced storage semantics.
- [ ] Blank or invalid content is refused by the same rules as creation.
- [ ] A real body change resets `failed` to `draft`; accepting byte-identical content is a no-op that performs no persistence and preserves failure evidence.
- [ ] ActionAvailability keeps edit discoverable but refuses Drafts owned by an active or recovered SubmissionRun and Drafts in `submitting`, transient `posted`, or `outcome_unknown` states with precise reasons.
- [ ] The store atomically rechecks ReviewIdentity, TempId, expected parentage, DraftState, and SubmissionRun participation before replacing the body.
- [ ] The mutation follows stage, persist, publish; allocation, Buffer, validation, concurrent-state, or persistence failure preserves the old Frame and keeps the Composer open with the attempted bytes.
- [ ] Success restores navigation by TempId and survives refresh, Review switching, restart, and Session replacement.
- [ ] Deterministic tests cover all Draft kinds, no-op edits, failed-state reset, immutability, rollback, interaction retention, cursor restoration, and persisted reload.
