Type: grilling
Status: resolved
Blocked by: 01

# Define Review Search Matching and Ordering

## Question

How should Review Search use fuzzy matching while returning one exact, selectable source or authored occurrence per result?

Define the fuzzy candidate unit, occurrence extraction, score, tie order, smart-case behavior, multiword behavior, and stable ordering while results stream. Prevent one fuzzy subsequence from creating ambiguous or excessive occurrences. Preserve exact source or ReviewBody ownership, line, column, and matched ranges. Define how equivalent unchanged old and new occurrences become one version-neutral result.

## Answer

### Candidate and query

Review Search evaluates each semantic logical line as one candidate. A source candidate belongs to one File version relation and source line. An authored candidate belongs to one ReviewBody owner and logical body line.

The complete nonempty query is one ordered fuzzy subsequence. Review Search does not split the query into terms. Spaces and punctuation are query scalars and must match corresponding scalars in the candidate. This matches Telescope's default `current_buffer_fuzzy_find` behavior rather than its separate whitespace-splitting substring matcher.

Review Search applies the smart-case contract from [Define Search Corpus and Occurrence Identity](01-define-search-corpus-and-occurrence-identity.md). Matching decodes the query and candidate as Unicode scalars, applies one-scalar case folding when the query has no uppercase scalar, and does not normalize Unicode.

### One occurrence per candidate

A matching candidate produces exactly one Search Occurrence. The occurrence uses the best fuzzy alignment for the complete query. Repeated text and alternate subsequence paths do not produce more results from the same logical line.

The matcher retains every matched scalar's half-open UTF-8 byte range. It combines adjacent ranges for storage. A ReviewBody maps semantic ranges back to authored UTF-8 ranges, including separate ranges when zero-width Markdown delimiters interrupt one semantic match.

### Score

M21 uses Telescope's default `fzy` score behavior as the reference, adapted from bytes to Unicode scalars and from unconditional case folding to the agreed smart-case rule.

The score gives the strongest preference to an exact whole-line match. It then rewards consecutive query scalars, path-separator boundaries, word boundaries, lower-to-upper boundaries, and dot boundaries. It penalizes leading, inner, and trailing gaps. The matcher uses the original candidate scalars to detect boundaries after it applies case folding for equality.

The implementation will add a pure Unicode `fzy`-style matcher. It will not add a second fuzzy-search dependency. The existing `zf` dependency remains for the PullRequest Picker and File finder. Its byte-based ASCII case handling cannot satisfy the Search Occurrence Unicode contract.

### Result order

Review Search sorts matches by the following keys:

1. Better `fzy` score.
2. Shorter candidate length in Unicode scalars.
3. Canonical corpus order.

Canonical corpus order uses Diff File order, version-neutral before old before new, source line order, and authored ReviewBody order. The score has no source or ReviewBody bonus. The final corpus key only makes exact ties deterministic.

Each streamed publication globally sorts every available occurrence with this tuple. Arrival order never affects the result order. A publication retains the selected Search Occurrence by identity, even when a new better result moves above it.

### Version-neutral occurrences

Review Search coalesces old and new source matches only when the authoritative Diff maps the lines as unchanged. The mapped line text and every matched UTF-8 range must also agree. Text equality without a Diff-proven unchanged relation is not enough.

The resulting version-neutral Search Occurrence keeps both exact source locations. It has one score, one result row, and one place in the result count. Changed, unmatched, or differently ranged old and new occurrences remain separate.
