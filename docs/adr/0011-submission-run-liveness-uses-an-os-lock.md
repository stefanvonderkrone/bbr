# SubmissionRun liveness uses an OS lock, not a heartbeat lease

A durable SubmissionRun records what work exists and where it stopped, but its SQLite row does not prove that an owning `bbr` process is still alive. Because every competing instance is local and Bitbucket offers no fencing token or idempotency key, the process performing a Submission holds an exclusive OS advisory lock for that Repository-qualified PullRequest; another instance treats a held lock as live ownership and an unheld lock beside an active SubmissionRun as recovery-needed work.

## Why not a heartbeat lease

A lease can expire while its owner is suspended or paused. A second process could then take over before the first resumes, allowing both to POST because Bitbucket cannot reject the unfenced former owner. PID and heartbeat metadata may explain who appears to own a run, but neither authorizes takeover.

## Consequences

- Acquire the OS lock before creating the active SubmissionRun and hold its file descriptor until the run becomes terminal. The kernel releases it on process exit or crash; lock-file existence alone has no meaning.
- A hung owner remains authoritative until the user terminates it. Another instance never steals its lock automatically.
- SubmissionRun and Draft state remain the recovery record. If a crash leaves a Draft `submitting`, the recovering owner runs the Duplicate guard before another POST (ADR-0007).
- Recovery re-checks the PullRequest's SourceCommit before publishing. A changed commit blocks every new POST, but does not block read-only Duplicate-guard reconciliation: already-published Comments must still be identified before the remaining Drafts can be edited, re-anchored, or deleted safely.
- Drafts and SubmissionRuns must be keyed by Workspace + Repository + PullRequestId. A PullRequestId alone is not globally unique.
- SQLite transactions remain short and are never held across network calls.
