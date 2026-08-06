# Add framed Panes and the Sidebar File Tree

Status: ready-for-human

## What to build

Present the Sidebar and DiffPane as focused tiled Panes and replace the flat File list with a compacted repository-path outline. Give the Sidebar its own cursor, scroll state, expanded Directories, conventional tree motions, centered active-File reveal, and fixed right-edge review tallies while retaining complete DiffPane keyboard navigation.

## Acceptance criteria

- [x] Sidebar and DiffPane use Frame-owned focused borders and joined one-row section rules; restrained single-line framing remains reserved for Overlays.
- [x] The Sidebar projects a deterministic compacted repository-path tree with stable Directory and File identities, grapheme-safe truncation, and fixed right-edge tallies.
- [x] `Tab` changes Pane focus; Sidebar `j`/`k`/`h`/`l` and arrow motions navigate, expand, collapse, and focus entries conventionally; `[` and `]` retain previous/next File navigation in the DiffPane.
- [x] A new Session starts in the DiffPane at the first File with all Directories expanded and the Sidebar cursor on the active File.
- [x] Active-File changes reopen its ancestors and reveal its row near the Sidebar center without destroying unrelated explicit Directory state.
- [x] Geometry and navigation tests cover empty and deep trees, long and Unicode paths, fixed tallies, zero/narrow/ordinary/wide terminals, resize, and Session replacement.

## Blocked by

- [15 — Establish the atomic Presentation Frame](15-establish-the-atomic-presentation-frame.md)
