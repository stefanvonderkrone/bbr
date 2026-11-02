# 09: Fix the M30 review findings

Status: resolved
Blocked by: 06
Spec: [M30 spec](../SPEC.md)

## What to build

Merge `origin/main` into the branch with a merge commit.
Fix each M30 finding of the adversarial review of 2026-10-31.
Fix the M30 parts of the cross-branch findings X-5 and X-6.
Each fix starts with a test that fails on the old code, or with recorded evidence when no failing test is possible.

## Out of scope

- X-2, the Credential transport on main. Another owner fixes `StdHttpClient`.
- X-3, the untrusted bytes that reach std and zigimg decoders.
- M29 ticket 08, the Overview scroll bar mouse target. It waits for triage on the M29 branch.
- Ticket 08 of this directory. It stays as it is.

## Acceptance criteria

- [x] The branch contains `origin/main` through a merge commit.
- [x] Every M30 finding has a fix with a proving test, or a recorded decision.
- [x] `zig build test`, `zig fmt --check build.zig src tests`, and `python3 tools/check_agent_docs.py` pass.

## Completion

### Merge

The merge commit is `45c5f98`. It resolves the conflicts as the recipe `merge-recipes/single-m30.remerge.diff` does.
The recipe has the same parents, so the runner took its conflict files.
Main's help rows and the M30 scroll bar rows both stay in AGENTS.md.
M30 adds no Keymap Action, so `keymap.helpSection` needs no new arm.
The Mouse fixed section in `src/tui/help.zig` gets the entry `track drag`, with the description `jump and drag scroll bar`.
The entry names both effects of a track press, the jump and the Scroll Drag.

### Findings

- M30-1. The test "M30 scrollbar the help Overlay Mouse section names the scroll bar drag" in `src/tui/render.zig` reads the Mouse section of the help lines. Without the entry, it fails. The merge commit holds the fix.
- M30-2, M30-7, and the M30 part of X-5. The help scroll bar gets the `.help` arm of `frame.ScrollBar` with a press and a Scroll Drag (`69a8c06`). The test "M30 scrollbar every layout scroll bar is one arm of frame.ScrollBar" in `src/tui/frame.zig` failed with "expected 3, found 4" before the fix. The test "M30 scrollbar the help track takes a press and a Scroll Drag and the help stays open" failed with a help scroll of 0 after the press. The AGENTS.md row and the GLOSSARY View entry are true again.
- M30-3. The SPEC puts the jump to the item of a pressed mark under Out of Scope. The runner kept the SPEC and narrowed ticket 07 to the mark position. Ticket 10 holds the jump for triage.
- M30-4. `03ef995` deletes `search_ranges_sorted` and the unsorted path in `scroll_marks.project` and in `render.zig`. The oracle test now builds its own linear scan. A mutation of the binary search makes it fail.
- M30-5 and the M30 part of X-6. The test "M30 scrollbar a press off the thumb and a drag that move the scroll repaint each bar" covers every arm (`81d6fa2`, `849647c`). It fails without the `interaction_revision` increment, and also without the increment for the Review Search list only.
- M30-6 and the M30 part of X-6. The tests "M30 scrollbar a press off the thumb centers the pressed cell and clamps at both track ends" and "M30 scrollbar a press on the thumb ends a Review Search double click and a pending version restoration" pin the SPEC offset and both resets (`3158bce`). Four mutations fail them: no centering, no clamp, a kept `last_review_click`, and a kept `version_restoration`.

### Other changes

- `db15376` removes `hits_sorted` from the SPEC.
- `849647c` adds a help fixture to the repaint test. The repaint test loops over every arm, so it needs the help Overlay open for `.help`. Commit `81d6fa2` alone fails on the `.help` arm, because the two fixes ran in parallel.
- Ticket 11 records that the wheel does not scroll the help Overlay. That behavior comes from main.

### Checks

- `zig build test --summary line`: 25 of 25 steps and 1490 of 1490 tests pass.
- `zig fmt --check build.zig src tests`: pass.
- `python3 tools/check_agent_docs.py`: pass.
- Every Zig command ran with HOME and the XDG directories under `$TMPDIR`, no `BITBUCKET_*` variable, and proxies at 127.0.0.1:9.
- No command started bbr or sent a request to Bitbucket.
- Native target: aarch64-macos with Zig 0.16.0.
