# Verify the integrated M15 acceptance matrix

Status: ready-for-agent

## What to build

Verify M15 as one coherent Presentation and navigation system after every preceding slice is independently complete. Add deterministic cross-feature coverage at the seams and perform direct-terminal, SSH PTY, and tmux smoke checks. Fix integration defects found within the resolved M15 contract, but do not reopen deferred M20 side-selection behavior or pull later milestone work into scope.

## Acceptance criteria

- [ ] Frame atomicity, revision consistency, logical restoration, and rollback hold across resize, disclosure, File isolation/focus, Draft save, File Enrichment, Overlay transitions, and forced allocation failure.
- [ ] Successful Session replacement performs the canonical reset and failed replacement preserves Session, Frame, focus, cursors, Directory state, disclosures, ReviewCards, Selection, and transient mouse state.
- [ ] Unified and SideBySide Layouts cross Changes, fetched-whole, and WholeFile scopes at zero, narrow, ordinary, and wide dimensions with grapheme-safe output and stable navigation.
- [ ] RemoteReview and LocalReview workflows cover every CommentScope, ActionAvailability edge, File/fallback placement, tally, Suggestion restriction, Selection, Count, yank, and clipboard outcome.
- [ ] Keyboard-only workflows and accepted mouse equivalents pass across Panes, disclosures, File finder, PullRequest Picker, Overlays, loading states, and ignored mouse inputs.
- [ ] Configuration defaults, zero semantics, opt-outs, renamed-key rejection, diagnostics, Theme roles, cache behavior, spinner shutdown, and idle blocking pass as an integrated matrix.
- [ ] Direct-terminal, SSH PTY, and tmux smoke checks are recorded with terminal/environment details and cover framing, Unicode widths, keyboard navigation, mouse behavior where supported, Picker loading, and OSC 52 outcomes.
- [ ] The complete automated test suite passes, and any environment-limited smoke check is documented with reproducible commands and observed evidence rather than silently skipped.

## Blocked by

- [15 — Establish the atomic Presentation Frame](15-establish-the-atomic-presentation-frame.md)
- [16 — Carry CommentScope end to end](16-carry-commentscope-end-to-end.md)
- [17 — Project Markdown ReviewCards](17-project-markdown-reviewcards.md)
- [18 — Unify review-content disclosures](18-unify-review-content-disclosures.md)
- [19 — Add framed Panes and the Sidebar File Tree](19-add-framed-panes-and-the-sidebar-file-tree.md)
- [20 — Introduce contextual Actions and purpose-shaped Overlays](20-introduce-contextual-actions-and-purpose-shaped-overlays.md)
- [21 — Add keyboard-parity mouse navigation](21-add-keyboard-parity-mouse-navigation.md)
- [22 — Complete Picker feedback and public configuration](22-complete-picker-feedback-and-public-configuration.md)
