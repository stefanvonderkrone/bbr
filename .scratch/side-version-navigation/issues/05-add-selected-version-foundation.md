# 05 — Add the Selected Version foundation

**What to build:** Add the inactive internal contract that lets Presentation describe old-version or new-version inspection without changing current reviewer behavior.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] `SelectedVersion` has `old` and `new` values, and default Preferences select `new`.
- [ ] Preferences retain the Selected Version across Layout, Scope, and Session replacement changes without adding configuration or persistence.
- [ ] Action includes `select_old_version` and `select_new_version`, but no default key or visible control activates them yet.
- [ ] ReviewProjection and each complete Presentation Frame publish the Selected Version.
- [ ] Semantic row ownership can expose an old yank candidate, a new yank candidate, or both without changing Line identity.
- [ ] ActionAvailability has separate typed refusal fields for yank, inline Comment, and Suggestion Actions.
- [ ] Presentation Frame metadata can describe exact old-version and new-version title targets without rendering them.
- [ ] Existing behavior and the complete test suite remain unchanged.
