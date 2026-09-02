# 17 — Add Reviewer Verdict Actions

**What to build:** A reviewer can see and change the Authenticated Account's Reviewer Verdict from a remote, open PullRequest. Presentation keeps unavailable Actions visible with a reason and keeps each authorized remote change valid across Session switches.

**Blocked by:** 16 — Add the Reviewer Verdict Bitbucket contract.

**Status:** done

- [x] Configurable Actions set Approved, Changes Requested, and No Verdict with default keys `g a`, `g c`, and `g n`. They use no confirmation Overlay.
- [x] The status bar shows Approved, Changes requested, No verdict, or Verdict unavailable after the PullRequest title. LocalReview omits the segment.
- [x] Presentation alone computes Reviewer Verdict `ActionAvailability` and gives a specific reason for each refusal.
- [x] Presentation refuses verdict changes for LocalReview, a PullRequest that is not open, missing identity or verdict data, the PullRequest Author, an unchanged target verdict, and a busy global remote-write lane.
- [x] Submission, published Comment mutation, and Reviewer Verdict changes share one global remote-write lane.
- [x] Presentation emits one typed command with the target Reviewer Verdict and expected SourceCommit. The terminal adapter owns preflight, mutation, and reconciliation and returns one typed completion.
- [x] A Reviewer Verdict change is a PullRequest-qualified Durable Operation. Session switching does not cancel it or project its result into a different PullRequest.
- [x] A successful or reconciled change prepares a complete Candidate Session replacement when the same PullRequest remains visible. Replacement failure preserves the published Session and the qualified result.
- [x] Tests cover key resolution, every refusal, lane exclusion, stale refusal, definite failure, uncertain reconciliation, Session switching, stale completion rejection, Session replacement, status projection, allocator failure, and cleanup.
- [x] Merge and decline remain absent from Actions, endpoints, confirmation flows, and strategy UI.
