# 09 — Persist bounded Submission retries

**What to build:** Make Submission retries bounded, server-aware, and crash-safe. A reviewer sees deterministic waiting and a recoverable durable checkpoint; bbr never retries earlier than valid Bitbucket guidance and never repeats an ambiguous POST when publication cannot be established.

**Blocked by:** 02 — Resume frozen SubmissionRuns safely.

**Status:** ready-for-agent

- [ ] HTTP responses expose optional `retry_after_ms` rather than raw headers; the real adapter recognizes `Retry-After` case-insensitively and parses non-negative delay-seconds and HTTP-date forms.
- [ ] Missing, malformed, overflowing, or expired guidance becomes absent; only definite `429` and `5xx` results propagate guidance, while undocumented rate-limit headers remain diagnostic only.
- [ ] Each Draft receives three total POST attempts with exact one-second and two-second fallback waits; effective delay is the maximum of local backoff and valid server guidance.
- [ ] Duplicate-guard reads after an ambiguous POST receive an independent three-attempt budget with the same waiting policy and do not consume POST attempts.
- [ ] Exhausted definite retryable POSTs become `failed`; exhausted publication checks become `outcome_unknown` and forbid another POST.
- [ ] Before any timer command, the SubmissionRun durably checkpoints phase, attempt, classified reason, local delay, server delay, effective delay, and pending-wait state.
- [ ] Recovery repeats a pending wait in full; timer launch or sleep failure pauses recoverably without consuming an attempt.
- [ ] Retry selected subtree receives a fresh attempt budget and honors the final server delay before its first POST when applicable.
- [ ] The pure Submission policy emits durations and effects without reading a clock, sleeping, performing I/O, or publishing Presentation state.
- [ ] Deterministic tests cover both wire forms, fallback cases, error propagation, maximum selection, exact schedules, independent budgets, wait recovery, timer failure, terminal-delay carryover, and no duplicate POST after unresolved ambiguity.
