# 12 — Verify M16 through production seams

**What to build:** Complete M16 with deterministic seam-crossing coverage and operational documentation. The same typed command/completion path used in production is driven by a scripted terminal-adapter harness, while narrow opt-in checks cover only terminal and Bitbucket behavior that fakes cannot establish.

**Blocked by:** 06 — Hand Composer bodies to External Edit; 08 — Delete author-owned Bitbucket Comments; 11 — Repair stale and recovered Submissions.

**Status:** resolved

- [x] A deterministic terminal-adapter harness drains every M16 command family into scripted executors and returns correlated completions through the production sink without real network, sleep, terminal, or PTY dependencies.
- [x] Representative `Action -> OwnedCommand -> typed completion -> Projection` sequences verify Draft mutation, published mutation, External Edit, Submission, recovery, stale repair, and Reconciliation without duplicating exhaustive lower-level branch tables.
- [x] Async sequences interleave Session replacement with POST, wait, Reconciliation, External Edit, and File Enrichment completions and verify Session-bound rejection versus Durable Operation continuation.
- [x] Every distinct admission rule covers late, duplicate, wrong-CommandId, wrong-OperationId, wrong-target, stale-Epoch, and command-launch-failure completion behavior with exactly-once cleanup.
- [x] Exhaustive allocation-failure sweeps and transaction fault injection prove complete Projection rollback and retention of Composer, re-anchor, confirmation, Buffer, navigation, durable records, and command ownership.
- [x] Pinned vaxis adapter fixtures verify portable shift-selection translation; documentation keeps `v` as the reliable Selection Action and records Shift+Arrow as terminal-dependent.
- [x] One opt-in PTY External Edit smoke verifies inherited streams, cooked mode and echo, exact bytes, mouse restoration, alternate-screen transitions, redraw, and recreated input.
- [x] One credential-gated, destructive-opt-in Bitbucket check creates, fetches, body-updates, and deletes a uniquely marked disposable Comment, verifies stable identity, author, and CommentScope, and performs best-effort cleanup without exposing Credential material.
- [x] Documentation covers mutation ownership, immutable published Anchors, Deleted Comments, External Edit configuration and precedence, Retry-After policy, Submission recovery, stale repair, no retry-all, no submit-anyway, and all opt-in checks.
- [x] The complete deterministic suite and formatting checks pass; live `429` induction is not required.
