# Establish the atomic Presentation Frame

Status: ready-for-human

## What to build

Introduce the Presentation-owned frame boundary that all later M15 behavior can rely on without deliberately changing the visible interface. A published Presentation Frame must be one internally consistent, revisioned projection of the current Session, geometry, Buffer, navigation metadata, and semantic input targets. Frame construction is network-free and failure-safe: a complete replacement is published atomically, while a failed rebuild leaves the previous Frame and interaction state usable.

## Acceptance criteria

- [x] Buffer construction is owned by a Presentation package; Diff remains responsible only for Files, Hunks, Lines, Folds, and intra-line data, and the terminal renderer remains an adapter over projected rows.
- [x] One Frame owns the geometry, projected rows, Pane and Overlay rectangles, navigation-restoration metadata, and semantic targets consumed by rendering, cursor movement, and hit testing.
- [x] Every geometry-affecting rebuild stages and publishes a complete revision; allocation or projection failure preserves the previous Frame, navigation, and interaction state.
- [x] Rebuilds restore logical navigation through stable Line, File, disclosure, or ReviewCard ownership and clear Selection when its projected row range changes.
- [x] Cell width and grapheme measurement enter through an injectable `CellMetrics` seam rather than terminal-specific logic in projection.
- [x] Deterministic tests cover revision consistency, resize/rebuild restoration, forced allocation failure, and the absence of intentional visible regressions.

## Blocked by

None - can start immediately
