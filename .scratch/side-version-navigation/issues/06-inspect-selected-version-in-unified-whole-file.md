# 06 — Inspect the Selected Version in Unified WholeFile

**What to build:** Let a reviewer inspect one complete old or new File version in Unified WholeFile without fallback or synthetic Anchors.

**Blocked by:** 05 — Add the Selected Version foundation.

**Status:** ready-for-agent

- [ ] Unified WholeFile shows only the Selected Version as one continuous File with that version's line numbers.
- [ ] The projection omits Hunk headers and Folds, preserves Hunk Line identity and styling, and keeps blob-sourced Lines neutral and non-anchorable.
- [ ] Added, modified, removed, and renamed Files use the Selected Version's content and path without substituting the other version.
- [ ] Loading, absent, binary, invalid UTF-8, acquisition failure, empty text, known-size, and unknown-size states identify the Selected Version.
- [ ] Current selected-version inline ReviewCards remain at their Hunk Lines.
- [ ] Current opposite-version inline ReviewCards appear once in one collapsed File section.
- [ ] File-level and outdated ReviewCard placement does not change, and every ReviewCard appears once.
- [ ] WholeFile inline Comment authoring accepts only selected-version Hunk Lines.
- [ ] Suggestion authoring also requires the Selected Version to be new.
- [ ] Pure projection tests cover complete gaps, first and last Lines, empty Files, paths, line numbers, Hunk identity, and no fallback.
