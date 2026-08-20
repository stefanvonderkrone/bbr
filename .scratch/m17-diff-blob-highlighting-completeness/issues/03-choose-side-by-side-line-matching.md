# Choose side-by-side line matching

Type: prototype
Status: resolved
Blocked by: none

## Question

What tested line-level matching strategy should replace index-based removed/added pairing inside change blocks so insertions, deletions, replacements, repeated lines, and blank lines remain aligned in SideBySide Layout without changing Diff anchoring or Unified rendering?

## Answer

- For each maximal removed-then-added change block, use order-preserving dynamic programming to project its Lines into `LinePair`s. This is a Presentation-only operation over the existing Line pointers; it does not change the Diff, Unified Layout, line numbers, or Anchors.
- Score a possible pair with the existing token-level longest-common-subsequence vocabulary, using symmetric similarity: twice the common byte count divided by the combined old/new byte count. Identical Lines, including two blank Lines, score `1`; a blank and non-blank Line score `0`.
- A pair is eligible at similarity `>= 0.5`. Minimize total alignment cost with eligible pair cost `1 - similarity` and one-sided gap cost `1`. This preserves order, aligns related replacements, and leaves inserted, removed, or unrelated Lines opposite an empty side.
- Resolve equal-cost paths deterministically: prefer exact pairs, then the earliest eligible pair in old/new order. Repeated Lines and blank Lines must produce stable output across Buffer rebuilds.
- Compute IntraLineSegments only for accepted pairs. Unmatched Lines keep whole-Line styling. Weave each accepted or unmatched underlying Line exactly once, so existing old/new Anchors and inline Comments remain unchanged.
- Required fixtures cover an insertion before related edits, a deletion between related edits, a related replacement, an unrelated replacement, unequal side lengths, repeated Lines, blank Lines, and identical input. Each fixture checks pair identity and order; Buffer tests also check Anchor and inline Comment placement, while Unified output remains byte-for-byte unchanged.
- Prototype: local branch `prototype/m17-side-by-side-line-matching`, commit `70d7901`, file `src/tui/side_by_side_matching.prototype.html`.
