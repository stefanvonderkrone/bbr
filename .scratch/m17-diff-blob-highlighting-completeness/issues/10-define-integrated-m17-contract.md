# Define the integrated M17 contract

Type: grilling
Status: resolved
Blocked by: 01, 02, 03, 04, 05, 06, 07, 08, 09

## Question

How should the accepted M17 decisions fit into the Diff, Git, Bitbucket, Highlighting, Presentation, File Enrichment, configuration, persistence, and test seams, and what dependency-ordered implementation slices and acceptance matrix make M17 executable without reopening product or architecture decisions?

## Answer

M17 lands as independently correct slices. A completed slice may become active when its own acceptance tests pass. There is no milestone feature flag. UserGrammar is the exception: expose its CLI and runtime activation only when installation, validation, registry updates, fallback, and recovery work as one complete workflow.

### Ownership and integration

- **Diff** parses RawDiff paths and binary stubs. It remains the authority for Files, Hunks, Lines, line numbers, change status, and Anchor eligibility. Binary classification does not create synthetic Lines. The index-aligned Session state exposes each present side's File Content Status and optional byte size to Buffer construction.
- **Bitbucket** normalizes Git-quoted RawDiff paths, rejects non-repository-relative paths, percent-encodes each path segment, and fetches old content from destination commit plus old path and new content from source commit plus new path. It returns classified per-side failures. No HTTP or Atlassian wire terms cross this adapter.
- **Git** continues to provide old and new content through `GitClient.blob`. It uses the same File Enrichment result and UTF-8 validation contract as Bitbucket. M17 adds no Git-only Diff or Presentation path.
- **File Enrichment** owns the mutable per-side transition from pending text to text, binary, or unavailable. It validates UTF-8 before ownership transfer or Highlighting, preserves the usable opposite side, retains typed failure reasons, and transfers no side on `OutOfMemory`. Its immutable projection gives Buffer only content, File Content Status, size, and Highlighting results.
- **Highlighting** keeps the public `Highlighter` seam unchanged. `TreeSitterHighlighter` privately owns GrammarMatch selection, validated queries, locals tracking, compiled RE2 expressions, UserGrammar handles, and process-lifetime caches. Plain-text fallback remains a successful readable result.
- **Presentation Buffer** owns side-by-side Line matching, old/new WholeFile splicing, Status Placeholder rows, and semantic Selection and Anchor projection. It never treats a Status Placeholder or blob-sourced context Line as a Hunk Line.
- **Presentation Frame** owns width-dependent wrapping into visual rows. Each visual row carries the underlying semantic owner and source-byte range. Cursor restoration uses the previous semantic owner and source offset. Buffer stays the width-independent semantic projection.
- **Presentation runtime** owns File focus, demand work, one-successor remote prefetch, WorkId, Session Epoch rejection, and atomic Frame replacement. A speculative result enters the existing File cache exactly like a late demand result.
- **Configuration** owns strict startup parsing and diagnostics. M17 adds no persistent File cache setting, prefetch setting, regex setting, or wrap-state setting. The default Keymap adds `toggle_diff_wrap = ["w"]`; users can override it through the existing `[keymap]` table. Wrap starts disabled on every process launch.
- **Persistence** stores only UserGrammar bundles, registry metadata, and validation receipts under the XDG data directory. SQLite and PendingReview schemas do not change. File content, Highlighting output, compiled queries, regexes, dynamic-library handles, wrap state, and prefetch state remain process- or Session-local.

### UserGrammar configuration

Use one strict table per installed UserGrammar in `config.toml`:

```toml
[grammars.ruby]
filenames = ["Rakefile", "Gemfile"]
compound_suffixes = ["html.erb"]
extensions = ["rb"]
shebangs = ["ruby"]
```

Each field is optional and contains ordered, non-empty UTF-8 strings. If the table supplies any match field, the table replaces all default GrammarMatch rules for that UserGrammar. An unknown Grammar name, unknown field, duplicate field, duplicate rule, empty value, malformed extension, or conflict with another active UserGrammar is a startup configuration error. Category precedence remains exact filename, compound suffix, simple extension, then shebang. Rule order inside one category is config order, installed-default order, then BuiltInGrammar order.

The installed registry, not `config.toml`, records enabled state and installation order. This keeps `enable`, `disable`, and atomic update usable without editing configuration. Config only replaces match rules.

### Build and target contract

M17 supports these native targets:

- macOS `x86_64`
- macOS `aarch64`
- Linux `x86_64`
- Linux `aarch64`

Vendor pinned RE2 and Abseil source archives and checksums. Compile them into the executable behind a small C ABI wrapper; do not expose C++ types to Zig. Keep the network-free `bbr` module C-free. The executable module owns tree-sitter, RE2, dynamic loading, UserGrammar registry I/O, and native fixture tests.

M17 pulls a narrow native CI matrix forward from M19. Every target must build and run, not only cross-compile. Each runner executes the RE2 wrapper smoke test, query predicate fixtures, dynamic UserGrammar load, real CLI lifecycle fixture, and the complete hermetic test suite. M19 still owns general CI policy and live-service hardening.

### Dependency-ordered implementation slices

1. **Pin and prove the regex runtime.** Vendor RE2 and Abseil, add the length-bearing C ABI wrapper, enforce the selected limits and dialect, and make all four native target smoke tests pass. This slice changes no highlighting behavior.
2. **Implement validated query execution.** Separate Grammar validation from per-File execution. Parse and compile `#match?`, `#eq?`, and `#is-not? local`; load pinned JavaScript and TypeScript locals queries; evaluate complete matches before Capture precedence; fail rather than publish partial Spans on cursor loss or malformed ranges. This depends on the regex runtime and may activate for BuiltInGrammars when its fixtures pass.
3. **Classify File content.** Teach the RawDiff parser to recognize binary stubs and preserve textual metadata where present. Extend File Enrichment's per-side projection with File Content Status, optional byte size, and typed unavailable reasons. Suppress unsafe fetch, Highlighting, Selection, and Anchors. Add stable Status Placeholders in both Layouts and Scopes.
4. **Complete old-side acquisition.** Normalize and encode RawDiff paths, classify endpoint failures, validate UTF-8 before transfer, fetch removed content from destination commit plus old path, and add the old-side WholeFile splice. Add the credential-gated blob shape checker as a separate build command. This depends on File content classification.
5. **Replace side-by-side index pairing.** Add deterministic order-preserving dynamic matching for each maximal removed-then-added block. Reuse token LCS similarity and the accepted threshold and tie rules. Keep Unified bytes, Diff identity, and Anchors unchanged. This slice is independent of acquisition and Highlighting.
6. **Project wrapped visual rows.** Add `toggle_diff_wrap`, geometry-aware Unified and SideBySide wrapping, decoration slicing, source-offset ownership, visual-row navigation, semantic Selection deduplication, and atomic cursor restoration. This depends on side-by-side matching because it wraps final LinePairs.
7. **Add bounded remote prefetch.** Arm one-successor prefetch only after explicit forward File traversal, promote speculative work on focus, disarm on all other focus changes, and reuse existing Session Epoch and File cache admission. This depends on complete per-side acquisition and File Content Status.
8. **Deliver UserGrammar atomically.** Add manifest and archive validation, trust confirmation, XDG registry transactions, the strict `grammars.<name>` config tables, dynamic loading, validation receipts, first-use process caching, BuiltInGrammar fallback, all lifecycle commands, and recovery diagnostics. This depends on validated query execution and the native target matrix. Do not expose partial commands in an intermediate release.
9. **Close non-implementation decisions and docs.** Remove the obsolete Diffstat deferral, document that File content and Highlighting remain Session-only, document native UserGrammar trust, and update the Keymap/configuration reference. Add no Diffstat client, persistent File cache, terminal image support, or compatibility aliases.
10. **Run integrated acceptance.** Run the complete matrix below, update M17 checkboxes only after all required evidence passes, and record test counts plus native target jobs. This depends on every prior slice.

Slices 1, 3, and 5 can begin in parallel. Slice 2 follows slice 1. Slice 4 follows slice 3. Slice 6 follows slice 5. Slice 7 follows slice 4. Slice 8 follows slice 2 and the native target matrix. Integrated acceptance joins all branches.

### Acceptance matrix

| Area | Required evidence |
| --- | --- |
| Shared Diff pipeline | The same binary, invalid UTF-8, added, modified, removed, renamed, empty, and path-special fixtures pass through remote and local File Enrichment projections. Diff and Anchor identities stay source-neutral. |
| Binary and unavailable content | Per-side status and known size are exact; the opposite text side remains usable; no unsafe fetch, Highlighting, Selection, Fold, or Anchor occurs; Status Placeholders render in Unified and SideBySide, Changes and WholeFile. |
| Blob acquisition | Hermetic Bitbucket fixtures assert commit and path choice, Git unquoting, segment encoding, redirects, empty content, typed failures, and old/new splice numbering. The optional live check reports metadata/raw mismatches and skipped fixture classes but is not a release gate. |
| Side-by-side matching | Fixtures cover insertion, deletion, related and unrelated replacement, unequal runs, repeated Lines, blank Lines, and identical input. Every underlying Line appears once; Unified output and inline Comment placement remain unchanged. |
| Wrapping | Headless tests cover soft and hard breaks, wide and combining graphemes, decoration boundaries, narrow panes, unequal SideBySide continuations, visual-row Motions and Counts, semantic Selection, continuation Anchors, resize/toggle restoration, and disabled clipping parity. |
| Predicates | Exact fixtures cover true and false `#match?` and `#eq?`, `#is-not? local`, fallback Captures, later-pattern precedence, UTF-8 and embedded NUL, diagnostics, invalid ranges, unknown operators and directives, regex limits, and cursor match loss. |
| UserGrammar | Real CLI tests in isolated XDG directories cover folder/archive input, interactive and digest trust, install/update/check/list/remove/enable/disable, atomic rollback, config replacement, conflict detection, ABI/target/query rejection, tamper detection, validation receipts, first-use cache, BuiltInGrammar precedence, and runtime plain-text fallback. |
| Prefetch and cache | A deterministic runtime test proves only explicit remote forward traversal arms one successor, demand is never duplicated or delayed, non-sequential and local navigation do not prefetch, cache disable suppresses prefetch, LRU admission remains bounded, failure stays silent until focus, and stale Epoch results cannot publish. |
| Persistence and migration | SQLite schema is byte-for-byte unchanged. No File bytes or Highlighting output appear under state/data directories except the explicitly installed UserGrammar bundle. Missing old config continues to use defaults; new grammar tables remain strict. |
| Native targets | Native macOS and Linux jobs on `x86_64` and `aarch64` run the full hermetic suite, RE2 smoke, dynamic fixture load, and CLI lifecycle. A compile-only job cannot substitute for a native run. |
| Documentation | README/config docs describe wrapping, File status behavior, no persistent File cache, and prefetch limits. UserGrammar docs state native-code risk, digest limits, platform bundle requirements, lifecycle commands, GrammarMatch precedence, fallback, and recovery. Vendor records contain exact pins and checksums. |

Completion requires all hermetic and native target rows. Credential-gated Bitbucket checks remain opt-in and must report a skip clearly when no Credential is available.
