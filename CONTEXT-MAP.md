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
- **Diff ↔ Review**: a root Comment's **CommentScope** is PullRequest-level, File-level, or inline. File and inline scopes retain their authored path/revision; Review computes ScopeState (current/moved/outdated) — trusting Bitbucket for remote comments and diff-walking via Git for local comments and drafts.
- **Diff → Presentation**: Presentation projects one Diff `Buffer` through a `Layout` × `Scope` matrix. No second data source.
- **Diff → Highlighting**: Highlighting colors both sides of a File's full content. A removed Line takes Spans from the old side, an added Line from the new side, and a context Line prefers the new side with old-side fallback; Presentation composes syntax foreground over diff background per cell, styled by the active `Theme`.
- **Shared kernel**: `ReviewIdentity`, `CommentScope`, `Anchor`, `LineKind`, and identifier types (`PullRequestId`, `CommentId`, commit hash) are shared vocabulary across Git, Diff, Review, and Presentation. A ReviewIdentity is either a Repository-qualified PullRequest or a ReviewRepository-qualified BaseRef/SourceRef pair; a Session Epoch identifies one loaded snapshot of that Review.

## Seams (dependency-inversion boundaries)

- `HttpClient` — vtable seam under Bitbucket; `std.http.Client` now, libcurl later, fake in tests.
- `GitClient` — seam under Git; shells out to `git` now, fakeable with fixtures in tests.
- `PendingReviewStore` — repository seam under Review; SQLite/libSQL now, in-memory fake in tests.
- `SubmissionLocks` — live local ownership seam under Review; OS advisory locks in production, an in-memory lock table in deterministic tests.
- `Highlighter` — seam under Highlighting; plain and tree-sitter implementations now, user-managed Grammars in M17.
