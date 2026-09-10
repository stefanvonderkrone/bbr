# 10 — Activate the Selected Version title controls

**What to build:** Give keyboard and mouse users one visible DiffPane title control for changing the Selected Version in every Layout and Scope.

**Blocked by:** 08 — Publish Selected Version changes atomically. 09 — Yank Selected Version source.

**Status:** ready-for-agent

- [ ] The default Keymap binds `g <` to `select_old_version` and `g >` to `select_new_version`.
- [ ] Configuration overrides support parsing, conflict checks, unbinding, and help grouping for both Actions without compatibility aliases.
- [ ] The DiffPane title shows `g< OLD` and `NEW g>` in every Layout and Scope.
- [ ] The selected segment uses the Theme accent and bold text without creating another Pane focus state.
- [ ] SideBySide WholeFile accents the selected column header and inner gutter edge without changing diff backgrounds, source colors, or Highlighting.
- [ ] Title layout reserves both segments before it truncates the path and Scope label.
- [ ] Clipped title cells create no hidden mouse target.
- [ ] Rendering uses the exact title rectangles from the published Presentation Frame.
- [ ] A primary press and release on the same segment and Frame revision dispatches the matching Action.
- [ ] Overlay capture, disabled mouse input, modifiers, motion, drag, unsupported buttons, mismatched release, and Frame replacement prevent activation.
- [ ] A source click leaves the Selected Version unchanged.
- [ ] Help keeps unavailable source Actions visible with their typed refusal reason.
