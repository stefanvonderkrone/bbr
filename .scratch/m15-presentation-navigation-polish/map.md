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
- [Establish the mouse compatibility envelope](issues/07-establish-mouse-compatibility-envelope.md) — Click focus/disclosure and vertical scrolling are sound candidates; drag selection needs a narrow contract, and every mouse gesture requires keyboard parity.

## Not yet specified

- The concrete mouse event, hit-testing, and selection work implied if mouse support is accepted.
- The rendering/parser seam and state representation implied by the chosen Markdown and disclosure behavior.
- Implementation slices and their test matrix until the interaction decisions establish the state transitions that must be integrated.

## Out of scope

- Implementing M15; this map ends at an implementation-ready specification.
- Review-item editing, mutation, and submission hardening owned by M16.
- Diff/highlighting completeness and persistent disk caching owned by M17.
