# Decide M15 mouse support

Type: grilling
Status: resolved
Blocked by: 02, 03, 07

## Question

Within the verified compatibility envelope and the chosen File Tree and disclosure interactions, which mouse conveniences—if any—earn inclusion in M15 while remaining optional, discoverable, and behaviorally equivalent to keyboard Actions?

## Answer

Include a deliberately narrow mouse contract in M15: Sidebar activation, DiffPane cursor placement, disclosure toggles, vertical scrolling, and Picker navigation. Mouse input is an optional convenience over the complete keyboard interface; it introduces no mouse-only workflow or state.

- Enable terminal mouse reporting by default. Configure it under `[input.mouse]` with `enabled = true`; setting it to `false` restores ordinary terminal mouse handling. Document that terminals commonly use Shift or Option as a terminal-dependent bypass for native text selection while reporting is enabled.
- Add count-aware `scroll_up` and `scroll_down` Presentation Actions, bound by default to `ctrl-y` and `ctrl-e`. Each keyboard invocation scrolls one row. A vertical wheel report dispatches the same transition for `vertical_scroll_rows`, configurable under `[input.mouse]` and defaulting to `3`, matching Neovim's default keyboard/wheel split.
- Target wheel input at the Pane or Picker under the pointer without changing focus. Keep its cursor visible by clamping it only when scrolling would otherwise move it outside the viewport; otherwise leave the cursor and any active Selection unchanged. Borders and blank or clipped geometry do nothing.
- In the Sidebar, a File-row click moves the tree cursor there, makes it the active File, and retains Sidebar focus. A Directory-row click moves the tree cursor there and toggles it. Blank Sidebar space only focuses the Sidebar.
- In the DiffPane, a row click focuses the DiffPane and moves its cursor to that visible Buffer row. Clicking a resolved-Thread, context-Fold, or Outdated-section disclosure row additionally dispatches the same `toggle_disclosure` Action as `Enter`; the entire rendered disclosure row is the target.
- In either the File finder or PullRequest Picker, wheel input scrolls the result list and clicking a result only moves the Picker selection. `Enter` remains the sole confirmation gesture, preventing an incidental click from focusing a File or replacing the Session.
- Recognize a click only when left-button press and release occur on the same current semantic target. Leaving the target, dragging, stale geometry, a clipped row, or an intervening Projection change cancels activation.
- An open Overlay exclusively captures mouse input. Apart from accepted Picker navigation, M15 adds no Overlay mouse controls: other clicks and wheels are ignored, outside clicks do not dismiss, and input never passes through to a Pane.
- Exclude mouse-driven Selection, right- and middle-click, horizontal wheel, hover/motion behavior, modifier-specific gestures, extra buttons, double-click, and drag from M15. Keyboard `v` plus Motions remains the complete bbr Selection interface.
- Add a compact Mouse section to the keybinding-help Overlay whether mouse reporting is enabled or disabled. It lists the accepted gestures, the opt-out setting, and the terminal-dependent native-selection bypass; no persistent status-bar hint is required.
- Derive hit testing from the exact current Presentation geometry and Projection. Mouse adapters identify a semantic target and dispatch the same Presentation state transition as its keyboard counterpart; rendering does not mutate state, and Overlays, borders, empty cells, clipped targets, and stale geometry cannot trigger underlying Actions.

The deterministic acceptance matrix must cover configuration defaults and opt-out, press/release cancellation, coordinate-to-target mapping at Pane and Overlay boundaries, configurable wheel counts, cursor clamping, Sidebar/File/disclosure/Picker Action parity, Projection changes between press and release, and ignored gestures. Interactive smoke checks cover a direct terminal, SSH PTY, and tmux; failure to deliver mouse events never removes the keyboard route.

## Comments

- 2026-08-04: Human accepted default-on configurable mouse reporting, configurable Neovim-style wheel steps, Sidebar and DiffPane clicks, disclosure toggles, Picker selection and scrolling, help discoverability, release-on-same-target activation, and the explicit exclusion of mouse Selection and unsupported gestures.
