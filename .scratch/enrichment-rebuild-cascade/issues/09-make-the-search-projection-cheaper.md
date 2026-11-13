# 09: Make SearchProjection.create cheaper

Status: needs-triage
Blocked by: none

## Summary

This is win 4 of [ticket 05](05-make-a-buffer-rebuild-faster.md).
`SearchProjection.create` in `src/tui/presentation.zig` runs on every rebuild.
After ticket 05, it costs a median of 46 to 51 ms of worker CPU on the ticket 05 workload, about 30 percent of a Unified rebuild of 124 to 167 ms.

The ticket 05 triage profile put its time in `addSourceRow` (the `SourceRowKey` map) and in the `NavigationIndex` owner maps (`getOrPutContext`, `grow`, and `NavigationIndex.add`).
Hash map growth was about 25 of its 555 samples, so a size known before the build cannot remove most of the cost.

## Method

Use the workload and the measurement method of ticket 05, with `[DEBUG-t09]` timing marks. Profile the phase first, and name the limiter before a change.

## Acceptance criteria

- [ ] Every Search projection result is the same as before: the source rows, the owners, and the navigation rows.
- [ ] The projection phase of a Unified disclosure toggle costs at least 40 percent less worker CPU than the baseline of the same run.
- [ ] `zig build test` passes.
