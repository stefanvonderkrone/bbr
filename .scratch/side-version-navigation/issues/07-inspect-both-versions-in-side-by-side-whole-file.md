# 07 — Inspect both versions in SideBySide WholeFile

**What to build:** Let a reviewer compare both complete File versions in SideBySide WholeFile while the Selected Version remains the source Action target.

**Blocked by:** 05 — Add the Selected Version foundation.

**Status:** resolved

- [x] SideBySide WholeFile builds old and new complete content independently.
- [x] The projection pairs unchanged full-content Lines and uses the existing bounded Hunk matcher for changed runs.
- [x] The projection does not parse or compute a second Diff.
- [x] Hunk Lines keep their identity, Anchor eligibility, diff styling, and authoritative old or new coordinates.
- [x] Each unavailable version shows its own loading, absent, binary, invalid UTF-8, acquisition-failure, or empty state.
- [x] Usable content stays visible when the opposite version is unavailable.
- [x] Current inline ReviewCards remain on their native old or new Hunk Lines.
- [x] File-level and outdated ReviewCard placement does not change, and every ReviewCard appears once.
- [x] Projection metadata identifies the Selected Version column and its inner gutter edge without changing source colors.
- [x] Pure projection tests cover paired Lines, unpaired Lines, gaps, all File shapes, independent states, and ReviewCard placement.
