# 20: Keep the cursor on a Whole File gap Line after a rebuild

Status: needs-triage
Blocked by: none

## Summary

In the Whole File scope, the cursor on an unchanged Line outside a Hunk goes to the top of the Buffer after an unrelated rebuild, for example a File Enrichment of another File.

The cursor restore finds the cursor row by its `RowOwner`.
For a Line, the owner is a `*const bbr.diff.Line`.
`spliceSide` in `src/tui/buffer.zig` creates each gap Line again in each Buffer build, with the allocator of that build.
So the next Frame has no row with the same pointer.
`NavigationIndex.find` gives null, and `frame.NavigationAnchor.resolve` falls back to the top of the Buffer.

The same gap applies to `BufferSearchInput.start` of [ticket 19](19-remap-the-buffer-search-input-origin-after-every-rebuild.md): a start on a gap Line resolves to the top after a rebuild.
An anchor holds the pointer after its Frame is freed.
The code only compares the pointer. It never reads through it.
But a later Frame can allocate another Line at the same address.
Then the anchor resolves to that Line.
That last effect is inferred from the code. No test showed it.

## Evidence

A throwaway test in `src/tui/presentation.zig` at commit `542fc7b` (and again with the ticket 19 fix) did these steps:

1. `testBufferSearchStartSession(true)`, 100 × 40, and `cycle_scope` twice to the Whole File scope.
2. A File Enrichment of File 0 with the content `a`, `zz1`, `zz2`, `zz3`, `zz4`, `b`.
3. Move the cursor to the row of the gap Line `zz2` (row 3, `in_hunk == false`).
4. A File Enrichment of File 1, then complete the queued work.

Output:

```
[PROBE] gap row 3 in_hunk=false
[PROBE] after other-File enrichment cursor 0 text -
```

File Enrichment runs in the background while the user reads, so the real user can reach this state.
No live run was made.

## Open questions

- Which identity of a gap Line survives a rebuild: the File, the side, and the line number, or a Session-owned Line from the File Enrichment?
- Does `VersionRestoration`, which already restores by line number, give the precedent?
