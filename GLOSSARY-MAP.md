# Glossary map

`bbr` (Bitbucket Reviewer) — a Zig TUI for reviewing Bitbucket **Cloud** pull requests:
browse the diff, read comment threads, and compose a batch of pending comments,
replies, and suggestions that are published together on submit.

## Contexts

- [Bitbucket](./src/bitbucket/GLOSSARY.md) defines Workspace, Repository, PullRequest, Credential, and Reviewer Verdict terms.
- [Git](./src/git/GLOSSARY.md) defines WorkingCopy, Remote, Ref, and LocalReview terms.
- [Diff](./src/diff/GLOSSARY.md) defines File, Hunk, Line, Buffer, Layout, and Scope terms.
- [Review](./src/review/GLOSSARY.md) defines Comment, Anchor, Draft, PendingReview, and Submission terms.
- [Presentation](./src/tui/GLOSSARY.md) defines Session, Pane, Overlay, Selection, search, and Action terms.
- [Highlighting](./src/highlight/GLOSSARY.md) defines Grammar, Capture, Span, and Theme terms.

Code entry points and implementation seams live in [Code navigation](./docs/code-navigation.md).

## Review modes

bbr reviews changes from one of two sources, sharing all rendering and comment machinery:

- **Remote review** — a Bitbucket PullRequest. Comments sync; Drafts submit as a batch.
- **Local review** — a local branch diffed against a base ref, no Bitbucket needed. Comments stay in SQLite and never submit. Anchors bind to commit + line (committed refs only in MVP).

## Relationships

- **Bitbucket / Git → Diff**: both produce unified diff text via a common **DiffSource**; Diff parses either into the same Line model. For remote review, Bitbucket's line numbers are authoritative for anchoring.
- **Git → Bitbucket**: from the current branch/worktree, Git finds the *adjacent* open PullRequest (source branch match) so a local checkout can open its remote review.
- **Bitbucket → Review**: Bitbucket returns existing comment threads (with resolved state and outdated verdicts); on submit, Review hands Bitbucket a topologically-ordered sequence of Drafts to POST.
- **Diff ↔ Review**: a root Comment's **CommentScope** is Review-level, File-level, or inline. File and inline scopes retain their authored path/revision; Review computes ScopeState (current/moved/outdated) — trusting Bitbucket for remote comments and diff-walking via Git for local comments and drafts.
- **Review → Presentation**: Review retains reviewer-local File Read Receipts keyed by ReviewIdentity and File Review Fingerprint; Presentation projects matching receipts as regular-weight Files and missing, changed, or unverifiable receipts as bold unread Files.
- **Diff → Presentation**: Presentation projects one Diff `Buffer` through a `Layout` × `Scope` matrix. No second data source.
- **Diff → Highlighting**: Highlighting colors both sides of a File's full content. A removed Line takes Spans from the old side, an added Line from the new side, and a context Line prefers the new side with old-side fallback; Presentation composes syntax foreground over diff background per cell, styled by the active `Theme`.
- **Shared kernel**: `ReviewIdentity`, `CommentScope`, `Anchor`, `LineKind`, and identifier types (`PullRequestId`, `CommentId`, commit hash) are shared vocabulary across Git, Diff, Review, and Presentation. A ReviewIdentity is either a Repository-qualified PullRequest or a ReviewRepository-qualified BaseRef/SourceRef pair; a Session Epoch identifies one loaded snapshot of that Review.
