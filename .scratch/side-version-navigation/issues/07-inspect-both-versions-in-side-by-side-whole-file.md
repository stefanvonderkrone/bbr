# 07 — Inspect both versions in SideBySide WholeFile

**What to build:** Let a reviewer compare both complete File versions in SideBySide WholeFile while the Selected Version remains the source Action target.

**Blocked by:** 05 — Add the Selected Version foundation.

**Status:** ready-for-agent

- [ ] SideBySide WholeFile builds old and new complete content independently.
- [ ] The projection pairs unchanged full-content Lines and uses the existing bounded Hunk matcher for changed runs.
- [ ] The projection does not parse or compute a second Diff.
- [ ] Hunk Lines keep their identity, Anchor eligibility, diff styling, and authoritative old or new coordinates.
- [ ] Each unavailable version shows its own loading, absent, binary, invalid UTF-8, acquisition-failure, or empty state.
- [ ] Usable content stays visible when the opposite version is unavailable.
- [ ] Current inline ReviewCards remain on their native old or new Hunk Lines.
- [ ] File-level and outdated ReviewCard placement does not change, and every ReviewCard appears once.
- [ ] Projection metadata identifies the Selected Version column and its inner gutter edge without changing source colors.
- [ ] Pure projection tests cover paired Lines, unpaired Lines, gaps, all File shapes, independent states, and ReviewCard placement.
