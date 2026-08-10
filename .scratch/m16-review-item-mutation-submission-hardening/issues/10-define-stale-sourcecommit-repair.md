# Define the stale-SourceCommit repair workflow

Type: grilling
Status: resolved
Blocked by: 04, 05, 08

## Question

How should the Stale-anchor guard lead the reviewer through reload, ScopeResolution, inspection, edit/re-anchor/delete repair, recovered ambiguous-outcome reconciliation or explicit Abandon recovery, and eventual selective Submission when new POSTs are always refused against a changed SourceCommit and no submit-anyway path exists?

## Answer

A changed SourceCommit enters the **Stale repair gate** and emits no new POST. The one live Submission Overlay remains the controlling surface and shows the Repository-qualified PullRequest, the loaded and observed SourceCommits, and the explicit reason that Submission is blocked. There is no submit-anyway Action. A newly authorized Submission that fails its preflight has no SubmissionRun to close; a recovered SubmissionRun remains active and retains its lock until reconciliation proves it clean or the reviewer explicitly chooses Abandon recovery.

The Overlay offers an explicit **Reload PullRequest** Action rather than silently replacing the Session or sending the reviewer through the Picker. Reload privately stages a Candidate Session from the latest PullRequest, PendingReview, Comments, Diff, ScopeProjection, initial Buffer, and identity-based navigation. It publishes atomically only when usable. Acquisition, projection infrastructure, allocation, or Buffer failure preserves the previous Session, Session Epoch, blocked Overlay, and retryable reload Action; an individual `unavailable` ScopeResolution remains usable inspection evidence rather than failing the reload.

Recovery performs the read-only Duplicate guard for an ambiguous `submitting` Draft even though the SourceCommit changed. A match checkpoints `posted(CommentId)` and Reconciliation makes Bitbucket authoritative. No match or multiple/insufficient evidence exposes the existing **Link existing author-owned Bitbucket Comment**, **Confirm not published**, and **Decide later** choices; it never silently equates absence with unpublished. If fetching Comments fails, the error is retryable, but the reviewer may still choose conservative Abandon recovery. Abandon emits no POST, checkpoints the in-flight Draft as `outcome_unknown`, preserves all evidence, closes the run terminal-partial, and releases its lock. If reconciliation proves every participant posted, the run may complete clean automatically; otherwise any unpublished participants require consequence-specific Abandon confirmation before mutation becomes available.

After reload, the Overlay rebuilds its dependency tree from durable identity and shows each unpublished root's authored scope, ScopeResolution, projected scope when available, and repair requirement. ScopeResolution remains inspection evidence and never silently rewrites authored scope. The Stale repair gate applies by root:

- A Review-level root is eligible after successful reload because its POST carries no File or Anchor.
- A File-level root is eligible only when ScopeResolution is `current`. A `moved`, `outdated`, or `unavailable` File root has no re-anchor Action under the settled mutation contract, so it must be deleted and recreated at the intended File or left pending; its projected path is never posted silently.
- A new-side inline root authored against the old SourceCommit must be explicitly re-anchored to a valid cursor or Selection in the refreshed Session, even when ScopeResolution projects it as `current` or `moved`. Re-anchor durably replaces the Anchor and resets an eligible failed Draft under the settled stage-persist-publish transaction. `outdated` and `unavailable` roots likewise require re-anchor or deletion.
- An old-side inline root still binds to BaseCommit, not SourceCommit. It is eligible unchanged only when the refreshed authoritative Diff contains the exact authored path, side, and complete span. Otherwise it requires a real re-anchor to a valid old-side span or deletion. The workflow never invents a SourceCommit binding for an old-side Anchor.
- Reply Drafts inherit their unpublished local root's gate and cannot bypass it. A Reply whose parent has already reconciled to a Bitbucket Comment may proceed after reload and inspection, including when Bitbucket marks that published Thread outdated, because the Reply POST carries only the stable parent CommentId and no Anchor.

The Overlay keeps mutation Actions visible with precise availability reasons. While the recovered run is active, all participating Drafts remain immutable. After terminalization, `draft` and confirmed `failed` items regain their settled edit, re-anchor, and delete Actions; `outcome_unknown` remains immutable until linked or confirmed unpublished. Returning from Composer, re-anchor capture, deletion, ambiguity resolution, or reload reconstructs the same dependency projection by typed identity and retains the logical selection where it survives.

Eventual Submission is per-subtree rather than globally gated. **Retry selected subtree** starts a fresh SubmissionRun containing exactly the selected eligible Draft and its Reply descendants; it captures the refreshed SourceCommit and performs the ordinary pre-Submission head check again. Unrelated stale or unrepaired roots remain pending and cannot leak into that run. A stale local root blocks its descendants, while a reconciled published ancestor supplies its CommentId normally. If SourceCommit changes again before authorization completes, the fresh attempt re-enters the Stale repair gate without POSTing.

Deterministic coverage must include initial preflight refusal without a run; recovered stale runs with matched, unmatched, unresolved, and fetch-failed Duplicate guards; automatic clean completion versus explicit terminal-partial Abandon; immutable ambiguous evidence; explicit reload success and atomic failure; every Review/File/new-side/old-side ScopeResolution branch including ranged spans; Replies beneath local and published parents; mutation return to the same Overlay; per-subtree eligibility; exclusion of unrelated stale roots; and a second SourceCommit change before the replacement run starts.
