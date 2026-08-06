# Add keyboard-parity mouse navigation

Status: ready-for-agent

## What to build

Add default-on, configurable mouse navigation as an adapter over existing semantic Actions. Use only targets and geometry from the published Frame, validate a click across press and release revisions, and support the accepted Pane, disclosure, Picker-selection, and vertical-wheel behaviors without weakening keyboard completeness.

## Acceptance criteria

- [ ] A press records the current Frame revision and semantic target; release activates only when both still match, and any intervening projection change cancels the click.
- [ ] Accepted clicks focus Panes, toggle disclosures, focus Files, and select Picker entries by dispatching the same semantic state transitions as their keyboard equivalents.
- [ ] Picker clicks select but never confirm; Composer and non-Picker Overlays add no mouse Actions.
- [ ] Vertical wheel input scrolls the target Pane or Picker by the configured row count, while drag, Selection, horizontal wheel, unsupported buttons, borders, clipped content, and blank space are ignored safely.
- [ ] `[input.mouse].enabled` defaults to `true`, can disable all mouse behavior, and keyboard operation remains complete in both settings.
- [ ] Deterministic parity tests cover press/release cancellation after movement or Frame replacement, Overlay capture, overlapping/clipped geometry, all accepted targets, ignored gestures, and configurable scrolling.

## Blocked by

- [20 — Introduce contextual Actions and purpose-shaped Overlays](20-introduce-contextual-actions-and-purpose-shaped-overlays.md)
