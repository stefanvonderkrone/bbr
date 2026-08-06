# Define the integrated M15 contract

Type: grilling
Status: resolved
Blocked by: 04, 05, 06, 08, 09, 10, 11, 13, 14

## Question

How should all accepted M15 behaviors fit into the Presentation-owned state machine, Session-relative state, Projection, Action grammar, rendering adapter, configuration, and deterministic acceptance matrix so implementation can proceed in coherent dependency-ordered slices without reopening product decisions?

## Answer

Organize M15 around one atomic **Presentation Frame** and a strict split between configuration, Session-relative interaction state, pure projection, and terminal effects.

### Ownership and frame publication

- `Published` owns the current Session, its Review projection, Session-relative interaction state, and the last complete Presentation Frame. Review and Diff continue to own domain data; they never acquire Pane, cursor, disclosure, geometry, Markdown, mouse, or Overlay state.
- A Presentation Frame is one internally consistent projection at the current terminal dimensions. It contains `FrameGeometry`, the DiffPane `Buffer`, projected File Tree rows, Pane and Overlay rectangles, navigation-restoration metadata, and semantic input targets. Rendering, cursor movement, and mouse hit testing consume that same Frame.
- Move Buffer construction from `bbr.diff.buffer` into a network-free `bbr.presentation` package as required by [Choose the Markdown projection seam](14-choose-markdown-projection-seam.md). Diff remains limited to Files, Hunks, Lines, Folds, and intra-line data. The vaxis renderer remains an adapter over already-projected rows and geometry.
- Stage every geometry-affecting change—resize, layout or scope change, File isolation, File focus, tree or disclosure toggle, Draft save, File Enrichment result, and Overlay transition—into a complete replacement Frame. Publish the Frame, navigation, and interaction-state mutation together. Allocation or projection failure preserves the previous complete Frame and state.
- Capture logical navigation before a rebuild and restore it through stable semantic ownership: source Line identity, disclosure identity, File identity, or ReviewCard owner plus source offset. Apply the more specific ReviewCard restoration rules from [Choose the Markdown projection seam](14-choose-markdown-projection-seam.md). Clear visual Selection whenever reconstruction changes its projected row range.
- Inject terminal grapheme/cell measurement through `CellMetrics`. Presentation emits semantic rows, style roles, geometry, and effects; concrete vaxis styles, cells, events, and tty writes stay in the adapter.
- Give every published Frame a revision. A mouse press records that revision and semantic target; release activates only when the current Frame has the same revision and the same target. Any intervening Projection change cancels the click.

### State lifetimes

- Process/configuration state includes Theme, resolved Keymap, File-cache policy, mouse policy, Comment-collapse limit, and the existing layout/scope preferences. It survives Session replacement.
- Session-relative interaction state includes Pane focus; DiffPane navigation; Sidebar tree cursor, scroll, and expanded Directories; File isolation; expanded resolved Threads, context Folds, Outdated sections, and ReviewCards. It survives redraws and Frame rebuilds but not successful Session replacement.
- A newly published Session starts in the DiffPane at the first File, with no File isolation, no Selection, every File Tree Directory expanded, the Sidebar cursor on the active File, and every content disclosure and over-limit ReviewCard collapsed.
- PullRequest switching and explicit refresh use that same canonical reset. A failed Candidate Session replacement preserves the old Session, Frame, focus, navigation, and interaction state unchanged.
- Overlay editing/query/selection and spinner phase are transient Presentation state. An Overlay exclusively defines the Interaction Context while open. Closing, confirming, replacement, staleness, failure, or shutdown discards its transient state as applicable.

### Action grammar and availability

- Resolve input against the current **Interaction Context**: the capturing Overlay, otherwise the focused Pane and its semantic cursor target. Keys resolve directly to precise semantic Actions rather than a generic `activate` Action.
- `Enter` therefore resolves to `toggle_disclosure` or `toggle_review_card` on the matching DiffPane row; `toggle_directory` or `focus_file` at the matching Sidebar entry; and `confirm_picker` in a Picker. Composer Enter remains `newline` text input.
- Make `[keymap]` Action-oriented so mutually exclusive contextual Actions may deliberately share a key:

  ```toml
  [keymap]
  down = ["j", "down"]
  toggle_disclosure = ["enter"]
  toggle_review_card = ["enter"]
  toggle_directory = ["enter"]
  focus_file = ["enter"]
  confirm_picker = ["enter"]
  link_existing_comment = ["g C"]
  ```

  An empty list unbinds an Action. Resolution filters same-chord candidates by Interaction Context and ActionAvailability and must yield at most one Action; configuration rejects two candidates that can be available in the same context. No compatibility alias for the old key-to-Action syntax is required. The help Overlay reads this same resolved Keymap and groups contextual bindings by surface.
- Apply the accepted defaults without reopening them: `Tab` changes Pane focus; Sidebar tree motions use `j`/`k`/`h`/`l` and arrows; `[`/`]` retain previous/next File in the DiffPane; `F` opens the File finder; `p` opens the PullRequest Picker; `i`/`I`/`C` create inline/File-level/Review-level Comments; `gC` performs recovery linking; `ctrl-y`/`ctrl-e` scroll by one row; and `y` yanks. Remove `comment`, lowercase `c`, `toggle_resolved`, `T`, and `expand_fold` without aliases.
- ActionAvailability depends on Review mode, active surface, target kind, and required source data. Unavailable Actions remain visible but subdued in help and produce an explanatory status message rather than disappearing or silently doing nothing.
- Keyboard remains complete. Mouse reports map current Frame targets to the same semantic state transitions only where [Decide M15 mouse support](08-decide-m15-mouse-support.md) accepted parity. Picker clicks select but never dispatch `confirm_picker`; Composer and non-Picker Overlays add no mouse Actions.

### Projection and adapter effects

- `CommentScope`, `ScopeProjection`, File-level placement, root tallies, and Bitbucket/persistence mapping follow [Choose the File-level Comment model](13-choose-file-level-comment-model.md). Frame construction receives already-classified roots and projects each root and its Replies exactly once.
- `ReviewBody`, `ReviewCardRow`, Markdown recovery, wrapping, hard row limits, Theme-role composition, and source-offset restoration follow [Choose the Markdown projection seam](14-choose-markdown-projection-seam.md). Comment and Draft bytes remain unchanged in Review.
- The compacted File Tree is projected from the Diff, the active File, and Session interaction state. It is fully expanded at Session initialization; subsequent explicit collapses survive Frame rebuilds. Active-File changes reopen its ancestors and reveal its File row near the Sidebar center.
- Frame geometry is the only authority for borders, inner widths, clipping, Sidebar tally reservation, Overlay placement, and hit targets. The renderer never recomputes layout or mutates Presentation.
- `yank` is available only on a source row or valid Selection. A Selection overrides Count. Otherwise Count selects that many visible source rows beginning at the cursor, skipping Presentation-only rows without expanding hidden content and stopping at the current File boundary. Join undecorated source text with newlines and no extra rendered gutters. In side-by-side layout use the new-side line when present, otherwise the old-side line for a deletion. Explicit old/new side selection is deferred to [Choose explicit old/new side inspection and yank behavior](../../side-version-navigation/issues/01-choose-old-new-side-inspection-and-yank.md) in M20.
- Presentation returns owned clipboard bytes as an effect; the application adapter performs OSC 52 and reports success or failure without changing Review state. The pinned API is `Vaxis.copyToSystemClipboard(_: Vaxis, tty: *std.Io.Writer, text: []const u8, encode_allocator: std.mem.Allocator) !void` (`libvaxis` 0.6.0 `src/Vaxis.zig:1107`).
- Picker animation remains scoped to a visible loading Picker. A low-frequency source posts `tick` through the blocking event path; injected ticks advance only Presentation-owned spinner phase. No polling loop, elapsed-time display, or background ticks while idle are introduced.

### Public configuration

Use these M15 settings and defaults:

```toml
[comments]
collapsed_rows = 6 # 0 means never collapse automatically

[files.cache]
enabled = true
max_bytes = 268435456 # 0 means unlimited inactive caching

[input.mouse]
enabled = true
vertical_scroll_rows = 3
```

`[comments].collapsed_rows` is the hard number of rendered Comment or Draft body rows retained in the collapsed state; headers and disclosure footers do not count. The File-cache semantics and `[highlight].max_file_bytes` distinction remain those from [Choose File cache configuration language](10-choose-file-cache-configuration-language.md). Invalid values, duplicate keys, unknown tables/keys, ambiguous contextual bindings, and unusable mouse scroll values produce line-specific configuration diagnostics.

### Dependency-ordered implementation slices

1. **Presentation Frame foundation:** extract `bbr.presentation`; move Buffer ownership; introduce shared geometry, cell metrics, Frame staging, logical restoration, revisioning, and rollback tests without intentionally changing visible behavior.
2. **CommentScope end to end:** introduce Review/File/inline scopes through Review, SQLite migration, Bitbucket mapping, ScopeProjection, File-header/fallback placement, root tallies, and exhaustive classification tests.
3. **ReviewCards and Markdown:** add ReviewBody parsing, width projection, Markdown roles, Suggestions, stable ownership, Comment configuration, Theme composition, and pathological-body tests.
4. **Unified disclosures:** replace global resolved visibility and one-way Fold expansion with independently keyed resolved-Thread, Fold, Outdated, and ReviewCard disclosure transitions and restoration.
5. **Framed Panes and File Tree:** add Pane focus, borders, compacted tree projection, Session initialization, tree motions, centered active-File reveal, truncation, and fixed tallies.
6. **Contextual Actions and Overlays:** migrate the Keymap grammar; add contextual resolution, the scope ladder, File finder, revised PullRequest Picker, scroll Actions, and OSC 52 yank.
7. **Mouse adapter:** add exact Frame-derived targeting, press/release validation, accepted Pane/Picker click and wheel behavior, opt-out, help, and parity tests.
8. **Loading and configuration completion:** add scoped Picker ticks/spinner; finish File-cache, Comment, mouse, Theme, Action, documentation, ADR, and diagnostic updates.
9. **Integrated acceptance pass:** run cross-feature deterministic tests and direct-terminal, SSH PTY, and tmux smoke checks. This pass verifies integration; each preceding slice already carries its own tests.

### Integrated acceptance matrix

The detailed matrices in every blocking decision remain mandatory. In addition, deterministic integration coverage must cross the seams they share:

- Frame/geometry atomicity across resize, disclosure, File isolation/focus, Draft save, File Enrichment, and forced allocation failure; rendering and hit testing always observe the same revision.
- Canonical successful Session reset versus complete failed-replacement preservation, including Pane focus, cursors, Directory state, disclosures, ReviewCards, Selection, and transient mouse press.
- Unified/side-by-side and Changes/Fetched/Whole scope combinations at zero, narrow, ordinary, and wide terminal sizes, with grapheme-safe wrapping/truncation and stable cursor restoration.
- RemoteReview and LocalReview ActionAvailability for all Comment scopes, invalid Directory/line/Selection targets, Suggestion restrictions, fallback placement, and File tallies.
- Action-oriented Keymap parsing, multiple keys per Action, same key across mutually exclusive contexts, ambiguity rejection, unbinding, Count clearing, help grouping, and removal of superseded Actions.
- Keyboard-only completion of every workflow; accepted mouse equivalents; press/release cancellation after movement or Frame replacement; Overlay capture; ignored buttons, drag, horizontal wheel, clipped geometry, borders, and blank space.
- File finder and PullRequest Picker empty, loading, populated, no-match, dismissal, mouse selection, Enter-only confirmation, title/id ranking, and distinct same-Session versus replacement effects.
- Yank source extraction for unified rows, side-by-side context/change/deletion rows, valid Selection, Count, interleaved Presentation rows, folds, File boundaries, clipboard success/failure, and no terminal decoration leakage.
- Configuration defaults, zero semantics, opt-outs, renamed keys without aliases, diagnostics, all built-in Theme roles, scoped tick shutdown, and idle blocking behavior.

This resolves the final M15 fog. Implementation can follow the slices above without another product or architecture decision; discoveries that require explicit old/new side choice belong to M20 rather than reopening M15.
