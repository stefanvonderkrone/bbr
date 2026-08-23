# 20 — Wrap SideBySide Halves Independently

**What to build:** Wrap old and new SideBySide halves within their own body widths while keeping paired continuations aligned around a fixed divider.

**Blocked by:** 19 — Add Complete Unified Wrapping.

**Status:** ready-for-agent

- [ ] Each half derives its body width after its gutter and the fixed divider and wraps without crossing the divider.
- [ ] A LinePair uses the larger continuation count, and the shorter or absent half contributes neutral blank cells.
- [ ] Each half preserves its own line number, decoration, Selection, semantic owner, and source offsets across continuations.
- [ ] Narrow panes with no body cells remain valid and publish no partial Frame.
- [ ] Visual-row navigation, Anchor creation, resize restoration, and disabled clipping parity work for unequal and absent halves.
