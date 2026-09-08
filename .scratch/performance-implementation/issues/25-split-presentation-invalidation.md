# Split Presentation invalidation

Type: task
Status: resolved
Blocked by: 22

## Question

If Action 21 passes the P2 gate, which independent Presentation changes can skip Buffer projection or paint while every published Presentation Frame remains internally consistent?

## Answer

Keep Buffer, visual-row, and File Tree publication in one transaction. They share one `ArenaRing`, and no stage-isolated measurement justifies separate lifetimes or partial publication. Existing navigation and height-only resize paths continue to skip Buffer projection.

Use a composite paint revision for interaction state and the published Presentation Frame. No-op mouse input and unchanged File Enrichment checks keep this revision stable. The app now skips both drawing and `vaxis.render` when the revision matches the last painted projection. A File Enrichment check that publishes a new Buffer changes the Frame part, so the app paints the complete new Presentation Frame.

The current `frame_paint_1000_rows` benchmark measures a 2,488,750 ns median and a 2,622,542 ns p95 with 15 ReleaseFast samples. Each skipped event removes that work and makes no allocation. The output checksum remains `31e6099593c99148`. `zig build test --summary all` passes all 709 tests. `zig fmt --check src/tui/presentation.zig src/tui/app.zig` and `git diff --check` pass.
