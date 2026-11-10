# Ban error comparisons and require a Canceled prong

Status: resolved
Type: implementation
Blocked by: 01
Parent: ../PRD.md

## Goal

Two checks keep the compiler able to see each error name.

1. No production code compares an error with `==` or `!=`.
   `err == error.X` compiles against `anyerror` and silently widens the error set.
   The compiler then cannot say that the name is impossible.
   TigerBeetle bans this pattern in `src/tidy.zig` (0.17.0, `ac790315`).
2. A `catch` switch on an error set that contains `error.Canceled` names `error.Canceled` in its own prong.
   The standard library says that ignoring `error.Canceled` "is usually a bug" (`std/Io.zig:1181-1188`).
   The prong returns the error, calls `io.recancel()`, or sits under `io.swapCancelProtection(.blocked)` and writes `unreachable`.

## Known sites

- `src/tui/presentation.zig:1325`: `if (err == error.OutOfMemory) .out_of_memory else .buffer_build_failed`.

## Work

1. Add the `== error.` and `!= error.` ban as a line check in `tools/`. It reads Zig source through `zig_files` in `tools/source_lines.py` with `literals=False`. Skip `test` blocks.
2. Convert each existing comparison to a `switch` on the error.
3. For the Canceled prong, find which callee error sets contain `error.Canceled`. A regex cannot see error sets. Decide between a list of known cancelable calls and a review convention. Record the decision in this issue.
4. Add regression tests and rows to the `AGENTS.md` rule table.

## Acceptance

- `zig build test` passes.
- The old line at `src/tui/presentation.zig:1325` fails the new check.
- The rule table names each check, or marks the Canceled rule "Convention (no check)" with its reason.

## Completion

Production Zig no longer compares an error with `==` or `!=`. Each site switches on the error. `tools/check_error_comparisons.py` reads Zig through `zig_files` with `literals=False`, skips `test` blocks, and `zig build test` runs it. `tests/check_error_comparisons_test.py` rejects the old `src/tui/presentation.zig` line and an inequality. A comparison in a test, a string, or a comment still passes. Test comparisons in `src/api/files.zig` and `src/bitbucket/client.zig` stay.

The Canceled rule is a convention with no line check. A line check cannot see an error set. A list of call names misses a `try` through another function. A `switch` with no `else` already requires a named `error.Canceled` prong. `std.Io.sleep` and `Group.await` return only `error{Canceled}`, so an `else` on those calls does not compile. The prong returns `error.Canceled`, calls `io.recancel()`, or is `unreachable` under `io.swapCancelProtection(.blocked)`.

- `da46dfd` converts the TUI. A canceled blob retry in `src/tui/file_enrichment.zig` returns `error.Canceled` and does not send the second request. The catch baseline falls from 37 to 36.
- `ee24f4e` converts `main`, the api verbs, config load, and stdout. stdout maps `error.WriteFailed` through the file error and returns every other error.
- `1a6b7f6` converts the Bitbucket client, auth, and types. `Group.await` cleanup calls `io.recancel()`. The benchmark sleep returns `error.Canceled`.
- `b5d148b` adds the check, the regression tests, and the `build.zig` step.
- `0ebca1a` adds the `AGENTS.md` rows and the same rules in `.agents/skills/zig/errors.md`.

A canceled Theme save was mapped to the read failure after `persistTheme` started returning `error.Canceled`. The status said `config.toml could not be read`. The follow-up `f709149` maps `error.Canceled` to the write failure, so the status says `config.toml could not be written`, and the handler calls `io.recancel()` after the diagnostic record. A canceled read takes the same status. Before this branch, a canceled read already used the read failure text.

Checks:

- `zig build test` after the Canceled edits: exit 0. `47/47 steps succeeded; 1546/1546 tests passed`. Log: `/private/var/folders/dq/11fgn5lj5l539gh02ty2qjv40000gn/T/opencode/issue04-zig-test-2.log`.
- The same command after the Theme save fix: exit 0. `47/47 steps succeeded; 1546/1546 tests passed`. Log: `/private/var/folders/dq/11fgn5lj5l539gh02ty2qjv40000gn/T/opencode/issue04-zig-test-3.log`.
- The red compile for the shadowed sleep capture is `/private/var/folders/dq/11fgn5lj5l539gh02ty2qjv40000gn/T/opencode/issue04-zig-build-6.log`.
- `python3 tools/check_diagnostics.py` passes. The catch baseline is 36. The record baseline is unchanged.
- `python3 tools/check_agent_docs.py` passes.

Review: Claude Opus 5.5 read the decision log and the commits. It found the Theme save mislabel. That fix is in the follow-up commit. The picker tick and the `Group.await` cleanups have no cancel test. The blob cancel test covers the 503 sleep, not the transport-error sleep. The five commits were cut from one green tree and were not built one by one.

## Comments

### 2026-11-09 re-verification

Commit `50a69d1` restores cancellation handling in the wait, blob, mention, account, auth permission, Git metadata, and benchmark auth paths.
It also propagates hidden `OutOfMemory` errors, as the request requires. Other fallback behavior stays unchanged.
Canceled workers retain their retirement completions. File Enrichment joins the remaining side and rearms a secondary cancellation when necessary.

Eleven new tests fail on detached `74a091a` and pass with the fix.
They cover retry suppression, canceled reads, worker retirement, account and mention acquisition, Git failures, and auth file state.
Benchmark auth resolution has compile coverage only. Its `main` has no injected auth seam, so selecting that error needs a new production interface.
No other listed site was dismissed as unreachable.

The logs are `red-final.log` and `green-final.log` under `/private/var/folders/dq/11fgn5lj5l539gh02ty2qjv40000gn/T/opencode/item-b-evidence/`.
The cancellation fixes keep the existing catch counts. The independent Highlighting fix `defe67a` lowers the baseline from 35 to 33.
The record baseline stays empty. No visible text literal changed.

Review found a second wait retirement gap after a successful sleep.
Commit `c52f4ea` protects that completion when cancellation meets a full event queue.
The new test fails on detached `50a69d1` and passes with the fix. It checks one completion and zero remaining tracked work.
The logs are `wait-retirement-red-50a69d1.log`, `wait-retirement-green.log`, and `wait-retirement-full.log` in the parent evidence directory.
The full native suite passes all 1,596 tests.

### 2026-11-09 benchmark cancellation follow-up

F18 is valid. `runSample` counted a canceled enrichment as a failure and scheduled another File.
It now returns `error.Canceled` before it changes the failure count or schedules another File.
Cleanup cancels the remaining tasks and releases every completed result in the Select queue.
The Select buffer holds at least as many results as the active task limit.

The benchmark has no test module in `build.zig`, so this path has compile coverage only.
`zig build bench-file-acquisition -- invalid` compiles the executable, then returns the expected `InvalidArguments` error.
The log is `f18-benchmark-compile.log` under `/private/var/folders/dq/11fgn5lj5l539gh02ty2qjv40000gn/T/opencode/pr22-d-evidence/`.
No runtime test reaches a canceled benchmark sample.

### 2026-11-09 File Enrichment join follow-up

F19 is valid. A side can return `error.Canceled` without cancellation of the worker that joins it.
`Future.await` returns the child's result. It does not make the child's cancellation request the worker's own request.
The installed Zig 0.16 `Threaded.recancelInner` requires the current task to hold the consumed cancellation state.
The old `dropSide` called `io.recancel()` on a child-only error and caused a panic.

The join now returns `error.Canceled` without `recancel` when either side returns cancellation.
It releases the sibling result and records a displaced OutOfMemory failure once through that side's own diagnostic slot.
It adopts old-side evidence only when it returns the old-side error.
The join no longer needs the `dropSide` helper.

The child-only cancellation test uses the real I/O implementation, not a fake `recancel` function.
It checks the returned cancellation, one old-side OutOfMemory record, and no old-side evidence in the parent slot.
A second test cancels the worker during the remaining side's read and checks cancellation and completed cleanup.
The existing two-OutOfMemory test still checks one record per side.

The detached `c8eab63` reproduction exits 1 and panics in `dropSide` through `Threaded.recancelInner`.
The fixed diagnostic tests exit 0. The full suite exits 0 with `49/49 steps succeeded; 1597/1597 tests passed`.
The logs are `f19-red.log`, `f19-green.log`, and `f19-full.log` under `/private/var/folders/dq/11fgn5lj5l539gh02ty2qjv40000gn/T/opencode/pr22-d-evidence/`.
The catch baseline stays at 33. The record baseline stays empty.
