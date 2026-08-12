# 02 — Resume frozen SubmissionRuns safely

**What to build:** Make each SubmissionRun a durable, PullRequest-qualified record of the exact Draft dependency graph the reviewer authorized. After interruption, bbr resumes that frozen graph rather than recomputing participants from a changed PendingReview, while preserving parent remapping, per-item evidence, and exclusive local ownership.

**Blocked by:** 01 — Canonicalize Review identity and command correlation.

**Status:** resolved

- [x] Beginning a SubmissionRun atomically persists its ordered participants, TempIds, parent dependencies, SourceCommit, and initial checkpoint before the first POST can be emitted.
- [x] Recovery loads the frozen participant graph and never adds, removes, or reorders items based on the current PendingReview.
- [x] One forward-only migration preserves all existing Draft identities, bodies, kinds, parent relationships, CommentScopes, AnchorSnapshots, and DraftStates while adding normalized SubmissionRun participant and checkpoint data.
- [x] The in-memory and SQLite adapters expose transaction-shaped begin, checkpoint, ambiguity-resolution, abandonment, and terminal-completion intentions without holding transactions across external work.
- [x] The OS advisory lock is acquired before a run becomes active, retained until terminalization, and never stolen from a live owner.
- [x] Drafts participating in an active or recovered run are reported as immutable even when an individual Draft is not currently `submitting`.
- [x] Crash/reopen tests prove participant stability, parent remapping, repository isolation, migration preservation, held-lock refusal, and complete cleanup after clean or partial terminalization.
