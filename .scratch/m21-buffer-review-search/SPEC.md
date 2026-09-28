# M21 Buffer and Review Search

Status: ready-for-agent
Milestone: M21

## Problem Statement

Reviewers cannot search source or authored text without leaving bbr. They must scan the current DiffPane Buffer, open Files one at a time, or use another tool that loses the Review context.

The current File finder searches paths only. It cannot find text in old and new File versions, Comments, Replies, or Drafts. Generated Presentation text also makes a row-based search unreliable because gutters, headers, Folds, and disclosure labels are not Review content.

Large Reviews add another constraint. Complete File content is lazy and subject to the File cache budget. A complete Review Search must remain responsive, preserve exact source identity, tolerate unavailable content, and reject work from an obsolete Session.

## Solution

Add two Session-scoped searches with separate purposes and retained state.

Buffer Search uses `/` for incremental literal smart-case search over semantic source and ReviewBody text in the current Buffer. It highlights every Search Occurrence, shows an active and total count, and uses `n` and `N` for semantic traversal.

Review Search uses a responsive Overlay for fuzzy search across both complete versions of every changed File and every authored Comment, Reply, and Draft body. It streams ranked Search Occurrences as File Enrichment becomes available, shows one dense result row per occurrence, previews the selected occurrence, and opens the exact source or ReviewBody location.

Presentation owns search state, scheduling, navigation, and atomic publication. One terminal-free search module owns Unicode query validation, literal matching, fuzzy ranking, range mapping, and deterministic ordering. Review Search reuses File Enrichment, the File cache, Session Epoch admission, and the common RemoteReview and LocalReview pipeline.

## User Stories

1. As a reviewer, I want to open Buffer Search with `/`, so that I can find text in the current Buffer.
2. As a reviewer, I want Buffer Search to update after each query edit, so that I can refine a search without confirming each query.
3. As a reviewer, I want Buffer Search to search source Lines, so that I can find code in the current Buffer.
4. As a reviewer, I want Buffer Search to search Comment, Reply, and Draft bodies, so that I can find authored discussion in context.
5. As a reviewer, I want Buffer Search to include hidden Fold Lines, so that collapsed source remains searchable.
6. As a reviewer, I want Buffer Search to include collapsed Thread and ReviewCard bodies, so that disclosure state does not hide authored matches.
7. As a reviewer, I want Buffer Search to exclude generated Presentation text, so that gutters, headers, borders, and labels do not create false matches.
8. As a reviewer, I want Layout, Scope, and File isolation to define the Buffer Search corpus, so that the search follows the current Buffer.
9. As a reviewer, I want Buffer Search to avoid File Enrichment, so that a local search does not start unrelated work.
10. As a reviewer, I want shared context to count once in Unified and SideBySide Layouts, so that duplicate projections do not inflate the match count.
11. As a reviewer, I want wrapped source to count by semantic Line, so that visual continuations do not duplicate a Search Occurrence.
12. As a reviewer, I want literal smart-case matching, so that lowercase queries ignore case and uppercase queries require exact case.
13. As a reviewer, I want whitespace and punctuation to match literally, so that query behavior is predictable.
14. As a reviewer, I want Unicode text search, so that non-ASCII source and authored text work like ASCII text.
15. As a reviewer, I want no Unicode normalization, so that search does not silently change authored bytes.
16. As a reviewer, I want literal matches to be leftmost and non-overlapping, so that repeated text has a stable count and order.
17. As a reviewer, I want each ReviewBody logical line searched separately, so that a match cannot cross a line ending.
18. As a reviewer, I want a ReviewBody match to cross Markdown formatting delimiters, so that emphasis markup does not split semantic prose.
19. As a reviewer, I want generated ReviewBody labels to stop a match, so that Presentation text cannot connect unrelated authored text.
20. As a reviewer, I want the active and total count visible as `active/total`, so that I know my position among matches.
21. As a reviewer, I want `0/0` in the error style when no match exists, so that failed incremental search is clear.
22. As a reviewer, I want the query end to remain visible in a narrow terminal, so that I can see what I most recently typed.
23. As a reviewer, I want Presentation to hide the count before the prompt, so that narrow terminals preserve query input.
24. As a reviewer, I want every match highlighted, so that I can compare all visible occurrences.
25. As a reviewer, I want the active match styled differently, so that I can locate the current Search Occurrence.
26. As a reviewer, I want search styling to preserve syntax color and existing attributes, so that search does not erase source meaning.
27. As a reviewer, I want `n` to move to the next Search Occurrence, so that I can traverse forward.
28. As a reviewer, I want `N` to move to the previous Search Occurrence, so that I can traverse backward.
29. As a reviewer, I want traversal to wrap with a status message, so that the end of the corpus is clear.
30. As a reviewer, I want Count to select or move by several Buffer Search occurrences, so that repeated traversal is efficient.
31. As a reviewer, I want same-Line occurrences traversed before another Line, so that movement follows source order.
32. As a reviewer, I want SideBySide occurrences ordered old before new, so that paired source has a stable traversal order.
33. As a reviewer, I want manual cursor movement to clear only the active occurrence, so that accepted highlights remain useful.
34. As a reviewer, I want `Esc` to restore the cursor, scroll, query, and highlights from before query input, so that cancellation has no navigation effect.
35. As a reviewer, I want `Enter` to accept the previewed query and location, so that the current result becomes the traversal origin.
36. As a reviewer, I want an empty accepted query to reuse the prior query, so that I can repeat a search without retyping it.
37. As a reviewer, I want an accepted no-match query to remain active, so that I can see and revise the failed search.
38. As a reviewer, I want Backspace to remove one Unicode scalar, so that query editing cannot split UTF-8.
39. As a reviewer, I want `ctrl-w` to remove the prior query word, so that I can revise input quickly.
40. As a reviewer, I want `ctrl-u` to clear the query, so that I can restart input.
41. As a reviewer, I want Buffer Search refused while Selection is active, so that search does not hide or change my Selection.
42. As a reviewer, I want an active hidden match to open only its required disclosures, so that I can inspect it without changing saved disclosure state.
43. As a reviewer, I want temporary disclosures restored when I leave a match, so that search does not change my review layout.
44. As a reviewer, I want Buffer Search rebuilt after Layout, Scope, isolation, disclosure, or body changes, so that matches stay aligned with the Buffer.
45. As a reviewer, I want a surviving Search Occurrence to remain active after Buffer reprojection, so that Presentation changes do not lose my place.
46. As a reviewer, I want to open Review Search with `g f`, so that I can search the complete Review.
47. As a reviewer, I want Review Search to search both complete versions of every changed File, so that removed and proposed source are both discoverable.
48. As a reviewer, I want Selected Version to leave the Review Search corpus unchanged, so that a review-wide query stays complete.
49. As a reviewer, I want Review Search to search every Comment, Reply, and Draft body, so that all authored Review text is discoverable.
50. As a reviewer, I want Review Search to include Review, File, and inline scopes, so that CommentScope does not limit discovery.
51. As a reviewer, I want Review Search to include resolved, outdated, unavailable, and collapsed authored items, so that current visibility does not hide Review history.
52. As a reviewer, I want Deleted Comments excluded, so that structural tombstones do not create matches.
53. As a reviewer, I want File paths excluded as occurrences, so that the File finder remains the path-search tool.
54. As a reviewer, I want one fuzzy result per matching logical line, so that repeated subsequence alignments do not flood the result list.
55. As a reviewer, I want the complete query treated as one ordered fuzzy subsequence, so that spaces and punctuation keep their meaning.
56. As a reviewer, I want Review Search to use smart case, so that fuzzy and literal search share case rules.
57. As a reviewer, I want exact whole-Line and consecutive matches ranked highest, so that the best result appears first.
58. As a reviewer, I want word, path, case, and dot boundaries rewarded, so that fuzzy ranking favors recognizable text boundaries.
59. As a reviewer, I want gaps penalized, so that compact fuzzy matches rank above scattered matches.
60. As a reviewer, I want deterministic tie-breaking, so that the same corpus and query always produce the same order.
61. As a reviewer, I want unchanged old and new source coalesced only when the authoritative Diff proves equivalence, so that one unchanged Line produces one result.
62. As a reviewer, I want changed old and new occurrences kept separate, so that version-specific source identity remains exact.
63. As a reviewer, I want one-based Unicode scalar columns in Review Search, so that displayed positions are stable across UTF-8 encodings.
64. As a reviewer, I want exact matched ranges retained, so that Preview and navigation highlight the matched scalars.
65. As a reviewer, I want a dense Kind, Source, and Position table, so that I can compare many results at once.
66. As a reviewer, I want old, new, version-neutral, Comment, Reply, and Draft kinds named, so that every result's source is clear.
67. As a reviewer, I want matched text shown in the Preview instead of repeated in the result list, so that result rows remain compact.
68. As a reviewer, I want source Preview to show nearby Lines and complete path details, so that I can identify a source result before opening it.
69. As a reviewer, I want ReviewBody Preview to show owner, CommentScope, and surrounding authored text, so that I can identify a discussion result.
70. As a reviewer, I want every fuzzy hit highlighted in the Preview, so that I can understand why a result matched.
71. As a reviewer, I want landscape terminals to show results beside Preview, so that wide space supports comparison.
72. As a reviewer, I want portrait terminals to show results above Preview, so that Review Search remains usable at narrow widths.
73. As a reviewer, I want the result list and Preview to scroll independently, so that long context does not move my selection.
74. As a reviewer, I want long paths complete in Preview and truncated only in the list, so that compact rows do not discard identity.
75. As a reviewer, I want source Preview to scroll horizontally, so that long source Lines remain inspectable.
76. As a reviewer, I want ReviewBody Preview to wrap, so that long authored prose remains readable.
77. As a reviewer, I want Down and `ctrl-n` to select the next result, so that Review Search supports common navigation keys.
78. As a reviewer, I want Up and `ctrl-p` to select the previous result, so that Review Search supports reverse navigation.
79. As a reviewer, I want result navigation to wrap, so that I can continue browsing without reversing direction.
80. As a mouse user, I want a primary click to select a result, so that pointer and keyboard input share selection behavior.
81. As a mouse user, I want a primary double-click to open a result, so that pointer and keyboard input share opening behavior.
82. As a mouse user, I want the wheel to scroll the region under the pointer, so that list and Preview scrolling remain independent.
83. As a reviewer, I want Review Search to start File Enrichment when the Overlay opens, so that complete Review results begin to arrive before I finish the query.
84. As a reviewer, I want query input to remain responsive during File Enrichment and scanning, so that a large Review does not block interaction.
85. As a reviewer, I want authored occurrences available before File acquisition completes, so that useful results appear early.
86. As a reviewer, I want source occurrences streamed by complete File partition, so that old and new coalescing is stable before publication.
87. As a reviewer, I want each publication globally reranked, so that arrival order cannot change the final result order.
88. As a reviewer, I want selection retained by Search Occurrence identity during reorder, so that new results do not move the Preview to another occurrence.
89. As a reviewer, I want a removed selection replaced at its prior list position, so that body edits preserve nearby context.
90. As a reviewer, I want per-version loading and terminal states visible, so that I know which corpus parts remain unavailable.
91. As a reviewer, I want absent, binary, invalid UTF-8, unavailable, and acquisition failure states distinguished, so that Review Search reports the exact limit.
92. As a reviewer, I want known byte size shown for non-text content, so that the status row retains useful File information.
93. As a reviewer, I want usable content from one File version retained when the other fails, so that partial failure does not discard results.
94. As a reviewer, I want one retry for transient remote failures, so that a short transport, rate, or server failure can recover.
95. As a reviewer, I want `Retry-After` honored for rate limits, so that retry does not ignore Bitbucket guidance.
96. As a reviewer, I want definitive remote and local failures left terminal, so that Review Search does not repeat work that cannot succeed.
97. As a reviewer, I want Review Search to honor the File cache budget, so that complete Review scanning does not retain all source indefinitely.
98. As a reviewer, I want cached and in-flight File Enrichment reused, so that Review Search does not issue duplicate reads.
99. As a reviewer, I want evicted content reacquired when needed, so that a bounded cache does not make old results unusable.
100. As a reviewer, I want closing Review Search to stop queued acquisition and scans, so that hidden search does not keep starting work.
101. As a reviewer, I want started File Enrichment to finish into the normal cache, so that closing the Overlay does not waste completed work.
102. As a reviewer, I want reopening Review Search to resume pending acquisition, so that I can continue the same Session search.
103. As a reviewer, I want Review Search to keep its query, selection, and scroll state after closure, so that reopening restores my place.
104. As a reviewer, I want Buffer Search and Review Search to retain separate state, so that using one does not overwrite the other.
105. As a reviewer, I want only the active search to paint highlights, so that two result sets do not compete on the DiffPane.
106. As a reviewer, I want Review Search highlights to remain after the Overlay closes, so that opened and visible results stay marked.
107. As a reviewer, I want Session replacement to clear both searches, so that an old Session cannot affect a new one.
108. As a reviewer, I want stale Session Epoch and query-generation work rejected, so that late worker results cannot replace current results.
109. As a reviewer, I want opening an old or new source result to select that version, so that the DiffPane shows the matched source.
110. As a reviewer, I want opening a version-neutral result to preserve Selected Version, so that unchanged source does not change my preference.
111. As a reviewer, I want a source result to focus its File without forcing File isolation, so that current all-Files context remains when possible.
112. As a reviewer, I want a source result outside a Hunk to switch to WholeFile, so that the exact Line becomes visible.
113. As a reviewer, I want a source result inside a visible Hunk to keep the current Scope, so that navigation changes no more state than required.
114. As a reviewer, I want the cursor on the first wrapped row containing the first match range, so that navigation lands at the exact occurrence.
115. As a reviewer, I want source wrapping always enabled, so that every matched range remains reachable without horizontal DiffPane scrolling.
116. As a reviewer, I want an evicted source result reacquired before navigation, so that Presentation never opens an approximate Line.
117. As a reviewer, I want a failed navigation acquisition to keep the Overlay open, so that I can inspect the failure and retain my selection.
118. As a reviewer, I want an authored result to focus its ReviewCard and exact body line, so that navigation lands on the matched prose.
119. As a reviewer, I want Review-level authored navigation to leave File isolation, so that its ReviewCard can appear in the all-Files Buffer.
120. As a reviewer, I want File-level and inline authored navigation to focus the owning File, so that CommentScope remains clear.
121. As a reviewer, I want inline navigation to select the resolved Anchor version when available, so that source and ReviewCard context agree.
122. As a reviewer, I want outdated or unavailable authored navigation to preserve Selected Version, so that missing current source does not imply a version.
123. As a reviewer, I want authored navigation to save required disclosure changes, so that the opened ReviewCard remains visible after navigation.
124. As a reviewer, I want source and authored opening to close the Overlay only after the destination Frame exists, so that navigation is atomic.
125. As a reviewer, I want RemoteReview and LocalReview search behavior to match, so that DiffSource changes acquisition only, not search semantics.

## Implementation Decisions

- Add one terminal-free, worker-free, and cache-free search module. It owns validated Query values, semantic Candidates, Search Occurrences, literal and fuzzy modes, and owned scan batches.
- Expose one scan operation for both search modes. Callers prepare Candidates but do not implement matching, ranking, range merging, or tie-breaking.
- Limit a Query to 256 Unicode scalars. Refuse NUL, line endings, invalid UTF-8, and a 257th scalar with a visible status message.
- Generate and commit a Unicode table from one pinned Unicode release. Record source checksums and the Unicode version with the generated data.
- Use simple one-scalar Unicode case folding and the Unicode Uppercase property. Do not use full mappings, locale mappings, or normalization.
- Use an ASCII fast path before the Unicode table.
- Literal mode returns leftmost, non-overlapping Search Occurrences in deterministic corpus order.
- Fuzzy mode uses Telescope's default `fzy` score behavior as its reference. Adapt matching to Unicode scalars and the shared smart-case rule.
- Return one best fuzzy alignment per Candidate. Retain each matched scalar's exact half-open UTF-8 range and merge adjacent stored ranges.
- Rank exact fuzzy calculations before fallback calculations. Within each class, sort by score, candidate scalar length, and canonical corpus order.
- Set the exact fuzzy dynamic-programming cell limit through the implementation benchmark. Use a deterministic greedy subsequence above that limit and record the chosen limit beside the implementation.
- Build Buffer Search Candidates from the same Diff, Review, and Buffer options that build the visible Buffer. Build Candidates before disclosure projection.
- Search every old-side and new-side source Line owned by the Buffer. Give shared unchanged context one identity in both Layouts.
- Search semantic ReviewBody text. Include prose, headings, Suggestion source, link labels, and visible link destinations.
- Map semantic ReviewBody ranges back to authored UTF-8 ranges. Markdown delimiters are zero-width, but generated labels form boundaries.
- Exclude all generated Presentation text, AnchorSnapshots, Deleted Comments, and File paths from the search corpus.
- Give each source Search Occurrence a Session Epoch, File identity, version relation, applicable paths and line numbers, and exact ranges.
- Give each authored Search Occurrence a Session Epoch, CommentId or TempId, one-based logical body line, and exact authored ranges.
- Use one-based Unicode scalar columns for Overlay positions. Use UTF-8 ranges for rendering and navigation.
- Coalesce old and new source occurrences only when the authoritative Diff maps the Lines as context and both text and matched ranges agree.
- Store Buffer Search state and Review Search state in the Session-scoped published Presentation aggregate.
- Keep an explicit active search value. Only the active search contributes match styles to a Presentation Frame.
- Buffer Search stores its accepted query, accepted occurrences, active identity, input preview, saved navigation, search origin, Count, and temporary disclosure reveals.
- Review Search stores its query generation, replaceable ReviewBody and File partitions, sorted occurrences, selected identity, acquisition states, scroll positions, queued work, active scan, and pending exact destination.
- Add configurable Actions for opening Buffer Search, traversing Buffer Search, opening Review Search, selecting Review Search occurrences, and opening the selected occurrence.
- Bind Buffer Search to `/`, `n`, and `N`. Bind Review Search to `g f`, Down, Up, `ctrl-n`, `ctrl-p`, and Enter.
- Add separate Buffer Search input and Review Search Interaction Contexts. Run fixed query editing keys before configurable Action resolution.
- Let configured Review Search navigation and opening Actions take priority over printable query input.
- Keep Buffer Search unavailable while Selection is active. Preserve the Selection and report how to clear it.
- Buffer Search opens in the bottom status line. Keep the prompt and query end visible before the count at narrow widths.
- Buffer Search query input ignores pointer input and accepts edits only at the end.
- Keep the prior accepted Buffer Search visible while new input is empty. Restore it if editing returns to zero bytes.
- Buffer Search cancellation restores the complete saved search and navigation state. Confirmation keeps the previewed query and location.
- Use the first Search Occurrence on the highlighted visual row as the search origin. Otherwise, use the next semantic occurrence with wraparound.
- Retain an active occurrence after an edit when the same semantic location still matches. Otherwise, select from the saved search origin.
- Traverse Buffer Search in semantic Buffer order. Order authored occurrences by owner and logical body line, and order old before new on a shared SideBySide row.
- Keep the viewport unchanged when the active row is visible. Otherwise, scroll only enough to place the row at the nearest viewport edge.
- Use search-owned temporary reveals for Buffer Search and source Review Search navigation. Restore saved Fold and disclosure state when the reveal no longer applies.
- Render Review Search as one responsive Overlay projection. Rendering cannot inspect mutable search state.
- Show the title, query prompt, available-result count, and candidate count in the Review Search header.
- Use a dense result table with Kind, Source, and Position fields. Keep matched text in the Preview.
- Show `OLD`, `NEW`, `OLD+NEW`, `COMMENT`, `REPLY`, and `DRAFT` kinds.
- Place the result list beside Preview in landscape geometry and above Preview in portrait geometry. Keep independent scroll state.
- Put non-selectable File-version status rows after available Search Occurrences.
- Show `No matching occurrence` and `No preview` when the current query has no available result. Continue to show acquisition states.
- Add search match, active match, and no-match styles to every built-in Theme. Match style preserves existing foreground and attributes. Active style replaces the foreground and adds bold.
- Project UTF-8 ranges to cells after wrapping. Search styles add no cells and cannot change wrapping.
- Make DiffPane source wrapping unconditional. Remove the wrapping Action, its default binding, and the wrapping preference.
- Add exact result-row pointer targets to the Presentation Frame. Click selection and double-click opening dispatch the same semantic Actions as keyboard input.
- Make Review Search available from every DiffPane Interaction Context. Let the Overlay capture the complete input surface while open.
- Use the same end-only Unicode editing keys for Review Search. Treat digits as query text and do not apply Count.
- Start complete Review File Enrichment when Review Search opens, even for an empty query. An empty query emits no Search Occurrences.
- Sort acquisition by File display path and then Diff File order.
- Reuse the existing File Enrichment pipeline, cached content, and in-flight work. Do not add a second source cache or a persistent search index.
- Limit Review Search acquisition to eight Files for both RemoteReview and LocalReview. A modified remote File can use two side requests, for a maximum of 16 requests. LocalReview can use eight Git processes.
- Give Review Search acquisition priority over new focused-File demand while the Overlay is open. Let started work finish and pause one-successor remote prefetch.
- Keep query scanning independent from acquisition. Increment a query generation after each edit and retain only the newest queued generation.
- Do not add a fixed query debounce. Let an active scan finish, reject its stale completion, and start only the newest queued generation.
- Run one self-owned scan command at a time. It carries a command id, Session Epoch, query generation, query snapshot, partition identity, and either a ReviewBody snapshot or one File read lease.
- Add one owned scan completion. Admit it only when the command id, Session Epoch, query generation, open state, and partition identity match.
- Scan ReviewBodies first. Make a File eligible after every present version reaches a terminal File Enrichment state.
- Publish a complete File partition at once. Replace that partition for the current generation and globally sort all available Search Occurrences.
- Retain selection by Search Occurrence identity after publication. If the identity disappears, retain its prior list position and clamp to the final result.
- Extend File Enrichment storage with a thread-safe read lease for one File. A lease exposes immutable old and new views and pins owned content against eviction.
- Permit at most one File scan lease in addition to focused-File protection. Reapply the normal inactive-content budget after lease release.
- Retire leased content on Session destruction. Free retired content after the final lease release without reading Session state.
- Let a streamed source Search Occurrence own location, score, and range data. It never borrows or copies the complete source Line.
- Classify File-version search state as loading, text, absent, binary, invalid UTF-8, unavailable, or acquisition failure.
- Let only text contribute source Candidates. Keep usable text when the opposite version has a terminal non-text state.
- Retry remote transport, rate-limit, and server failures once in the same File slot. Honor normalized `Retry-After` evidence.
- Do not retry authentication, authorization, validation, missing content, other definitive remote failures, or local failures.
- Closing the Overlay removes queued acquisition and scan commands. Started File Enrichment can finish into the current Session cache, but it cannot publish closed-search results.
- Reopening Review Search restores its retained state and resumes pending acquisition from current cache states.
- Keep Review Search active after Overlay closure. Keep projected result highlights until Buffer Search becomes active or the Session changes.
- Do not clear Review Search selection or highlights after DiffPane Motions, pointer navigation, Layout, Scope, or isolation changes.
- Recompute projected Review Search ranges after each Buffer reprojection. Highlight every available occurrence that belongs to the current Buffer.
- Session replacement clears both searches and stops old queued work. Every stale completion must release its owned batch and lease.
- Resolve every navigation destination against the current Session before changing the Presentation Frame.
- Opening a source occurrence stages File focus, isolation replacement when applicable, Selected Version, Scope, disclosures, exact wrapped row, and highlights in one Frame.
- Set Selected Version for old or new source occurrences. Preserve it for version-neutral occurrences.
- Keep Scope when the source Line belongs to a visible Hunk. Switch to WholeFile when the Line is outside all Hunks.
- Reacquire evicted destination content before source navigation. Keep the Overlay open until an exact destination Frame is ready.
- Opening an authored occurrence resolves its CommentId or TempId against current Threads and PendingReview data.
- Apply Review-level, File-level, inline, Reply, Draft, outdated, and unavailable navigation through their existing CommentScope and ScopeResolution rules.
- Keep M21 navigation on existing ReviewCards. Do not add a Comment Overview.
- Stage every search mutation that changes rows, highlights, disclosures, Scope, isolation, Selected Version, or cursor as one complete Presentation Frame.
- Preserve the prior Frame and report a classified Presentation error when Candidate building, matching, allocation, or Frame construction fails.
- Implement M21 in five usable slices: the search kernel and reachable source, Buffer Search, authored Review Search, streamed source Review Search, and exact navigation with hardening.
- Keep each slice runnable and keep the existing test suite green. Do not add placeholder interfaces for later slices.
- Add no runtime dependency for M21.

## Testing Decisions

- Good tests assert reviewer-visible search behavior, emitted typed commands, published Presentation state, exact destination identity, and rendered cells. Tests do not assert worker threads, private queues, cache internals, or dynamic-programming tables.
- The highest shared integration seam is the existing Presentation transition and immutable projection. Tests dispatch Actions and owned completions, drain commands, and inspect one complete Presentation Frame.
- The only new logic seam is the pure search scan operation. Pure tests cover query validation, Unicode rules, literal matching, fuzzy ranking, range mapping, and deterministic order.
- Headless rendering is the secondary seam. It verifies prompt layout, count clipping, search style composition, Overlay geometry, Preview content, status rows, wrapping, and pointer targets.
- Existing Buffer tests are prior art for Unified and SideBySide projection, Scope, File isolation, Folds, wrapped semantic Lines, ReviewCard placement, and generated-row exclusion.
- Existing Presentation tests are prior art for typed Actions, Count, Selection refusal, Session replacement, Session Epoch rejection, File Enrichment admission, atomic rollback, cursor restoration, and ActionAvailability.
- Existing Frame tests are prior art for semantic target geometry, stable navigation identity, narrow terminal behavior, and stale target rejection.
- Existing render tests are prior art for detached headless surfaces, cell-level style assertions, SideBySide boundaries, ReviewCards, and status placeholders.
- Existing Keymap and configuration tests are prior art for default bindings, overrides, unbinding, conflict rejection, Leader handling, help grouping, and strict unknown Action rejection.
- Existing File Enrichment tests are prior art for independent version outcomes, RemoteReview concurrency, LocalReview acquisition, cache admission, LRU eviction, stale work, and cleanup.
- Pure query tests cover ASCII and non-ASCII uppercase detection, simple folds, excluded multi-scalar folds, no normalization, invalid UTF-8, NUL, and the 256-scalar limit.
- Pure literal tests cover leftmost non-overlap, repeated matches, whitespace, punctuation, tabs, combining scalars, scalar columns, and logical line boundaries.
- Pure fuzzy tests cover exact and boundary bonuses, gaps, smart case, one result per Candidate, exact ranges, deterministic ties, and exact versus fallback classes.
- ReviewBody tests cover Markdown delimiters, links, Suggestions, generated boundaries, authored range mapping, and logical body lines.
- Search Occurrence tests cover old, new, version-neutral, CommentId, TempId, body mutation, Buffer rebuild stability, and Session Epoch expiry.
- Buffer corpus tests cross both Layouts, all Scope values, File isolation, shared context, hidden Folds, hidden authored text, and generated Presentation text.
- Buffer input tests cover incremental edits, cancellation, confirmation, empty-query reuse, no prior query, no matches, Count, query limits, and Selection refusal.
- Buffer traversal tests cover same-Line occurrences, old-before-new order, `n`, `N`, Count, both wrap messages, manual cursor movement, and reprojection.
- Buffer rendering tests cover command-line input, active and total count, narrow clipping, no-match color, style priority, wrapped matches, and shared SideBySide matches.
- Review input tests cover first empty open, restored reopen, Unicode edits, digits as text, Escape retention, and absence of Count behavior.
- Review publication tests cover ReviewBody-first results, File-atomic partitions, global reorder, selection identity retention, and selection clamping.
- Overlay tests cross landscape and portrait geometry, dense result fields, complete Preview context, independent scrolling, long paths, horizontal source Preview, and wrapped ReviewBody text.
- Pointer tests cover click selection, double-click opening, wheel routing, modifiers, unsupported buttons, and stale Presentation Frame targets.
- Acquisition tests cover path order, eight File slots, 16 remote side requests, eight Git processes, in-flight joining, duplicate-read prevention, and paused prefetch.
- Retry tests cover one transport retry, rate-limit retry with `Retry-After`, one server retry, definitive remote failure, and local no-retry behavior.
- File-state tests cover loading, text, absent, binary size, invalid UTF-8 size, invalid path, acquisition failure, and usable opposite-version content.
- Lease tests cover scan pinning, focused-File pinning, temporary budget excess, eviction after release, reacquisition, Session retirement, and rejected completion cleanup.
- Stale-work tests cover old command ids, closed Overlay, old query generations, old Session Epochs, Session replacement, and shutdown queue closure.
- Source navigation tests cover old, new, and version-neutral occurrences in isolated and all-Files Buffers. They also cover visible Hunks, Folds, out-of-Hunk WholeFile, and exact wrapped ranges.
- Reacquisition tests cover a retained loading Overlay, successful atomic destination publication, terminal failure, and refusal to navigate approximately.
- Authored navigation tests cover Review, File, and inline CommentScope, Reply inheritance, Drafts, outdated state, unavailable resolution, and complete disclosure chains.
- Search-lifetime tests cover separate states, one active highlight owner, Overlay close and reopen, Layout, Scope, isolation, refresh, and Review switching.
- Wrapping tests cover removed Action and preference behavior, strict override rejection, Unified and SideBySide reachability, and absence of hidden horizontal destinations.
- Failure tests inject allocation failure into Query construction, Candidate building, matching, lease creation, and Frame construction. Each test verifies preservation of the prior complete Frame and cleanup of owned data.
- The bounded fuzzy benchmark covers long generated Lines, long Unicode Lines, and a 256-scalar query. It records the exact cell limit before the search kernel merges.
- The complete hermetic suite must pass with `zig build test --summary all`, and the reported test count must increase.
- Live Bitbucket and PTY checks remain optional. Required acceptance uses pure tests, typed Presentation command tests, and headless rendering.

## Out of Scope

- Regular-expression search.
- Text replacement.
- Repository-wide search.
- Search of unchanged Files outside the current Review.
- File path search, which remains owned by the File finder.
- A persistent search index.
- Search history across application restarts.
- Unicode normalization, locale-specific case rules, or full multi-scalar case folding.
- A Comment Overview. M29 owns that cross-item presentation.
- A second source cache, a disk-backed search cache, or a new File Enrichment pipeline.
- A new runtime fuzzy-search or Unicode dependency.
- Changes to DiffSource, CommentScope, Anchor, or Bitbucket line-number authority.
- M28 evaluation of the long-term Full-Review File cache policy.
- Implementation work outside M21.

## Further Notes

- The completed M21 map is the decision index for this spec.
- The corpus and Search Occurrence decision owns semantic inclusion, Unicode matching, and exact identity.
- The Buffer Search interaction decision owns query lifecycle, traversal, Count, cancellation, and temporary disclosure behavior.
- The accepted Buffer Search prototype owns command-line layout and Theme behavior.
- The Review Search matching decision owns fuzzy Candidate units, scores, tie order, and version-neutral coalescing.
- The accepted Review Search prototype owns Overlay structure, Preview, exceptional states, and pointer parity.
- The streaming decision owns File acquisition, query generations, cache use, publication, retry, and stale-work rejection.
- The navigation decision owns search state lifetime and exact source or ReviewBody destinations.
- The integrated contract owns module boundaries, leases, typed commands, implementation slices, and the complete acceptance matrix.
- The concurrency benchmark selected eight Files for both RemoteReview and LocalReview. It measured no accepted-run failures or rate limits.
- M21 depends on completed M20 Selected Version behavior and the existing Presentation Frame contract.
