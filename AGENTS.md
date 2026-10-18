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
| `presentation.zig` does not import vaxis or `theme.zig`. The Theme reaches Presentation only as a `ThemeId`. | Convention (no check). `presentation.zig` imports `keymap.zig`, and `keymap.zig` imports vaxis. |
