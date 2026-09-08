# Limit Highlight query ranges

Type: task
Status: resolved
Blocked by: 22

## Question

If Action 20 passes the P2 gate, can visible-range queries satisfy WholeFile and Review Search contracts, or must measured correctness needs reject this optimization?

## Answer

Reject Action 20 under the current Highlighter contract. The 2 MiB JavaScript benchmark confirms a material 913,664,208 ns cost, but a visible-range query cannot produce complete File Spans.

Tree-sitter returns only matches that intersect the byte range. Non-local patterns also reduce the range optimization. File Enrichment retains one Highlighting result before Presentation chooses the DiffPane scope. WholeFile later projects lines outside the hunks, and Review Search crosses File boundaries without a stable viewport.

Supporting partial results would require a new range-aware Highlighter contract, result completeness state, and re-query rules. That larger change is not justified by Action 20. No production code changed. `zig build test --summary all` passes all 708 tests.
