# TODO

Actionable, near-term work. Grouped by milestone; check off as completed. Each item should be
small enough to land in one focused change with tests where the seam allows.

Sizes are relative effort (S/M/L), not calendar estimates. Dependencies noted per milestone.

## M0 — Walking skeleton  ·  S  ·  ✅ done
- [x] `build.zig` + `build.zig.zon`: pin libvaxis (`ca781b3`, min zig 0.16.0) and zf (`c35c421`).
- [x] `Credential` from env (`BITBUCKET_USERNAME` / `BITBUCKET_TOKEN` / `BITBUCKET_WORKSPACE`); fail clearly if missing.
- [x] `HttpClient` vtable seam + `StdHttpClient` (std.http.Client) + `FakeHttpClient`.
- [x] `initDefaultProxies` wired from env in `StdHttpClient`.
- [x] Bitbucket adapter: `getPullRequest(id)` → typed `PullRequest`; classify `ApiError`.
- [x] vaxis boots, alt-screen, quit key; render one PR's title/author/branches.
- [x] Test: FakeHttpClient fixture → parsed PullRequest; 401/429/5xx → correct `ApiError`. (8/8 pass)

## M1 — Diff model & parser (pure, no UI)  ·  S/M  ·  ✅ done
- [x] Bitbucket: `getDiff` (raw unified text). ✅ done. The parser supplies the File list used by the viewer; M17 will either give paginated `getDiffStat` a concrete metadata consumer or close the original deferral as obsolete.
- [x] Diff parser: RawDiff → `Diff`/`File`/`Hunk`/`Line` (Bitbucket line numbers authoritative). ✅ done — `src/diff/parser.zig`, zero-copy over the raw text.
- [x] `File` status (added/modified/removed/renamed). ✅ done. Full blob acquisition later shipped lazily in M9 because Bitbucket serves blobs from a separate endpoint.
- [x] Tests: fixtures — hunk boundaries, line numbering, adds/removes, `\ No newline`, count-omitted ranges, malformed headers, end-to-end getDiff→parse. **No UI.** ✅ 8 diff tests + 3 getDiff tests (19 total green).

## M2 — Unified diff viewer (open by id)  ·  M  ·  ✅ done
- [x] `Theme` abstraction + one default. ✅ `src/tui/theme.zig` — `dark`; selectable themes are M12.
- [x] Presentation: Sidebar (files) + DiffPane (unified) with neutral/green/red backgrounds. ✅ `src/diff/buffer.zig` (pure flatten → rows) + `src/tui/render.zig` (full-width bands, gutter line numbers, sidebar highlight).
- [x] Buffer-scoped arena. ✅ in `app.run` (buffer arena + per-frame gutter arena, reset after render). Background runtime + event queue + Session Epoch later shipped in M4, when PRs became switchable.
- [x] Basic navigation: arrows + core motions (`j`/`k`, `ctrl-d`/`ctrl-u`, `gg`/`G`, numeric Count). ✅ `src/tui/nav.zig` (pure) wired in `app.run`.
- [x] Test: headless surface asserts cell colors for a known Buffer. ✅ `render.zig` builds a detached Window over `Screen.init` and asserts band bg + sidebar highlight via `readCell`; nav math + buffer flatten unit-tested. Suite green.

## M3 — Comments (read)  ·  M  ·  ✅ done
- [x] Bitbucket: `getComments` (paginated), incl. resolved state + outdated verdict. ✅ `Client.getComments` follows `next` links; anchors carry path + old/new line; `resolved` from the resolution object; `AnchorState` honors Bitbucket's `inline.outdated`. `FakeHttpClient` gained a `responses` sequence for hermetic pagination tests.
- [x] Thread builder: flat comments → nested `Thread`s (by `parent.id`). ✅ `src/review/thread.zig` — resolves each comment to its ultimate root, buckets replies in creation order, promotes orphans, handles out-of-order input. Zero-copy over the comment slice.
- [x] ThreadPane: inline threads + PR-level comments; render ```suggestion``` blocks distinctly. ✅ woven in `buffer.buildWithComments` (PR-level section at top; inline threads under their anchored line; root/reply rows) and drawn in `render.zig` (`▸` root, `↳` reply, `±` suggestion with its own band). Multi-line bodies show the lead line + `…` (full markdown rendering is M11).
- [x] `resolved` state + reveal-resolved toggle (whole thread). ✅ resolved-but-current threads hidden by default; `R` flips `show_resolved` and rebuilds the buffer, revealing the *whole* thread. Status bar shows the toggle state.
- [x] AnchorState display (current/moved/outdated from Bitbucket verdict); per-file Outdated grouping. ✅ outdated threads grouped in a per-file "Outdated (N)" section and **never hidden** (even when resolved). Outdated is derived from each comment's `links.code` revision vs the PR's current source/destination commits — the list endpoint omits `inline.outdated` and it can't be recomputed from line numbers (see `bitbucket/CONTEXT.md`). Verified live on PR 1726 (8 outdated roots). `moved` isn't produced remotely; local diff-walk ships in M14. The Outdated group is always expanded — collapse/re-expand is scheduled for M15.
- [x] Tests: thread nesting, resolved toggle, outdated grouping. ✅ thread nesting/orphan/out-of-order (`thread.zig`), weaving + resolved toggle + outdated grouping (`buffer.zig`), headless comment/suggestion render (`render.zig`), paginated `getComments` (`client.zig`). Suite green 62/62.

## M4 — PR discovery & switching  ·  M  ·  ✅ done
- [x] Minimal read-only `GitClient`: current branch + tracking Remote (SSH/HTTPS + `url.insteadof`). ✅ `src/git/remote.zig` (pure, allocation-free URL→workspace/repo parser handling scp/ssh/https forms and longest-alias insteadof rewrites) + `src/git/client.zig` (`GitClient` seam; `ShellGitClient` shells out via `std.process.run` reading `git config --get-regexp url\..*\.insteadof`; `FakeGitClient` for tests). Detached HEAD / no origin / non-repo each map to a distinct `GitError`.
- [x] Bitbucket: list open PRs filtered by source branch. ✅ `Client.listPullRequests` follows `next` pagination, returns `[]PullRequestSummary`; optional `source_branch` filter via the `q` query language (`source.branch.name="…"`, percent-encoded). Verified live: paged through 71 open PRs of `pr-webapp`.
- [x] Startup resolution: arg → CWD auto-detect → picker; no-PR chooser; pre-filtered picker on multiple. ✅ `src/startup.zig` `resolve`: URL → explicit repo+id → auto-detect (repo from remote, adjacent PRs on the branch: 1 opens, >1 pre-filtered picker, 0 → all-open picker; empty repo → `empty`). Detached HEAD skips the branch filter.
- [x] PR Picker overlay (zf); URL parser; switch PRs with Epoch cancellation. ✅ `src/tui/picker.zig` (pure zf-ranked, navigable state machine), `src/bitbucket/url.zig` (web+API PR URL parser), and an async switch: `p` opens the picker, Enter bumps an Epoch and spawns a load worker (`std.Io.concurrent`) that builds the new `Session` off `page_allocator` and posts a `load_done` event; only the current epoch's result is applied (stale discarded). Futures are awaited before teardown.
- [x] Tests: remote URL parsing, branch detection (fake GitClient), resolution branches. ✅ remote parser (8), GitClient fakes (4), url parser (6), listPullRequests (4), resolution branches (7), picker (6), session loader over fake http (2), picker-overlay headless render (1). Suite green. `bbr detect [<repo>]` prints the resolution without the TUI (scriptable live check).

_Follow-through:_ SideBySide + folds shipped in M5, moved-anchor local diff-walk in M14, and async Picker loading in M7. Whether Picker-open should initially filter to the current branch is scheduled for M15.

## M5 — Diff polish  ·  M  ·  ✅ done
- [x] Intra-line word-diff → emphasis `Segment`s; emphasized background. ✅ `src/diff/intraline.zig` (token-level LCS: word/whitespace/punct tokens, common tokens marked, the rest coalesced into emphasized runs; `similarity()` gates edit-vs-unrelated). Woven at buffer build: `computeEmphasis` pairs a removed run with the following added run by index and attaches segments when similar ≥ 0.5. `Row.line` is now a `LineRow` (line + emphasis); renderer draws the body as styled segments so only changed runs get the brighter `added_emphasis`/`removed_emphasis` band.
- [x] SideBySide layout projection over the same Buffer. ✅ `buildWithComments` branches on layout; the side-by-side path emits a `line_pair` row (context fills both sides, add/remove fills one, a modification aligns removed+added on one row carrying each side's emphasis). Inline threads woven once per underlying line. Renderer draws each pair into two 1-row child windows split by a divider (clips at the divider). `s` toggles layout live.
- [x] Scope: Changes with `Fold`s (expand without refetch); WholeFile scope. ✅ `computeFolds` collapses context runs longer than `2*margin + min_fold`, keeping a margin next to each change; a `fold` row shows the hidden count. Folds are keyed by their first line's pointer, so revealing one adds that id to an `expanded` set and rebuilds — the hidden lines are a model subslice, so expansion is free (no refetch). `f` toggles fold-vs-whole-file scope, enter expands the fold under the cursor; a PR switch clears the expanded set. Applies in both layouts.
- [x] Arena pool/ring for multi-file view. ✅ `src/tui/arena_ring.zig` — a fixed ring of N arenas; `next()` rotates + resets. The viewer uses a ring of 2 to double-buffer the row-buffer rebuild (the displayed buffer stays valid while the next builds), replacing the single reset-and-reuse arena.
- [x] Tests: intra-line segment cases; fold expansion; projection invariants. ✅ intraline (8: partition/emphasis/insertion/identical/disjoint/empty/similarity/indent), buffer emphasis + side-by-side pairing + fold/expand/whole-file/side-by-side-fold, renderer emphasis-band + side-by-side panes + fold-row, arena ring (3). Suite green 130/130.

_Follow-through:_ true **whole-file** scope shipped in M9. Fold re-collapse is scheduled for M15; line-level side-by-side matching for change blocks is scheduled for M17.

## M6 — Pending review: authoring & persistence  ·  M  ·  ✅ done
- [x] `PendingReviewStore` seam + in-memory fake + SQLite implementation (schema + migrations). ✅ `src/review/store.zig` (ptr+vtable seam mirroring `HttpClient`, `InMemoryStore` fake) + `src/persist/sqlite_store.zig` (vendored amalgamation, `vendors/sqlite`, compiled into the exe only so the pure module stays C-free — ADR-0006). One row per Draft keyed `(pr_id, local_id)`; `PRAGMA user_version` migrations.
- [x] Composer overlay; create `Draft` (top_level / inline / reply / suggestion), incl. reply-to-draft. ✅ `src/tui/composer.zig` (pure state machine); viewer keys `c` (top-level), `i` (inline on cursor line), `S` (suggestion), `r` (reply to the comment/draft under the cursor — records the parent for M10 ordering, co-locates via the parent's anchor). ^D submits, esc cancels.
- [x] `DraftState` + `CommentTarget` persistence; resume on launch; render drafts distinctly. ✅ all four DraftStates + parent + anchor (with authored-against commit, ADR-0005) round-trip through SQLite; `app.run` loads the PR's Drafts on entry and re-loads on each PR switch (PR-scoped review arena). Drafts weave into the buffer (anchored under their line, unanchored in a "Pending" section) and render in a distinct amber band (`✎`/`↳`/`±`).
- [x] Tests: store round-trip (fake + SQLite), draft graph construction. ✅ draft graph (add/topological-order/remove), fake + SQLite round-trip (fields/anchor/parent/state, replace, scoped remove, close-reopen durability), buffer draft weaving, headless composer + draft-row render, `commitDraft` round-trip. Suite green 155.

_Follow-through:_ `AnchorState.moved` via local diff-walk shipped in M14. Side-by-side draft weaving works (via `weaveInline`), including removed-only Anchors on the old side. Full editing and an external-editor handoff are scheduled for M16.

## M7 — Responsiveness (non-blocking loads)  ·  M  ·  ✅ done
- [x] Async picker open: `p` shows the picker overlay instantly in a loading state; the `listPullRequests` fetch runs off-thread and populates the rows when it returns. ✅ done via a sibling `picker_done` event with its own `picker_epoch` generation; `Picker.initLoading`/`populate` let the overlay exist with no items yet.
- [x] Boot the TUI immediately with a static "Loading PR #N…" view instead of blocking on `session.load` before `enterAltScreen`. ✅ the initial load now goes through the `spawnLoad` path; `run` holds `current: ?*Session` and dispatches loading-view vs. viewer per frame (`render.drawLoading`). `p` still opens the picker during the initial load.
- [x] Scope parallel Session fetches and keep them out of M7 until live measurement justifies them. ✅ This is a single-load latency optimization, not responsiveness: the whole load already runs off the UI thread. `std.http.Client` reuses one keep-alive connection sequentially, while true fan-out needs another connection/TLS handshake. The measurement/implementation gate is scheduled for M19.
- [x] Tests: async picker open (loading → populated over a fake) and boot loading-view render. ✅ M19 owns fan-out ordering/parity tests if its measurement gate selects parallel loading.

_Follow-up:_ an animated spinner needs a tick thread because vaxis `nextEvent` blocks; its measured UX gate is scheduled for M15.

## M8 — File view scope (single-file)  ·  S/M  ·  ✅ done
- [x] `only_file` scope in `BuildOptions`: project the Buffer to a single File's rows. ✅ `buffer.zig` `only_file: ?usize`; when set, only `diff.files[only_file]` is emitted (header, hunks, woven inline threads/drafts, outdated section) and the PR-level comment/pending sections plus other-file stranded drafts are suppressed (`draftInScope`). Reconciles the code with the domain language (`src/diff/CONTEXT.md` Buffer entry updated: whole-Diff scroll by default, single-File isolate view as the canonical review unit).
- [x] Make the Sidebar a selector, not just a position indicator. ✅ `o` isolates the focused file (captures `fileIndexForRow(cursor)` into `isolate_file`); the sidebar highlight then tracks `isolate_file` directly. `o` again exits and lands the cursor back on that file's header (`fileHeaderRow`).
- [x] Jump-to-file motion: scroll the pane to a File's header within the all-files buffer. ✅ `[`/`]` jump the cursor to the prev/next `file_header` (`prevFileHeaderRow`/`nextFileHeaderRow` + `Nav.jumpTo`); in the isolate view they step which file is isolated instead. Both readings (jump vs. isolate) are offered.
- [x] Treat File Enrichment as Epoch-stamped work once focus has a real payload. ✅ M9 (blobs) and M13 (highlighting) implement the seam; M8 correctly keeps isolation as an in-memory projection.
- [x] Tests: `only_file` projection (one File's rows, nothing else) + isolate suppression of PR-level/other-file rows (`buffer.zig`), `Nav.jumpTo` (`nav.zig`), jump-to-file cursor math (`nextFileHeaderRow`/`prevFileHeaderRow`/`fileHeaderRow`, `app.zig`).

## M9 — True whole-file view (Bitbucket blobs)  ·  M  ·  ✅ done
Today's `WholeFile` scope shows every *fetched* diff line but not the unchanged regions **outside** the hunks — the diff endpoint only returns hunks + context. True whole-file needs the full file blob, which Bitbucket serves from a separate endpoint.
- [x] Bitbucket: fetch a file's blob at a commit. ✅ `Client.getFileBlob(repo, commit, path)` → `GET /repositories/{ws}/{repo}/src/{commit}/{path}`, raw text owned by the caller, same `classify`/`ApiError` mapping as `getDiff`. M17 owns the opt-in live shape check; M9's hermetic contract is complete.
- [x] Populate blobs **lazily per file** on the Epoch-per-file seam anticipated by M8. ✅ `Session.blobs: []FileBlob` (side table, index-aligned with `diff.files`, empty at load — blobs can't live on the const `File` the parser yields). `app.ensureBlob` fetches the *focused* file's new-side blob on a worker thread when scope is whole-file, keyed by `(pr_id, file_idx)` so each file fetches at most once; the result posts a `blob_done` event and re-weaves. Stale results (superseded PR / filled slot) are discarded; in-flight fetches are awaited before teardown.
- [x] `buffer.zig`: true-whole-file splice. ✅ `BuildOptions.whole_file` + `blobs`; `spliceNewSide` fills the gaps before/between/after hunks with `.context` lines drawn from the blob, keyed off the authoritative hunk line numbers (ADR-0001); hunk lines are copied verbatim. No hunk headers/folds in this scope. `f` cycles Changes → fetched-whole → whole-file (per the chosen 3-state model); whole-file falls back to the fetched rendering when the blob isn't loaded or the file is removed.
- [x] Anchor safety: blob-sourced context lines get `Line.in_hunk = false` and `weaveInline` refuses to attach comments/drafts to them — only hunk lines anchor.
- [x] Tests: blob fetch + `ApiError` (fake http, `client.zig`); splice invariants (hunk lines preserved, gaps filled from the blob, `in_hunk` flags, fallback to per-hunk when no blob) + anchor-safety (`buffer.zig`); `Session.blobs` alloc (`session.zig`).

_Follow-up (M17):_ add the **removed-file** old-side splice and live blob shape checks. Whole-file remains demand-loaded for the focused File; M17 also owns the measurement gate for bounded prefetch.

## M10 — Pending review: submission & failures  ·  M  ·  ✅ done
- [x] `Submission`: topological order, temp-id → CommentId remap. ✅ `src/review/submission.zig` — a pure, clock-free state machine (`advance` returns the next action as data — post/wait/done/aborted — `report` feeds outcomes back). Reply parents remap to the parent's freshly-posted `CommentId` (or a `Parent.comment`'s existing id). The network is the new `CommentPoster` ptr+vtable seam (`Poster` in `src/bitbucket/poster.zig` implements it; `Client.createComment` POSTs).
- [x] Failure model: retry (network/429/5xx), abort-on-auth, mark-and-continue (validation). ✅ retryable → capped exponential backoff (`.wait` step; 429 honors an explicit `Retry-After` param); auth (401/403) → `aborted`, everything kept pending; validation (400/404/malformed) → item `failed`, its reply-descendants `skipped` (a missing parent id blocks them naturally). Retries exhaust into an item failure after `max_attempts`.
- [x] Duplicate guard (GET-and-dedupe on ambiguous failure). ✅ a transport failure is a distinct `ambiguous` outcome; the retry sets a `dedupe` flag and the worker `findExisting`s (GET-and-match on anchor + body) before re-POSTing.
- [x] Stale-anchor check: capture SourceCommit on load, re-check head before submit. ✅ the submit worker re-fetches the PR head and, if `headChanged` vs the loaded source commit, refuses the batch (`stale`) with a "reopen the PR" message. M16 owns the explicit UX decision about any submit-anyway path.
- [x] Per-item summary + selective retry of failed subtrees. ✅ each item's fate streams back (`submit_progress`, persisted as it lands — ADR-0007 crash-safety) and rolls up into a status-bar summary (`N posted · M failed · K skipped`); a clean batch deletes its published Drafts, a partial one keeps failures pending so `X` again is selective retry (posted Drafts skipped). M16 adds the richer per-item overlay.
- [x] Tests: submission ordering, remap, each failure class, dedupe. ✅ 15 engine tests (ordering, remap, abort, skip-descendants, backoff schedule + Retry-After, dedupe-on-ambiguous, retry exhaustion, selective retry, `headChanged`, driver-through-seam) + `createComment` URL/body/id/error tests + `Poster` posted/rejected/ambiguous mapping + dedupe hit/miss. Suite green.

_Follow-up (M16):_ integration-test the async worker/event glue and surface live `Retry-After`. Submission intentionally remains single-batch-at-a-time. Bitbucket exposes no idempotency key, so the duplicate guard remains best-effort (Anchor + exact body).

## M10b — Multi-line anchors, suggestion prefill & post-submit reconcile  ·  M  ·  ✅ done
- [x] Multi-line anchors: thread `start_from`/`start_to` through the `Anchor` model, the client (send null-omitted + parse back), the `Poster` dedupe, and the SQLite store (v2 migration). ✅ Field names/roles verified by live probes on PR 1856 (`{start_to, to}` new-side, `{start_from, from}` old-side; start_* = range top).
- [x] Visual line selection: `Nav.mark` + `v` toggle and shift+arrow start/extend (one sticky model; plain motions extend, Esc clears); selection band tinted in the pane. ✅ shift+arrow is terminal-dependent so `v` is the robust primary — both drive the same state.
- [x] Selection → anchor mapping (`spanFromLines`, pure/tested): new-side range for additions+context, old-side for deletions, single line stays single-sided; refuse mixed sides / hunk gaps / file borders / a suggestion over removed lines. ✅ `i`/`S` act on the selection when active, else the cursor line.
- [x] Suggestion prefill: seed the composer with the anchored source lines so the reviewer edits real code in the fence (`Composer.seed`). ✅ plain comments stay empty.
- [x] Post-submit reconciliation: re-fetch the PR after a batch that posted anything, so published Comments reappear (ADR-0001); hide a posted/submitting Draft's row (the fetched Comment represents it) while keeping its pending descendants (ADR-0007 render-path dedup). ✅
- [x] Submit modal: float a "Submitting review — n/total" overlay over the viewer during a batch, then the loading frame covers the re-fetch. ✅ shared `centeredModal` helper extracted; picker/composer/submit all route through it.

_Follow-up (M16):_ add the `$EDITOR` handoff, live-probe old-side ranges, document Bitbucket's multi-line Suggestion UI behavior, and drive the shift+arrow/selection glue through vaxis.

## M11 — Keymap & motions  ·  S/M  ·  ✅ done
- [x] Full vim motion set + numeric Count register (`5j`, `zz`, …); arrows side by side. ✅ Added `ctrl-f`/`ctrl-b` (full page), `zz`/`zt`/`zb` (center / cursor-to-top / cursor-to-bottom scroll positioning), and `H`/`M`/`L` (cursor to viewport top/middle/bottom) as pure `Nav` methods; the existing `hjkl`/arrows/`ctrl-d`/`ctrl-u`/`gg`/`G`/Count/shift-select carry over. Skipped search/paragraph/operator-pending (no meaning in a diff viewer). `PageUp`/`PageDown` stay half-page (unchanged); `ctrl-f`/`ctrl-b` are the full-page keys.
- [x] Configurable `Keymap` seam. ✅ Vim-aligned: one `(chord)→Action` table (`src/tui/keymap.zig`) where motions and commands are both bindings, so dispatch and the help overlay read one source of truth. The Count and the multi-key **Leader** (`g`/`z`) stay in the engine (`Nav` + `Resolver`), not the table — matching how vim keeps that grammar above its mapping table. The 15-arm `key.matches` viewer chain became one `switch (Action)`; config-file overrides shipped in M12.
- [x] Keybinding-help Overlay (reads Keymap). ✅ `?` floats a centered "Keybindings" modal (`render.drawHelp`) built straight from `Keymap.default` — Motions in the left column, commands in the right, adjacent alternate bindings coalesced (`j ↓`), so it can't drift from the live table. Any key dismisses it (captures input while open); a `? help` hint sits in the status bar for discoverability.
- [x] **Multi-line comment/draft/suggestion body rendering.** ✅ Kept the one-Row-per-screen-line invariant (so `Nav`/scroll are untouched): a multi-line body emits one `CommentRow`/`DraftRow` per visual line, all sharing the owner pointer, `is_first` marking the header row (option A2). `r`/reply resolves from any line for free (every row carries the owner). Bodies render **verbatim**, fences and all (§Q5-A) — the `±` marker + suggestion band still signal a suggestion. Full body, **no cap** — the pane already scrolls. M15 owns Markdown styling and optional folding. Continuation rows hang-indent two columns; a single trailing newline is trimmed so it emits no blank row.

  _Follow-up (M15):_ Markdown rendering and a length cap/fold for pathological bodies.

## M12 — Themes & config  ·  S  ·  ✅ done
- [x] Config file. ✅ Strict, allocation-light TOML subset at `$XDG_CONFIG_HOME/bbr/config.toml` (fallback `$HOME/.config/bbr/config.toml`); a missing file uses defaults, while malformed/unknown entries produce collected path + line/column diagnostics before the TUI starts.
- [x] Built-in Themes. ✅ Default `system` follows terminal colors; fixed plain light/dark, all four Catppuccin flavors, and light/dark Gruvbox and Solarized variants resolve inside the Theme module.
- [x] **Keymap overrides from config.** ✅ `[keymap]` maps one-to-eight chord sequences to Actions (or `none`), canonicalizes modifier aliases, preserves Count, rejects prefix conflicts, and materializes one Keymap shared by dispatch and the help Overlay.

## M13 — Syntax highlighting  ·  L  ·  ✅ done
- [x] `Highlighter` seam + `PlainHighlighter`. ✅ C-free ptr/vtable seam; ordered line-relative `Span`s and zero-copy `LineDecoration` live in the core module.
- [x] tree-sitter Zig bindings; decide built-in Grammar delivery. ✅ C runtime and copied, pinned Grammar sources compile into the executable; no submodules or build-time downloads (ADR-0009). Grammar selection remains private to the adapter so M17 can add `UserGrammar` installation without changing the public seam.
- [x] Grammars: tsx/jsx, css, go, bash, json, yaml + highlight queries. ✅ JavaScript/TypeScript/TSX, CSS, Go, Bash, JSON, and YAML are vendored with commits/checksums and fixture tests; unsupported Files stay plain.
- [x] Compose syntax foreground over diff background per cell; wire into `Theme`. ✅ Buffer constructs `LineDecoration`s from side-specific Spans + intra-line emphasis; Presentation maps Capture foregrounds while retaining diff/emphasis/cursor backgrounds.

_Delivery notes:_ focused Files enrich lazily off-thread in one old/new pipeline; partial side failures remain usable and report context in the status bar. `[highlight].max_file_bytes` defaults to 2 MiB per side (`0` = unlimited). M17 owns query-predicate support and the `UserGrammar` lifecycle.

## M14 — Local / offline review  ·  M/L  ·  ✅ done
- [x] Explicit `bbr local [base-ref] [source-ref]` entry with no credential requirement: SourceRef defaults to the current Worktree branch; BaseRef defaults to Git's locally recorded remote default and otherwise requires an argument.
- [x] Extend `GitClient` with diffing subset: worktree list, ref resolution, `diff` between refs, blob at ref.
- [x] `DiffSource` abstraction; local `git diff <base>..<branch>` → same Diff parser.
- [x] Local `CommentTarget` in SQLite (no submission path); Presentation enforces one target per PendingReview.
- [x] Durable ReviewRepository identity: stable store-assigned id with normalized Remote and common-Git-directory aliases; share no-remote linked Worktrees, but keep unverifiable separate no-remote clones distinct. Refuse alias conflicts rather than merging automatically. TempIds are reserved transactionally across processes.
- [x] Local anchor lifecycle via diff-walking (`git diff <anchor_commit> <ref>`); committed refs only. Resolve all persisted root Draft anchors to current/moved/outdated/unavailable while staging the candidate Session, before atomic publication; cache compatible transition Diffs and keep outdated/unavailable anchors visible from immutable snapshots.
- [x] Shared configurable `R` refresh Action: atomically reload the same PullRequest or re-resolve the same LocalReview's Refs. Remote-only Actions stay discoverable but grey in local help and report a status message when invoked.
- [x] Tests: shell worktree/ref/diff/blob acquisition, DiffSource parity, repository aliases and concurrent TempIds, local authoring/snapshots/action gating, and local anchor mapping/projection (current/moved/outdated/unavailable).

## M15 — Presentation & navigation polish  ·  M  ·  needs M14
Finish the visible interaction details deferred by M3–M14 before expanding the product surface.
- [x] File-content cache configuration UX: `[files.cache]` exposes `enabled` and `max_bytes`, defaults to a 256 MiB inactive-content budget, treats zero as unlimited, excludes the focused File, and cleanly rejects the pre-release superseded key. User documentation distinguishes retention from `[highlight].max_file_bytes`; M17 separately decides whether to add persistent disk caching.
- [ ] Resolved threads: show a collapsed **indicator** in place (not just hide-behind-toggle), e.g. `✓ resolved · N replies`, that expands the whole Thread on demand. **Note:** this reverses the current domain rule — the Thread entry in `src/review/CONTEXT.md` explicitly says "never a bare 'a resolved comment exists' marker". Confirm and update that glossary entry (and the `show_resolved` behaviour in `buffer.zig`) as part of this item. Reply count comes from `Thread.replies.len`.
- [ ] Make both context Folds and per-file Outdated sections independently collapsible and re-collapsible. Preserve expansion state across Buffer rebuilds and clear it only when its Session identity is no longer valid. This closes the one-way Fold and always-expanded Outdated follow-ups from M3/M5.
- [ ] Layout polish: borders/separators around panes and overlays (sidebar ↔ diff, the composer modal, section dividers). Today panes are separated by spacing only (`src/tui/render.zig`); add box-drawing borders styled via the active `Theme`.
- [ ] Sidebar: the per-file comment/draft counts should be **right-aligned and always visible**, and the file name **truncated with an ellipsis** when the row is too narrow. Today the counts are printed immediately after the name using the name segment's `PrintResult.col` (`drawSidebar` in `render.zig`), so a long name pushes them off-screen. Reserve a fixed right-hand column for the counts, then truncate the name to fill the remaining width.
- [ ] Keep the active File visible when navigating the Diff by automatically scrolling the Sidebar. Prefer positioning the active entry near the vertical center when enough surrounding entries exist, while handling the beginning and end of the list naturally.
- [ ] Replace the Sidebar's flat File list with a collapsible File tree derived from repository paths. Preserve the active-File indicator, comment/draft counts, and keyboard navigation across collapsed directories.
- [ ] Add fuzzy finding over the Files changed by the current Pull Request, with selection moving focus directly to the chosen File.
- [ ] Tune Pull Request picker fuzzy matching so the Pull Request title is preferred over its id when ranking matches; keep id matching available for users who know the number.
- [ ] Consider `c` for an inline Comment and `C` for a whole-File Comment. Evaluate the bindings against existing Actions and help text, then make the scope distinction clear in the composer.
- [ ] Evaluate mouse support for high-value interactions such as focusing Files, scrolling panes, expanding/collapsing tree nodes and Threads, and placing or extending a selection. Define terminal/SSH compatibility and keyboard-parity expectations before committing to an implementation.
- [ ] Yank to clipboard: a `y` Action that copies the current diff line (or, with an active selection, the selected lines) to the system clipboard. Add a `yank` Action to the Keymap and copy the underlying source text — the code content of each `BufferRow`, not the rendered gutter/marker decoration — joined by newlines. Use libvaxis's OSC 52 clipboard write (`vaxis.copyToSystemClipboard` / the `Vaxis.copy_to_clipboard` path) so it works over SSH without a local clipboard daemon; verify the exact API against the 0.6.0 source before wiring it. Count-aware like other Motions (`3y`).
- [ ] Render Comment/Draft Markdown (at least headings, emphasis, links, and fence-aware Suggestions) and add a configurable collapsed summary for pathological body lengths, expandable in place.
- [ ] Add an event-loop tick only if an instrumented UX check shows the static loading frame feels stalled; use it for a loading spinner without weakening the blocking `nextEvent` model.
- [ ] Decide whether opening the Picker should retain the current all-open list or initially filter to the adjacent branch; whichever behavior wins, make the active filter visible and easy to clear.

## M16 — Review-item mutation & submission hardening  ·  M/L  ·  needs M10b
Complete the repair and mutation workflows around the client-side Pending Review. The detailed
acceptance criteria already live in `.scratch/review-item-mutation/issues/`.
- [ ] Implement `.scratch/review-item-mutation/issues/01-edit-reanchor-delete-drafts.md`: edit Draft bodies without changing identity, re-anchor root Drafts, cascade deletion through Draft descendants, enforce active/recovered SubmissionRun immutability, and persist before publishing Presentation state.
- [ ] Implement `.scratch/review-item-mutation/issues/02-edit-delete-owned-bitbucket-comments.md`: verify Bitbucket Cloud's authorship and mutation contract, expose edit/delete only for author-owned Comments, and reconcile after success.
- [ ] Add an `$EDITOR` handoff for substantial or prefilled multi-line bodies: write a secure temporary file, suspend/restore the terminal safely, read the result through `Composer.seed`, and preserve cancel/error semantics. Keep the inline Composer for short edits.
- [ ] Replace the status-bar-only Submission result with a per-item overlay showing posted/failed/skipped state, classified reason, reply dependency, and the selective-retry subtree.
- [ ] Surface Bitbucket's `Retry-After` response header through `HttpClient`/`Poster`, and tune retry/backoff limits from observed rate-limit behavior while retaining the pure engine override tests.
- [ ] Decide and document SourceCommit-change UX. Default to reload/re-anchor; add an explicit submit-anyway path only if its anchor and confirmation semantics can be made unambiguous.
- [ ] Add deterministic integration coverage for the async Submission worker/event glue and vaxis selection input, including recovery and stale-epoch rejection.
- [ ] Live-probe old-side multi-line Comment ranges and document the observed Bitbucket UI behavior for multi-line Suggestions; keep unsupported behavior out of the UI.

## M17 — Diff, blob & highlighting completeness  ·  M/L  ·  needs M13
Close fidelity gaps in the shared remote/local rendering pipeline.
- [ ] Detect binary Files from diff stubs and non-UTF-8 blobs, suppress text enrichment, and render a clear size/status placeholder. Treat terminal image protocols as a separately gated stretch, not baseline behavior.
- [ ] Fetch the old-side blob for removed Files and splice a true whole-file deletion view. Add an opt-in live shape check for both old- and new-side Bitbucket blob endpoints; fixtures remain the hermetic test tier.
- [ ] Replace index-based removed/added pairing in side-by-side change blocks with tested line-level matching so insertions do not misalign the rest of a block.
- [ ] Decide whether Bitbucket `diffstat` adds metadata the parsed Diff cannot supply. Implement paginated `getDiffStat` only for a concrete consumer; otherwise record the M1 deferral as obsolete.
- [ ] Evaluate focused-only whole-file fetching against sequential all-file review. Keep demand loading as the baseline, and add bounded prefetch only if measurements show it improves navigation without defeating the File cache budget.
- [ ] Evaluate and implement the tree-sitter query predicates needed by the built-in queries, with fixtures proving captures are neither silently dropped nor incorrectly applied.
- [ ] Deliver the `UserGrammar` workflow anticipated by ADR-0009: installation/update/removal, trust and ABI checks, query validation, ordered GrammarMatch configuration, and cache lifecycle without changing the `Highlighter` seam.
- [ ] Decide whether a persistent disk cache earns its storage/invalidation complexity; document a no-go decision or introduce it behind the existing in-memory File cache policy.

## M18 — Local-review expansion  ·  L  ·  needs M14
Address the workflows intentionally excluded from the committed-ref MVP.
- [ ] Review dirty index/worktree changes through the common Diff pipeline. Define a stable snapshot identity and fuzzy content-based Anchor projection before allowing locally authored Drafts on mutable lines.
- [ ] Add an explicit ReviewRepository relink/merge workflow for no-Remote clones and alias conflicts, with preview, conflict refusal, transactional migration, and rollback-safe tests.
- [ ] Design an explicit copy workflow from a LocalReview's Drafts to an AdjacentPullRequest's PendingReview. Never retarget or silently mix `CommentTarget`s; preview every Anchor translation and leave the source Review intact.
- [ ] Evaluate live synchronization between concurrent bbr processes. Keep explicit refresh as the documented baseline unless a watcher/notification design preserves atomic Session replacement.

## M19 — Operational hardening & product gates  ·  S/M  ·  needs M14
Turn the remaining environment-dependent questions into measured decisions.
- [ ] Add CI for `zig build test` on Zig 0.16.0 plus `zig fmt --check`; keep live Bitbucket checks opt-in and credential-gated.
- [ ] Rotate the API token currently present in plaintext `opencode.jsonc`, remove it from tracked/local plaintext configuration, and document environment/keychain injection without logging secret values.
- [ ] Identify the corporate proxy/authentication type and run a representative connectivity check. Add a libcurl adapter only if `std.http.Client` cannot support the observed requirement; otherwise close the fallback decision.
- [ ] Benchmark sequential versus parallel PR/diff/comment loading against the live API, including TLS handshakes and rate-limit behavior. Implement fan-out and order-independent fakes only when the measured latency gain justifies the second connection.
- [ ] Decide whether approve/merge/decline belongs in bbr after the review workflow is stable. If accepted, specify permissions, confirmation, stale-head, and failure behavior before adding Actions; otherwise record it as a durable non-goal.

## M20 — Side-aware version inspection  ·  M  ·  needs M15/M17
Make old-versus-new File version choice explicit after M15 establishes the Presentation contract
and M17 closes the remaining old-side and side-by-side fidelity gaps.
- [ ] Resolve `.scratch/side-version-navigation/issues/01-choose-old-new-side-inspection-and-yank.md`: decide how a reviewer switches between old and new versions for isolated viewing and clipboard operations, including Action grammar, visible side indication, Selection/Count behavior, unavailable sides, state lifetime, and keyboard/mouse parity.

## M21 — Buffer & Review search  ·  M/L  ·  needs M20
Find source text without leaving the review, first within the current DiffPane Buffer and then
across the complete contents of every changed File in the current Review.
- [ ] Add `/` search for the current Buffer. Open an inline query prompt, update matches as the reviewer types, highlight every occurrence, show the active/total match count, and use `n`/`N` to move forward/backward with wraparound. `esc` cancels without moving; accepting an empty query retains the previous query. Match semantic source and authored body text, not gutters, borders, or other generated presentation chrome.
- [ ] Define and test predictable query semantics: Buffer Search uses literal smart-case matching; Review Search uses fuzzy ranking while preserving exact occurrence locations. Matching operates on Unicode text without allowing invalid/non-text File content to break the search.
- [ ] Add a Review Search Overlay that searches the full selected version of every changed File, not only loaded blobs or visible diff hunks. Show one selectable result per occurrence with path, line/column, and a contextual snippet; keep a larger preview of the selected occurrence with all query hits highlighted, comparable to a live-grep picker.
- [ ] Stream Review Search results as File content becomes available without blocking input. Scope acquisition and result publication to the Session Epoch, cancel stale work on review replacement, bound concurrent File Enrichment, honor the File cache budget, and expose per-File loading/failure state without discarding usable results.
- [ ] Selecting an occurrence closes the Overlay, focuses its File and selected side, switches to WholeFile scope when the line is outside a visible hunk, and positions the cursor on the exact occurrence. Returning to the Overlay preserves the query and selection while the Session remains current.
- [ ] Support remote PullRequests and LocalReviews through their existing File Enrichment seams. Search the chosen old/new side from M20; when a side is unavailable (including binary Files), show that explicitly instead of silently searching a different version.
- [ ] Add pure matcher/ranker tests plus Presentation integration coverage for incremental input, match highlighting, `n`/`N`, streamed result ordering, preview selection, navigation into out-of-hunk content, partial failures, and stale-Epoch rejection.

## M22 — Durable File read state  ·  M  ·  needs M15/M17
Make review progress visible in the File Tree and preserve it locally without allowing a changed
File to inherit an obsolete read decision.
- [ ] Derive a deterministic File Review Fingerprint from the review-visible change: old/new path, change kind, side availability, and canonical old/new diff content (including the binary/removed-file representation completed by M17). The fingerprint must remain stable across an unchanged Session reload but change whenever what the reviewer must inspect changes; do not use the PullRequest SourceCommit alone, which would invalidate unrelated Files.
- [ ] Add a reviewer-local File Read Receipt keyed by `ReviewIdentity` and canonical File path (new path when present, otherwise old path), carrying the File Review Fingerprint that was accepted. Persist receipts in SQLite through a narrow `FileReadStore` seam with an in-memory fake; add a forward `PRAGMA user_version` migration without coupling the state to PendingReview Draft rows.
- [ ] Render every File without a matching receipt in bold in the File Tree. A File with a matching receipt renders at regular weight. Directory rows remain structural, but may summarize descendant progress without replacing the per-File distinction.
- [ ] Add a configurable `toggle_file_read` Action, initially bound to `m`, for the focused File in either the Sidebar or DiffPane. Persist before publishing the regular-weight state; a failed write leaves the File bold and reports the error. Toggling a read File back to unread deletes its receipt so reviewers can correct accidental completion.
- [ ] During Candidate Session preparation and explicit refresh, load receipts and compare them with the new File Review Fingerprints before atomic publication. A missing, mismatched, or unverifiable fingerprint is unread and therefore bold; discard stale receipts for changed or no-longer-participating Files. A receipt-load failure must not block the Review—publish conservatively with Files unread and a visible warning.
- [ ] Preserve matching read state across quit/reopen, PullRequest switching, Session replacement, and LocalReview Ref refresh. Keep receipts isolated by full ReviewIdentity so equal paths or PullRequestIds in different Reviews never share progress.
- [ ] Add fingerprint fixtures and fake/SQLite round-trip tests, plus Presentation coverage for initial bold styling, successful and failed toggles, unchanged reload retention, selective invalidation when only one File changes, rename/removal/binary cases, storage failure fallback, and ReviewIdentity isolation.

### Closed historical deferrals

The following notes remain in M0–M14 as implementation history but require no post-M14 work:
M1 blob capture → M9; M2 background runtime/Epoch → M4; M3/M6 moved Anchors → M14;
M4/M7 async Picker loading → M7; M5 true whole-file scope → M9; M8 per-File Epoch work →
M9/M13 File Enrichment; M11 config loading → M12; M13 grammar delivery → ADR-0009.

---

## Sequencing at a glance

```
M0 ─ M1 ─ M2 ─┬─ M3 ─ M6 ─ M10    (authoring → submission)
              ├─ M4              (PR discovery)
              ├─ M5              (diff polish)
              ├─ M4 ─ M7         (responsiveness / non-blocking loads)
              ├─ M8 ─ M9         (file view scope → true whole-file via blobs)
              ├─ M11             (keymap)
              ├─ M12             (themes/config)
              ├─ M13             (highlighting)
              ├─ M15             (presentation & navigation polish)
              ├─ M6 ─ M10b ─ M16 (review-item mutation & submission hardening)
              ├─ M9 ─ M13 ─ M17  (diff, blob & highlighting completeness)
              ├─ M3 ─ M6 ─ M14 ─ M18 (local-review expansion)
              ├─ M14 ─ M19       (operational hardening & product gates)
              ├─ M15 ─ M17 ─ M20 ─ M21 (side-aware inspection → review search)
              └─ M15 ─ M17 ─ M22 (durable File read state)
```

**MVP line:** M0–M3 gives a usable read-only reviewer; M4 makes it ergonomic; M6+M10 make it
write-capable (the headline). M5/M7/M8/M9/M11/M12/M13 are parallelizable polish once M2 lands; M14 is the
largest standalone feature and depends only on read + authoring, not submission. M15–M22 gather
all still-actionable follow-ups recorded by the completed milestones, design open questions,
ADRs, domain docs, and the local issue tracker.
