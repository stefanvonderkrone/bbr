# 12 — Add File Content Status and Status Placeholders

**What to build:** Give each expected old and new File side a text, binary, or unavailable File Content Status. Project unavailable sides as stable Status Placeholders without hiding usable content or review discussion.

**Blocked by:** None — can start immediately.

**Status:** done

- [x] Each expected side exposes its File Content Status, optional byte size, and typed unavailable reason independently of Highlighting status.
- [x] Existing acquisition failures render distinct non-anchorable Status Placeholders in Unified and SideBySide Layout and in Changes and WholeFile Scope.
- [x] A Status Placeholder cannot receive an Anchor, Selection, Fold, or Highlighting, while File-level and Review-level Comments remain visible.
- [x] A known size is shown in bytes, and an unknown size is shown as `size unavailable`.
- [x] A usable opposite side remains visible when one side is unavailable.
