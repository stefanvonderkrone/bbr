# Review

Comment threads on a PullRequest and the client-side **Pending Review**: the batch of
drafts the reviewer composes locally and publishes together. Bitbucket Cloud has no native
draft/pending concept, so this batching is entirely ours to model.

## Language

**ReviewIdentity**:
The durable identity of one Review: either a Workspace/Repository/PullRequestId for remote review or a ReviewRepository/BaseRef/SourceRef for local review. It survives Session replacement and never includes resolved commit hashes; a Session Epoch identifies a particular loaded snapshot.
_Avoid_: ReviewKey, Session identity, commit pair.

**Anchor**:
The location a Comment attaches to: a File `path`, the **commit** containing its anchored side, plus line coordinates `{ from, to, start_from, start_to }`, where `from`/`start_from` are old-file lines and `to`/`start_to` are new-file lines. In a LocalReview, an old-side Anchor binds to the resolved BaseRef commit and a new-side Anchor binds to the resolved SourceRef commit. A range spans `start_*` → `from`/`to`; captured context keeps an unresolved or outdated Comment legible.
_Avoid_: position, location, target, ref.

**AnchorState**:
The successful verdict for an Anchor against the currently viewed Diff: `current` (same path and coordinates), `moved` (Git proves the same Anchor at different coordinates or a renamed path), or `outdated` (the anchored content no longer exists). For remote Comments we trust Bitbucket's verdict; for local Comments and Drafts we compute it by diff-walking via the GitClient.
_Avoid_: status, stale, dangling.

**AnchorResolution**:
The result of attempting to place an Anchor against the currently viewed Diff: either a resolved AnchorState or `unavailable` when required Git history or mapping evidence cannot be obtained. Unavailable never implies outdated and retains the Anchor's captured context.
_Avoid_: AnchorState (only a successful verdict), unknown state, assumed outdated.

An AnchorResolution is derived projection data, not durable authored state. For Drafts it lives in the Presentation-owned AnchorProjection keyed by root TempId; the PendingReview retains only the original Anchor and AnchorSnapshot. Replies inherit their root's projected placement.

**AnchorSnapshot**:
The immutable authored code stored with a root local Draft: its complete selected range plus three surrounding lines on each side. It keeps outdated or unavailable Anchors legible but never participates in mapping or silently changes an Anchor; Replies inherit their root Draft's snapshot.
_Avoid_: fuzzy-match context, cached blob, projected source.

**Outdated**:
The `outdated` AnchorState. Outdated Comments and Drafts are never hidden — Presentation shows them with their AnchorSnapshot in an always-expanded File or review-level section.
_Avoid_: stale, orphaned, dead.

**CommentTarget**:
Where every Draft in one PendingReview lives: `bitbucket` (Drafts submit) or `local` (persists only in SQLite, never submits). It is an invariant of the Review mode; a PendingReview never mixes targets.
_Avoid_: backend, sink, destination.

**Comment**:
A piece of authored prose on a PullRequest, optionally scoped to a File or anchored to lines. May be a root comment or a Reply. The generic term; prefer Thread/Reply/Suggestion when the role is specific.
_Avoid_: note, remark, message.

**File-level Comment**:
A root Comment scoped to one File as a whole, without line coordinates. It is distinct from both an inline Comment, whose Anchor identifies lines, and a PullRequest-level Comment, which belongs to no File.
_Avoid_: whole-File Comment (confusable with the WholeFile Diff scope), unanchored inline Comment.

**Thread**:
A root Comment together with its ordered Replies, carrying a `resolved` flag. The unit the UI displays and collapses. Resolved Threads are hidden behind a toggle that reveals the *whole* Thread (comment + replies) — never a bare "a resolved comment exists" marker.
_Avoid_: conversation, discussion, chain.

**Reply**:
A non-root Comment whose parent is another Comment (which may itself still be a Draft).
_Avoid_: child, response, answer.

**Suggestion**:
A Comment whose body contains a fenced ```suggestion``` block proposing replacement lines. Authoring one prefills the composer with the current source of the anchored line(s), so the reviewer edits real code inside the fence rather than retyping it. A Suggestion is only meaningful over new-file lines — Bitbucket refuses to *apply* a suggestion anchored to removed lines — so authoring one over an old-side (deletion) range is refused. *Applying* a Suggestion stays in the Bitbucket web UI.
_Avoid_: patch, fix, edit, proposal.

**Selection**:
A contiguous run of diff lines the reviewer marks (via `v` or shift+arrow) to anchor a multi-line Comment or Suggestion. Maps to a **ranged Anchor**: a new-side selection (lines present in the new file) yields `{ start_to, to }`, an old-side one (a removed line) yields `{ start_from, from }`. A selection that mixes sides, crosses a hunk gap, or spans files is refused rather than anchored to the wrong lines — the same "refuse over guess" stance as the Stale-anchor guard.
_Avoid_: highlight, mark, region.

**Draft**:
An authored-but-unpublished Comment/Reply/Suggestion held locally. Carries a local temp id, its DraftState, and — for a root Draft — an Anchor. A *reply* Draft carries no Anchor of its own: its location comes from its parent. The parent link (not a copied Anchor) is the single expression of that relationship — it drives both rendering placement and Submission ordering. A reply therefore shares its parent's visibility: hide the parent thread (resolved, toggle off) and the reply hides with it. The atom of a Pending Review.
_Avoid_: pending comment, unsent, staged.

**DraftState**:
A Draft's lifecycle: `draft` → `submitting` → `posted` (carries the server-assigned CommentId), `failed` (carries a confirmed ApiError reason), or `outcome_unknown` (every Duplicate-guarded retry still lost the POST response, so publication remains unresolved). Persisted, so a crash resumes mid-Submission. An `outcome_unknown` Draft remains immutable until the reviewer links it to an existing Comment or confirms it was not published. `posted` is a *transient reconciliation* state, not a permanent record: it exists to survive a crash mid-batch, and the Draft's row is deleted once the whole Submission batch succeeds — thereafter the published Comment lives only on Bitbucket (ADR-0007).
_Avoid_: status, phase.

**PendingReview**:
The whole graph of Drafts for one Review, with one CommentTarget, persisted via the PendingReviewStore. Survives quit and Review switches.
_Avoid_: batch (that's the act), queue, staging.

**Submission**:
The act of publishing a PendingReview: topologically order Drafts (parents before Replies), POST each, remap temp ids to server CommentIds, and continue-on-item-failure while stopping the batch on auth failure. A retryable failure (rate-limit, server, network) is retried with backoff; a validation failure fails that Draft and *skips its reply-descendants* (they have no valid parent to attach to); an auth failure aborts the whole batch with everything kept pending. Modeled as a clock-free state machine that emits the next action as data, so its policy is pure; the network is the **CommentPoster** seam. After a batch that posts anything, the PR is re-fetched so the freshly published Comments reappear (see Reconciliation) — Bitbucket, not the deleted Drafts, is now their home.
_Avoid_: submit, flush, push, sync.

**SubmissionRun**:
The durable record of one attempt to carry a PullRequest's Submission to a terminal outcome, including where an interrupted attempt must resume. It is identified within a Repository-qualified PullRequest and is distinct from the process that currently owns the work.
_Avoid_: batch (the Submission is the batch), worker, job, Session.

**Reconciliation**:
The step after a Submission that posted at least one Comment: re-fetch the PR so the just-published Comments (now owned by Bitbucket, ADR-0001) reappear in place of the Drafts that were deleted on a clean batch. During the transient window of a *partial* batch, a still-pending Draft under a now-posted parent stays visible while the posted parent's own row is hidden (the fetched Comment represents it) — the render-path dedup ADR-0007 anticipates.
_Avoid_: refresh, sync, merge.

**Selective retry**:
Re-running Submission over a PendingReview that already has posted Drafts: those are recognized (their transient `posted` state) and skipped, so only the still-pending failures and their descendants are re-attempted. The user's remedy for a partial batch.

**Stale-anchor guard**:
A pre-Submission check that the PR's SourceCommit has not moved since load. If it has, the diff shifted under the Drafts' Anchors and their lines may no longer exist, so the batch is refused rather than posting to wrong lines.

**Duplicate guard**:
The defense against double-posting when a POST's response is lost (an *ambiguous* outcome — the comment may or may not have been created). Before retrying such a POST, fetch the PR's comments and skip if one already matches the Draft's anchor and body; Bitbucket has no idempotency key.
