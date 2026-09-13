# 10 — Activate the Selected Version title controls

**What to build:** Give keyboard and mouse users one visible DiffPane title control for changing the Selected Version in every Layout and Scope.

**Blocked by:** 08 — Publish Selected Version changes atomically. 09 — Yank Selected Version source.

**Status:** resolved

- [x] The default Keymap binds `g <` to `select_old_version` and `g >` to `select_new_version`.
- [x] Configuration overrides support parsing, conflict checks, unbinding, and help grouping for both Actions without compatibility aliases.
- [x] The DiffPane title shows `g< OLD` and `NEW g>` in every Layout and Scope.
- [x] The selected segment uses the Theme accent and bold text without creating another Pane focus state.
- [x] SideBySide WholeFile accents the selected column header and inner gutter edge without changing diff backgrounds, source colors, or Highlighting.
- [x] Title layout reserves both segments before it truncates the path and Scope label.
- [x] Clipped title cells create no hidden mouse target.
- [x] Rendering uses the exact title rectangles from the published Presentation Frame.
- [x] A primary press and release on the same segment and Frame revision dispatches the matching Action.
- [x] Overlay capture, disabled mouse input, modifiers, motion, drag, unsupported buttons, mismatched release, and Frame replacement prevent activation.
- [x] A source click leaves the Selected Version unchanged.
- [x] Help keeps unavailable source Actions visible with their typed refusal reason.

## Implementation

- Commit: `7f96d07 tui: activate Selected Version title controls`.
- Verification: `zig build test --summary all` passes with 744 tests.
