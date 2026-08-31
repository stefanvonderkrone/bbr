# Decide PullRequest lifecycle Action product scope

Type: grilling
Status: resolved
Blocked by: 07

## Question

Should bbr add approve, unapprove, merge, or decline Actions after the review workflow, or record some or all as durable non-goals, and what reviewer intent, confirmation, ActionAvailability, stale-SourceCommit, permission, local-review refusal, and failure behavior must an accepted Action expose?

## Answer

bbr will expose one three-state Reviewer Verdict for remote, open PullRequests:

- `g a` sets Approved.
- `g c` sets Changes Requested.
- `g n` sets No Verdict by removing the Authenticated Account's current Approved or Changes Requested state.

These are separate, configurable Actions with no confirmation Overlay. Merge and decline are durable non-goals for bbr because they change the PullRequest lifecycle rather than express a review decision.

A Candidate Session captures the PullRequest state, PullRequest Author UUID, Authenticated Account UUID, and current Reviewer Verdict. Verdict Actions are unavailable with a precise refusal when the review is local, the PullRequest is not open, identity or verdict data is unavailable, the Authenticated Account is the PullRequest Author, the requested verdict already matches, or the global remote-write lane is busy. Bitbucket decides permissions that bbr cannot prove before the request. A `401` invalidates the cached Authenticated Account identity.

Before mutation, bbr fetches the current PullRequest and compares its SourceCommit with the Session. A mismatch sends no mutation and requires an explicit refresh. After mutation, bbr fetches the Reviewer Verdict and SourceCommit. If the SourceCommit changed during the request race, bbr reports the exact reconciled result and never applies a compensating mutation.

The verdict change is a Durable Operation in the global remote-write lane. It continues after Session switching and reports a PullRequest-qualified result. A successful or reconciled change prepares a Candidate Session replacement when the same PullRequest remains visible. Replacement failure preserves the old Session and the qualified result.

Definite failures use the existing ApiError classification. A transport, rate-limit, or server result that leaves the mutation outcome uncertain triggers reconciliation before any retry. bbr never retries a verdict mutation automatically. Another mutation requires fresh reviewer intent.
