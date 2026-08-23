# M17 Diff, Blob, and Highlighting Completeness

Status: ready-for-agent
Milestone: M17

## Problem Statement

Reviewers cannot yet trust every changed File to render completely. Binary Files and invalid UTF-8 can enter text workflows, removed Files cannot show complete old content, and index-based SideBySide matching can misalign related Lines after an insertion or deletion. Long Lines are clipped with no wrap option.

Highlighting also has two incomplete contracts. BuiltInGrammar queries use predicates that the current tree-sitter adapter does not evaluate, so valid conditional Captures can disappear. Users cannot install a trusted UserGrammar for unsupported file types without changing bbr itself.

Remote sequential review also waits for each File Enrichment request even when the reviewer moves through Files in order. At the same time, adding remote-only Diffstat acquisition or a persistent File cache without a proven consumer would add policy and storage risk without reviewer value.

## Solution

Complete the shared remote and local Diff pipeline. Classify each File side as text, binary, or unavailable. Preserve usable text on the opposite side, show non-anchorable Status Placeholders for content that cannot render, and add a true old-side WholeFile projection for removed Files.

Use deterministic line-level matching for SideBySide change blocks. Add optional display-cell-aware DiffPane wrapping that preserves each underlying Line, Selection, decoration, and Anchor. Keep clipping as the launch default.

Validate and execute the tree-sitter predicates required by BuiltInGrammars and UserGrammars. Add a trusted, local, native UserGrammar lifecycle with atomic installation, strict GrammarMatch rules, compatibility checks, and BuiltInGrammar or plain-text fallback. Keep the public Highlighter seam unchanged.

Prefetch at most one remote successor after explicit forward File traversal. Reuse the existing Session Epoch and inactive File cache rules. Do not add Bitbucket Diffstat, persistent File content storage, or general speculative loading.

## User Stories

1. As a reviewer, I want a binary File identified from its RawDiff stub, so that bbr does not treat binary bytes as source text.
2. As a reviewer, I want each old and new File side classified independently, so that one unusable side does not hide usable content from the other side.
3. As a reviewer, I want invalid UTF-8 reported as unavailable content, so that malformed bytes cannot corrupt Highlighting or terminal rendering.
4. As a reviewer, I want the known byte size shown for binary or unavailable content, so that I can judge the File without opening it elsewhere.
5. As a reviewer, I want `size unavailable` shown when bbr has no reliable size, so that an absent value is not mistaken for an empty File.
6. As a reviewer, I want binary, invalid UTF-8, and acquisition failures named differently, so that I know why content is unavailable.
7. As a reviewer, I want a Status Placeholder in Unified Layout, so that unavailable content has a clear and stable representation.
8. As a reviewer, I want independent old-side and new-side Status Placeholders in SideBySide Layout, so that added, removed, and partly unavailable Files remain understandable.
9. As a reviewer, I want Status Placeholders in both Changes and WholeFile Scope, so that changing Scope never makes unavailable content ambiguous.
10. As a reviewer, I want a Status Placeholder to reject Selection and Anchors, so that a generated row cannot become authored source identity.
11. As a reviewer, I want File-level and Review-level Comments to remain visible for a binary File, so that unavailable source content does not hide review discussion.
12. As a reviewer, I want bbr to skip fetch and Highlighting work for a side already known to be binary, so that unsafe or wasteful work does not start.
13. As a reviewer, I want a removed File's complete old content in WholeFile Scope, so that I can inspect unchanged old Lines outside the diff Hunks.
14. As a reviewer, I want a removed File fetched from the destination commit and old path, so that bbr reads the version that the PullRequest removes.
15. As a reviewer, I want an added File fetched only from the source commit and new path, so that bbr does not request a side that cannot exist.
16. As a reviewer, I want renamed Files to use their distinct old and new paths, so that each side resolves to the correct content.
17. As a reviewer, I want paths with spaces, Unicode, quotes, and reserved URL characters handled correctly, so that valid repository paths remain reviewable.
18. As a reviewer, I want malformed or non-repository-relative paths refused, so that File Enrichment cannot request an unintended resource.
19. As a reviewer, I want an expected side that returns `not_found` reported as unavailable rather than absent, so that a server failure is not confused with File status.
20. As a reviewer, I want an empty text File to produce a complete zero-Line WholeFile projection, so that empty content does not fall back to Changes Scope.
21. As a reviewer, I want blob-sourced context Lines to remain non-anchorable, so that only authoritative Hunk Lines can receive inline Comments or Drafts.
22. As a LocalReview reviewer, I want Git content to use the same File Content Status and UTF-8 rules as remote content, so that both DiffSources behave alike.
23. As a remote reviewer, I want Bitbucket failures classified per side, so that one failed request does not discard the successful side.
24. As a reviewer, I want an allocation failure to transfer no partial side result, so that the published Session keeps consistent ownership.
25. As a reviewer, I want SideBySide Layout to align related replacement Lines after an insertion, so that one extra Line does not offset the remaining block.
26. As a reviewer, I want SideBySide Layout to align related replacement Lines after a deletion, so that one missing Line does not offset the remaining block.
27. As a reviewer, I want unrelated Lines placed opposite an empty side, so that bbr does not imply a false replacement.
28. As a reviewer, I want repeated and blank Lines matched deterministically, so that Buffer rebuilds do not change alignment.
29. As a reviewer, I want every underlying Line shown exactly once in SideBySide Layout, so that matching cannot lose or duplicate source content.
30. As a reviewer, I want IntraLineSegments only for accepted related pairs, so that unrelated Lines do not receive misleading word emphasis.
31. As a reviewer, I want Unified Layout unchanged by SideBySide matching, so that the new projection cannot alter the authoritative Diff order.
32. As a reviewer, I want existing inline Comments and Drafts to stay on their old-side or new-side Line after matching changes, so that presentation does not change Anchor identity.
33. As a reviewer, I want to toggle DiffPane wrapping with a configurable Action, so that I can inspect long Lines without horizontal clipping.
34. As a reviewer, I want wrapping disabled at each launch, so that bbr preserves the current clipped default.
35. As a reviewer, I want wrapping to survive Buffer rebuilds and Session replacement during one process, so that routine navigation does not reset my preference.
36. As a reviewer, I want soft wrapping at Unicode whitespace when possible, so that long source text remains readable.
37. As a reviewer, I want a hard break at a grapheme boundary when no whitespace fits, so that long tokens wrap without splitting a visible character.
38. As a reviewer, I want syntax foreground, diff background, IntraLineSegment emphasis, and Selection styling preserved across wrapped rows, so that wrapping changes geometry only.
39. As a reviewer, I want continuation rows to have blank line-number gutters, so that one semantic Line does not appear to have multiple source numbers.
40. As a reviewer, I want old and new SideBySide halves wrapped independently, so that neither side crosses the fixed divider.
41. As a reviewer, I want the shorter SideBySide half padded with neutral blank cells, so that paired continuations stay aligned.
42. As a reviewer, I want visual-row Motions, Counts, paging, and scrolling while wrapping is active, so that long Lines remain navigable.
43. As a reviewer, I want Selection to deduplicate continuations of one Line, so that a wrapped Line still creates one semantic source range.
44. As a reviewer, I want a Comment or Suggestion created from any continuation to use the underlying Hunk Line Anchor, so that wrapping creates no new Anchor type.
45. As a reviewer, I want cursor position restored by semantic owner and source offset after resize or reprojection, so that layout changes keep my place.
46. As a reviewer, I want the prior complete Presentation Frame preserved when reprojection fails, so that bbr never publishes a partial screen state.
47. As a reviewer, I want BuiltInGrammar `#match?` conditions evaluated, so that matching Captures appear and nonmatching Captures do not.
48. As a reviewer, I want BuiltInGrammar `#eq?` conditions evaluated, so that exact query conditions work as authored.
49. As a reviewer, I want `#is-not? local` use real locals queries and scope tracking, so that local identifiers are not highlighted as global symbols.
50. As a reviewer, I want a false predicate to reject only its match and preserve fallback Captures, so that one condition cannot erase valid later highlighting.
51. As a reviewer, I want malformed predicates, unknown operators, directives, regexes, ranges, or properties to reject the complete Grammar with a source diagnostic, so that bbr never publishes partial Spans silently.
52. As a UserGrammar author, I want the same predicate profile as BuiltInGrammars, so that query behavior does not depend on provenance.
53. As a UserGrammar user, I want to check a local bundle without activating it, so that I can inspect compatibility before installation.
54. As a UserGrammar user, I want to install a folder or archive only after an explicit native-code trust decision, so that executable code never activates because of its path alone.
55. As a UserGrammar user, I want non-interactive trust bound to one SHA-256 digest, so that automation cannot approve changed payload bytes.
56. As a UserGrammar user, I want target, tree-sitter ABI, symbol, manifest, payload digest, query, and GrammarMatch validation before activation, so that an invalid bundle cannot replace working Highlighting.
57. As a UserGrammar user, I want install and update to be atomic, so that failure preserves the prior active Grammar and registry.
58. As a UserGrammar user, I want install, update, check, list, remove, enable, and disable commands, so that I can manage the complete lifecycle from bbr.
59. As a UserGrammar user, I want installation to activate the declared default GrammarMatch rules, so that a valid bundle works without a second setup step.
60. As a UserGrammar user, I want strict configuration to replace one UserGrammar's default matches, so that I can control exact filenames, compound suffixes, extensions, and shebangs.
61. As a UserGrammar user, I want conflicts between active UserGrammars refused, so that File matching remains deterministic.
62. As a UserGrammar user, I want an active UserGrammar to take precedence over an overlapping BuiltInGrammar after bbr reports the overlap, so that the installation has a clear effect.
63. As a UserGrammar user, I want disable, removal, or runtime failure to restore a matching BuiltInGrammar or plain text, so that source content remains readable.
64. As a UserGrammar user, I want tampered active payloads to block startup with a precise error, so that trusted identity cannot change unnoticed.
65. As a UserGrammar user, I want an invalid inactive installation listed without blocking startup, so that a disabled bundle does not stop reviews.
66. As a UserGrammar user, I want validation receipts reused only while bundle and runtime identities match, so that startup avoids unnecessary validation without trusting stale evidence.
67. As a reviewer moving forward through remote Files, I want the immediate successor enriched in advance, so that sequential review hides most remote acquisition delay.
68. As a reviewer, I want only one speculative File in flight, so that prefetch remains bounded.
69. As a reviewer, I want demand work to promote matching speculative work without duplication, so that focus never starts a second request for the same File.
70. As a reviewer who jumps, moves backward, uses File finding, clicks a File, or starts a LocalReview, I want demand loading only, so that bbr does not guess my next File.
71. As a reviewer who disables the inactive File cache, I want prefetch disabled too, so that speculative work cannot bypass my retention choice.
72. As a reviewer, I want speculative failures silent until I focus the File, so that background work does not replace the current File's status.
73. As a reviewer, I want stale speculative results rejected by Session Epoch, so that a replaced Session cannot receive old File content.
74. As a reviewer, I want no File content or Highlighting data written to disk, so that reviewed source code remains Session-only.
75. As a LocalReview reviewer, I want no remote-only Diffstat dependency, so that shared Diff behavior remains source-neutral.

## Implementation Decisions

- Diff remains authoritative for Files, Hunks, Lines, line numbers, change status, and Anchor eligibility. RawDiff binary classification creates no synthetic Line.
- Each present File side exposes File Content Status as text, binary, or unavailable, plus optional byte size and a typed unavailable reason.
- File Enrichment owns per-side state transitions, UTF-8 validation, Highlighting results, and owned content. Old and new sides commit independently. `OutOfMemory` commits neither pending result.
- A RawDiff Git binary stub classifies the File as binary before acquisition. Invalid UTF-8 classifies only the fetched side as unavailable.
- Presentation uses Status Placeholders for binary or unavailable content. A Status Placeholder cannot receive an Anchor, Selection, Fold, or Highlighting.
- Bitbucket normalizes Git-quoted paths, requires repository-relative File paths, and percent-encodes each segment while preserving path separators.
- Bitbucket acquires old content from the destination commit and old path. It acquires new content from the source commit and new path. It does not request absent File sides.
- A successful Bitbucket content response is opaque bytes. Extension-derived content type does not establish text encoding. UTF-8 validation occurs before ownership transfer.
- WholeFile uses old content for removed Files and new content for other Files. Old-side splicing uses authoritative old line numbers. Blob-sourced context Lines remain non-anchorable.
- Git uses the same File Enrichment result and File Content Status contract. No source-specific Diff or Presentation branch is added.
- SideBySide matching operates only on maximal removed-then-added blocks. It uses order-preserving dynamic programming over existing Line identities.
- Pair similarity is twice the common token byte count divided by the combined old and new token byte count. Two identical Lines, including blank Lines, score one. A blank and nonblank Line score zero.
- A pair is eligible at similarity greater than or equal to 0.5. Pair cost is one minus similarity. A one-sided gap costs one.
- Equal-cost matching prefers exact pairs, then the earliest eligible pair in old and new order. Accepted pairs alone receive IntraLineSegments.
- Buffer remains a width-independent semantic projection. Presentation Frame owns geometry-dependent wrapping into visual rows.
- `toggle_diff_wrap` is a configurable Action with default binding `w`. Wrap state lasts for the process and starts disabled.
- Wrapping applies only to Diff Line and LinePair rows. Headers, Folds, Status Placeholders, sections, and ReviewCards keep their existing projection contracts.
- Wrapping uses terminal display-cell width. It prefers the last Unicode whitespace boundary that fits, then uses a grapheme boundary. It never changes source bytes.
- Every wrapped visual row carries its semantic owner and source-byte start. Navigation uses visual rows. Selection and Anchor creation resolve through the semantic owner.
- SideBySide halves derive independent body widths after gutters and the fixed divider. The larger continuation count sets the LinePair height.
- Reprojection publishes one complete Presentation Frame. Cursor restoration uses semantic owner and source offset with nearest-following and final-row fallback.
- The public Highlighter seam does not change. TreeSitterHighlighter privately owns Grammar selection, query validation, locals tracking, compiled regexes, native handles, and process-lifetime caches.
- Grammar validation supports `#match?`, `#eq?`, and `#is-not? local`. It rejects unknown operators, directives, malformed arguments, invalid ranges, invalid regexes, and unsupported properties atomically.
- Predicate filtering occurs before Capture precedence. A false predicate removes one query match, not fallback Captures. Cursor match loss fails Highlighting instead of returning partial Spans.
- JavaScript and TypeScript local-scope behavior uses pinned locals queries. It is not approximated from highlight Captures.
- Query regexes use pinned RE2 2025-11-05 at commit `927f5d53caf8111721e734cf24724686bb745f55` and pinned Abseil 20250512.1 through a length-bearing C ABI wrapper.
- The regex profile uses RE2 Perl mode, UTF-8, case-sensitive unanchored search, and no multiline mode. Embedded NUL is valid. Each pattern is at most 4096 UTF-8 bytes and has a 1 MiB RE2 memory limit.
- The executable module owns tree-sitter, RE2, dynamic loading, UserGrammar registry I/O, and native fixtures. The network-free core module remains C-free.
- A UserGrammar bundle is a local folder or `.tar.gz` archive. bbr neither downloads sources nor compiles a UserGrammar.
- The bundle manifest declares identity, version, target, tree-sitter ABI, exported symbol, payloads, SHA-256 values, queries, and default GrammarMatch rules. Validation rejects extra files, duplicate entries, links, unsafe paths, and mismatched targets.
- Interactive installation reports native-code risk, digest, Grammar identity, matches, and affected BuiltInGrammars before confirmation. Non-interactive installation requires the exact trusted digest.
- UserGrammar storage uses the XDG data directory. Candidate installation, validation, registry update, and replacement are atomic. Failed update preserves the prior working installation.
- The lifecycle commands are `grammar install`, `update`, `check`, `list`, `remove`, `enable`, and `disable`. Partial lifecycle exposure is not permitted.
- GrammarMatch precedence is exact filename, compound suffix, simple extension, then shebang. Explicit configuration rules precede installed defaults, which precede BuiltInGrammar rules.
- Configuration rules for one UserGrammar replace all bundle defaults when any rule is present. Enabled state and installation order remain registry data.
- Active UserGrammar conflicts are startup configuration errors. An active UserGrammar can override a BuiltInGrammar but cannot silently override another UserGrammar.
- Validation receipts are keyed by bundle digest and bbr and tree-sitter runtime versions. Payload or runtime changes require complete validation.
- TreeSitterHighlighter loads an active UserGrammar at first matching use. CLI changes apply to new bbr processes. There is no live reload or serialized compiled-query cache.
- Remote prefetch arms only after explicit navigation to the immediately next Diff File. It starts only after the focused File reaches a terminal File Enrichment state.
- At most one speculative File Enrichment runs. Demand work is never delayed. Matching speculative work becomes demand work without a duplicate request.
- Any focus change other than immediate forward navigation disarms later prefetch. Running work may complete through normal Session Epoch and File cache admission.
- LocalReview, initial focus, backward navigation, direct File Tree focus, File finding, and mouse focus do not prefetch.
- Disabling the inactive File cache disables prefetch. A speculative inactive File that exceeds the existing budget is evicted through the existing whole-File LRU policy.
- Diffstat is not implemented. A future change-total feature must first define a source-neutral Diff summary and prove that the parsed Diff cannot supply it.
- File content and Highlighting remain Session-only. No persistent File cache, compiled-query cache, or SQLite schema change is part of M17.
- Native support requires test execution on macOS x86_64, macOS aarch64, Linux x86_64, and Linux aarch64. Cross-compilation alone is insufficient.
- Implementation lands as independently correct slices. UserGrammar CLI and runtime activation ship only as one complete lifecycle.

## Testing Decisions

- Good tests assert external behavior: Diff identity, File Content Status, rendered rows, semantic navigation, emitted requests, diagnostics, registry state, fallback, and cache admission. Tests do not assert private allocation layout, dynamic-programming table cells, worker phases, or internal cache objects.
- The highest shared seam is remote and local File Enrichment into the common Diff and Highlighter pipeline, followed by headless Buffer and Presentation Frame projection. This seam proves source parity, Anchor safety, Layout, Scope, wrapping, and fallback behavior.
- RawDiff parser fixtures cover binary stubs, added, modified, removed, renamed, empty, malformed, and path-special Files. They preserve authoritative Hunk Lines and File identity.
- File Enrichment contract tests run equivalent remote and local fixtures through independent old and new outcomes. They cover text, binary, invalid UTF-8, typed failure, known and unknown size, opposite-side preservation, Highlighting failure, and `OutOfMemory` ownership.
- Existing prior art is the remote and local DiffSource parity test, true WholeFile splice tests, non-anchorable blob context tests, independent File Enrichment ownership tests, and stale Session Epoch rejection.
- Bitbucket fake-adapter tests verify commit and path selection, Git path unquoting, segment encoding, redirect bounds, empty bytes, `not_found`, every ApiError class, invalid UTF-8, and response ownership.
- The opt-in credential-gated blob checker compares metadata and raw reads for exact path, commit, type, size, attributes, and raw length. It reports skipped fixture classes and never runs in the default suite.
- Buffer tests cover old-side and new-side WholeFile splicing, exact Hunk Line preservation, line numbering, empty content, Changes fallback rules, Status Placeholder identity, and Anchor refusal.
- SideBySide matcher fixtures cover insertion, deletion, related replacement, unrelated replacement, unequal side lengths, repeated Lines, blank Lines, and identical input. Each fixture verifies pair identity, stable order, and exactly-once Line ownership.
- Buffer integration tests verify unchanged Unified output, accepted-pair IntraLineSegments, and unchanged old-side and new-side inline Comment and Draft placement.
- Headless Presentation tests cover soft and hard wrapping, wide and combining graphemes, decoration boundaries, disabled clipping parity, unequal and absent SideBySide halves, fixed divider position, and panes with no body cells.
- Presentation state tests cover visual-row Motions, Counts, paging, Selection deduplication, Anchor creation from a continuation, semantic jumps, resize restoration, wrapping and Layout toggles, and failed reprojection preserving the prior Frame.
- Existing prior art is detached headless rendering, CellMetrics injection, Frame navigation restoration by stable owner and source offset, Selection-to-Anchor tests, and configurable Keymap Action tests.
- Grammar validation fixtures assert exact Captures for true and false `#match?`, true and false `#eq?`, `#is-not? local`, local shadowing, fallback Captures, later-pattern precedence, UTF-8, embedded NUL, zero-width Captures, invalid ranges, unknown operators, unknown directives, malformed arguments, regex limits, and cursor match loss.
- RE2 wrapper tests verify length-bearing input, the pinned dialect, unsupported syntax diagnostics, pattern and memory limits, and one smoke test on every native target.
- UserGrammar tests run the real CLI in isolated XDG directories with native fixture libraries. They cover folder and archive input, interactive and digest trust, check without activation, install, update rollback, list, remove, enable, disable, conflict detection, configuration replacement, and installation order.
- UserGrammar failure tests cover unsafe archives, extra files, digest mismatch, tampering, wrong target, wrong ABI, missing symbol, invalid query, invalid predicate, invalid regex, runtime failure, BuiltInGrammar fallback, plain-text fallback, and inactive invalid installation.
- UserGrammar cache tests verify receipt invalidation after payload or runtime identity changes and process-lifetime reuse after first matching File. Tests do not require or imply persistent compiled-query storage.
- Deterministic runtime tests prove that only explicit forward remote traversal arms one successor. They also prove promotion without duplication, demand priority, disarm rules, LocalReview exclusion, cache-disable exclusion, bounded LRU admission, silent speculative failure, and stale Session Epoch rejection.
- Persistence tests verify that SQLite bytes and schema remain unchanged and that no File content or Highlighting output appears in state or data directories outside an installed UserGrammar bundle.
- The complete hermetic suite, RE2 smoke test, dynamic UserGrammar fixture load, and real CLI lifecycle fixture run natively on all four supported target combinations.
- Each implementation slice keeps the complete default test command green. Credential-gated Bitbucket checks remain explicit and report a clear skip when no Credential is available.

## Out of Scope

- Terminal image protocols or rendering binary content as an image.
- Bitbucket Diffstat acquisition or a remote-only File inventory.
- Persistent File content, Highlighting, compiled-query, or regex caches.
- General look-ahead, adaptive prefetch, timers, parallel old and new requests, or a prefetch configuration setting.
- LocalReview prefetch.
- UserGrammar source downloads, compilation, package discovery, or automatic updates.
- UserGrammar sandboxing. Native UserGrammars execute in the bbr process with the user's permissions.
- Wasm Grammars or confined helper processes.
- Live UserGrammar reload in a running process.
- Dirty Worktree review, ReviewRepository relinking, LocalReview Draft copy to a PullRequest, or concurrent-process synchronization.
- Explicit old-side and new-side version inspection.
- Buffer Search, Review Search, and durable File Read Receipts.
- General CI policy and live-service hardening beyond the native target proof required by RE2 and UserGrammar delivery.

## Further Notes

- Bitbucket RawDiff remains authoritative for remote File, Hunk, Line, and Anchor identity. Full content fills WholeFile gaps but never recomputes the Diff.
- File Enrichment retains independent per-side ownership and the existing whole-File inactive LRU. The focused File remains outside the inactive byte budget.
- Remote measurements showed approximately 299 ms for one content request and 531 ms for a representative two-request modified File. One-successor prefetch removes most repeated wait during forward review while limiting abandoned speculation to one File.
- Local Git content reads measured approximately 6 to 11 ms per side. This result does not justify LocalReview prefetch.
- SHA-256 proves bundle identity and integrity, not safety. UserGrammar documentation must state the native-code risk before installation steps.
- Hermetic fixtures are the release authority for Bitbucket content behavior. The live blob checker is diagnostic evidence, not a release gate.
- M17 closes the old Diffstat and persistent File cache questions with explicit no-go decisions. New evidence and a concrete user workflow are required to reopen either decision.
