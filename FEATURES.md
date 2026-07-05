# Features

The feature set of **bbr**, grouped by area and tagged with the milestone that delivers it
(see `docs/design.html` §14 and `TODO.md`). Status: `planned` · `in progress` · `done`.

> Vocabulary in this file is the ubiquitous language — see `CONTEXT-MAP.md` and each
> context's `CONTEXT.md`. Rationale for the hard choices lives in `docs/adr/`.

## Navigation & PR management
- [ ] **Open PR by id** — load a PullRequest from the workspace by integer id. `M0`
- [ ] **Open PR by URL** — parse a `bitbucket.org/check24/<repo>/pull-requests/<id>` link. `M4`
- [ ] **Auto-detect PR from CWD** — on launch, read the git branch + remote and open the matching open PR; no-PR chooser / pre-filtered picker otherwise. `M4`
- [ ] **PR Picker** — fuzzy-find a PullRequest by id or title (zf) and switch. `M4`
- [ ] **Epoch cancellation** — switching PRs / files cancels in-flight loads. `M2`

## Diff viewing
- [ ] **Unified layout** — one column, removed above added, colored backgrounds. `M2`
- [ ] **Line coloring** — neutral context / green added / red removed. `M2`
- [ ] **File sidebar** — files with change status + comment/draft counts. `M2`
- [ ] **Side-by-side layout** — old left, new right. `M5`
- [ ] **Intra-line emphasis** — stronger background on the changed characters. `M5`
- [ ] **Scope: Changes** — hunks + context with expandable Folds. `M5`
- [ ] **Scope: WholeFile** — entire file with changes inline. `M5`
- [ ] **Syntax highlighting** — tree-sitter foreground over diff background. `M10`

## Comments (read)
- [ ] **View Threads** — root comments + replies, inline on the diff. `M3`
- [ ] **View PR-level comments** — unanchored comments. `M3`
- [ ] **Render suggestions** — show ```suggestion``` blocks distinctly. `M3`
- [ ] **Resolved toggle** — reveal whole resolved Threads (comment + replies), not bare markers. `M3`

## Comment anchoring
- [ ] **Anchor state** — render comments as current / moved / outdated. `M3` (remote) · `M11` (local)
- [ ] **Show outdated comments** — never hidden; per-file collapsible with captured context. `M3`
- [ ] **Stale-anchor warning** — detect SourceCommit change before submit. `M7`

## Navigation & input
- [ ] **Basic motions** — arrows + `j`/`k`, `ctrl-d`/`ctrl-u`, `gg`/`G`. `M2`
- [ ] **Full vim motions** — `zz` and numeric Count (`5j`), complete set. `M8`
- [ ] **Configurable Keymap** — bindings from config; drives the help overlay. `M8`

## Pending Review (write)
- [ ] **Draft top-level comment** `M6`
- [ ] **Draft inline comment** — anchored to a File + line (or range). `M6`
- [ ] **Draft reply** — including replies to other pending Drafts. `M6`
- [ ] **Author suggestion** — compose a ```suggestion``` block. `M6`
- [ ] **Persist PendingReview** — SQLite, survives crash / quit / PR switch. `M6`
- [ ] **Submit batch** — topological POST + temp-id remap. `M7`
- [ ] **Failure handling** — retry / abort-on-auth / mark-and-continue + dedupe guard. `M7`

## Local & offline review
- [ ] **Detect current branch/worktree** — read the WorkingCopy's branch. `M4` (branch+remote) · `M11` (worktree/diff)
- [ ] **Parse tracking remote** — `origin` → `(workspace, repo_slug)`, SSH + HTTPS + `url.insteadof`. `M4`
- [ ] **Local branch diff** — review a branch against a BaseRef with no Bitbucket. `M11`
- [ ] **Local comments** — persist to SQLite with `CommentTarget = local`; never submit. `M11`
- [ ] **git worktree support** — each worktree reviews its own branch. `M11`
- [ ] *(deferred)* dirty working-tree diffs with fuzzy content-based anchoring. `later`

## Shell & UX
- [ ] **Overlay: Composer** — write a Draft. `M6`
- [ ] **Overlay: keybinding help** `M8`
- [ ] **Config file** — TOML at `~/.config/bbr/`. `M9`
- [ ] **Themes** — built-in catppuccin / gruvbox / solarized + plain light/dark; the `Theme` seam exists from `M2`, extra themes at `M9`.

## Explicit non-features (for now)
- Bitbucket Server / Data Center · approve/merge/decline · applying suggestions ·
  editing files · NTLM/Kerberos proxy auth · dirty working-tree diffs. See `docs/design.html` §2.
