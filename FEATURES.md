# Features

The feature set of **bbr**, grouped by area and tagged with the milestone that delivers it
(see `docs/design.html` §14 and `TODO.md`). Status: `planned` · `in progress` · `done`.

> Vocabulary in this file is the ubiquitous language — see `CONTEXT-MAP.md` and each
> context's `CONTEXT.md`. Rationale for the hard choices lives in `docs/adr/`.

## Navigation & PR management
- [x] **Open PR by id** — load a PullRequest from the workspace by integer id. `M0`
- [x] **Open PR by URL** — parse a `bitbucket.org/check24/<repo>/pull-requests/<id>` link. `M4`
- [x] **Auto-detect PR from CWD** — on launch, read the git branch + remote and open the matching open PR; no-PR chooser / pre-filtered picker otherwise. `M4`
- [x] **PR Picker** — fuzzy-find a PullRequest by id or title (zf) and switch. `M4`
- [x] **Epoch cancellation** — switching PRs / files cancels in-flight loads. `M4` (Session) · `M9`/`M13` (File Enrichment)

## Diff viewing
- [x] **Unified layout** — one column, removed above added, colored backgrounds. `M2`
- [x] **Line coloring** — neutral context / green added / red removed. `M2`
- [x] **File sidebar** — files with change status + comment/draft counts. `M2`
- [x] **Side-by-side layout** — old left, new right. `M5`
- [x] **Intra-line emphasis** — stronger background on the changed characters. `M5`
- [x] **Scope: Changes** — hunks + context with expandable Folds. `M5`
- [x] **Scope: WholeFile** — entire file with changes inline. `M5` (fetched) · `M9` (true full file)
- [x] **Single-file view** — isolate the DiffPane to one File (`only_file`); Sidebar selects it. `M8`
- [x] **Jump-to-file** — motion to scroll the pane to a File's header. `M8`
- [x] **Syntax highlighting** — tree-sitter foreground over diff background. `M13`
- [ ] **Binary and removed-file completeness** — safe placeholders and old-side whole-file splice. `M17`
- [ ] **User-installed Grammars** — managed, validated tree-sitter Grammars and match rules. `M17`

## Comments (read)
- [x] **View Threads** — root comments + replies, inline on the diff. `M3`
- [x] **View PR-level comments** — unanchored comments. `M3`
- [x] **Render suggestions** — show ```suggestion``` blocks distinctly. `M3`
- [x] **Resolved toggle** — reveal whole resolved Threads (comment + replies). `M3`
- [ ] **Collapsed resolved/outdated indicators** — independently expand and collapse hidden context. `M15`

## Comment anchoring
- [x] **Anchor state** — render comments as current / moved / outdated. `M3` (remote) · `M14` (local)
- [x] **Show outdated comments** — never hidden; grouped per File with captured context. `M3` (remote) · `M14` (local)
- [x] **Stale-anchor warning** — detect SourceCommit change before submit. `M10`

## Navigation & input
- [x] **Basic motions** — arrows + `j`/`k`, `ctrl-d`/`ctrl-u`, `gg`/`G`. `M2`
- [x] **Full vim motions** — `zz` and numeric Count (`5j`), complete set. `M11`
- [x] **Configurable Keymap** — bindings from config; drives the help overlay. `M11`/`M12`
- [ ] **Yank source text** — OSC 52 clipboard copy for current/selected diff lines. `M15`

## Pending Review (write)
- [x] **Draft top-level comment** `M6`
- [x] **Draft inline comment** — anchored to a File + line (or range). `M6`/`M10b`
- [x] **Draft reply** — including replies to other pending Drafts. `M6`
- [x] **Author suggestion** — compose a ```suggestion``` block. `M6`/`M10b`
- [x] **Persist PendingReview** — SQLite, survives crash / quit / PR switch. `M6`
- [x] **Submit batch** — topological POST + temp-id remap. `M10`
- [x] **Failure handling** — retry / abort-on-auth / mark-and-continue + dedupe guard. `M10`
- [ ] **Mutate review items** — edit/re-anchor/delete Drafts and edit/delete owned Comments. `M16`
- [ ] **Submission repair UX** — per-item outcomes, recovery, Retry-After, and stale-head decision. `M16`

## Local & offline review
- [x] **Detect current branch/worktree** — read the WorkingCopy's branch and common Git directory. `M4` (branch+remote) · `M14` (worktree/diff)
- [x] **Parse tracking remote** — SSH/HTTPS/`url.insteadof`, normalized without credentials for durable repository identity. `M4` · `M14`
- [x] **Local branch diff** — review committed SourceRef changes against a BaseRef with no Bitbucket or credentials. `M14`
- [x] **Local comments** — persist to SQLite with `CommentTarget = local`; never submit. `M14`
- [x] **git worktree support** — linked worktrees share a logical Review and drafts for the same BaseRef/SourceRef. `M14`
- [x] **Local anchor projection** — refresh maps drafts to current/moved/outdated/unavailable and preserves authored context. `M14`
- [ ] **Dirty working-tree review** — mutable snapshots with fuzzy content-based anchoring. `M18`
- [ ] **Repository relinking** — explicitly resolve ReviewRepository aliases/conflicts. `M18`
- [ ] **Copy local Drafts to an adjacent PR** — explicit, previewed Anchor translation. `M18`

## Shell & UX
- [x] **Overlay: Composer** — write a Draft. `M6`
- [x] **Non-blocking startup** — boot the TUI with a "Loading PR #N…" view; fetch the initial Session off-thread. `M7`
- [x] **Non-blocking picker** — `p` opens the picker instantly; the PR list loads off-thread and fills in. `M7`
- [ ] **Measured parallel Session fetch** — overlap PR/diff/comment requests only if live measurements beat sequential keep-alive loading. `M19`
- [x] **Overlay: keybinding help** `M11`
- [x] **Config file** — TOML at the XDG config location. `M12`
- [x] **Themes** — built-in Catppuccin / Gruvbox / Solarized + plain light/dark. `M12`
- [ ] **Markdown comment bodies and long-body folding** `M15`
- [ ] **External editor handoff** `M16`

## Explicit non-features (for now)
- Bitbucket Server / Data Center · applying suggestions · editing files. Approve/merge/decline
  has a product gate in `M19`; dirty working-tree review is planned for `M18`. See
  `docs/design.html` §2.
