# Introduce contextual Actions and purpose-shaped Overlays

Status: ready-for-agent

## What to build

Resolve keys to precise semantic Actions using the current Interaction Context: a capturing Overlay, otherwise the focused Pane and its Frame target. Migrate configuration and help to the Action-oriented grammar, add the accepted Comment scope ladder, introduce distinct File finder and PullRequest Picker workflows, and complete keyboard scrolling and source-text yank through the same Presentation effect boundary.

## Acceptance criteria

- [ ] The Keymap binds Actions to one or more chords, permits the same chord in mutually exclusive contexts, supports empty-list unbinding, and rejects bindings that can be simultaneously available.
- [ ] `Enter` resolves only to the contextually valid disclosure, ReviewCard, Directory, File, or Picker Action; Composer Enter remains text input, and an Overlay exclusively captures its Interaction Context.
- [ ] Defaults include `F` File finder, `p` PullRequest Picker, `i`/`I`/`C` inline/File-level/Review-level Comment creation, `gC` recovery linking, `ctrl-y`/`ctrl-e` row scrolling, and `y` yank; superseded Actions and aliases are removed.
- [ ] ActionAvailability accounts for Review mode, surface, semantic target, and source data; unavailable Actions remain subdued in help and produce an explanatory status message when invoked.
- [ ] File finder and PullRequest Picker have purpose-shaped startup, ranking, empty/loading/no-match, dismissal, and Enter-only confirmation behavior, including correct same-Session versus replacement effects.
- [ ] Yank extracts undecorated source text for Selection or Count, skips Presentation-only rows, stops at the File boundary, applies the provisional new-side-first rule, and returns owned bytes for adapter-performed OSC 52 with visible success/failure.
- [ ] Tests cover configuration parsing and ambiguity, Counts and Leaders, help grouping, keyboard-only completion, Overlay capture, both Pickers, all Comment scopes, scrolling, and yank across layouts and disclosures.

## Blocked by

- [16 — Carry CommentScope end to end](16-carry-commentscope-end-to-end.md)
- [18 — Unify review-content disclosures](18-unify-review-content-disclosures.md)
- [19 — Add framed Panes and the Sidebar File Tree](19-add-framed-panes-and-the-sidebar-file-tree.md)
