# 10: Require the cell metrics of every Buffer build

Status: ready-for-agent
Blocked by: none

## Summary

`CellMetrics.bytes` counts one cell per byte. The app measures each grapheme through vaxis with `terminal_cell_metrics` in `src/tui/terminal_cell_metrics.zig`.
A benchmark that measures with `CellMetrics.bytes` misses the vaxis cost.

[Ticket 05](05-make-a-buffer-rebuild-faster.md) found three cases of this mistake in `src/benchmark/`.
It added `tools/check_benchmark_metrics.py`, which rejects `.bytes` in `src/benchmark/` and `src/benchmark_buffer_search.zig`.
The check cannot see two other forms of the mistake:

- A build that omits `cell_metrics` gets the `.bytes` default of `BuildOptions` in `src/tui/buffer.zig` or of `Dependencies` in `src/tui/presentation.zig`.
- Benchmark code that lives outside the checked paths uses `.bytes`.

Both forms are live today in the Buffer Search benchmark (`zig build bench-buffer-search`).
Its code is `benchmarkBufferSearch`, `benchmarkInitialSession`, and `benchmarkDisclosureHandoff` in `src/tui/presentation.zig`.
Four `Presentation.init` calls there take the `.bytes` default, and `benchmarkInitialSession` passes `.bytes` to `Published.create` explicitly.
So this is the fourth case of the class, and the lint cannot catch it.

A required field alone does not fix the class.
`Published.create` already requires its metrics, and the benchmark wrote `.bytes` explicitly.
The fix must also make `CellMetrics.bytes` unreachable outside a test build.

## Evidence

Site counts at `60d7553`:

| Site | Count | Where |
| --- | --- | --- |
| `.bytes` defaults | 2 | `BuildOptions.cell_metrics` (`src/tui/buffer.zig`), `Dependencies.cell_metrics` (`src/tui/presentation.zig`) |
| `Presentation.init` calls that take the default | 464 | 451 in test blocks of `presentation.zig`, `presentation_runtime.zig`, `render.zig`, and `selected_version_hardening_test.zig`. 9 in test helper functions of `presentation.zig`. 4 in the Buffer Search benchmark functions of `presentation.zig`. |
| `Presentation.init` calls that name the metrics | 6 | `src/tui/app.zig` (the app) and 5 tests |
| `buildWithComments` calls that take the default | 97 | 92 in tests of `main.zig`, `buffer.zig`, and `render.zig`. 3 in `src/benchmark/` (`buffer_projection.zig`, `p1_actions.zig`, `span_projection.zig`). 2 in helpers, which include `buffer.build`. |
| `buildSearchCandidates` calls that take the default | 2 | tests of `buffer.zig` |
| `buffer.build` calls (it passes `.{}`) | about 24 | tests of `buffer.zig` and `render.zig`, and `src/benchmark/side_by_side_matching.zig` |
| Explicit `.bytes` metrics | about 37 | all in tests, except `benchmarkInitialSession` in `presentation.zig` |

The counts come from a script that reads the options argument of each call.

Production exposure:

- The app does not reach a `.bytes` default. `src/tui/app.zig` passes `render.terminal_cell_metrics` to `Presentation.init`, and Presentation passes its `cell_metrics` to every Buffer, visual row, File Tree, and search build.
- The Buffer Search benchmark measures with `.bytes`, as described in the Summary.
- The three `src/benchmark/` Buffer builds that take the default build no ReviewCards. A Buffer build uses `cell_metrics` only for ReviewCards, so these measurements do not change. They must still name the metrics after the change.
- The Buffer Search fixture is printable ASCII. `ascii_is_narrow` is true for `.bytes` and for the terminal metrics, so both take the ASCII fast path of ticket 05. The measured difference can be small (inferred, not measured).

Two Zig 0.16 experiments in a standalone project decide the design:

- `pub const bytes = if (builtin.is_test) value else @compileError(...)` compiles in a test build of a module that imports it. In an executable build, a reference fails with the message.
- A field default of the same form fails every executable build that uses the struct, also when the caller sets the field. So a test-only default is impossible, and the defaults must go.

## Design

1. In `src/tui/cell_metrics.zig`, make `CellMetrics.bytes` exist only in a test build. Outside a test build, a reference is a `@compileError` that says `CellMetrics.bytes` counts one cell per byte and names `terminal_cell_metrics` in `src/tui/terminal_cell_metrics.zig`. Code that must not import vaxis, such as `presentation.zig`, takes the metrics as a parameter.
2. Remove the default of `BuildOptions.cell_metrics` and of `Dependencies.cell_metrics`. Give `buffer.build` a `CellMetrics` parameter.
3. Give `benchmarkBufferSearch` a `CellMetrics` parameter. It passes the parameter to `benchmarkInitialSession`, `benchmarkDisclosureHandoff`, `Published.create`, and every `Presentation.init`. `src/benchmark_buffer_search.zig` passes `render.terminal_cell_metrics`.
4. The four Buffer builds in `src/benchmark/` pass `tui.terminal_cell_metrics`.
5. Make `zig build` compile `bbr-buffer-search-bench`. Today only `zig build bench-buffer-search` compiles it, so CI does not see a compile error in it. A compile dependency of the install step is enough. The benchmark does not need to run.
6. Add `.cell_metrics = .bytes` to each test literal that took the default, and pass `.bytes` to each test `buffer.build` call. Use a codemod, not hand edits. The test widths do not change.
7. Delete `tools/check_benchmark_metrics.py`, `tests/check_benchmark_metrics_test.py`, and their step in `build.zig`. The compile error makes the mistake impossible in every built benchmark. A test can still use `.bytes`, but a test is not a measurement.
8. Rewrite the AGENTS.md row for the benchmark metrics. The new enforcement is the compile error in `src/tui/cell_metrics.zig` and the compile of every benchmark executable by `zig build`. The rule that no file keeps its own copy of the vaxis adapter stays a convention.

`ReviewSearchProjection.cell_metrics` is optional and `render.zig` falls back to the terminal metrics. That fallback is not `.bytes`, so this ticket leaves it.

## Acceptance criteria

- [ ] `BuildOptions.cell_metrics` and `Dependencies.cell_metrics` have no default. A literal without the field fails to compile.
- [ ] A reference to `CellMetrics.bytes` outside a test build fails to compile, and the message names `terminal_cell_metrics`. Proof: restore the old `.bytes` argument of `Published.create` in `benchmarkInitialSession`, and `zig build` fails with that message.
- [ ] `zig build` compiles `bbr-buffer-search-bench`.
- [ ] The Buffer Search benchmark and every Buffer build in `src/benchmark/` use the terminal metrics.
- [ ] `tools/check_benchmark_metrics.py`, its test, and its `build.zig` step are gone. The AGENTS.md row names the compile error as its enforcement.
- [ ] The completion records `zig build bench-buffer-search` before and after the change. It says that earlier Buffer Search numbers measured `CellMetrics.bytes`.
- [ ] `zig build`, `zig build test`, and `python3 tools/check_agent_docs.py` pass.

## Comments

### 2026-11-13 triage

Decision: `ready-for-agent`.

The class has a fourth live case that the lint cannot see: the Buffer Search benchmark in `src/tui/presentation.zig` measures with `.bytes`, through four defaults and one explicit argument.
A required field alone does not fix it, because one of the five sites writes `.bytes` explicitly.
A test-only `CellMetrics.bytes` makes the mistake a compile error in every built benchmark, so the lint becomes redundant and goes.
A test-only default was the cheaper design, but a Zig 0.16 experiment shows that such a default fails every executable build. So the defaults must go.
A shared test helper does not reduce the edits, because each literal must change anyway.
The edit count is large, about 590 call sites in about 15 files, but each edit is mechanical, so a codemod does the work.
