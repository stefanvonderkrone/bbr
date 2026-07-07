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
- [x] `Theme` abstraction + one default. ✅ `src/tui/theme.zig` — `dark`; selectable themes are M11.
- [x] Presentation: Sidebar (files) + DiffPane (unified) with neutral/green/red backgrounds. ✅ `src/diff/buffer.zig` (pure flatten → rows) + `src/tui/render.zig` (full-width bands, gutter line numbers, sidebar highlight).
- [x] Buffer-scoped arena. ✅ in `app.run` (buffer arena + per-frame gutter arena, reset after render). — Background runtime + event-queue + Epoch **deferred to M4**: nothing to cancel until PRs can be *switched*; M2 fetches synchronously in `main`.
- [x] Basic navigation: arrows + core motions (`j`/`k`, `ctrl-d`/`ctrl-u`, `gg`/`G`, numeric Count). ✅ `src/tui/nav.zig` (pure) wired in `app.run`.
- [x] Test: headless surface asserts cell colors for a known Buffer. ✅ `render.zig` builds a detached Window over `Screen.init` and asserts band bg + sidebar highlight via `readCell`; nav math + buffer flatten unit-tested. Suite green.

## M3 — Comments (read)  ·  M  ·  ✅ done
- [x] Bitbucket: `getComments` (paginated), incl. resolved state + outdated verdict. ✅ `Client.getComments` follows `next` links; anchors carry path + old/new line; `resolved` from the resolution object; `AnchorState` honors Bitbucket's `inline.outdated`. `FakeHttpClient` gained a `responses` sequence for hermetic pagination tests.
- [x] Thread builder: flat comments → nested `Thread`s (by `parent.id`). ✅ `src/review/thread.zig` — resolves each comment to its ultimate root, buckets replies in creation order, promotes orphans, handles out-of-order input. Zero-copy over the comment slice.
- [x] ThreadPane: inline threads + PR-level comments; render ```suggestion``` blocks distinctly. ✅ woven in `buffer.buildWithComments` (PR-level section at top; inline threads under their anchored line; root/reply rows) and drawn in `render.zig` (`▸` root, `↳` reply, `±` suggestion with its own band). Multi-line bodies show the lead line + `…` (full markdown rendering is M10).
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

_Deferred:_ true **whole-file** scope (unchanged regions *outside* the fetched hunks) needs the file blob from a separate Bitbucket endpoint — the current whole-file scope shows every *fetched* line. Fold re-collapse is one-way (revealed folds stay revealed until the scope toggles). Side-by-side pairs removed[k]↔added[k] by index (no LCS line-matching across a block).

## M6 — Pending review: authoring & persistence  ·  M  ·  ✅ done
- [x] `PendingReviewStore` seam + in-memory fake + SQLite implementation (schema + migrations). ✅ `src/review/store.zig` (ptr+vtable seam mirroring `HttpClient`, `InMemoryStore` fake) + `src/persist/sqlite_store.zig` (vendored amalgamation, `vendors/sqlite`, compiled into the exe only so the pure module stays C-free — ADR-0006). One row per Draft keyed `(pr_id, local_id)`; `PRAGMA user_version` migrations.
- [x] Composer overlay; create `Draft` (top_level / inline / reply / suggestion), incl. reply-to-draft. ✅ `src/tui/composer.zig` (pure state machine); viewer keys `c` (top-level), `i` (inline on cursor line), `S` (suggestion), `r` (reply to the comment/draft under the cursor — records the parent for M9 ordering, co-locates via the parent's anchor). ^D submits, esc cancels.
- [x] `DraftState` + `CommentTarget` persistence; resume on launch; render drafts distinctly. ✅ all four DraftStates + parent + anchor (with authored-against commit, ADR-0005) round-trip through SQLite; `app.run` loads the PR's Drafts on entry and re-loads on each PR switch (PR-scoped review arena). Drafts weave into the buffer (anchored under their line, unanchored in a "Pending" section) and render in a distinct amber band (`✎`/`↳`/`±`).
- [x] Tests: store round-trip (fake + SQLite), draft graph construction. ✅ draft graph (add/topological-order/remove), fake + SQLite round-trip (fields/anchor/parent/state, replace, scoped remove, close-reopen durability), buffer draft weaving, headless composer + draft-row render, `commitDraft` round-trip. Suite green 155.

_Deferred:_ `AnchorState.moved` via local diff-walk (needs the GitClient diffing subset — M13). Side-by-side draft weaving works (via `weaveInline`), but a draft anchored to a *removed-only* line pairs on the old side only. The Composer is append-only (no mid-text cursor); full editing is post-MVP.

## M7 — Responsiveness (non-blocking loads)  ·  M  ·  needs M2, M4
- [ ] Async picker open: `p` shows the picker overlay instantly in a loading state; the `listPullRequests` fetch runs off-thread and populates the rows when it returns. Today `openPicker` blocks the render loop synchronously inside the key handler (`app.zig:258`) — this is the "takes long until the overlay appears" lag. Generalize the existing epoch/worker/`load_done` machinery to carry a summaries result (or add a sibling event) and let the Picker exist with no items yet.
- [ ] Boot the TUI immediately with a static "Loading PR #N…" view instead of blocking on `session.load` before `enterAltScreen` (`main.zig:100`). Kick the initial load through the existing `spawnLoad` path; populate on the first `load_done`. `run` holds `current: ?*Session` and dispatches once per frame — loading view vs. viewer — so `render.draw`/`drawStatus` keep their non-optional session args; `buf`/`nav` become lazy (`?Buffer`, built on the first session).
- [ ] Parallelize the initial fetches in `loadWith` (`session.zig:58`): `getPullRequest` ∥ `getDiff` (both need only repo+id), `getComments` after the PR (needs its commit hashes). Critical path drops from PR+diff+comments to PR+comments, with the diff overlapping for free.
  - [ ] Investigate whether `getComments` needs the commit hashes to *fetch* or only to *anchor*; if only to anchor, all three fan out (critical path → max of the three).
  - [ ] Investigate HTTP keep-alive / connection reuse across the three requests (a fresh `StdHttpClient` per load may pay a TLS handshake 3×); reuse may beat fan-out on cost.
- [ ] Tests: async picker open (loading → populated over a fake), boot loading-view render, `loadWith` fan-out ordering + result parity with the sequential path.

_Deferred:_ animated spinner — the vaxis `Loop` has no timer (`nextEvent` blocks on real events), so animation needs a tick thread posting via `postEvent`; static "Loading…" text delivers most of the perceived win at no concurrency cost. Revisit if the static frame feels dead.

## M8 — File view scope (single-file)  ·  S/M  ·  needs M2
- [ ] `only_file` scope in `BuildOptions`: project the Buffer to a single File's rows. Reconciles the code with the domain language — `buffer.zig` currently flattens the *whole* diff into one continuous scroll (file_header separators), but a Buffer is defined as "the loaded, rendered model of exactly one File … reset/reused on file switch" (`src/diff/CONTEXT.md`).
- [ ] Make the Sidebar a selector, not just a position indicator: a key focuses a File and (in isolate mode) drives `only_file`. `fileIndexForRow` (`app.zig:359`) already maps cursor → File for the reverse direction; the Sidebar has no selection input today.
- [ ] Jump-to-file motion: scroll the pane to a File's header within the all-files buffer — cheap navigation, independent of isolate mode. The two readings of "single-file view" (jump vs. isolate) are both offered.
- [ ] Optional: treat a File focus as an Epoch-stamped load, matching the "each PR/File load" language, so a future per-file lazy fetch/highlight can hang off the same seam.
- [ ] Tests: `only_file` projection (one File's rows, nothing else), sidebar selection state, jump-to-file cursor math.

## M9 — Pending review: submission & failures  ·  M  ·  needs M6
- [ ] `Submission`: topological order, temp-id → CommentId remap.
- [ ] Failure model: retry (network/429/5xx), abort-on-auth, mark-and-continue (validation).
- [ ] Duplicate guard (GET-and-dedupe on ambiguous failure).
- [ ] Stale-anchor check: capture SourceCommit on load, re-check head before submit.
- [ ] Per-item summary + selective retry of failed subtrees.
- [ ] Tests: submission ordering, remap, each failure class, dedupe.

## M10 — Keymap & motions  ·  S/M  ·  needs M2
- [ ] Full vim motion set + numeric Count register (`5j`, `zz`, …); arrows side by side.
- [ ] Configurable `Keymap` from config.
- [ ] Keybinding-help Overlay (reads Keymap).

## M11 — Themes & config  ·  S  ·  needs M2
- [ ] Config file (TOML at `~/.config/bbr/`).
- [ ] Built-in themes: catppuccin, gruvbox, solarized (+ light/dark); selection in config.

## M12 — Syntax highlighting  ·  L  ·  needs M2
- [ ] `Highlighter` seam + `PlainHighlighter`.
- [ ] tree-sitter Zig bindings; decide grammar delivery (build-time vs runtime).
- [ ] Grammars: tsx/jsx, css, go, bash, json, yaml + highlight queries.
- [ ] Compose syntax foreground over diff background per cell; wire into `Theme`.

## M13 — Local / offline review  ·  M/L  ·  needs M6 (not M9)
- [ ] Extend `GitClient` with diffing subset: worktree list, ref resolution, `diff` between refs, blob at ref.
- [ ] `DiffSource` abstraction; local `git diff <base>..<branch>` → same Diff parser.
- [ ] Local `CommentTarget` in SQLite (no submission path).
- [ ] Local anchor lifecycle via diff-walking (`git diff <anchor_commit> <ref>`); committed refs only.
- [ ] Tests: worktree detection, DiffSource parity, local anchor mapping (current/moved/outdated).

## Cross-cutting / tech debt
- [ ] Decide libcurl fallback trigger (once proxy type at check24 is known).
- [ ] Rotate the API token currently in plaintext in `opencode.jsonc`; move to keychain.
- [ ] CI: `zig build test` on 0.16.0; formatting check.
- [ ] *(deferred)* dirty working-tree diffs with fuzzy content-based anchoring.

---

## Sequencing at a glance

```
M0 ─ M1 ─ M2 ─┬─ M3 ─ M6 ─ M9    (authoring → submission)
              ├─ M4              (PR discovery)
              ├─ M5              (diff polish)
              ├─ M4 ─ M7         (responsiveness / non-blocking loads)
              ├─ M8              (file view scope / single-file)
              ├─ M10             (keymap)
              ├─ M11             (themes/config)
              ├─ M12             (highlighting)
              └─ M3 ─ M6 ─ M13   (local review; needs authoring, not submission)
```

**MVP line:** M0–M3 gives a usable read-only reviewer; M4 makes it ergonomic; M6+M9 make it
write-capable (the headline). M5/M7/M8/M10/M11/M12 are parallelizable polish once M2 lands; M13 is the
largest standalone feature and depends only on read + authoring, not submission.
