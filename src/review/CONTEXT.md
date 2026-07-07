# Review

Comment threads on a PullRequest and the client-side **Pending Review**: the batch of
drafts the reviewer composes locally and publishes together. Bitbucket Cloud has no native
draft/pending concept, so this batching is entirely ours to model.

## Language

**Anchor**:
The location a Comment attaches to: a File `path`, the **commit** it was authored against, plus line coordinates `{ from, to, start_from, start_to }`, where `from`/`start_from` are old-file lines and `to`/`start_to` are new-file lines. A range spans `start_*` → `from`/`to`. A Comment with no Anchor is a PR-level comment. Anchors also carry a few captured context lines so an outdated Comment stays legible.
_Avoid_: position, location, target, ref.

**AnchorState**:
Where a Comment resolves against the currently viewed diff: `current` (line unchanged), `moved` (line shifted by surrounding edits), or `outdated` (line no longer exists). For remote Comments we trust Bitbucket's verdict; for local Comments and Drafts we compute it by diff-walking via the GitClient.
_Avoid_: status, stale, dangling.

**Outdated**:
The `outdated` AnchorState. Outdated Comments are never hidden — Presentation shows them in a per-file collapsible using their captured context.
_Avoid_: stale, orphaned, dead.

**CommentTarget**:
Where a Comment/Draft lives: `bitbucket` (syncs; Drafts submit) or `local` (persists only in SQLite, never submits). Set by the review mode.
_Avoid_: backend, sink, destination.

**Comment**:
A piece of authored prose on a PullRequest, optionally anchored. May be a root comment or a Reply. The generic term; prefer Thread/Reply/Suggestion when the role is specific.
_Avoid_: note, remark, message.

**Thread**:
A root Comment together with its ordered Replies, carrying a `resolved` flag. The unit the UI displays and collapses. Resolved Threads are hidden behind a toggle that reveals the *whole* Thread (comment + replies) — never a bare "a resolved comment exists" marker.
_Avoid_: conversation, discussion, chain.

**Reply**:
A non-root Comment whose parent is another Comment (which may itself still be a Draft).
_Avoid_: child, response, answer.

**Suggestion**:
A Comment whose body contains a fenced ```suggestion``` block proposing replacement lines. We can author suggestions; *applying* them stays in the Bitbucket web UI.
_Avoid_: patch, fix, edit, proposal.

**Draft**:
An authored-but-unpublished Comment/Reply/Suggestion held locally. Carries a local temp id, its DraftState, and — for a root Draft — an Anchor. A *reply* Draft carries no Anchor of its own: its location comes from its parent. The parent link (not a copied Anchor) is the single expression of that relationship — it drives both rendering placement and Submission ordering. A reply therefore shares its parent's visibility: hide the parent thread (resolved, toggle off) and the reply hides with it. The atom of a Pending Review.
_Avoid_: pending comment, unsent, staged.

**DraftState**:
A Draft's lifecycle: `draft` → `submitting` → `posted` (carries the server-assigned CommentId) or `failed` (carries the ApiError reason). Persisted, so a crash resumes mid-Submission. `posted` is a *transient reconciliation* state, not a permanent record: it exists to survive a crash mid-batch, and the Draft's row is deleted once the whole Submission batch succeeds — thereafter the published Comment lives only on Bitbucket (ADR-0007).
_Avoid_: status, phase.

**PendingReview**:
The whole graph of Drafts for one PullRequest, persisted via the PendingReviewStore. Survives quit and file/PR switches.
_Avoid_: batch (that's the act), queue, staging.

**Submission**:
The act of publishing a PendingReview: topologically order Drafts (parents before Replies), POST each, remap temp ids to server CommentIds, and continue-on-item-failure while stopping the batch on auth failure.
_Avoid_: submit, flush, push, sync.
