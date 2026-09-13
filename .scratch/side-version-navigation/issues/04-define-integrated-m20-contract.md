# Define the integrated M20 contract

Type: grilling
Status: resolved
Blocked by: 01, 02, 03

## Question

How should the accepted M20 decisions fit into `Preferences`, Presentation Frame publication, Buffer construction, File Enrichment, ActionAvailability, Keymap configuration, rendering, mouse hit testing, and deterministic tests?

Define dependency-ordered implementation slices and an acceptance matrix. The final contract must cover RemoteReview and LocalReview, Unified and SideBySide Layouts, every Scope, added and removed Files, unavailable content, Session replacement, application restart, Count, Selection, wrapping, clipboard failure, and allocation-failure rollback.

## Answer

M20 extends the existing Presentation Frame and File Enrichment contracts. It adds no second Diff pipeline, persisted setting, or version-specific acquisition command.

### Ownership and frame publication

- Add a `SelectedVersion` enum with `old` and `new` values. Presentation owns it through `Preferences.selected_version`, which defaults to `new`.
- The Selected Version is process state, not configuration. Do not add a TOML key, SQLite field, command-line option, or Session field.
- Session replacement receives the current `Preferences`. A successful replacement keeps the Selected Version and resets the existing Session-relative interaction state. An application restart constructs default `Preferences` and selects new.
- Include the Selected Version in `ReviewProjection` and every complete Presentation Frame. Buffer construction, rendering, ActionAvailability, cursor restoration, and mouse hit testing must read the same published value.
- Dispatch `select_old_version` and `select_new_version` through the existing preference transaction. Stage the candidate Buffer, visual rows, navigation, title targets, and File Tree before changing `Preferences`.
- Publish an actual version change as one Frame replacement. Commit the new Selected Version and clear the Count and Selection only when that Frame publishes.
- If allocation or projection fails, keep the previous Preferences, Frame, Count, Selection, cursor, and pending mouse press. Report the existing allocation or projection failure.
- Selecting the current value is an exact no-op. It does not rebuild the Frame, change its revision, clear state, or start File Enrichment.

### Buffer construction

- Add `selected_version` to `BuildOptions`. Keep Diff limited to Files, Hunks, Lines, line numbers, change status, and Anchor eligibility.
- Keep Changes and fetched-whole Buffer rows unchanged in both Layouts. Add selected-version row ownership as Presentation metadata for source Actions. Do not mutate a Line or its old and new identity.
- Unified WholeFile splices only the Selected Version. Filter each Hunk to Lines that exist in that version, and fill non-Hunk gaps from that version's File Enrichment content. Use old line numbers for old and new line numbers for new.
- SideBySide WholeFile splices old and new content independently. Pair unchanged full-content Lines across hunk boundaries, and use the existing order-preserving Hunk matcher for removed and added runs. Do not parse or compute another diff.
- Use the Selected Version's path in a WholeFile File header. Keep the current display-path rule in Changes and fetched-whole scopes.
- Preserve each Hunk Line pointer when it enters a WholeFile projection. Blob-sourced context remains a new non-anchorable Line in the Buffer arena.
- Project loading, absent, binary, invalid UTF-8, acquisition failure, and empty text as explicit version-named placeholders. Include known byte size. In SideBySide, one placeholder occupies only its version column and does not suppress usable opposite-version content.
- Unified WholeFile weaves current selected-version inline ReviewCards at their Hunk Lines. Put current opposite-version inline ReviewCards in one collapsed per-File disclosure. Keep File-level and Outdated placement unchanged.
- SideBySide WholeFile keeps current inline ReviewCards at their old or new Hunk Lines. Project every ReviewCard once.
- Extend semantic row ownership so one visual row can expose its old candidate, new candidate, or both. Wrapped rows retain the same candidates and source-byte ranges as their semantic Line owner.

### File Enrichment

- Reuse the existing `EnrichFile` command and per-File WorkId. A request continues to acquire both present sides through the common remote or local File Enrichment path.
- A version change in WholeFile stages the focused File for File Enrichment when required content is pending. Publish the version-specific loading placeholder before the adapter starts the command.
- Changes and fetched-whole version changes do not start File Enrichment. Their source Lines already come from the Diff.
- Keep the current one-successor remote prefetch policy. Do not add version-specific prefetch, cancellation, concurrency, retry, or cache policy.
- Admit each completion by Session Epoch and WorkId. Rebuild the complete Frame after admission. A stale completion cannot alter the Session, Selected Version, or Frame.
- Preserve independent per-side results. A failed side remains visible until `R` replaces the Session, while usable opposite-version content stays available.

### Actions and availability

- Add `select_old_version` and `select_new_version` to `Action`. They are valid for every published RemoteReview and LocalReview, including when the requested version is absent or unavailable.
- Add typed source refusal fields to `ActionAvailability` for `yank`, `inline_comment`, and `suggest`. Replace the shared `source` Boolean for these Actions.
- A yank refusal distinguishes unavailable Selected Version content from no selected-version source at the cursor or in the Selection. Include the Selected Version in the status message.
- In Changes and fetched-whole scopes, keep existing inline Comment and Suggestion availability. The Selected Version changes `yank`, not Anchor interpretation.
- In WholeFile, inline Comment authoring requires a selected-version Hunk Line. A Suggestion also requires the Selected Version to be new. Blob-sourced context, placeholders, empty-file placeholders, and opposite-version Lines refuse these Actions with a typed reason.
- Keep `toggle_select` unavailable on placeholders, empty-file placeholders, and blob-sourced full-content context. Version selection itself remains available there.
- Keep `yank` terminal-independent. Presentation returns one owned clipboard effect, and the adapter continues to report success or failure without changing Review state.

### Yank extraction

- Resolve yank candidates from semantic row ownership and the Selected Version. A Unified row contributes only its selected-version Line. A SideBySide row contributes only the selected column's Line.
- Deduplicate wrapped visual rows by semantic Line identity. Order all output by the Selected Version's source line number, not visual pairing order.
- With no Selection, scan forward from the cursor. Skip rows with no candidate, stop at the File boundary, and copy the requested Count or all available candidates before the boundary.
- With a Selection, ignore the Count. Limit candidates to inclusive selected visual rows and the cursor's File.
- Join undecorated Line text with `\n` and add no trailing newline. Count empty source Lines as Lines.
- When Presentation queues a clipboard effect, clear the Count and Selection. A later clipboard failure does not restore them.
- A refused yank consumes the Count and keeps the Selection. An allocation failure follows the same cleanup rule as a refusal.

### Keymap, rendering, and mouse input

- Add default bindings `select_old_version = ["g <"]` and `select_new_version = ["g >"]`. Keep them in the same strict Action-oriented Keymap used by dispatch and help.
- Add both Actions to config override parsing, conflict checks, unbinding, and help grouping. Add no compatibility alias.
- Give the Presentation Frame exact rectangles for the `g< OLD` and `NEW g>` title segments. Add semantic title targets for old and new selection to `HitTarget`.
- Keep title hit testing in `frame.zig`. The renderer consumes the published rectangles and does not recompute mouse geometry.
- Apply the existing press and release rule. Dispatch a version Action only when both events target the same segment on the same Frame revision.
- An Overlay captures title clicks. Disabled mouse input, modified clicks, drag, motion, non-primary buttons, and clicks outside a segment do nothing.
- Reserve title width for both segments before truncating the path and Scope label. At widths that cannot contain the full control, clip without creating a target outside visible cells.
- Accent and bold only the selected title segment. In SideBySide, also accent the matching column header and inner gutter edge. Keep focus, cursor, Selection, diff backgrounds, and Highlighting unchanged.
- Use the same rendering and mouse contract for loading, unavailable, and empty versions. Never move selection to the usable version.

### Cursor restoration

- Capture the focused File and semantic source target before an actual version change.
- In WholeFile, first restore the same Hunk Line when it exists in the Selected Version. Otherwise choose the next selected-version Line in source order, then the nearest prior Line, then the File header.
- Retain the unresolved restoration target while the focused File shows a loading placeholder. Apply it when matching File Enrichment completes unless the reviewer has moved to another semantic target.
- In Changes and fetched-whole scopes, preserve the current cursor because Buffer rows do not change. Only clear the Count and Selection after publication.
- Wrapping changes no restoration identity. Restore the semantic Line and nearest valid source-byte offset through the existing visual-row projection.

### Dependency-ordered implementation slices

1. **Add internal Selected Version types.** Add `SelectedVersion`, the `Preferences` field, Action cases, typed source refusals, selected-version row ownership, and Frame title-target metadata. Keep the default keys and visible control inactive.
2. **Project complete versions.** Add side-specific Unified splicing, dual SideBySide WholeFile construction, version placeholders, selected paths, opposite-version ReviewCard placement, and pure Buffer tests. This slice depends on the internal types.
3. **Publish version changes atomically.** Add preference transactions, WholeFile cursor restoration, pending restoration through File Enrichment, Session replacement lifetime, and rollback tests. This slice depends on complete Buffer projection.
4. **Replace provisional yank behavior.** Add selected-version candidate extraction, typed ActionAvailability, Count and Selection cleanup, wrapping deduplication, source ordering, and clipboard-effect tests. This slice depends on row ownership and atomic state.
5. **Activate the complete interaction.** Add default Keymap entries, help rows, title rendering, SideBySide accents, Frame-derived segment hit testing, and mouse dispatch. Activate public controls only when slices 2 through 4 work together.
6. **Run integrated acceptance.** Cross both review sources, every Layout and Scope, File status and content state, state lifetime, terminal geometry, input path, and forced failure. Update the M20 milestone only after this matrix passes.

Slices 1 and the File Enrichment fixture extensions can start together. Slice 2 follows slice 1. Slice 3 follows slice 2. Slice 4 follows slices 1 and 2, then joins slice 3 for activation. Slice 5 follows slices 3 and 4. Slice 6 follows all prior slices.

### Acceptance matrix

| Area | Required evidence |
| --- | --- |
| Review sources | Identical RemoteReview and LocalReview behavior uses the common Diff, Buffer, and File Enrichment pipeline. Adapter fixtures verify the existing commit, Ref, and path choices without a Presentation branch by source. |
| Layout and Scope | Unified and SideBySide cross Changes, fetched-whole, and WholeFile. Changes and fetched-whole retain current rows. Unified WholeFile shows only the Selected Version. SideBySide WholeFile shows both complete versions and accents the selected column. |
| File shape | Added, modified, removed, and renamed Files verify selected paths, old and new line numbers, complete first and last gaps, Hunk identity, empty files, and no fallback to the other version. |
| Content status | Loading, absent, binary, invalid UTF-8, failed, and known-size states render exact version-named placeholders. SideBySide keeps usable opposite content. No placeholder accepts Selection, Anchor, Comment, Suggestion, or yank source. |
| ReviewCards | Unified WholeFile places selected-version inline ReviewCards at Hunk Lines and opposite-version cards in one disclosure. SideBySide places both sides inline. File-level and Outdated placement stays unchanged. Every ReviewCard appears once. |
| State lifetime | New is the process default. Layout, Scope, and Session replacement preserve the Selected Version. Successful replacement applies the canonical Session reset. Failed replacement preserves all prior state. A new process selects new. No config or persistence artifact records the choice. |
| Version Actions | Keyboard and mouse dispatch the same Actions. Selecting the current value is inert. An actual change publishes one Frame revision and clears Count and Selection. An unavailable version remains selectable. |
| Cursor and wrapping | Context, removed, added, first, last, missing, and empty targets follow the restoration order. Loading defers restoration. Reviewer movement cancels a deferred target. Wrapped rows restore one semantic Line and do not duplicate yank output. |
| Yank | Both versions cross Unified and SideBySide paired and unpaired rows, Count, Selection, Presentation-only rows, File boundaries, empty Lines, source ordering, and no trailing newline. Changes and fetched-whole replace M15's new-side-first rule. |
| ActionAvailability | Typed refusals cover unavailable selected content, no selected source, non-Hunk WholeFile content, opposite-version WholeFile content, and old-version Suggestions. Help keeps unavailable Actions visible. Status text names the Selected Version and reason. |
| File Enrichment | Focus demand and one-successor remote prefetch reuse one two-side command. Local acquisition stays sequential. Partial success remains usable. Duplicate, stale-Epoch, stale-WorkId, launch-failure, and refresh cases cannot corrupt the Frame or Selected Version. |
| Rendering and geometry | Zero, narrow, ordinary, and wide dimensions verify control reservation, clipping, title accent, SideBySide gutter accent, focus independence, Highlighting preservation, and exact visible hit rectangles. |
| Mouse | Same-target press and release activates one segment. Frame replacement, movement, mismatched release, Overlay capture, disabled mouse input, unsupported buttons, modifiers, and hidden clipped cells do not activate it. |
| Failure atomicity | Forced allocation failure at Buffer, visual-row, title-target, clipboard, and File Enrichment admission boundaries preserves the prior complete Frame. Version-change failure preserves Count and Selection. Yank refusal and clipboard failure follow their specified cleanup rules. |
| Public activation | A build cannot expose the default keys or title control without complete projection, Actions, ActionAvailability, rendering, mouse hit testing, and deterministic tests. No milestone feature flag or compatibility alias remains after activation. |

This contract resolves the final M20 decision. Implementation can follow these slices without reopening old and new File version behavior.
