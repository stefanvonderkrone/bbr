# 12 — Harden Selected Version failure and geometry boundaries

**What to build:** Finish M20 with deterministic proof that allocation failures, small terminal geometry, and rejected mouse input cannot publish mixed state or hidden controls.

**Blocked by:** 11 — Prove cross-source Selected Version behavior.

**Status:** ready-for-agent

- [ ] Failure injection covers Buffer, visual-row, title-target, clipboard, and File Enrichment admission allocations.
- [ ] Version-change failure preserves the complete prior Presentation Frame, Preferences, cursor, Count, Selection, and pending mouse press.
- [ ] Yank refusal, yank allocation failure, and clipboard adapter failure follow their specified cleanup rules.
- [ ] Headless rendering tests cover zero-width, narrow, ordinary, and wide DiffPane geometry.
- [ ] Rendering tests verify title reservation, clipping, segment accent, SideBySide gutter accent, Pane focus independence, and Highlighting preservation.
- [ ] Mouse tests cover same-target activation, Frame replacement, movement, mismatched release, Overlay capture, disabled input, modifiers, unsupported buttons, and clipped cells.
- [ ] Tests added in new Zig files join the test import chain, and the reported test count increases.
- [ ] The repository test command passes with default keys and visible controls active.
- [ ] M20 adds no persistent setting, second Diff, source-specific Presentation branch, retry Action, feature flag, or compatibility alias.
