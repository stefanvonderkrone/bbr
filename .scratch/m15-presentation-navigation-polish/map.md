# M15 presentation and navigation polish

Label: wayfinder:map

## Destination

An implementation-ready M15 specification and dependency map in which every presentation and navigation decision is resolved, without implementing the milestone itself.

## Notes

- Primary domain: Presentation. Consult `src/tui/CONTEXT.md`, with Review, Diff, and Bitbucket context where comment scope or rendered data crosses those boundaries.
- Use the `prototype`, `grilling`, `domain-modeling`, `research`, and `zig` skills as each ticket requires.
- Treat the specific acceptance criteria already written under M15 in `TODO.md` as constraints rather than reopening them from first principles.
- Keyboard operation must remain complete. Mouse support, if accepted, is additive and must retain keyboard parity.
- Evaluative items may resolve to a no-go when evidence does not justify implementation.
- Breaking changes to default keys and configuration are acceptable during initial development; there is no compatibility or alias requirement.
- File-level Comments enter M15 only if research finds a native Bitbucket representation that fits the existing model cleanly; otherwise defer them.

## Decisions so far

- [Establish Bitbucket's File-level Comment contract](issues/01-establish-bitbucket-file-level-comment-contract.md) — Bitbucket natively supports path-only root Comments through its ordinary comment and Thread APIs, so M15's File-level scope gate passes.
- [Choose the Sidebar File Tree interaction](issues/02-choose-sidebar-file-tree-interaction.md) — Use a compacted repository-path outline with conventional tree motions, a separate Sidebar cursor, centered active-File reveal, and fixed right-edge tallies.
- [Choose the disclosure language for hidden review content](issues/03-choose-disclosure-language-for-hidden-review-content.md) — Use type-shaped persistent disclosure rows with one Enter-to-toggle contract and independent Session-relative state for resolved Threads, context Folds, and Outdated sections.
- [Choose Markdown and long-body presentation](issues/04-choose-markdown-and-long-body-presentation.md) — Use bounded review cards with terminal-native Markdown, visible link destinations, structural Suggestion fences, and per-body disclosure after six rendered rows.
- [Choose Pane and Overlay framing](issues/05-choose-pane-and-overlay-framing.md) — Frame the Sidebar and DiffPane as focused tiled boxes, use joined one-row section rules, and keep Overlays to a restrained single-line frame.
- [Establish the mouse compatibility envelope](issues/07-establish-mouse-compatibility-envelope.md) — Click focus/disclosure and vertical scrolling are sound candidates; drag selection needs a narrow contract, and every mouse gesture requires keyboard parity.
- [Decide M15 mouse support](issues/08-decide-m15-mouse-support.md) — Ship default-on, configurable clicks and wheel navigation for Panes, disclosures, and Pickers, while excluding mouse Selection and less portable gestures.

## Not yet specified

- Implementation slices and their test matrix until the interaction decisions establish the state transitions that must be integrated.

## Out of scope

- Implementing M15; this map ends at an implementation-ready specification.
- Review-item editing, mutation, and submission hardening owned by M16.
- Diff/highlighting completeness and persistent disk caching owned by M17.
