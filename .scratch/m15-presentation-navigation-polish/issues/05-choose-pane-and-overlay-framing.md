# Choose Pane and Overlay framing

Type: prototype
Status: resolved
Blocked by: none

## Question

Which box-drawing borders, separators, spacing, and Theme roles give the Sidebar, DiffPane, Composer, Picker, help Overlay, and section dividers a clear hierarchy without consuming too much space or failing in narrow terminals?

## Answer

Combine the prototype's **B — Framed Panes** main layout with **A — Hairline split** Overlays.

- Give the Sidebar and DiffPane independent one-cell, single-line box frames. Their title row sits inside the frame and a horizontal rule separates it from content. At ordinary widths, leave one blank column between the two frames so they read as adjacent tiled Panes rather than one subdivided box.
- Use the frame to communicate focus: the focused Pane uses an accent `pane_border_focused` Theme role and the other uses a muted `pane_border` role. Borders never borrow gutter, diff-band, selection, or status colors. Pane content backgrounds and the existing full-width diff bands continue inside the frame without painting over it.
- Render File headers and disclosure sections as one-row rules joined to the DiffPane frame, such as `├─ M src/tui/render.zig ─────┤` and `├─ ▸ Outdated · path · 2 threads ─┤`. Preserve the disclosure glyph, kind, and count before truncating the descriptive path; do not spend three rows on a nested box.
- Center each Composer, Picker, help, loading, and submission Overlay over the complete tiled area. Give it one single-line outer frame, a title row separated from the body by one rule, and an optional footer/hint row separated by another rule. Use no double border. The frame uses `overlay_border`, its title uses `overlay_title`, and the body/footer keep their existing surface and semantic roles. The underlying Panes remain visible but inactive while the Overlay captures input.
- At narrow widths, preserve semantic content before ornament: remove the blank inter-Pane column first, joining the two complete frames side by side; truncate Pane titles and section labels inside their borders; then allow the existing Sidebar name/indentation rules to yield. Overlays clamp to the available terminal rectangle and retain their outer border whenever at least a three-by-three surface exists. Below that, draw only the highest-priority title/body cells that fit rather than indexing outside the Window.
- Add explicit Theme roles for normal and focused Pane borders, Overlay border/title, and section rules. Every built-in Theme must keep normal borders visible but subordinate, focused borders distinguishable without color alone where practical, and Overlay borders stronger than either Pane border.

Prototype context: branch `prototype/m15-pane-overlay-framing`, commit `99527839839f50bc4d94c5142955a692a3cc296f`, path `.scratch/m15-presentation-navigation-polish/prototypes/pane-overlay-framing/`.

## Comments

- 2026-08-04: Interactive framing prototype prepared with Hairline split, Framed Panes, and Navigation rail variants. It compares Composer, Picker, and help Overlays at 56, 80, and 120 columns. Captured on branch `prototype/m15-pane-overlay-framing` at commit `99527839839f50bc4d94c5142955a692a3cc296f`.
- 2026-08-04: Human selected B — Framed Panes for the main layout and A — Hairline split for Overlays.
