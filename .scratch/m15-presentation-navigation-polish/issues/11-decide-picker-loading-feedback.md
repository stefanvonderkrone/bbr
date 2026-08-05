# Decide Picker loading feedback

Type: prototype
Status: resolved
Blocked by: none

## Question

When representative Picker delays are instrumented, does the current static loading frame feel stalled, and if so what minimal animated feedback justifies adding a tick while preserving the blocking `nextEvent` model?

## Answer

The static frame feels stalled at representative multi-second delays, and the minimal improvement earns its event-loop cost: use the prototype's **B — Single-glyph spinner** beside the existing `Loading pull requests…` copy. The human selected B after comparing the static baseline, single-glyph spinner, and ambient animation at selectable 0.25, 1, 3, and 8 second delays. The ambient treatment adds hierarchy without adding useful information; the static treatment gives no continuing evidence that the application is alive.

The implementation contract is deliberately narrow:

- Animate one fixed-width Braille spinner glyph beside the unchanged loading label. Do not add a progress bar, elapsed time, staged copy, or indeterminate sweep.
- A low-frequency timer source posts a `tick` through the same event path that wakes the blocking `nextEvent` loop; the UI loop must not become a polling or timeout loop.
- Run ticks only while an animated loading surface is visible. Stop them when the Picker is populated, fails, closes, becomes stale, or shutdown begins, so an idle review still blocks completely.
- The tick advances Presentation-owned animation phase and requests a redraw; it never changes Review state, loading identity, cancellation, or completion semantics.
- Deterministic rendering and transition tests inject ticks explicitly rather than depending on wall-clock time.

Prototype: [Picker loading feedback variants](../prototypes/picker-loading/index.html) ([run instructions](../prototypes/picker-loading/README.md)).
