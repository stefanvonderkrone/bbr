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

## M1 — Diff model & parser (pure, no UI)  ·  S/M  ·  needs M0
- [x] Bitbucket: `getDiff` (raw unified text). ✅ done · `getDiffStat` (paginated file list) deferred to M2 (viewer needs the file list, not the parser).
- [x] Diff parser: RawDiff → `Diff`/`File`/`Hunk`/`Line` (Bitbucket line numbers authoritative). ✅ done — `src/diff/parser.zig`, zero-copy over the raw text.
- [x] `File` status (added/modified/removed/renamed). ✅ done. Full old/new blob capture deferred — needed only for `WholeFile` scope (M5), and Bitbucket serves blobs from a separate endpoint.
- [x] Tests: fixtures — hunk boundaries, line numbering, adds/removes, `\ No newline`, count-omitted ranges, malformed headers, end-to-end getDiff→parse. **No UI.** ✅ 8 diff tests + 3 getDiff tests (19 total green).

## M2 — Unified diff viewer (open by id)  ·  M  ·  needs M1
- [x] `Theme` abstraction + one default. ✅ `src/tui/theme.zig` — `dark`; selectable themes are M12.
- [x] Presentation: Sidebar (files) + DiffPane (unified) with neutral/green/red backgrounds. ✅ `src/diff/buffer.zig` (pure flatten → rows) + `src/tui/render.zig` (full-width bands, gutter line numbers, sidebar highlight).
- [x] Buffer-scoped arena. ✅ in `app.run` (buffer arena + per-frame gutter arena, reset after render). — Background runtime + event-queue + Epoch **deferred to M4**: nothing to cancel until PRs can be *switched*; M2 fetches synchronously in `main`.
- [x] Basic navigation: arrows + core motions (`j`/`k`, `ctrl-d`/`ctrl-u`, `gg`/`G`, numeric Count). ✅ `src/tui/nav.zig` (pure) wired in `app.run`.
- [x] Test: headless surface asserts cell colors for a known Buffer. ✅ `render.zig` builds a detached Window over `Screen.init` and asserts band bg + sidebar highlight via `readCell`; nav math + buffer flatten unit-tested. Suite green.

## M3 — Comments (read)  ·  M  ·  ✅ done
- [x] Bitbucket: `getComments` (paginated), incl. resolved state + outdated verdict. ✅ `Client.getComments` follows `next` links; anchors carry path + old/new line; `resolved` from the resolution object; `AnchorState` honors Bitbucket's `inline.outdated`. `FakeHttpClient` gained a `responses` sequence for hermetic pagination tests.
- [x] Thread builder: flat comments → nested `Thread`s (by `parent.id`). ✅ `src/review/thread.zig` — resolves each comment to its ultimate root, buckets replies in creation order, promotes orphans, handles out-of-order input. Zero-copy over the comment slice.
- [x] ThreadPane: inline threads + PR-level comments; render ```suggestion``` blocks distinctly. ✅ woven in `buffer.buildWithComments` (PR-level section at top; inline threads under their anchored line; root/reply rows) and drawn in `render.zig` (`▸` root, `↳` reply, `±` suggestion with its own band). Multi-line bodies show the lead line + `…` (full markdown rendering is M11).
- [x] `resolved` state + reveal-resolved toggle (whole thread). ✅ resolved-but-current threads hidden by default; `R` flips `show_resolved` and rebuilds the buffer, revealing the *whole* thread. Status bar shows the toggle state.
- [x] AnchorState display (current/moved/outdated from Bitbucket verdict); per-file Outdated collapsible. ✅ outdated threads grouped in a per-file "Outdated (N)" section and **never hidden** (even when resolved). Outdated is derived from each comment's `links.code` revision vs the PR's current source/destination commits — the list endpoint omits `inline.outdated` and it can't be recomputed from line numbers (see `bitbucket/CONTEXT.md`). Verified live on PR 1726 (8 outdated roots). `moved` isn't produced remotely; local diff-walk for `moved` is M6. The Outdated group is always expanded — fold/collapse deferred to M5 (`Fold`s).
- [x] Tests: thread nesting, resolved toggle, outdated grouping. ✅ thread nesting/orphan/out-of-order (`thread.zig`), weaving + resolved toggle + outdated grouping (`buffer.zig`), headless comment/suggestion render (`render.zig`), paginated `getComments` (`client.zig`). Suite green 62/62.

## M4 — PR discovery & switching  ·  M  ·  ✅ done
- [x] Minimal read-only `GitClient`: current branch + tracking Remote (SSH/HTTPS + `url.insteadof`). ✅ `src/git/remote.zig` (pure, allocation-free URL→workspace/repo parser handling scp/ssh/https forms and longest-alias insteadof rewrites) + `src/git/client.zig` (`GitClient` seam; `ShellGitClient` shells out via `std.process.run` reading `git config --get-regexp url\..*\.insteadof`; `FakeGitClient` for tests). Detached HEAD / no origin / non-repo each map to a distinct `GitError`.
- [x] Bitbucket: list open PRs filtered by source branch. ✅ `Client.listPullRequests` follows `next` pagination, returns `[]PullRequestSummary`; optional `source_branch` filter via the `q` query language (`source.branch.name="…"`, percent-encoded). Verified live: paged through 71 open PRs of `pr-webapp`.
- [x] Startup resolution: arg → CWD auto-detect → picker; no-PR chooser; pre-filtered picker on multiple. ✅ `src/startup.zig` `resolve`: URL → explicit repo+id → auto-detect (repo from remote, adjacent PRs on the branch: 1 opens, >1 pre-filtered picker, 0 → all-open picker; empty repo → `empty`). Detached HEAD skips the branch filter.
- [x] PR Picker overlay (zf); URL parser; switch PRs with Epoch cancellation. ✅ `src/tui/picker.zig` (pure zf-ranked, navigable state machine), `src/bitbucket/url.zig` (web+API PR URL parser), and an async switch: `p` opens the picker, Enter bumps an Epoch and spawns a load worker (`std.Io.concurrent`) that builds the new `Session` off `page_allocator` and posts a `load_done` event; only the current epoch's result is applied (stale discarded). Futures are awaited before teardown.
- [x] Tests: remote URL parsing, branch detection (fake GitClient), resolution branches. ✅ remote parser (8), GitClient fakes (4), url parser (6), listPullRequests (4), resolution branches (7), picker (6), session loader over fake http (2), picker-overlay headless render (1). Suite green. `bbr detect [<repo>]` prints the resolution without the TUI (scriptable live check).

_Deferred:_ SideBySide + folds (M5), moved-anchor local diff-walk (M6). The Picker lists **all** open PRs on open (not re-filtered to the current branch); PR-list fetch on picker-open is synchronous (one request) while the *switch load* is async — listing could go async later if it ever feels slow.

## M5 — Diff polish  ·  M  ·  ✅ done
- [x] Intra-line word-diff → emphasis `Segment`s; emphasized background. ✅ `src/diff/intraline.zig` (token-level LCS: word/whitespace/punct tokens, common tokens marked, the rest coalesced into emphasized runs; `similarity()` gates edit-vs-unrelated). Woven at buffer build: `computeEmphasis` pairs a removed run with the following added run by index and attaches segments when similar ≥ 0.5. `Row.line` is now a `LineRow` (line + emphasis); renderer draws the body as styled segments so only changed runs get the brighter `added_emphasis`/`removed_emphasis` band.
- [x] SideBySide layout projection over the same Buffer. ✅ `buildWithComments` branches on layout; the side-by-side path emits a `line_pair` row (context fills both sides, add/remove fills one, a modification aligns removed+added on one row carrying each side's emphasis). Inline threads woven once per underlying line. Renderer draws each pair into two 1-row child windows split by a divider (clips at the divider). `s` toggles layout live.
- [x] Scope: Changes with `Fold`s (expand without refetch); WholeFile scope. ✅ `computeFolds` collapses context runs longer than `2*margin + min_fold`, keeping a margin next to each change; a `fold` row shows the hidden count. Folds are keyed by their first line's pointer, so revealing one adds that id to an `expanded` set and rebuilds — the hidden lines are a model subslice, so expansion is free (no refetch). `f` toggles fold-vs-whole-file scope, enter expands the fold under the cursor; a PR switch clears the expanded set. Applies in both layouts.
- [x] Arena pool/ring for multi-file view. ✅ `src/tui/arena_ring.zig` — a fixed ring of N arenas; `next()` rotates + resets. The viewer uses a ring of 2 to double-buffer the row-buffer rebuild (the displayed buffer stays valid while the next builds), replacing the single reset-and-reuse arena.
- [x] Tests: intra-line segment cases; fold expansion; projection invariants. ✅ intraline (8: partition/emphasis/insertion/identical/disjoint/empty/similarity/indent), buffer emphasis + side-by-side pairing + fold/expand/whole-file/side-by-side-fold, renderer emphasis-band + side-by-side panes + fold-row, arena ring (3). Suite green 130/130.

_Deferred:_ true **whole-file** scope (unchanged regions *outside* the fetched hunks) needs the file blob from a separate Bitbucket endpoint — the current whole-file scope shows every *fetched* line. **Now planned as its own milestone, M9.** Fold re-collapse is one-way (revealed folds stay revealed until the scope toggles). Side-by-side pairs removed[k]↔added[k] by index (no LCS line-matching across a block).

## M6 — Pending review: authoring & persistence  ·  M  ·  ✅ done
- [x] `PendingReviewStore` seam + in-memory fake + SQLite implementation (schema + migrations). ✅ `src/review/store.zig` (ptr+vtable seam mirroring `HttpClient`, `InMemoryStore` fake) + `src/persist/sqlite_store.zig` (vendored amalgamation, `vendors/sqlite`, compiled into the exe only so the pure module stays C-free — ADR-0006). One row per Draft keyed `(pr_id, local_id)`; `PRAGMA user_version` migrations.
- [x] Composer overlay; create `Draft` (top_level / inline / reply / suggestion), incl. reply-to-draft. ✅ `src/tui/composer.zig` (pure state machine); viewer keys `c` (top-level), `i` (inline on cursor line), `S` (suggestion), `r` (reply to the comment/draft under the cursor — records the parent for M10 ordering, co-locates via the parent's anchor). ^D submits, esc cancels.
- [x] `DraftState` + `CommentTarget` persistence; resume on launch; render drafts distinctly. ✅ all four DraftStates + parent + anchor (with authored-against commit, ADR-0005) round-trip through SQLite; `app.run` loads the PR's Drafts on entry and re-loads on each PR switch (PR-scoped review arena). Drafts weave into the buffer (anchored under their line, unanchored in a "Pending" section) and render in a distinct amber band (`✎`/`↳`/`±`).
- [x] Tests: store round-trip (fake + SQLite), draft graph construction. ✅ draft graph (add/topological-order/remove), fake + SQLite round-trip (fields/anchor/parent/state, replace, scoped remove, close-reopen durability), buffer draft weaving, headless composer + draft-row render, `commitDraft` round-trip. Suite green 155.

_Deferred:_ `AnchorState.moved` via local diff-walk (needs the GitClient diffing subset — M14). Side-by-side draft weaving works (via `weaveInline`), but a draft anchored to a *removed-only* line pairs on the old side only. The Composer is append-only (no mid-text cursor); full editing is post-MVP.

## M7 — Responsiveness (non-blocking loads)  ·  M  ·  ✅ core done (fan-out deferred)
- [x] Async picker open: `p` shows the picker overlay instantly in a loading state; the `listPullRequests` fetch runs off-thread and populates the rows when it returns. ✅ done via a sibling `picker_done` event with its own `picker_epoch` generation; `Picker.initLoading`/`populate` let the overlay exist with no items yet.
- [x] Boot the TUI immediately with a static "Loading PR #N…" view instead of blocking on `session.load` before `enterAltScreen`. ✅ the initial load now goes through the `spawnLoad` path; `run` holds `current: ?*Session` and dispatches loading-view vs. viewer per frame (`render.drawLoading`). `p` still opens the picker during the initial load.
- [ ] _Deferred (needs live measurement)._ Parallelize the initial fetches in `loadWith` (`session.zig`): `getPullRequest` ∥ `getDiff`, `getComments` after the PR. **Findings from scoping:** (1) this is a single-load *latency* optimization only — the whole load already runs off the UI thread (`loadWorker`), so responsiveness is unaffected. (2) `getComments` needs the commit hashes only to *anchor* (`dupeComment`, `client.zig`), never to *fetch* the URL — so all three could fan out. (3) But `StdHttpClient` wraps `std.http.Client.fetch`, whose pool already reuses **one** keep-alive connection across the three sequential requests (**1 TLS handshake**); true fan-out can't share that connection concurrently and would open a second → **+1 handshake**. So fan-out trades one overlapped fetch against one extra handshake — a net win only if the diff fetch dominates a handshake, which needs measurement against the live API. Revisit with a real timing before adding the complexity (threading `io` into `loadWith`, a second client, and making the `FakeHttpClient` test order-independent).
- [x] Tests: async picker open (loading → populated over a fake) and boot loading-view render. ✅ (`loadWith` fan-out ordering/parity tests deferred with the fan-out itself.)

_Deferred:_ animated spinner — the vaxis `Loop` has no timer (`nextEvent` blocks on real events), so animation needs a tick thread posting via `postEvent`; static "Loading…" text delivers most of the perceived win at no concurrency cost. Revisit if the static frame feels dead.

## M8 — File view scope (single-file)  ·  S/M  ·  ✅ done (Epoch-per-file deferred)
- [x] `only_file` scope in `BuildOptions`: project the Buffer to a single File's rows. ✅ `buffer.zig` `only_file: ?usize`; when set, only `diff.files[only_file]` is emitted (header, hunks, woven inline threads/drafts, outdated section) and the PR-level comment/pending sections plus other-file stranded drafts are suppressed (`draftInScope`). Reconciles the code with the domain language (`src/diff/CONTEXT.md` Buffer entry updated: whole-Diff scroll by default, single-File isolate view as the canonical review unit).
- [x] Make the Sidebar a selector, not just a position indicator. ✅ `o` isolates the focused file (captures `fileIndexForRow(cursor)` into `isolate_file`); the sidebar highlight then tracks `isolate_file` directly. `o` again exits and lands the cursor back on that file's header (`fileHeaderRow`).
- [x] Jump-to-file motion: scroll the pane to a File's header within the all-files buffer. ✅ `[`/`]` jump the cursor to the prev/next `file_header` (`prevFileHeaderRow`/`nextFileHeaderRow` + `Nav.jumpTo`); in the isolate view they step which file is isolated instead. Both readings (jump vs. isolate) are offered.
- [ ] _Deferred (no payload to fetch yet)._ Treat a File focus as an Epoch-stamped load. **Finding:** the whole Diff already lives in one `Session` (one fetch), so isolating a file is a pure in-memory projection — an Epoch-stamped per-file "load" would be ceremony with nothing to load or cancel. The seam only earns its keep once a file focus triggers real work (lazy per-file blob fetch for true WholeFile — M9, or syntax highlighting — M13). Revisit with M9 / M13.
- [x] Tests: `only_file` projection (one File's rows, nothing else) + isolate suppression of PR-level/other-file rows (`buffer.zig`), `Nav.jumpTo` (`nav.zig`), jump-to-file cursor math (`nextFileHeaderRow`/`prevFileHeaderRow`/`fileHeaderRow`, `app.zig`).

## M9 — True whole-file view (Bitbucket blobs)  ·  M  ·  ✅ done (removed-file old-side splice deferred)
Today's `WholeFile` scope shows every *fetched* diff line but not the unchanged regions **outside** the hunks — the diff endpoint only returns hunks + context. True whole-file needs the full file blob, which Bitbucket serves from a separate endpoint.
- [x] Bitbucket: fetch a file's blob at a commit. ✅ `Client.getFileBlob(repo, commit, path)` → `GET /repositories/{ws}/{repo}/src/{commit}/{path}`, raw text owned by the caller, same `classify`/`ApiError` mapping as `getDiff`. _Live shape-check against the real API still pending (only exercised via `FakeHttpClient`)._
- [x] Populate blobs **lazily per file** on the Epoch-per-file seam M8 deferred. ✅ `Session.blobs: []FileBlob` (side table, index-aligned with `diff.files`, empty at load — blobs can't live on the const `File` the parser yields). `app.ensureBlob` fetches the *focused* file's new-side blob on a worker thread when scope is whole-file, keyed by `(pr_id, file_idx)` so each file fetches at most once; the result posts a `blob_done` event and re-weaves. Stale results (superseded PR / filled slot) are discarded; in-flight fetches are awaited before teardown.
- [x] `buffer.zig`: true-whole-file splice. ✅ `BuildOptions.whole_file` + `blobs`; `spliceNewSide` fills the gaps before/between/after hunks with `.context` lines drawn from the blob, keyed off the authoritative hunk line numbers (ADR-0001); hunk lines are copied verbatim. No hunk headers/folds in this scope. `f` cycles Changes → fetched-whole → whole-file (per the chosen 3-state model); whole-file falls back to the fetched rendering when the blob isn't loaded or the file is removed.
- [x] Anchor safety: blob-sourced context lines get `Line.in_hunk = false` and `weaveInline` refuses to attach comments/drafts to them — only hunk lines anchor.
- [x] Tests: blob fetch + `ApiError` (fake http, `client.zig`); splice invariants (hunk lines preserved, gaps filled from the blob, `in_hunk` flags, fallback to per-hunk when no blob) + anchor-safety (`buffer.zig`); `Session.blobs` alloc (`session.zig`).

_Deferred:_ the **removed-file** old-side splice — a deletion's whole-file view would show the entire old file as removed; low value over the hunks, and it needs the old blob at the destination commit (a second fetch side). The splice handles new-side files (added/modified/renamed); removed files fall back to the fetched rendering. Also: whole-file currently splices only the *focused* file's blob (the isolate trigger); scrolling across files in whole-file scope without isolating fetches each file as it gains focus.

## M10 — Pending review: submission & failures  ·  M  ·  ✅ done (rich per-item overlay & Retry-After deferred)
- [x] `Submission`: topological order, temp-id → CommentId remap. ✅ `src/review/submission.zig` — a pure, clock-free state machine (`advance` returns the next action as data — post/wait/done/aborted — `report` feeds outcomes back). Reply parents remap to the parent's freshly-posted `CommentId` (or a `Parent.comment`'s existing id). The network is the new `CommentPoster` ptr+vtable seam (`Poster` in `src/bitbucket/poster.zig` implements it; `Client.createComment` POSTs).
- [x] Failure model: retry (network/429/5xx), abort-on-auth, mark-and-continue (validation). ✅ retryable → capped exponential backoff (`.wait` step; 429 honors an explicit `Retry-After` param); auth (401/403) → `aborted`, everything kept pending; validation (400/404/malformed) → item `failed`, its reply-descendants `skipped` (a missing parent id blocks them naturally). Retries exhaust into an item failure after `max_attempts`.
- [x] Duplicate guard (GET-and-dedupe on ambiguous failure). ✅ a transport failure is a distinct `ambiguous` outcome; the retry sets a `dedupe` flag and the worker `findExisting`s (GET-and-match on anchor + body) before re-POSTing.
- [x] Stale-anchor check: capture SourceCommit on load, re-check head before submit. ✅ the submit worker re-fetches the PR head and, if `headChanged` vs the loaded source commit, refuses the batch (`stale`) with a "reopen the PR" message. _A force-submit-anyway path is deferred — reload is the remedy for now._
- [x] Per-item summary + selective retry of failed subtrees. ✅ each item's fate streams back (`submit_progress`, persisted as it lands — ADR-0007 crash-safety) and rolls up into a status-bar summary (`N posted · M failed · K skipped`); a clean batch deletes its published Drafts, a partial one keeps failures pending so `X` again is selective retry (posted Drafts skipped). _A richer per-item overlay (list each Draft's status/reason) is deferred to M15 polish._
- [x] Tests: submission ordering, remap, each failure class, dedupe. ✅ 15 engine tests (ordering, remap, abort, skip-descendants, backoff schedule + Retry-After, dedupe-on-ambiguous, retry exhaustion, selective retry, `headChanged`, driver-through-seam) + `createComment` URL/body/id/error tests + `Poster` posted/rejected/ambiguous mapping + dedupe hit/miss. Suite green.

_Deferred:_ the async submit worker glue (event wiring, worker loop) isn't unit-tested — same posture as the M7/M9 workers; the pure engine and adapter carry the logic. `Retry-After` is plumbed through `report` but the `Poster` doesn't yet surface the header, so live 429s use computed backoff. Submission is single-batch-at-a-time (a second `X` while one runs is refused). No idempotency key exists on Bitbucket, so the duplicate guard is best-effort (anchor + exact-body match).

## M10b — Multi-line anchors, suggestion prefill & post-submit reconcile  ·  M  ·  ✅ done ($EDITOR handoff deferred)
- [x] Multi-line anchors: thread `start_from`/`start_to` through the `Anchor` model, the client (send null-omitted + parse back), the `Poster` dedupe, and the SQLite store (v2 migration). ✅ Field names/roles verified by live probes on PR 1856 (`{start_to, to}` new-side, `{start_from, from}` old-side; start_* = range top).
- [x] Visual line selection: `Nav.mark` + `v` toggle and shift+arrow start/extend (one sticky model; plain motions extend, Esc clears); selection band tinted in the pane. ✅ shift+arrow is terminal-dependent so `v` is the robust primary — both drive the same state.
- [x] Selection → anchor mapping (`spanFromLines`, pure/tested): new-side range for additions+context, old-side for deletions, single line stays single-sided; refuse mixed sides / hunk gaps / file borders / a suggestion over removed lines. ✅ `i`/`S` act on the selection when active, else the cursor line.
- [x] Suggestion prefill: seed the composer with the anchored source lines so the reviewer edits real code in the fence (`Composer.seed`). ✅ plain comments stay empty.
- [x] Post-submit reconciliation: re-fetch the PR after a batch that posted anything, so published Comments reappear (ADR-0001); hide a posted/submitting Draft's row (the fetched Comment represents it) while keeping its pending descendants (ADR-0007 render-path dedup). ✅
- [x] Submit modal: float a "Submitting review — n/total" overlay over the viewer during a batch, then the loading frame covers the re-fetch. ✅ shared `centeredModal` helper extracted; picker/composer/submit all route through it.

_Deferred:_ editing a prefilled/multi-line suggestion is append-only (revise from the tail); the real multi-line editor is an `$EDITOR` handoff (spawn `$EDITOR` on a temp file, read the result back through the same `Composer.seed` seam) — recorded, not built. Old-side (deletion) ranges are supported for comments but were only lightly probed; the apply-replaces-N-lines behavior of a multi-line suggestion is Bitbucket UI behavior we don't control (our POST contract is verified). No test drives the shift+arrow/selection glue through vaxis (same posture as the worker glue); the pure `spanFromLines`/`Nav` selection logic carries the rules.

## M11 — Keymap & motions  ·  S/M  ·  ✅ done (config-file loading → M12; markdown → follow-up)
- [x] Full vim motion set + numeric Count register (`5j`, `zz`, …); arrows side by side. ✅ Added `ctrl-f`/`ctrl-b` (full page), `zz`/`zt`/`zb` (center / cursor-to-top / cursor-to-bottom scroll positioning), and `H`/`M`/`L` (cursor to viewport top/middle/bottom) as pure `Nav` methods; the existing `hjkl`/arrows/`ctrl-d`/`ctrl-u`/`gg`/`G`/Count/shift-select carry over. Skipped search/paragraph/operator-pending (no meaning in a diff viewer). `PageUp`/`PageDown` stay half-page (unchanged); `ctrl-f`/`ctrl-b` are the full-page keys.
- [x] Configurable `Keymap` from config. ✅ Vim-aligned: one `(chord)→Action` table (`src/tui/keymap.zig`) where motions and commands are both bindings, so dispatch and the help overlay read one source of truth. The Count and the multi-key **Leader** (`g`/`z`) stay in the engine (`Nav` + `Resolver`), not the table — matching how vim keeps that grammar above its mapping table. The 15-arm `key.matches` viewer chain became one `switch (Action)`. _Loading overrides from a config file is deferred to **M12** (which introduces the TOML config); M11 ships the defaults + the seam (`Keymap.default`, overlaid at the `km` binding in `app.run`)._
- [x] Keybinding-help Overlay (reads Keymap). ✅ `?` floats a centered "Keybindings" modal (`render.drawHelp`) built straight from `Keymap.default` — Motions in the left column, commands in the right, adjacent alternate bindings coalesced (`j ↓`), so it can't drift from the live table. Any key dismisses it (captures input while open); a `? help` hint sits in the status bar for discoverability.
- [x] **Multi-line comment/draft/suggestion body rendering.** ✅ Kept the one-Row-per-screen-line invariant (so `Nav`/scroll are untouched): a multi-line body emits one `CommentRow`/`DraftRow` per visual line, all sharing the owner pointer, `is_first` marking the header row (option A2). `r`/reply resolves from any line for free (every row carries the owner). Bodies render **verbatim**, fences and all (§Q5-A) — the `±` marker + suggestion band still signal a suggestion; fence-aware styling waits for markdown. Full body, **no cap** — the pane already scrolls; capping/folding is a deferred follow-up (layers cleanly on A2). Continuation rows hang-indent two columns; a single trailing newline is trimmed so it emits no blank row.

  _Deferred:_ markdown rendering (headings/bold, fence-aware suggestion styling — item (B) above); a length cap/fold for pathological bodies.

## M12 — Themes & config  ·  S  ·  needs M2
- [ ] Config file (TOML at `~/.config/bbr/`).
- [ ] Built-in themes: catppuccin, gruvbox, solarized (+ light/dark); selection in config.
- [ ] **Keymap overrides from config** (deferred here from M11). The `Keymap` abstraction, defaults, and dispatch already exist (`src/tui/keymap.zig`); this parses a `[keymap]` section into `Chord`/`Action` overrides and overlays them on `Keymap.default` at the `km` binding in `app.run`.

## M13 — Syntax highlighting  ·  L  ·  needs M2
- [ ] `Highlighter` seam + `PlainHighlighter`.
- [ ] tree-sitter Zig bindings; decide grammar delivery (build-time vs runtime).
- [ ] Grammars: tsx/jsx, css, go, bash, json, yaml + highlight queries.
- [ ] Compose syntax foreground over diff background per cell; wire into `Theme`.

## M14 — Local / offline review  ·  M/L  ·  needs M6 (not M10)
- [ ] Extend `GitClient` with diffing subset: worktree list, ref resolution, `diff` between refs, blob at ref.
- [ ] `DiffSource` abstraction; local `git diff <base>..<branch>` → same Diff parser.
- [ ] Local `CommentTarget` in SQLite (no submission path).
- [ ] Local anchor lifecycle via diff-walking (`git diff <anchor_commit> <ref>`); committed refs only.
- [ ] Tests: worktree detection, DiffSource parity, local anchor mapping (current/moved/outdated).

## M15 — Polish  ·  S/M  ·  needs M2 (resolved indicator needs M3/M6)
Small feature and layout refinements once the core flow works.
- [ ] Resolved threads: show a collapsed **indicator** in place (not just hide-behind-toggle), e.g. `✓ resolved · N replies`, that expands the whole Thread on demand. **Note:** this reverses the current domain rule — the Thread entry in `src/review/CONTEXT.md` explicitly says "never a bare 'a resolved comment exists' marker". Confirm and update that glossary entry (and the `show_resolved` behaviour in `buffer.zig`) as part of this item. Reply count comes from `Thread.replies.len`.
- [ ] Layout polish: borders/separators around panes and overlays (sidebar ↔ diff, the composer modal, section dividers). Today panes are separated by spacing only (`src/tui/render.zig`); add box-drawing borders styled via the active `Theme`.
- [ ] Sidebar: the per-file comment/draft counts should be **right-aligned and always visible**, and the file name **truncated with an ellipsis** when the row is too narrow. Today the counts are printed immediately after the name using the name segment's `PrintResult.col` (`drawSidebar` in `render.zig`), so a long name pushes them off-screen. Reserve a fixed right-hand column for the counts, then truncate the name to fill the remaining width.
- [ ] Binary files (images etc.): Bitbucket's diff renders a binary change as a `Binary files … differ` stub with no hunks, so today such a File flattens to just a header with nothing under it — and the whole-file scope (M9) would try to fetch/splice a text blob that isn't text. Detect binary Files (the diff stub, or a non-UTF-8 blob) and show a clear placeholder row instead of an empty file / garbled bytes, e.g. `⬦ binary file (N bytes) · added/modified/removed`. An actual inline image preview (e.g. via a terminal image protocol like kitty/iterm/sixel) is a stretch goal, gated on terminal capability; the baseline is just "don't pretend it's text." Suppress the M9 blob fetch for binary Files.

## Cross-cutting / tech debt
- [ ] Decide libcurl fallback trigger (once proxy type at check24 is known).
- [ ] Rotate the API token currently in plaintext in `opencode.jsonc`; move to keychain.
- [ ] CI: `zig build test` on 0.16.0; formatting check.
- [ ] *(deferred)* dirty working-tree diffs with fuzzy content-based anchoring.

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
              ├─ M15             (polish: resolved indicator, borders, sidebar)
              └─ M3 ─ M6 ─ M14   (local review; needs authoring, not submission)
```

**MVP line:** M0–M3 gives a usable read-only reviewer; M4 makes it ergonomic; M6+M10 make it
write-capable (the headline). M5/M7/M8/M9/M11/M12/M13 are parallelizable polish once M2 lands; M14 is the
largest standalone feature and depends only on read + authoring, not submission.
