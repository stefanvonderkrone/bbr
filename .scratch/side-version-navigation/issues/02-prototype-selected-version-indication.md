# Prototype the Selected Version indication

Type: prototype
Status: resolved
Blocked by: 01

## Question

How should the DiffPane show and change the Selected Version without confusing that review-wide choice with Pane focus, a SideBySide column, or an Anchor side?

Build a rough terminal prototype for Unified and SideBySide Layouts in Changes and WholeFile scopes. Test the Old/New title controls, the selected-column accent, unavailable and loading states, narrow terminals, keyboard focus, and mouse targets. Record the accepted visual and interaction contract as the answer, and link the prototype asset.

## Answer

Use a two-segment control at the right edge of the DiffPane title. The segments read `g< OLD` and `NEW g>`. The selected segment uses the Theme accent and bold text. The other segment keeps the normal title style.

The control appears in Unified and SideBySide Layouts and in every Scope. A narrow DiffPane truncates the path and Scope label before it truncates the control. Pane focus keeps its existing border and cursor treatment. The Selected Version control does not gain a second keyboard focus state.

`g<` dispatches `select_old_version`, and `g>` dispatches `select_new_version`. A primary mouse click on a segment dispatches the same Action. Clicking the selected segment is an idempotent Action. Clicking a source Line never changes the Selected Version.

Changes and fetched-whole scopes change only the title control and source Action target. Unified WholeFile rebuilds for the Selected Version. SideBySide keeps both columns and accents the selected column header and its inner gutter edge. The accent does not dim or recolor source text, diff styling, or Highlighting. The accent identifies the source Action target, not an Anchor target or a focused column.

Loading and unavailable content keep the selected segment accented. The Buffer shows the version-specific Status Placeholder from [Define the Selected Version projection](01-choose-old-new-side-inspection-and-yank.md). Presentation does not select the usable version as a fallback.

The accepted design is variant A with visible command keys. The rejected context ribbon consumes a source row. The rejected action dock covers Buffer content and separates the control from its state label.

Prototype context: branch `prototype/selected-version-indication`, commit `83ac38a`, [prototype asset](https://github.com/stefanvonderkrone/bbr/blob/prototype/selected-version-indication/.scratch/side-version-navigation/prototypes/selected-version-indication.html).
