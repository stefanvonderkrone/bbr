# Choose the disclosure language for hidden review content

Type: prototype
Status: resolved
Blocked by: none

## Question

What consistent in-place disclosure interaction should independently collapse and expand resolved Threads, context Folds, and Outdated sections while keeping each kind recognizable, navigable, and stable across Buffer rebuilds within one Session?

## Answer

Adopt the prototype's **B — Type-shaped affordances** contract: the three disclosure rows share one interaction and state model, but each retains the visual hierarchy appropriate to its content.

- Keep a persistent, navigable disclosure row at the content's position in both states. `Enter` toggles the disclosure under the DiffPane cursor in either direction; replace the one-way `expand_fold` Action with a general `toggle_disclosure` Action. Rebuilding the Buffer keeps the cursor on that same disclosure row, so expanding or re-collapsing does not cause a navigation jump.
- Render a collapsed resolved Thread as a compact success-styled row, `✓ Resolved thread · N replies`; expanding keeps that row as the Thread header and inserts the root Comment plus all Replies beneath it. Resolved indicators are always projected. Retire the global `show_resolved` preference and `toggle_resolved` Action rather than allowing `T` to hide the required indicators.
- Render a context Fold as a low-emphasis divider between rules, `⋯ N unchanged lines`; expanding keeps the divider in place and inserts the already-loaded context below it. The same row therefore supports re-collapse without refetching.
- Render each per-File Outdated disclosure as a warning-styled section header, `Outdated · <path> · N threads`; expanding keeps the header and inserts all of that File's outdated Threads and Draft snapshots beneath it. Outdated content remains represented even while collapsed, replacing the old always-expanded rule.
- Start every resolved Thread, context Fold, and Outdated section collapsed. Their states are independent: toggling one never opens or closes another object or another disclosure kind.
- Store expanded disclosure state in Presentation as a Session-relative set keyed by a tagged identity: resolved Thread by root `CommentId`, Fold by its stable first-hidden-Line identity, and Outdated section by its Session File identity. Preserve the set across redraws and Buffer rebuilds, including temporary omission through File isolation, Draft saves, and File Enrichment updates; clear it only on successful Session replacement.
- Give each kind its own Theme role while preserving the shared disclosure glyph semantics: right/down chevrons communicate collapsed/expanded state. Narrow terminals may truncate the descriptive label after preserving the glyph, kind, and count.

Prototype context: branch `prototype/m15-disclosure-language`, commit `77a7e93`, path `.scratch/m15-presentation-navigation-polish/prototypes/disclosure/`.

## Comments

- 2026-08-04: Interactive disclosure prototype prepared with Uniform disclosure rows, Type-shaped affordances, and Minimal gutter controls variants. It exercises independent toggles, Buffer-rebuild preservation, and Session-reset behavior. Captured on branch `prototype/m15-disclosure-language` at commit `77a7e93`.
- 2026-08-04: Human selected B — Type-shaped affordances.
