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
- [x] `Theme` abstraction + one default. ✅ `src/tui/theme.zig` — `dark`; selectable themes are M9.
- [x] Presentation: Sidebar (files) + DiffPane (unified) with neutral/green/red backgrounds. ✅ `src/diff/buffer.zig` (pure flatten → rows) + `src/tui/render.zig` (full-width bands, gutter line numbers, sidebar highlight).
- [x] Buffer-scoped arena. ✅ in `app.run` (buffer arena + per-frame gutter arena, reset after render). — Background runtime + event-queue + Epoch **deferred to M4**: nothing to cancel until PRs can be *switched*; M2 fetches synchronously in `main`.
- [x] Basic navigation: arrows + core motions (`j`/`k`, `ctrl-d`/`ctrl-u`, `gg`/`G`, numeric Count). ✅ `src/tui/nav.zig` (pure) wired in `app.run`.
- [x] Test: headless surface asserts cell colors for a known Buffer. ✅ `render.zig` builds a detached Window over `Screen.init` and asserts band bg + sidebar highlight via `readCell`; nav math + buffer flatten unit-tested. Suite green.

## M3 — Comments (read)  ·  M  ·  ✅ done
- [x] Bitbucket: `getComments` (paginated), incl. resolved state + outdated verdict. ✅ `Client.getComments` follows `next` links; anchors carry path + old/new line; `resolved` from the resolution object; `AnchorState` honors Bitbucket's `inline.outdated`. `FakeHttpClient` gained a `responses` sequence for hermetic pagination tests.
- [x] Thread builder: flat comments → nested `Thread`s (by `parent.id`). ✅ `src/review/thread.zig` — resolves each comment to its ultimate root, buckets replies in creation order, promotes orphans, handles out-of-order input. Zero-copy over the comment slice.
- [x] ThreadPane: inline threads + PR-level comments; render ```suggestion``` blocks distinctly. ✅ woven in `buffer.buildWithComments` (PR-level section at top; inline threads under their anchored line; root/reply rows) and drawn in `render.zig` (`▸` root, `↳` reply, `±` suggestion with its own band). Multi-line bodies show the lead line + `…` (full markdown rendering is M8).
- [x] `resolved` state + reveal-resolved toggle (whole thread). ✅ resolved-but-current threads hidden by default; `R` flips `show_resolved` and rebuilds the buffer, revealing the *whole* thread. Status bar shows the toggle state.
- [x] AnchorState display (current/moved/outdated from Bitbucket verdict); per-file Outdated collapsible. ✅ outdated threads grouped in a per-file "Outdated (N)" section and **never hidden** (even when resolved). Outdated is derived from each comment's `links.code` revision vs the PR's current source/destination commits — the list endpoint omits `inline.outdated` and it can't be recomputed from line numbers (see `bitbucket/CONTEXT.md`). Verified live on PR 1726 (8 outdated roots). `moved` isn't produced remotely; local diff-walk for `moved` is M6. The Outdated group is always expanded — fold/collapse deferred to M5 (`Fold`s).
- [x] Tests: thread nesting, resolved toggle, outdated grouping. ✅ thread nesting/orphan/out-of-order (`thread.zig`), weaving + resolved toggle + outdated grouping (`buffer.zig`), headless comment/suggestion render (`render.zig`), paginated `getComments` (`client.zig`). Suite green 62/62.

## M4 — PR discovery & switching  ·  M  ·  needs M2
- [ ] Minimal read-only `GitClient`: current branch + tracking Remote (SSH/HTTPS + `url.insteadof`).
- [ ] Bitbucket: list open PRs filtered by source branch.
- [ ] Startup resolution: arg → CWD auto-detect → picker; no-PR chooser; pre-filtered picker on multiple.
- [ ] PR Picker overlay (zf); URL parser; switch PRs with Epoch cancellation.
- [ ] Tests: remote URL parsing, branch detection (fake GitClient), resolution branches.

## M5 — Diff polish  ·  M  ·  needs M2
- [ ] SideBySide layout projection over the same Buffer.
- [ ] Intra-line word-diff → `IntraLineSegment`s; emphasized background.
- [ ] Scope: Changes with `Fold`s (expand without refetch); WholeFile scope.
- [ ] Arena pool/ring for multi-file view.
- [ ] Tests: intra-line segment cases; fold expansion; projection invariants.

## M6 — Pending review: authoring & persistence  ·  M  ·  needs M3
- [ ] `PendingReviewStore` seam + in-memory fake + SQLite implementation (schema + migrations).
- [ ] Composer overlay; create `Draft` (top_level / inline / reply / suggestion), incl. reply-to-draft.
- [ ] `DraftState` + `CommentTarget` persistence; resume on launch; render drafts distinctly.
- [ ] Tests: store round-trip (fake + SQLite), draft graph construction.

## M7 — Pending review: submission & failures  ·  M  ·  needs M6
- [ ] `Submission`: topological order, temp-id → CommentId remap.
- [ ] Failure model: retry (network/429/5xx), abort-on-auth, mark-and-continue (validation).
- [ ] Duplicate guard (GET-and-dedupe on ambiguous failure).
- [ ] Stale-anchor check: capture SourceCommit on load, re-check head before submit.
- [ ] Per-item summary + selective retry of failed subtrees.
- [ ] Tests: submission ordering, remap, each failure class, dedupe.

## M8 — Keymap & motions  ·  S/M  ·  needs M2
- [ ] Full vim motion set + numeric Count register (`5j`, `zz`, …); arrows side by side.
- [ ] Configurable `Keymap` from config.
- [ ] Keybinding-help Overlay (reads Keymap).

## M9 — Themes & config  ·  S  ·  needs M2
- [ ] Config file (TOML at `~/.config/bbr/`).
- [ ] Built-in themes: catppuccin, gruvbox, solarized (+ light/dark); selection in config.

## M10 — Syntax highlighting  ·  L  ·  needs M2
- [ ] `Highlighter` seam + `PlainHighlighter`.
- [ ] tree-sitter Zig bindings; decide grammar delivery (build-time vs runtime).
- [ ] Grammars: tsx/jsx, css, go, bash, json, yaml + highlight queries.
- [ ] Compose syntax foreground over diff background per cell; wire into `Theme`.

## M11 — Local / offline review  ·  M/L  ·  needs M6 (not M7)
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
M0 ─ M1 ─ M2 ─┬─ M3 ─ M6 ─ M7
              ├─ M4              (PR discovery)
              ├─ M5              (diff polish)
              ├─ M8              (keymap)
              ├─ M9              (themes/config)
              ├─ M10             (highlighting)
              └─ M3 ─ M6 ─ M11   (local review; needs authoring, not submission)
```

**MVP line:** M0–M3 gives a usable read-only reviewer; M4 makes it ergonomic; M6+M7 make it
write-capable (the headline). M5/M8/M9/M10 are parallelizable polish once M2 lands; M11 is the
largest standalone feature and depends only on read + authoring, not submission.
