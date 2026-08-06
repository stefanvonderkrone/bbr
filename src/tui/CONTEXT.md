# Presentation

The terminal UI shell built on libvaxis: how the screen is divided, what floats over it,
and how the reviewer navigates. Owns no domain data — it projects the Diff and Review models.

## Language

**Session**:
The currently loaded review: private source context plus the common Diff, Threads, and per-File data materialized by either remote or local acquisition. Switching or explicitly refreshing a review replaces the Session; Buffer rebuilds and screen redraws do not.
_Avoid_: workspace, document, review state.

**ReviewHeader**:
The source-agnostic facts Presentation exposes to identify the current review: title, source and base Refs, their resolved commits, an optional author, a locator, and a source label. It is display metadata only; review policy never interprets its formatted labels.
_Avoid_: PullRequest header, comparison string, byline.

**File Enrichment**:
The lazily acquired old/new full-file content and Highlighting attached to a File during a Session. Each side becomes available independently; failure on one side does not suppress usable content from the other.
_Avoid_: blob load, highlight job, hydration.

**Pane**:
A tiled region of the screen with a defined role (Sidebar, DiffPane, ThreadPane). Panes tile; they do not overlap.
_Avoid_: window (reserved for vaxis's surface), view, panel.

**Sidebar**:
The persistent Pane containing the current review's File Tree, with change status and comment/draft counts.
_Avoid_: nav, drawer.

**File Tree**:
The collapsible repository-path hierarchy shown inside the Sidebar. Its entries are Directories and Files.
_Avoid_: Sidebar (the containing Pane), flat file list.

**Overlay**:
A floating surface drawn over the Panes — keybinding help, the PR picker, a comment composer. Dismissible; captures input while open.
_Avoid_: popup, modal, dialog, hover (describe the trigger, not the thing).

**Picker**:
The Overlay for fuzzy-finding a PullRequest by id or title (backed by `zf`) to switch the loaded PR. While its PullRequest list loads, a scoped low-frequency tick advances a single-glyph spinner without changing the blocking input loop.
_Avoid_: search, finder, switcher, palette.

**Composer**:
The Overlay for writing a Draft (comment, reply, or suggestion) before it enters the PendingReview.
_Avoid_: editor, input, form.

**ReviewBody**:
Presentation's width-independent semantic reading of a Comment or Draft's authored Markdown. Review retains the authored bytes; a ReviewBody identifies prose, headings, Suggestions, visible links, and inline emphasis so terminal-width changes only reproject its rows.
_Avoid_: parsed Comment, rendered Markdown, Markdown document.

**ReviewCard**:
The bounded DiffPane presentation of one Comment or Draft: an identifying header, ReviewBody rows, and an in-place disclosure footer when the projected body exceeds its row budget. Every row belongs to the same stable Comment or Draft identity.
_Avoid_: Comment (the Review entity), panel, box.

**Presentation Frame**:
One internally consistent projection of the published Session and its Session-relative interaction state at the current terminal geometry. It is the shared source for rendering, navigation restoration, and semantic mouse targeting; a failed reprojection preserves the previous complete Frame.
_Avoid_: screen (the terminal output), Buffer (only the DiffPane rows), render state, layout snapshot.

**Session Epoch**:
The identity of one published Session. Session-bound work such as File Enrichment carries that Session's Epoch and cannot change a later Session, even when both Sessions represent the same PullRequest. The Epoch changes only when a complete Session replacement is published; a failed replacement preserves the current Epoch and its in-flight work.
_Avoid_: PR id (identifies the PullRequest, not one Session), generation, version, token, nonce.

**Candidate Session**:
A privately staged replacement for the published Session. For a LocalReview, loading it includes resolving every persisted root Draft CommentScope against the candidate's resolved Refs before publication. Every attempt finishes as `current`, `moved`, `outdated`, or `unavailable`; unavailable placement is usable fallback content, not a failed candidate. Presentation publishes the candidate only after this phase and initial Buffer construction complete.
_Avoid_: partially loaded Session, hydration state, incremental refresh.

**ScopeProjection**:
The Session-scoped placement of a PendingReview's root Draft CommentScopes, keyed by root TempId. It is derived from the durable authored scope plus the current Session and owns each ScopeResolution and projected scope; Replies reuse their root's entry. Review scope resolves unchanged, while File and inline scopes may move or become outdated or unavailable. It belongs to the published review aggregate, not to Session or PendingReview, and is rebuilt on Session replacement. A newly saved Draft enters it as `current` because it was authored against that Session.
_Avoid_: persisted scope state, resolved Draft, mutable CommentScope, AnchorProjection.

**Durable Operation**:
Reviewer-authorized work that belongs to a PullRequest rather than to the Session that started it. A Submission remains valid and persists its outcomes when that Session is replaced; only projecting its progress or result into the current screen depends on which Session is published.
_Avoid_: Session work, background job, task.

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
The semantic operation input resolves to in the current Interaction Context: a Motion or a command (quit, reply, submit, toggle a disclosure…). The unit the Keymap binds and Presentation dispatch acts on; the broader term Motion specializes. The same key may resolve to different Actions in different Interaction Contexts, while mouse parity dispatches the same semantic Action where the accepted gesture has a keyboard equivalent.
_Avoid_: command, handler, event.

**Interaction Context**:
The active input surface and semantic target from the current Presentation Frame: an Overlay when one captures input, otherwise the focused Pane and its cursor target. It determines Action resolution and ActionAvailability without becoming Review state.
_Avoid_: mode (too broad), focus alone (omits the target), input state.

**ActionAvailability**:
Whether an Action is valid for the currently published Review. Unavailable Actions remain visible but greyed in the help Overlay; invoking one produces an explanatory status message, while Presentation alone decides availability.
_Avoid_: mode check, hidden binding, silent no-op.

**Leader**:
A key that begins a multi-chord Action — the first `g` of `gg`, or the first chord of a longer configured sequence. A Leader has no Action of its own; input continues until the sequence resolves or becomes unrecognized. Distinct from the Count, which the engine accumulates separately.
_Avoid_: prefix, modifier, chord.
