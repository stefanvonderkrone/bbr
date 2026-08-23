# 18 — Project Diff Lines as Visual Rows

**What to build:** Let Presentation Frame project width-independent Diff Line owners into geometry-dependent visual rows while preserving the current clipped display.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] Each projected Diff visual row carries its semantic owner, source-byte start, source-byte end, and sliced LineDecoration.
- [ ] Buffer remains width-independent and continues to contain each semantic Line or LinePair once.
- [ ] With wrapping disabled, Presentation emits one visual row per Diff row and clips exactly as before.
- [ ] Headers, Folds, Status Placeholders, sections, and ReviewCards keep their current projection contracts.
- [ ] Presentation publishes one complete Frame, and a projection allocation failure preserves the prior Frame.
