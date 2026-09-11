# 08 — Publish Selected Version changes atomically

**What to build:** Let a reviewer change the Selected Version without observing mixed title, Buffer, navigation, File Tree, or source Action state.

**Blocked by:** 06 — Inspect the Selected Version in Unified WholeFile. 07 — Inspect both versions in SideBySide WholeFile.

**Status:** resolved

- [x] Selecting the current version is an exact no-op that preserves Frame revision, cursor, Count, Selection, pending mouse press, and File Enrichment work.
- [x] An actual change publishes one complete Presentation Frame and then clears Count and Selection.
- [x] A failed change preserves the prior Preferences, Frame, cursor, Count, Selection, and pending mouse press.
- [x] Changes and fetched-whole keep their Buffer rows and cursor position while the title and source Action target change.
- [x] WholeFile restores the same selected-version Hunk Line when that Line exists.
- [x] Restoration otherwise chooses the next selected-version Line, the nearest prior Line, or the File header in that order.
- [x] Wrapping preserves semantic Line identity and the nearest valid source offset.
- [x] A focused WholeFile requests the existing two-version File Enrichment command only when required content is pending.
- [x] A loading Frame retains the restoration target until matching File Enrichment completes.
- [x] Later reviewer navigation cancels deferred restoration.
- [x] Session replacement preserves the Selected Version, while a new Presentation instance defaults to new.
- [x] Session Epoch and WorkId checks prevent stale File Enrichment from changing the Session, Selected Version, or Frame.

- Commit: `6f98706 tui: publish Selected Version changes atomically`.
