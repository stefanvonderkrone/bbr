# 11 — Repair stale and recovered Submissions

**What to build:** Guide reviewers through interrupted and SourceCommit-stale SubmissionRuns in the same dependency-tree Overlay. bbr reconciles ambiguous publication read-only, reloads one complete Candidate Session, requires explicit scope-appropriate repair, and starts fresh SubmissionRuns only for eligible selected subtrees.

**Blocked by:** 04 — Re-anchor inline root Drafts; 05 — Delete Draft subtrees atomically; 09 — Persist bounded Submission retries; 10 — Project the Submission dependency tree.

**Status:** resolved

- [x] Startup discovers active SubmissionRuns and distinguishes a held lock from recoverable work; recovery requires explicit reviewer authorization.
- [x] Recovered ambiguous `submitting` items run the Duplicate guard before any mutation or new POST, including when SourceCommit changed.
- [x] A found Comment checkpoints `posted(CommentId)`; unresolved recovery offers link existing author-owned Comment, confirm not published, and decide later with settled mutability consequences.
- [x] `outcome_unknown` uses explicit amber/orange treatment and `outcome unknown - resolve before editing`; meaning never depends on color.
- [x] Abandon recovery emits no POST, preserves ambiguous evidence as `outcome_unknown`, terminalizes the run partial, releases its lock, and restores mutability only to eligible `draft` and `failed` items.
- [x] A changed SourceCommit enters the Stale repair gate, displays loaded and observed SourceCommits, emits no new POST, and offers no submit-anyway Action.
- [x] Reload PullRequest privately stages a complete Candidate Session, PendingReview, Comments, Diff, ScopeProjection, Frame, and identity-based navigation; failure preserves the exact previous Session, Epoch, Overlay, and retry Action.
- [x] Review-level roots become eligible after reload; File-level roots require current authored scope; new-side inline roots require explicit re-anchor; old-side roots require the exact authored span; Replies inherit an unpublished root’s gate or may use a reconciled published parent CommentId.
- [x] Eligibility is evaluated independently per root subtree so unrelated unrepaired roots cannot enter or block a selected eligible run.
- [x] A fresh selected-subtree Submission captures the refreshed SourceCommit and checks it again before POST; a second change re-enters the gate without external mutation.
- [x] Deterministic tests cover held ownership, current-source resume, every Duplicate-guard outcome, automatic clean completion, abandonment, immutable ambiguity, reload success and rollback, all scope branches including ranges, local and published parents, unrelated-root exclusion, and a second source change.
