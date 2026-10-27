# Agent guidance

## Agent skills

### Issue tracker

Issues and PRDs are tracked as local Markdown under `.scratch/`; external PRs are not a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the canonical `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix` states. See `docs/agents/triage-labels.md`.

### Domain docs

Read `GLOSSARY-MAP.md` for domain vocabulary and relationships. Read `docs/code-navigation.md` to find implementation owners. System-wide decisions live under `docs/adr/`. See `docs/agents/domain.md`.

### Agent checks and tools

After agent document or tracker changes, run `python3 tools/check_agent_docs.py`. See `docs/agents/tools.md` for project MCP defaults.

## Rules and enforcement

Each rule names the check that fails when you break it. A rule marked "convention (no check)" fails nowhere, so read it before you change that code.

| Rule | Enforcement |
| --- | --- |
| A List Overlay arm holds no pointer except the buffers it owns. Borrowed data, such as the Session's Files, comes in as an argument at each call. | The `comptime` block after `ListOverlay` in `src/tui/list_overlay.zig` (compile error). |
| The File Finder and the Command Palette close before Session replacement. | The exhaustive switch in `ListOverlay.closesOnReplacement` in `src/tui/list_overlay.zig` (compile error for a new arm). The tests "File finder opened during a replacement does not outlive the replaced Session" and "a Session replacement closes the Command Palette" in `src/tui/presentation.zig`. |
| A new List Overlay is one arm of the `ListOverlay` union in `src/tui/list_overlay.zig`. | The exhaustive switches in the `ListOverlay` methods (compile error). |
| An `OwnedCommand` converts to its launch-failure `OwnedInput` only in `OwnedCommand.launchFailed` in `src/tui/presentation.zig`. No arm frees its payload. | The exhaustive switch in `OwnedCommand.launchFailed` (compile error). The test "every OwnedCommand launch failure keeps its correlation and frees the command". |
| Each `ThemeId` has one built-in Theme with the same name. | The `comptime` block after `theme.value` in `src/tui/theme.zig` (compile error). The test "every ThemeId resolves to the built-in Theme of the same name". |
| Only `src/xdg.zig` reads `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `XDG_STATE_HOME`. Other code calls `xdg.configHome`, `xdg.dataHome`, `xdg.stateHome`, or `xdg.configFile`, which ignore an empty or relative base. | `tools/check_xdg_reads.py`, run by `zig build test`. It skips `test` blocks and `env.put(` lines. |
| A terminal surface is a View tree in `src/tui/layouts.zig`. Only `src/tui/view_paint.zig` paints borders, rules, junctions, Titles, and scroll bars. A content painter draws into a Slot's content rect. | `tools/check_box_glyphs.py`, run by `zig build test`. It fails on a border corner or junction glyph in `render.zig` or `app.zig` outside `test` blocks. |
| A Pane has rounded corners and its Title in the top border. Its body starts in the next row, with no rule under the Title. The Sidebar and the DiffPane touch, with no empty column between them. | The tests "focused Pane frames and File Tree tallies use Frame-owned geometry" in `src/tui/render.zig` and "the Panes touch with no gap and a 28-cell Sidebar" in `src/tui/layouts.zig`. |
| Every Title has one blank cell on each side, so its text never touches the border. A Title that a View tree cannot hold, such as the DiffPane path, goes through `view_paint.titleText`. A control that its owner paints, such as the Selected Version control, calls `view_paint.titleGaps`. | `view_paint.titleText` and `view_paint.titleGaps` add the blank cells and take no option to drop them. The tests "the painter joins a rule into its parent border and paints Titles and thumbs" in `src/tui/view_paint.zig` and "DiffPane title reserves and renders published Selected Version targets" in `src/tui/render.zig`. |
| Every Overlay surface has a rounded border. An input Overlay, which is every List Overlay and Review Search, builds its surface with `inputSurface` in `src/tui/layouts.zig`. That surface is a bordered input box above a bordered result box, with no outer border. Every other Overlay builds its surface with `overlaySurface`. A border has no square option. | `view.Border` has no corner field (compile error). The tests "every Overlay surface has a rounded border" and "an input Overlay is a bordered input box above a bordered result list" in `src/tui/render.zig`. |
| A new Composition is one arm of the `Composition` union in `src/tui/view.zig`. | The exhaustive switch in `view.walk` (compile error). |
| A layout tree places each of its Slots exactly once. | The assertions in `view.Solver`. The test "every layout places each of its Slots" in `src/tui/layouts.zig`. |
| A layout tree always declares its scroll bars, and only the scroll numbers vary. Presentation solves a tree without the numbers, so a scroll bar that comes and goes would move a padding or margin ring between hit testing and paint. | Convention (no check). `layouts.Scroll` is not optional in the existing trees. |
| `presentation.zig` does not import vaxis or `theme.zig`. The Theme reaches Presentation only as a `ThemeId`. | Convention (no check). `presentation.zig` imports `keymap.zig`, and `keymap.zig` imports vaxis. |
| A File Jump calls `Published.jumpToFileHeader` in `src/tui/presentation.zig`. It puts the File header on the top DiffPane row, and Nav clamps the scroll at the end of the Buffer. A File Jump from the File Tree moves focus to the DiffPane. | The test "every File jump puts the File header on the top DiffPane row and the File Tree cursor on the File" in `src/tui/presentation.zig`. |
| While the DiffPane has focus, the File Tree cursor follows the active File. `revealActiveFile` moves it, and keyboard, mouse, and view-build paths all call `revealActiveFile` when the active File changes. | The tests "every File jump puts the File header on the top DiffPane row and the File Tree cursor on the File" and "M21 kernel active File reveal without collapsed ancestors needs no allocation or Buffer rebuild" in `src/tui/presentation.zig`. |
| The status row paints each part through `Theme.statusStyle` in `src/tui/theme.zig`. Every cell has the status bar background, and the bar follows the Theme polarity: a dark bar with light text in a dark Theme, a light bar with dark text in a light Theme. A new part is one arm of `StatusPart`. | The exhaustive switch in `Theme.statusStyle` (compile error). The tests "the status row follows the Theme polarity and emphasizes its parts" and "the status row colors each Reviewer Verdict, Buffer Search miss, and busy state" in `src/tui/app.zig`. |
