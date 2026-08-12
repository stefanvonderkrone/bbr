# 01 — Canonicalize Review identity and command correlation

**What to build:** Establish one ReviewIdentity-based protocol for Presentation, persistence, SubmissionLocks, and external effects so later M16 operations can be correlated and admitted without confusing a Review, Session, command, operation, or target. Preserve current user-visible behavior while replacing competing Review identity vocabulary and making every external completion safe to accept or discard exactly once.

**Blocked by:** None — can start immediately.

**Status:** resolved

- [x] ReviewIdentity is the sole domain identity for remote and local Reviews; any owned command representation is explicitly a copy-safe representation of ReviewIdentity rather than a second domain concept.
- [x] Remote-only operations accept only the remote ReviewIdentity variant at their type boundary, while local Review behavior remains unchanged.
- [x] Every external command has a unique CommandId; Durable Operation commands also carry OperationId and remote ReviewIdentity, and Session-bound commands also carry Session Epoch.
- [x] Completion admission requires matching CommandId, operation identity where applicable, typed target, and Session Epoch where applicable; late, duplicate, and mismatched completions are consumed and discarded exactly once.
- [x] SubmissionLocks and durable persistence remain Repository-qualified and cannot collide when PullRequestIds match across Repositories.
- [x] Existing load, File Enrichment, Picker, clipboard, Submission, recovery, and shutdown behavior remains green through the canonical protocol.
- [x] Deterministic tests cover remote and local identity equality, command correlation, wrong-target rejection, stale-Epoch rejection, duplicate completion disposal, and owned-payload cleanup.
