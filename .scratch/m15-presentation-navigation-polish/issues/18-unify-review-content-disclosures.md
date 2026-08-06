# Unify review-content disclosures

Status: ready-for-agent

## What to build

Replace global and one-way visibility controls with one persistent disclosure language for resolved Threads, context Folds, Outdated sections, and over-limit ReviewCards. Each disclosure is independently keyed, exposes the same toggle transition to Presentation, survives Frame reconstruction within a Session, and resets canonically when the Session is replaced.

## Acceptance criteria

- [ ] Resolved Threads, Folds, Outdated sections, and ReviewCards render type-shaped persistent disclosure rows with a common toggle contract.
- [ ] Disclosure state is keyed per semantic owner so toggling one item never changes another item of the same or a different type.
- [ ] Explicit disclosure choices survive redraw, resize, File focus/isolation, Draft save, and enrichment-driven Frame rebuilds.
- [ ] A successful Session replacement resets all disclosures to their accepted defaults, while a failed replacement preserves every disclosure and the published Frame.
- [ ] Toggling restores navigation to the semantic owner or nearest valid source position and clears an invalidated Selection.
- [ ] Deterministic tests cover independent toggles, nested ReviewCard/Thread behavior, rebuild persistence, canonical reset, and failed-replacement preservation.

## Blocked by

- [16 — Carry CommentScope end to end](16-carry-commentscope-end-to-end.md)
- [17 — Project Markdown ReviewCards](17-project-markdown-reviewcards.md)
