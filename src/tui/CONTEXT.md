# Presentation

The terminal UI shell built on libvaxis: how the screen is divided, what floats over it,
and how the reviewer navigates. Owns no domain data — it projects the Diff and Review models.

## Language

**Pane**:
A tiled region of the screen with a defined role (Sidebar, DiffPane, ThreadPane). Panes tile; they do not overlap.
_Avoid_: window (reserved for vaxis's surface), view, panel.

**Sidebar**:
The persistent Pane listing the current PullRequest's Files, with change status and comment/draft counts.
_Avoid_: file tree, nav, drawer.

**Overlay**:
A floating surface drawn over the Panes — keybinding help, the PR picker, a comment composer. Dismissible; captures input while open.
_Avoid_: popup, modal, dialog, hover (describe the trigger, not the thing).

**Picker**:
The Overlay for fuzzy-finding a PullRequest by id or title (backed by `zf`) to switch the loaded PR.
_Avoid_: search, finder, switcher, palette.

**Composer**:
The Overlay for writing a Draft (comment, reply, or suggestion) before it enters the PendingReview.
_Avoid_: editor, input, form.

**Epoch**:
A monotonically increasing token stamped on each PR/File load; background results carrying a stale Epoch are discarded. How a PR switch cancels in-flight work.
_Avoid_: generation, version, token, nonce.

**Keymap**:
The binding of key input to actions, supporting vim-style Motions and arrow keys side by side. Config-driven; the source the keybinding-help Overlay reads from.
_Avoid_: bindings, shortcuts, hotkeys.

**Motion**:
A navigation command that may take a numeric Count prefix — `hjkl`, arrows, `ctrl-d`/`ctrl-u`, `gg`/`G`, `zz`. The vocabulary of movement within a Pane.
_Avoid_: movement, command, action (an action is the broader term).

**Count**:
The pending numeric prefix applied to the next Motion (e.g. `5j`). Held in a register and cleared after the Motion runs.
_Avoid_: repeat, multiplier, prefix.

**Action**:
What a key resolves to in the Keymap: a Motion or a command (quit, reply, submit, toggle a view…). The unit the Keymap binds and dispatch acts on; the broader term Motion specializes.
_Avoid_: command, handler, event.

**Leader**:
A key that begins a multi-chord Action — the first `g` of `gg`, or the first chord of a longer configured sequence. A Leader has no Action of its own; input continues until the sequence resolves or becomes unrecognized. Distinct from the Count, which the engine accumulates separately.
_Avoid_: prefix, modifier, chord.
