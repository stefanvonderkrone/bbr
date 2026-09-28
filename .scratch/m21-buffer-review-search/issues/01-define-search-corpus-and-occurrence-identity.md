Type: grilling
Status: resolved
Blocked by: none

# Define Search Corpus and Occurrence Identity

## Question

What semantic text belongs to Buffer Search and Review Search, and what stable identity names one occurrence?

Define source and authored-body inclusion across Unified and SideBySide Layouts, all Scope settings, hidden disclosures, old and new File versions, and equivalent unchanged content. Define Unicode matching and exact line and column coordinates. Cover binary Files, invalid UTF-8, unavailable versions, generated Presentation text, wrapped visual rows, multiline ReviewBodies, and Session replacement.

## Answer

### Buffer Search corpus

Buffer Search searches semantic text owned by the current Buffer. Layout, Scope, and File isolation define which source and authored owners belong to that Buffer.

- Search every old-side and new-side source Line in the Buffer. Count shared context once in Unified and SideBySide Layouts.
- Search hidden Fold Lines and every Comment, Reply, and Draft body owned by the Buffer. A collapsed Thread or ReviewCard does not remove its body from the corpus.
- Search complete File content only when the current Buffer owns that content. Buffer Search does not start File Enrichment.
- Count one semantic Line once when wrapping projects it through multiple visual rows.
- Exclude File headers, paths, gutters, Hunk headers, borders, status text, section titles, disclosure labels, ReviewCard headers, AnchorSnapshots, and all other generated Presentation text.

### Review Search corpus

Review Search searches the complete Review rather than the current Buffer. The same contract applies to a PullRequest and a LocalReview.

- Search both complete text versions of every changed File. Selected Version does not limit the corpus.
- Search every Comment, Reply, and Draft body at Review, File, and inline scope. Include resolved, outdated, unavailable, and collapsed items.
- Exclude Deleted Comments because they have no authored body. Exclude File paths as occurrences. The existing File finder owns path search.
- An absent, binary, invalid UTF-8, or unavailable File version contributes no text occurrence. Later tickets define how Review Search reports these states without discarding usable results.
- Keep changed old-side and new-side occurrences separate. Coalesce old and new occurrences only when the authoritative Diff proves that they refer to the same unchanged text and their match ranges agree. A version-neutral occurrence retains both exact source locations.

### ReviewBody text

Search the semantic ReviewBody, not raw Markdown or projected ReviewCard rows.

- Include prose, heading text, Suggestion source, link labels, and visible link destinations.
- Treat Markdown formatting delimiters as zero-width. A match can cross emphasis and other formatting delimiters.
- Treat generated text as a boundary. A match cannot cross a generated Suggestion label, disclosure label, ReviewCard header, or generated link punctuation.
- Keep each authored logical line separate. A match cannot cross a line ending.

### Text matching

All searchable text and query input must be valid UTF-8. Buffer Search uses literal matching. Review Search applies its later fuzzy policy to the same line-local corpus.

- Any uppercase Unicode scalar in the query makes matching case-sensitive.
- A query with no uppercase Unicode scalar uses one-scalar Unicode case folding, like Neovim smart-case search.
- Matching does not normalize Unicode. Canonically equivalent but differently encoded text does not match.
- Literal matching selects leftmost, non-overlapping occurrences on each logical line.
- Source and authored line endings do not participate.

Neovim documents the uppercase smart-case rule in its [pattern documentation](https://neovim.io/doc/user/pattern/). Neovim treats combining-character equivalence as a separate opt-in rule, so M21 does not apply it.

### Search Occurrence identity

A Search Occurrence belongs to one Session Epoch. It survives Buffer rebuilds, Layout and Scope reprojection, disclosure changes, and wrapping changes. Session replacement expires it.

A source Search Occurrence identifies:

- the File;
- the old version, the new version, or a Diff-proven version-neutral relation;
- the exact old and new paths and line numbers that apply;
- one or more half-open UTF-8 byte ranges in the Line text.

An authored Search Occurrence identifies:

- its CommentId or TempId owner;
- its one-based logical body line;
- one or more half-open UTF-8 byte ranges in the authored body.

Multiple ranges let one ReviewBody occurrence cross zero-width Markdown delimiters while retaining exact authored locations. A body mutation removes obsolete occurrences and creates identities for the new body.

The Overlay displays one-based Unicode scalar columns. Tabs and combining scalars each count as one source scalar. Rendering and navigation use the retained UTF-8 ranges, so terminal cell width does not change occurrence identity.
