# 10: Require the cell metrics of every Buffer build

Status: needs-triage
Blocked by: none

## Summary

`BuildOptions.cell_metrics` in `src/tui/buffer.zig` and `cell_metrics` in the Presentation configuration in `src/tui/presentation.zig` default to `CellMetrics.bytes`.
`CellMetrics.bytes` counts one cell per byte. The app measures each grapheme through vaxis.

[Ticket 05](05-make-a-buffer-rebuild-faster.md) found the class: the visual row and File Tree benchmarks passed `.bytes`, and the comment anchor benchmark took the default, so no benchmark showed the vaxis cost that took 78 percent of the visual row build.
Ticket 05 added `tools/check_benchmark_metrics.py`, which rejects `.bytes` in the benchmark sources.
That check cannot see a build that omits `cell_metrics` and takes the default.

A required field fixes the class at the type level: every caller must name its metrics, and a production build can then refuse `CellMetrics.bytes` with a compile error that names `terminal_cell_metrics`.
The change touches every test that builds a Buffer or a Presentation with the default, so ticket 05 did not make it.

## Acceptance criteria

- [ ] `BuildOptions.cell_metrics` and the Presentation `cell_metrics` have no default.
- [ ] A reference to `CellMetrics.bytes` outside a test fails to compile and names `terminal_cell_metrics`, or the triage records why a test-only form does not work.
- [ ] The AGENTS.md row for the benchmark metrics drops the default from its convention.
- [ ] `zig build test` passes.
