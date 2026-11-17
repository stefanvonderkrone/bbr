# 20: Keep the cursor on a Whole File gap Line after a rebuild

Status: resolved
Blocked by: none

## Summary

In the Whole File scope, the cursor on a gap Line goes to the top of the Buffer after an unrelated rebuild.
A gap Line is an unchanged Line outside a Hunk (`in_hunk == false`) that the Buffer build makes from the File blob.
The rebuilds that show the defect include a File Enrichment of another File, a resize that changes the width, and the deletion of a Draft whose next row is a gap Line.
The DiffPane scrolls to the top, and the active File and the File Tree cursor change to the first File.
No message tells the user that the cursor moved. This part is inferred from the code: the restore path sets no message.

The cause is the identity of the row.
`frame.RowOwner.line` holds a `*const bbr.diff.Line`.
A Hunk Line lives as long as the Session, so its pointer identifies it in every Frame.
`spliceSide` in `src/tui/buffer.zig` allocates each gap Line again in each Buffer build, from the arena of that build.
So the pointer of a gap Line identifies it only in the Frame that made it.
Every lookup by row identity misses a gap Line after a rebuild, and `frame.NavigationAnchor.resolve` falls back to the top of the Buffer.

The fix holds a gap Line by its File and its line numbers, a value that every build of the same Session derives from the source.

## Evidence

All evidence is from throwaway tests through `Presentation` in a detached worktree at commit `e4c7d46`.
The setup was `testBufferSearchStartSession(true)` (3 Files), 100 × 40, `cycle_scope` twice to the Whole File scope, and a File Enrichment of File 0 with the content `a`, `zz1`, `zz2`, `zz3`, `zz4`, `b`.

### Reproduction

| Case | Before the rebuild | After the rebuild and the queued work, at `e4c7d46` | With the sketch below |
| --- | --- | --- | --- |
| A File Enrichment of File 1 | Cursor on the gap Line `zz2`, row 3, File 0 | Cursor 0 (the File 0 header), scroll 0 | Row 3, `zz2` |
| A width resize to 90 × 38 | The same | Cursor 0, scroll 0 | Row 3, `zz2` |
| SideBySide, 140 × 40, a File Enrichment of File 1 | Cursor on the `zz2` pair, row 4 | Cursor 0, scroll 0 | Row 4, `zz2` |
| Buffer Search input opened on a gap Line, a File Enrichment, then Escape | Input start on `zz2`, row 3 | Cursor 0 | Row 3, `zz2` |
| File 2 also enriched (`a`, `yy1`, `yy2`, `yy3`). Input start on `yy2` in File 2. A File Enrichment of File 1 and 6 width resizes, then Escape | Row 16, File 2 | Cursor 0, active File 0 | Row 21, `yy2`, File 2 |
| A Draft on line 1 of File 0, so the row after its card is the gap Line `zz1`. Delete the Draft and confirm | Cursor on the Draft header, row 2 | Cursor 0 | Row 2, `zz1` |

The last case is a second instance of the same fault.
`SurvivingRow.line` in `src/tui/presentation.zig` holds the pointer of the first surviving Line after the deleted card.
For a gap Line, `followSurvivingRow` finds no row, and the cursor stays where `restoreNavigationIndexed` put it, the top of the Buffer.

A height-only resize does not rebuild the Buffer (`resize` calls `resizeHeight`), so it keeps the cursor.

### The inferred wrong-line match

An anchor keeps the pointer after its Frame is freed, and a later build can allocate another gap Line at the same address.
Then the anchor would resolve to that other Line.
No test showed this.
The Buffer Search input cases above ran 2 rebuilds with `std.testing.allocator` and 7 rebuilds with `std.heap.smp_allocator` as the `Presentation` allocator. The start always fell back to the top.
The cursor restore of an admission cannot match a reused address: it captures the anchor from the published Frame, which stays alive while the candidate build allocates.
Only an anchor captured in an earlier Frame, such as `BufferSearchInput.start` or `DisclosureBuild.restore_navigation`, could meet a reused address.
The fix removes the risk for gap Lines, because their identity holds no pointer into a build.

### Reachability

A real user reaches the defect with the default keys:

1. Press `f` twice for the Whole File scope.
2. Move to an unchanged Line outside a Hunk in a File whose content has loaded.
3. Wait while File Enrichment loads another File in the background, or resize the terminal width.

File Enrichment runs in the background while the user reads, and an evicted File loads again later, so the rebuild comes without user input.
The Draft deletion case is reachable through the delete confirmation in the Whole File scope.
No live run was made.

## Expected behavior and its precedent

After a rebuild that keeps the Whole File scope, the cursor stays on the same source Line: the same File, side, and line number, with the same viewport offset.
The Selection mark and the Buffer Search input start keep their Lines the same way.
After a Draft deletion, the cursor goes to the first surviving row after the card, also when that row is a gap Line.

The precedent, so no human answer is needed:

- The Diff glossary defines a gap Line as a Line synthesized from the File blob, with `old_no` or `new_no`. Its source position is its identity.
- `VersionRestoration` restores the cursor across a Selected Version change to a source row of the same File, by its Hunk Line and source offset or else the nearest row. A File with no source row falls back to its File header.
- `ReviewLocation` (the `Review recovery` rows of `AGENTS.md`) holds a source row as `{ side, line, source_offset }` and the File path, not as a pointer or a File index from an earlier Session.
- The Navigation Anchor glossary entry says that any later Frame of the same Session resolves the anchor. Today that is false for a gap Line.

The fallback for a row that a Frame really lost stays the top of the Buffer.
This ticket does not change it, because every reproduced case lost the row only through the unstable identity.

## Root cause

The identity is unstable by construction. `resolve` and `NavigationIndex.find` look the row up by the correct key, but the key is a pointer into the arena of one Buffer build.
A special case in `resolve` would not reach `SurvivingRow`, and it would keep the address-reuse risk.

A Session-owned gap Line from the File Enrichment is not a stable identity either.
`file_enrichment.clearText` evicts File content under the cache budget, and a later File Enrichment loads it again.
So a pointer to Session-owned gap Lines would change after an eviction, and a freed array could give its address to another Line.

## What to build

1. In `src/tui/frame.zig`, add a public `LineOwner` and make `RowOwner.line` hold it:

   ```zig
   /// The identity of a Line row. A Hunk Line lives as long as the Session. Each
   /// Buffer build makes its own Whole File gap Lines, so a gap Line is held by
   /// its File and line numbers.
   pub const LineOwner = union(enum) {
       hunk: *const bbr.diff.Line,
       gap: struct { file: *const bbr.diff.File, old_no: u32, new_no: u32 },

       pub fn of(file: ?*const bbr.diff.File, line: *const bbr.diff.Line) LineOwner { ... }
       /// The owner of another Line in the same File, such as the other half of a pair.
       fn sibling(self: LineOwner, line: *const bbr.diff.Line) LineOwner { ... }
       pub fn eql(a: LineOwner, b: LineOwner) bool { ... }
       pub fn oldNo(self: LineOwner) ?u32 { ... }
       pub fn newNo(self: LineOwner) ?u32 { ... }
   };
   ```

   `of` gives `.hunk` when `line.in_hunk`, else `.gap` with the File.
   The `.line` arm stays, so the checks `owner == .line` in `presentation.zig` and `render.zig` keep their meaning.
2. Give `owner(row, file)` the File of the row. `buildVisualRowsWithOptions` and `buildUnwrappedVisualRows` keep the File of the last `.file_header` row and pass it to `makeVisualRow`, `appendWrappedVisualRow`, and `appendWrappedLinePair`.
   Every Line row of a File follows its header, and `emitWholeFileGap` pairs a gap Line only with a gap Line, so the halves of a pair share the kind of the row owner.
3. In `NavigationIndex.build`, key each half by `row.owner.line.sibling(half.line)`. In `lineRangeForOwner`, take a `LineOwner` and compare each half the same way.
4. In `src/tui/presentation.zig`, change `SurvivingRow.line` to `frame_mod.LineOwner`. The deletion-row loop in `SearchProjection` keeps the File of the last `.file_header` row and passes it to `survivingRowIdentity(row, file)`.
   `sourceLineForVisual` reads the Line from `row.yank_candidates` instead of the owner, and the search snapshot rows read `line.oldNo()` and `line.newNo()` from the `LineOwner`.
5. Update the tests that build an owner from a Line pointer: `.{ .line = .{ .hunk = &line } }` in `frame.zig`, and `owner.line.hunk` in the `render.zig` and `presentation.zig` tests.
6. Update the Navigation Anchor entry in `src/tui/GLOSSARY.md`: a Line row is held by its Hunk Line, or a Whole File gap Line by its File and line numbers.
7. Add a row to the rules table in `AGENTS.md`: a `RowOwner` holds only identities that outlive a Buffer build, Session-owned pointers or values, and a Whole File gap Line is held by its File and line numbers. Name the reproducing tests in the enforcement column.

A sketch of steps 1 to 5 in a detached worktree added about 80 production lines and removed about 30.
With the sketch, the 6 reproducing cases of the Evidence table kept the cursor on its Line.
`zig build test --summary all` passed with exit 0: 56/56 steps and 1657/1657 tests (1651 existing tests and the 6 probes).
`zig fmt --check src build.zig tests` passed.

## Acceptance criteria

- [x] Tests through `Presentation` in the `M21 kernel` group reproduce these cases. Each test puts the gap Line in a File after the first File, so that a fall back to the top of the Buffer changes the active File:
  - "M21 kernel the cursor on a Whole File gap Line stays after a File Enrichment of another File"
  - "M21 kernel the cursor on a Whole File gap Line stays after a width resize"
  - "M21 kernel the cursor on a SideBySide Whole File gap Line stays after a File Enrichment of another File"
  - "M21 kernel Buffer Search input Escape returns to its start on a Whole File gap Line after rebuilds"
  - "M21 kernel a Draft deletion puts the cursor on the next Whole File gap Line"

  Each test finds the expected row by its text and line number in the current Frame, not by a fixed number.
  After the rebuild and the queued work, the cursor is on that row, `activeFile()` is its File, and `action_error` is null.
  Each test fails at `e4c7d46`.
- [x] No `RowOwner` built from a Buffer row holds a pointer to a gap Line.
- [x] The `Review recovery` tests, the ticket 16 to 19 tests, and the Selected Version tests pass.
- [x] `zig build test` passes. `zig fmt --check build.zig src tests` passes. `python3 tools/check_agent_docs.py` passes.

## Completion

Commits:

- `8797020` adds the five acceptance tests. Each test fails at that commit with the cursor on row 0 of the first File.
- `d3852da` deletes `frame.SourceMatch` and `frame.projectSourceRanges`. No production code called them, and they keyed search ranges by Line pointer.
- `8975b16` adds `frame.LineOwner` and makes `RowOwner.line` and `SurvivingRow.line` hold it. It also updates the glossary and the `AGENTS.md` rules table, and adds the invariant test "M21 kernel no Line row identity of a Whole File Frame holds a gap Line pointer".
- `e854626` renames the Hunk Line arm to `hunk_line` and splits long sentences in the documents.

The change differs from the sketch in these points:

- The gap arm is `{ file, side, number }`. A gap Line has exactly one line number, so the sketch's `{ old_no, new_no }` could hold states that cannot occur. `LineOwner.of` asserts the one-sided number.
- The Hunk Line arm is `hunk_line`, because `RowOwner.hunk` already names a Hunk header.
- `RowOwner.eql` compares the arm with `std.meta.eql`, so `LineOwner` has no `eql`.
- The Selection mark has no test. `canStartSelection` refuses a Selection on a gap Line in the Whole File scope, so a user cannot put the mark there with `select_down`. The mark resolves through the same `findRow` as the cursor.
- The tests use 10 terminal rows. A Buffer that fits in the DiffPane has scroll 0, so a test at 40 rows cannot see the viewport offset.

The `File` pointer is a stable File identity in one Session. File isolation filters `diff.files` by index and does not copy a File. File Enrichment and its cache eviction change only the enrichment storage. `spliceSide` is the only per-build `model.Line` allocation, and it sets `in_hunk = false`, so a Hunk Line pointer is stable across a File Enrichment.

Checks, all with exit 0:

- `zig build test --summary all`: 56/56 steps, 1654/1654 tests. The count is 1651 existing tests, minus 3 deleted `SourceMatch` tests, plus 6 new tests.
- `zig fmt --check src build.zig tests`
- `python3 tools/check_agent_docs.py`, `check_benchmark_metrics.py`, `check_diagnostics.py`, `check_search_index.py`, and `check_navigation_fields.py`

A live check ran in tmux at 160 × 80 with `bbr local` on a local review. The cursor was on line 6 of `docs/agents/triage-labels.md`, a gap Line in the Whole File scope. Then a background File Enrichment of `src/tui/presentation.zig` arrived, and a width resize ran. A ReleaseSafe build of `dde803e` moved the cursor to `1/41000` on the first File after the File Enrichment, and to `1/4546` after the resize. The build of this branch kept the cursor on line 6 in the same screen row in both cases.

Review: the Standards review found long sentences in the new document text and the arm name `hunk`. Commit `e854626` fixes both. It also noted that four loops track the File of the last File header. That stays, because the visual row projection gets only the Buffer rows. The Spec review found no missing requirement. It noted that the invariant test reads only the visual row owners, and the `AGENTS.md` row now says so.

## Comments

### 2026-11-14, triage

Decision: `ready-for-agent`.

The defect reproduces through `Presentation` for a File Enrichment of another File, a width resize, the SideBySide layout, the Buffer Search input start, and a Draft deletion before a gap Line.
The real user reaches it with the default keys while File Enrichment runs in the background.
The expected behavior has a precedent: the Diff glossary, `VersionRestoration`, and `ReviewLocation` identify a source row by its File, side, and line number.
So the ticket needs no answer from a human.

The ticket first suggested two identities.
A Session-owned gap Line from the File Enrichment is not stable, because cache eviction frees File content and a later File Enrichment loads it again.
The ticket now asks for a value identity derived from the source.
The wrong-line match through a reused address was not observed in up to 7 rebuilds with two allocators. It stays inferred, and the fix removes it.

Mistake class for the `correct` skill: this ticket forms its own class, an identity that points into a per-build allocation.
It is not the class "a stored visual row number outlives its Frame" of ticket 19, because the fault is in the key, not in a stored row number.
The cases found:

| Identity | State |
| --- | --- |
| `RowOwner.line` for a gap Line, read by the cursor restore of every admission, the Selection mark, `BufferSearchInput.start`, and `DisclosureBuild.restore_navigation` | Reproduced |
| `SurvivingRow.line` after a Draft deletion | Reproduced |
| `VersionRestoration.destination_hunk_line` | Holds only a Hunk Line (`in_hunk` check). No gap |
| `DisclosureKey.fold` | A Hunk Line in the Changes scope. No gap |
| `SourceMatch.old_line` and `new_line` | Compared in the Frame that made them. Not checked across builds |

A line check cannot see which allocation a pointer comes from.
The `LineOwner` type puts the rule in one constructor, `LineOwner.of`, and the `AGENTS.md` row of step 7 names the tests.

The probe worktree is deleted. The sketch diff is at `t20-sketch.diff` in the session temporary directory, outside the repo. No live run was needed.
