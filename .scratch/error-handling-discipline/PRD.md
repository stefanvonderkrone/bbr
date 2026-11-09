# Error handling discipline

Status: claimed
Implementation directory: .

## Problem

The diagnostic logging work of PR #19 records a failure only when the code keeps the cause.
The catch ratchet in `tools/check_diagnostics.py` counts 381 production `catch` sites that drop the cause.
The ratchet stops new drops. It does not tell an intentional drop from a mistake.
Some captured forms also drop the cause, and the lint cannot see them.
The repo also has no rule that says where `try` stops and where code must handle an error.

## Source

[research.md](research.md) holds every finding, with sources.
It covers the Zig 0.16 language and standard library, Ghostty at `5813c946`, TigerBeetle at `68958eb7` and `ac790315` (0.17.0), Zig issue #2647, and Yuan et al. (OSDI 2014).
Its section "Implications for bbr" lists 11 proposals. This PRD adopts five of them.

## Adopted decisions

1. The checked drop form `catch |err| switch (err) { error.X => fallback }` is the one sanctioned way to drop an error. The switch has no `else` prong. The lint counts `_ = err;` and a non-recording `else` prong as drops. See research proposals 1 and 3.
2. The large groups of cause-dropping sites convert in bulk to the sanctioned form or to a helper that holds it. See research proposal 2.
3. A boundary rule says where `try` stops. Inside a module, code uses `try`. Code records each failure exactly once. See research proposal 4 and [ADR-0014](../../docs/adr/0014-a-failure-is-recorded-once-and-error-reported-marks-it.md).
4. A line check bans `== error.` comparisons. A `catch` switch on an error set that contains `error.Canceled` names `error.Canceled` in its own prong. See research proposals 6 and 7.
5. `Handle.fail` records a failure and returns `error.Reported`. A site that records a failure and must still fail upward returns it, and the callers above keep `try`. A boundary records every error except `error.Reported`. See research proposal 5 and [ADR-0014](../../docs/adr/0014-a-failure-is-recorded-once-and-error-reported-marks-it.md).
   This answers research open question 2. The boundary owns the user message. It tells a recorded error from an unrecorded one by the name. `error.Reported` means that a layer below recorded the failure through its Handle, and every other error has no record yet. When logging is off, that record writes nothing. `error.Reported` also drops the name of the cause. So, after TigerBeetle, a CLI-path site prints its own message when its boundary prints or branches on the error name. The site records through `fail` first, then prints its message and returns the `error.Reported` result. A failed write cannot drop the record. At a translation site that message names the leaf cause and the translated meaning. A TUI-path site cannot print. When its boundary branches on the error name, the site returns the error without a record. The operator made this decision on 2026-11-08. Re-verification on 2026-11-09 corrected the record order.
   Issue 06 converted the sites that recorded and then returned a plain error. Issue 08 tracks the gaps that remain.

## Out of scope

- Explicit `ReadFailed` and `WriteFailed` helpers (research proposal 6, first part).
- An AST checker (research proposal 8). Reconsider it only if the regex misclassifies the residue after issue 02.
- Fault injection, assertion policy, and CLI exit codes (research proposals 9 to 11).

## Open questions

These come from research.md. Each issue names the questions that it must answer before it is resolved.

1. Is `error.OutOfMemory` in a render path an expected outcome or a failure to record?
2. Does a log-only `catch` count as a drop for the ratchet?
3. Does the ratchet need a per-site allow marker, or does the checked switch form make a marker unnecessary?

## Issues

- [01 Sanction the checked drop form in the lint](issues/01-sanction-checked-drop-form.md)
- [02 Convert the large drop groups](issues/02-convert-large-drop-groups.md)
- [03 State the try boundary rule](issues/03-state-try-boundary-rule.md)
- [04 Ban error comparisons and require a Canceled prong](issues/04-ban-error-comparisons-require-canceled-prong.md)
- [05 Fix the out-of-memory mislabels](issues/05-fix-out-of-memory-mislabels.md)
- [06 Record each failure once through fail](issues/06-record-once-through-fail.md)
- [07 Keep the leaf evidence in the one record](issues/07-keep-leaf-evidence-in-the-one-record.md)
- [08 Close the remaining record gaps](issues/08-close-the-remaining-record-gaps.md)
- [09 Close the remaining evidence and test gaps](issues/09-close-the-remaining-evidence-and-test-gaps.md)
