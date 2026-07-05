# Context Map

`bbr` (Bitbucket Reviewer) — a Zig TUI for reviewing Bitbucket **Cloud** pull requests:
browse the diff, read comment threads, and compose a batch of pending comments,
replies, and suggestions that are published together on submit.

## Contexts

- [Bitbucket](./src/bitbucket/CONTEXT.md) — anti-corruption layer over the Bitbucket Cloud REST API; the only place that knows about HTTP, JSON, and Atlassian's wire vocabulary.
- [Git](./src/git/CONTEXT.md) — local git integration: the current branch/worktree, ref resolution, and local diffs for offline review without Bitbucket.
- [Diff](./src/diff/CONTEXT.md) — the parsed, renderable model of a set of changes (from a DiffSource): Files, Hunks, Lines, intra-line segments, and folds.
- [Review](./src/review/CONTEXT.md) — comment threads, anchor lifecycle, and the client-side Pending Review: drafts, their lifecycle, and batched submission.
- [Presentation](./src/tui/CONTEXT.md) — the terminal UI shell: panes, sidebar, overlays, the PR picker, keymap, and themes.
- [Highlighting](./src/highlight/CONTEXT.md) — syntax coloring of file content via tree-sitter (post-MVP, behind a seam).

## Review modes

bbr reviews changes from one of two sources, sharing all rendering and comment machinery:

- **Remote review** — a Bitbucket PullRequest. Comments sync; Drafts submit as a batch.
- **Local review** — a local branch diffed against a base ref, no Bitbucket needed. Comments stay in SQLite and never submit. Anchors bind to commit + line (committed refs only in MVP).

## Relationships

- **Bitbucket / Git → Diff**: both produce unified diff text via a common **DiffSource**; Diff parses either into the same Line model. For remote review, Bitbucket's line numbers are authoritative for anchoring.
- **Git → Bitbucket**: from the current branch/worktree, Git finds the *adjacent* open PullRequest (source branch match) so a local checkout can open its remote review.
- **Bitbucket → Review**: Bitbucket returns existing comment threads (with resolved state and outdated verdicts); on submit, Review hands Bitbucket a topologically-ordered sequence of Drafts to POST.
- **Diff ↔ Review**: a comment's **Anchor** references a `File` path + Line numbers + the commit it was authored on. Review computes AnchorState (current/moved/outdated) — trusting Bitbucket for remote comments, diff-walking via Git for local comments and drafts.
- **Diff → Presentation**: Presentation projects one Diff `Buffer` through a `Layout` × `Scope` matrix. No second data source.
- **Diff → Highlighting**: Highlighting colors a File's full content; Presentation composes syntax foreground over diff background per cell, styled by the active `Theme`.
- **Shared kernel**: `Anchor`, `LineKind`, and identifier types (`PullRequestId`, `CommentId`, commit hash) are shared vocabulary across Git, Diff, and Review.

## Seams (dependency-inversion boundaries)

- `HttpClient` — vtable seam under Bitbucket; `std.http.Client` now, libcurl later, fake in tests.
- `GitClient` — seam under Git; shells out to `git` now, fakeable with fixtures in tests.
- `PendingReviewStore` — repository seam under Review; SQLite/libSQL now, in-memory fake in tests.
- `Highlighter` — seam under Highlighting; no-op/plain now, tree-sitter later.
