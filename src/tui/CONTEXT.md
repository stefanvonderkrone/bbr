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

**File Read State**:
The current Presentation projection of a File Read Receipt against its File Review Fingerprint. An unread File is bold in the File Tree; a read File uses regular weight. It is derived from durable review state and the current Session rather than persisted as a bare boolean.
_Avoid_: File Read Receipt (the durable evidence), viewed state, bold flag.

**Overlay**:
A floating surface drawn over the Panes — keybinding help, the PR picker, a comment composer. Dismissible; captures input while open.
_Avoid_: popup, modal, dialog, hover (describe the trigger, not the thing).

**Picker**:
The Overlay for fuzzy-finding a PullRequest by id or title (backed by `zf`) to switch the loaded PR. While its PullRequest list loads, a scoped low-frequency tick advances a single-glyph spinner without changing the blocking input loop.
_Avoid_: search, finder, switcher, palette.

**Buffer Search**:
The `/`-initiated search over semantic text in the current DiffPane Buffer. It highlights every occurrence and gives `n`/`N` a current match to traverse without including rendered gutters or framing.
_Avoid_: Review Search (crosses File boundaries), find (the Action has defined search semantics).

**Review Search**:
The Overlay for fuzzy-searching occurrences across the selected version of every changed File in the current remote PullRequest or LocalReview. Results stream as File Enrichment arrives and retain exact source locations for preview and navigation.
_Avoid_: Pull Request search (also applies to LocalReview), repository search (only changed Files participate), Picker (switches PullRequests).

**Composer**:
The Overlay for authoring or editing a Comment, Reply, or Suggestion body. Mutation uses the same interaction and validation as creation with the previous editable content prefilled; a Suggestion exposes its replacement code while bbr preserves the fenced Markdown representation.
_Avoid_: editor, input, form.

**MutationTarget**:
The typed identity a Composer save mutates instead of creating: a local Draft's TempId or a Bitbucket Comment's CommentId. Every ReviewCard row resolves to one, and Presentation carries it through the whole interaction rather than flattening both provenances into one numeric id. A Composer without one is authoring something new.
_Avoid_: selected item, comment id (only one of the two), edit mode.

**Armed Re-anchor**:
The two-stage interaction that repairs one mutable inline root Draft's Anchor. Stage one retains the Draft's TempId and hands input back to the DiffPane; stage two reads whatever the source cursor or Selection currently names, so navigating re-reads the candidate instead of accumulating interaction state. Enter accepts, Escape cancels, and a Session replacement disarms it. Replies, Review- and File-level Drafts, and published Comments have no re-anchor at all.
_Avoid_: move Anchor (an authored Anchor never moves itself), drag, re-target.

**Delete Confirmation**:
The keyboard-complete Overlay that names one local Draft's TempId and the complete Reply-descendant consequence of deleting it, before anything is removed. Enter or `y` confirms, Escape or `n` cancels, every other key is captured so the cursor cannot drift off the Draft it names, and a Session replacement disarms it. It survives a refused or failed deletion so the reviewer can retry. The consequence it shows is a projection, not a promise: the cascade is recomputed at confirmation and rechecked again inside the store's own write, which is what makes it authoritative.
_Avoid_: delete prompt, are-you-sure dialog, undo (there is none).

**External Edit**:
The Composer Action that temporarily hands its exact authored body to a configured external editing program and, when accepted, returns the changed body to the same open Composer. It does not save or publish the Comment, Reply, or Suggestion.
_Avoid_: external editor (the program, not the interaction), edit in place, direct Comment edit.

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

Remote acquisition uses one `StdHttpClient` connection pool and at most two active requests. PullRequest, RawDiff, and Comments are required. Authenticated Account acquisition is independent. Comments wait for PullRequest commit data and take priority over RawDiff when both can start. All started branches complete without branch cancellation. LocalReview acquisition remains sequential.

**ScopeProjection**:
The Session-scoped placement of a PendingReview's root Draft CommentScopes, keyed by root TempId. It is derived from the durable authored scope plus the current Session and owns each ScopeResolution and projected scope; Replies reuse their root's entry. Review scope resolves unchanged, while File and inline scopes may move or become outdated or unavailable. It belongs to the published review aggregate, not to Session or PendingReview, and is rebuilt on Session replacement. A newly saved Draft enters it as `current` because it was authored against that Session.
_Avoid_: persisted scope state, resolved Draft, mutable CommentScope, AnchorProjection.

**Durable Operation**:
Reviewer-authorized work that belongs to a PullRequest rather than to the Session that started it. Submission, mutation of an author-owned published Comment, and a Reviewer Verdict change remain valid when that Session is replaced; only projecting their progress or result into the current screen depends on which Session is published. One global remote-write lane serializes these operations.
_Avoid_: Session work, background job, task.

**Submission Overlay**:
The PullRequest-qualified dependency-tree Overlay that follows one authorized SubmissionRun from queued work through terminal inspection. Its frozen forest shows typed Draft identities, scope or Reply context, explicit item states, retry evidence, and blocking ancestry; terminal repair and retry operate only on the selected eligible failed Draft subtree. Switching Reviews hides the Overlay without cancelling its Durable Operation.
_Avoid_: submission result dialog, progress popup, retry-all.

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
Whether an Action is valid for the currently published Review. Unavailable Actions remain visible but greyed in the help Overlay; invoking one produces an explanatory status message, while Presentation alone decides availability. A mutation Action carries the precise refusal reason for the item under the cursor — an active or recovered SubmissionRun owns it, its publication outcome is unresolved, it is in flight, it is already represented by Bitbucket, or there is no ReviewCard there at all. A cascading Action answers for its whole consequence: one ineligible Reply below the item refuses the complete deletion rather than applying part of it.
_Avoid_: mode check, hidden binding, silent no-op.

**Leader**:
A key that begins a multi-chord Action — the first `g` of `gg`, or the first chord of a longer configured sequence. A Leader has no Action of its own; input continues until the sequence resolves or becomes unrecognized. Distinct from the Count, which the engine accumulates separately.
_Avoid_: prefix, modifier, chord.
