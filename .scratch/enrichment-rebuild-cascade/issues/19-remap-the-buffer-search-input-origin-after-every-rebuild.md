# 19: Remap the Buffer Search input origin after every rebuild

Status: needs-triage
Blocked by: none

## Summary

While the Buffer Search input is open, `acceptViewBuild` in `src/tui/presentation.zig` remaps `input.saved_navigation` and `input.origin` only for a `.view` or `.cache_update` build.
An `.enrichment`, `.draft_save`, or `.draft_mutation` build keeps the old visual row numbers.
When the rebuild adds or removes rows above the cursor, these rows name a different place in the new Buffer.

The real user can reach this state.
File Enrichment can finish while the input is open.

## Evidence

The triage of [ticket 18](18-decide-the-buffer-search-input-occurrence-rule-after-a-rebuild.md) found this defect with a throwaway test through `Presentation` at commit `cf2d34c`.

Steps: in the Whole File scope of the ticket 16 test, put the cursor on the header of File 1 (`a.txt`, row 2), open the input, type `zz`, and deliver a File Enrichment of File 0 that adds rows above.

| Step | Cursor row | `input.origin` | `input.saved_navigation.cursor` | Row of the File 1 header |
| --- | --- | --- | --- | --- |
| Before the input | 2 | | | 2 |
| After the enrichment | 13 (the preview, kept) | 2 | 2 | 7 |
| After Escape | 2, in File 0 | | | 7 |

Escape puts the cursor in File 0, not on the File 1 header where the user opened the input.
A later keystroke that loses the preview also computes the preview from the stale `input.origin`.
The preview itself stays on the correct match.

## Expected behavior

After any rebuild that is admitted while the input is open, Escape restores the cursor to the place where the user opened the input.
A preview that a later keystroke computes starts from that place.

## Comments
