# 01: Decide how a ready GrammarLibrary reaches an admitted File

Status: ready-for-human
Blocked by: none
Spec: [M33 brief](../brief.md)

## Problem

The brief promises Spans after the GrammarLibrary becomes ready.
Line 85 says "The Spans arrive when the GrammarLibrary is ready".
Line 201 says that the File Enrichment worker adds the Spans "as it does for content today".
Line 208 says that a ready GrammarLibrary adds the injected Spans "at the next Enrichment".

The current code has no path for this.
A File is enriched once, and its first result is final.
A File that shows plain text because its GrammarLibrary is not ready never gets Spans in the same Session.
This limit is older than PR #33. Commit `88696013` (2026-07-11) added the `AlreadyAdmitted` check.

## Evidence

- A side without a Grammar is a finished result.
  `highlightBuiltIn` returns `.{ .spans = &.{} }` when no BuiltInGrammar matches (`src/highlight/tree_sitter_highlighter.zig:128`).
  `enrichSide` stores it as `.ready` (`src/tui/file_enrichment.zig:411`), and `projectSide` sets the status `.ready` (`src/tui/file_enrichment.zig:906`).
- Presentation never asks for a second Enrichment of that File.
  `sideNeedsEnrichment` is true only for `.pending` (`src/tui/file_enrichment.zig:978`).
  Every queue site in `src/tui/presentation.zig` checks `needsEnrichment` first (lines 12457, 12463, 12470, and 12475).
- The Storage rejects a second result for the File.
  `checkAdmission` returns `error.AlreadyAdmitted` when a side holds content (`src/tui/file_enrichment.zig:685`).
  `stageAdmission` and `admit` call it (`src/tui/file_enrichment.zig:680` and `:693`).
- Presentation treats that error as a refused build, not as new Spans.
  `admissible` returns false on `AlreadyAdmitted` (`src/tui/presentation.zig:4310`).
  The caller then calls `refuseEnrichments` (`src/tui/presentation.zig:9998`), which sets `action_error = .action_refused` (`src/tui/presentation.zig:10392`).
- Cache eviction is the only way back to `.pending`.
  `stageCacheVictims` sets a content side to `.pending` through `retainedTerminalSide` (`src/tui/file_enrichment.zig:935` and `:1024`).
  It never evicts a focused or leased File (the assertion at `:937`), and the default `CachePolicy` has no byte limit (`:486`).
  So the File that the reviewer reads keeps its plain text.

Measured on 2026-11-17 with a temporary test, not committed.
The test admitted a content result with no Spans for File 0, and then a second result.
`needsEnrichment(0)` was false, and the second `admit` returned `error.AlreadyAdmitted`.

## Options

The operator decides. The agent does not choose.

| Option | What changes | Cost |
| --- | --- | --- |
| A. Re-highlight an admitted File | A new side state, such as "content without its Grammar", makes `needsEnrichment` true again when the GrammarLibrary becomes ready. A re-highlight request reuses the retained blob and needs no fetch. The single queued Enrichment rebuild replaces the File's Spans through a new Storage operation that retires the old side, as `stageCacheVictims` does. | The most code. It adds a Storage transition, a request kind, and a readiness event from the GrammarLibrary loader to Presentation. A Read Lease on the old side must stay valid. The Buffer rebuild and Review Search must accept new Spans for the same blob. A focused File gets Spans without a refetch. |
| B. Reload the File when its GrammarLibrary becomes ready | The readiness event resets each File of that language to `.pending`, also a focused File. The normal Enrichment path then fetches and highlights it again. | Less code than A, but a new reset path for focused and leased Files, because eviction cannot reset them. Each File is fetched again. A remote Review pays the Bitbucket requests again. Between the reset and the new result, the File shows its pending state, so the reviewer can see a flicker. |
| C. Wait for the GrammarLibrary before the first admission | `enrichSide` waits for the download, the check, and the load before it highlights. A failed download gives plain text, as today. | The least Presentation code. The content of the File, its Whole File gaps, and Review Search over it wait for the download. A side task holds its worker while it waits. With at most 4 speculative Files and the active File (`src/tui/presentation.zig:5739`), a slow download delays the other Files too. |
| D. Accept plain text until the next Session load | Nothing in the Enrichment path changes. The brief changes lines 85, 201, and 208 to say that the Spans come at the next Session load, such as a Refresh. | No code. The first Review of a new language shows plain text for that File for the whole Session. The reviewer must refresh to see Spans. |

An injected GrammarLibrary has the same limit, because the host File is already admitted with its host Spans.
Each option must also cover that case.

## Comments
