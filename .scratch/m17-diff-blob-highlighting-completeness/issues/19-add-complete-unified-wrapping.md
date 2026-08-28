# 19 — Add Complete Unified Wrapping

**What to build:** Let reviewers toggle display-cell-aware wrapping for Unified Diff Lines without changing source bytes, Selection meaning, or Anchor identity.

**Blocked by:** 18 — Project Diff Lines as Visual Rows.

**Status:** done

- [x] The configurable `toggle_diff_wrap` Action defaults to `w`, starts disabled at launch, and persists across Buffer rebuilds and Session replacement in one process.
- [x] Wrapping prefers Unicode whitespace and otherwise breaks at a grapheme boundary without splitting a visible character.
- [x] Continuation rows have blank gutters and preserve syntax foreground, diff background, IntraLineSegment emphasis, and Selection styling.
- [x] Motions, Counts, paging, scrolling, and semantic jumps operate correctly over visual rows.
- [x] Selection deduplicates continuations, and a Comment or Suggestion from any continuation uses the underlying Hunk Line Anchor.
- [x] Resize and reprojection restore the cursor by semantic owner and source offset with the specified fallbacks; failure preserves the prior complete Frame.
