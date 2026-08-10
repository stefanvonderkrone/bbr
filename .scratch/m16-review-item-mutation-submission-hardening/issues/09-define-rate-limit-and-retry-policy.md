# Define the rate-limit and retry policy

Type: grilling
Status: resolved
Blocked by: 03, 08

## Question

Given Bitbucket's verified headers and observed behavior, how should HttpClient parse and own retry metadata, CommentPoster report it, Submission combine server delay with its pure backoff and attempt ceiling, and the live Submission Overlay explain waiting, exhaustion, and selective repair without introducing wall-clock policy into the state machine?

## Answer

`HttpClient.Response` owns HTTP retry metadata as `retry_after_ms: ?u64`; no raw header or absolute date crosses the transport seam. The real adapter matches `Retry-After` case-insensitively, accepts either a non-negative integer number of delay-seconds or an HTTP-date, and converts it to checked milliseconds using the response-time wall clock. Missing, malformed, overflowing, or already-expired values become `null`. The fake supplies the optional duration directly. Undocumented `X-RateLimit-*` headers may be retained in diagnostics but never affect policy.

The Bitbucket adapter carries retry guidance only from definite retryable responses: `429` classified as `rate_limited` and `5xx` classified as `server`. Success, auth and validation failures ignore it; an ambiguous transport failure has no response metadata to trust. `CommentPoster.post` therefore returns one typed result containing both `PostOutcome` and optional `retry_after_ms` rather than passing a parallel ad hoc argument through Presentation. Duplicate-guard comment-list reads likewise return a typed found/missing/rejected result with retry metadata, so a rate-limited or server-failed guard cannot silently bypass the same policy.

Each Draft receives three total POST attempts: the initial POST plus at most two automatic retries. With no valid server guidance, the deterministic waits are exactly 1 second and 2 seconds. For each retry, Submission emits `max(local_backoff, server_delay)`; valid server guidance is never shortened. There is no jitter and no arbitrary duration cap. The pure state machine compares durations and emits wait data but never reads a clock or sleeps.

Duplicate-guard reads after an ambiguous POST receive their own three-attempt budget with the same 1-second/2-second schedule and server-delay rule. Guard attempts never consume POST attempts. If all guard reads fail, the Draft becomes `outcome_unknown`; bbr must not issue another POST when it cannot establish whether the ambiguous POST landed.

Before launching a timer, persist the current operation phase, attempt count, classified reason, local delay, optional server delay, effective delay, and a `wait_pending` marker in the SubmissionRun checkpoint. A crash, restart, or recovery while that marker is pending repeats the full effective wait. This can wait longer than the server required but can never retry early and needs no persisted wall-clock deadline. A timer launch or sleep failure is an infrastructure pause: retain the recoverable checkpoint, consume no attempt, and offer resume rather than converting the Draft to an ApiError failure.

Exhausting a definite retryable POST leaves the Draft `failed` with its classified ApiError and closes the run terminal-partial; retry timing remains SubmissionRun result metadata rather than authored Draft state. **Retry selected subtree** starts a fresh three-attempt budget for exactly the selected failed Draft and its Reply descendants. If the final exhausted response carried `Retry-After`, the new run emits that full delay before its first POST. The retry preview states this mandatory initial wait; deliberately over-waiting avoids a durable retry-deadline model.

The live Submission Overlay projects exact static state rather than a countdown. A waiting row says `waiting to retry 2/3` or `waiting to check publication 2/3`; its detail names the failure class, local delay, server-requested delay when present, and effective wait. Completion of the timer changes the state to posting or reconciling. Exhaustion says, for example, `failed - rate limited after 3 attempts` or `outcome unknown - publication check failed after 3 attempts`, explains Reply-descendant impact, and exposes only the Actions already valid for that state. No periodic tick, absolute retry timestamp, or wall-clock value enters Presentation.

Deterministic coverage must include both `Retry-After` forms, case-insensitive lookup, malformed/expired/overflow fallback, `429` and `5xx` propagation, ignored metadata on other classes, `max` selection in both directions, the exact 1-second/2-second sequence and three-attempt exhaustion, independent Duplicate-guard budgeting, wait-checkpoint recovery, timer-launch pause/resume, terminal-delay carryover into selected-subtree retry, and the static Overlay detail. The broader seam-crossing placement belongs to [Define M16's deterministic integration coverage](11-define-m16-integration-coverage.md).
