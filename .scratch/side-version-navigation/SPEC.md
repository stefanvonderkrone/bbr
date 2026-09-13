# M20 side-aware version inspection

Status: ready-for-agent
Milestone: M20

## Problem Statement

Reviewers cannot explicitly choose whether version-specific inspection and source Actions use a File's old content or new content. WholeFile currently chooses content from File status, and yank uses a provisional new-first rule. This makes removed content, paired SideBySide rows, unavailable content, and clipboard output hard to predict.

The DiffPane also has no review-wide version indicator. A source click, a SideBySide column, and an Anchor coordinate already have separate meanings. Reusing one of those meanings for version selection would make source Actions and Comment authoring ambiguous.

## Solution

Add a review-wide Selected Version with old and new values. It defaults to new, remains selected across Session replacement in one process, and resets to new after application restart.

Show `g< OLD` and `NEW g>` as a two-segment control in the DiffPane title. The Selected Version controls explicit WholeFile inspection and yank source selection. It does not change Changes or fetched-whole rows, a Line's identity, a SideBySide Anchor target, or a source click.

Project both complete versions in SideBySide WholeFile and only the Selected Version in Unified WholeFile. Show explicit version-specific states for loading, absent, binary, invalid UTF-8, acquisition failure, and empty text. Never substitute the other version.

Implement the feature through the existing Presentation state-machine boundary. Presentation publishes the Selected Version, Buffer, navigation, ActionAvailability, title targets, and File Tree as one complete Presentation Frame. Existing File Enrichment continues to acquire both present File versions through the shared RemoteReview and LocalReview pipeline.

## User Stories

1. As a reviewer, I want new to be the default Selected Version, so that the initial behavior follows the current review focus.
2. As a reviewer, I want to select the old version with `g<`, so that I can inspect and copy removed source.
3. As a reviewer, I want to select the new version with `g>`, so that I can return to proposed source.
4. As a reviewer, I want the Selected Version shown in the DiffPane title, so that the source Action target is always visible.
5. As a reviewer, I want the selected title segment accented and bold, so that I can distinguish it from the other segment.
6. As a reviewer, I want the title control visible in every Layout and Scope, so that Selected Version state does not disappear when I change presentation.
7. As a reviewer, I want narrow DiffPanes to preserve the title control before the path and Scope label, so that the active source remains visible.
8. As a reviewer, I want clipped title segments to have no hidden mouse target, so that clicks activate only visible controls.
9. As a mouse user, I want to select either version from its title segment, so that mouse and keyboard input dispatch the same Action.
10. As a mouse user, I want a version change only after press and release hit the same segment, so that drags and mismatched clicks do not change state.
11. As a reviewer, I want Overlays to capture title clicks, so that hidden controls cannot activate under an Overlay.
12. As a reviewer, I want modified, non-primary, disabled, and motion-only mouse input ignored, so that Selected Version changes only through accepted input.
13. As a reviewer, I want source clicks to leave the Selected Version unchanged, so that cursor placement does not imply a source Action target change.
14. As a reviewer, I want Pane focus to remain separate from Selected Version, so that the title accent does not create another focus state.
15. As a reviewer, I want SideBySide Anchor identity to remain separate from Selected Version, so that Comments keep their authoritative old or new coordinate.
16. As a reviewer, I want Unified WholeFile to show one continuous Selected Version, so that I can read that File version without mixed source.
17. As a reviewer, I want Unified WholeFile to show the Selected Version's line numbers, so that source coordinates match the visible content.
18. As a reviewer, I want Unified WholeFile to omit Hunk headers and Folds, so that complete content reads as one File.
19. As a reviewer, I want Hunk Lines to keep their diff styling in WholeFile, so that changed source remains identifiable.
20. As a reviewer, I want blob-sourced full-content Lines to remain neutral and non-anchorable, so that complete content does not create synthetic Anchor targets.
21. As a reviewer, I want SideBySide WholeFile to show both complete versions, so that I can compare old and new context outside Hunks.
22. As a reviewer, I want SideBySide WholeFile to accent the Selected Version column, so that I can see which column source Actions use.
23. As a reviewer, I want the selected column's inner gutter edge accented, so that the indication remains visible beside long source text.
24. As a reviewer, I want the column accent to preserve source colors and diff backgrounds, so that selection does not hide Highlighting or change meaning.
25. As a reviewer, I want SideBySide WholeFile to use existing Hunk matching, so that version inspection cannot create a second Diff.
26. As a reviewer, I want renamed WholeFile headers to use the Selected Version's path, so that the displayed path matches the inspected File version.
27. As a reviewer, I want Changes rows unchanged when I select a version, so that version selection does not alter the authoritative Diff projection.
28. As a reviewer, I want fetched-whole rows unchanged when I select a version, so that unfolding fetched Hunks keeps its current meaning.
29. As a reviewer, I want the title and source Action target to update in Changes and fetched-whole, so that yank still follows the Selected Version.
30. As a reviewer, I want an absent Selected Version shown explicitly, so that an added or removed File never displays the other version as fallback.
31. As a reviewer, I want loading, binary, invalid UTF-8, and acquisition failure shown as different states, so that I know why source is unavailable.
32. As a reviewer, I want an unavailable state to name old or new, so that the state cannot be mistaken for the other File version.
33. As a reviewer, I want an unavailable state to show byte size when known, so that I retain useful File information.
34. As a reviewer, I want an empty text File shown as `Empty file`, so that valid zero-Line content is not classified as unavailable.
35. As a reviewer, I want usable SideBySide content to remain visible beside an unavailable version, so that one failure does not suppress the other version.
36. As a reviewer, I want to keep an unavailable version selected, so that inspection never changes my explicit choice.
37. As a reviewer, I want `R` to retry acquisition failures through Session replacement, so that M20 does not add another retry Action.
38. As a reviewer, I want the focused WholeFile to start File Enrichment when selected content is pending, so that complete source becomes available on demand.
39. As a reviewer, I want unfocused Files to remain in a loading state until demand or existing prefetch starts work, so that M20 does not widen acquisition policy.
40. As a reviewer, I want RemoteReview and LocalReview to use the same Selected Version behavior, so that DiffSource does not change Presentation semantics.
41. As a reviewer, I want the Selected Version to survive Layout and Scope changes, so that presentation changes do not reset my source target.
42. As a reviewer, I want the Selected Version to survive Session replacement in one process, so that review switching preserves my preference.
43. As a reviewer, I want application restart to select new, so that no hidden persistent setting changes startup behavior.
44. As a reviewer, I want selecting the current version to do nothing, so that repeated input preserves the Presentation Frame, cursor, Count, and Selection.
45. As a reviewer, I want an actual version change published atomically, so that the title, Buffer, navigation, and source Actions never disagree.
46. As a reviewer, I want a failed version change to preserve the complete prior Presentation Frame, so that allocation failure cannot publish mixed state.
47. As a reviewer, I want an actual version change to clear Count and Selection only after publication, so that failed publication loses no input state.
48. As a reviewer, I want my cursor restored to the matching Hunk Line after a WholeFile version change, so that I keep the same semantic location when possible.
49. As a reviewer, I want cursor restoration to choose the next source Line and then the nearest prior Line, so that missing opposite-version Lines have a predictable fallback.
50. As a reviewer, I want cursor restoration to choose the File header when no selected-version Line exists, so that the cursor always lands on a valid target.
51. As a reviewer, I want a loading WholeFile to retain the pending cursor target, so that completed File Enrichment can restore the intended location.
52. As a reviewer, I want later cursor movement to cancel a pending restoration target, so that delayed work cannot move me after I navigate elsewhere.
53. As a reviewer, I want wrapping to preserve semantic cursor identity and nearest source offset, so that visual continuation rows do not change restoration.
54. As a reviewer, I want yank to copy only Lines from the Selected Version, so that clipboard text never interleaves old and new source.
55. As a reviewer, I want a Unified row to contribute source only when that Line exists in the Selected Version, so that removed and added Lines follow my choice.
56. As a reviewer, I want a SideBySide row to contribute only its selected column's Line, so that paired and unpaired rows have one clear source.
57. As a reviewer, I want wrapped continuations to contribute one semantic Line, so that yank does not duplicate source.
58. As a reviewer, I want blob-sourced full-content Lines included in yank, so that complete File inspection supports clipboard use outside Hunks.
59. As a reviewer, I want generated rows excluded from yank, so that headers, placeholders, Folds, and ReviewCards cannot enter source text.
60. As a reviewer, I want Count-based yank to scan forward over candidate Lines, so that Presentation-only rows do not consume the Count.
61. As a reviewer, I want Count-based yank to stop at the File boundary, so that one Action cannot copy another File by accident.
62. As a reviewer, I want Count-based yank to copy available candidates when the File ends early, so that a large Count still returns useful source.
63. As a reviewer, I want Selection to override Count, so that an explicit visual range controls clipboard output.
64. As a reviewer, I want cross-File Selection to copy only the cursor's File, so that clipboard output has one File source.
65. As a reviewer, I want selected Lines ordered by Selected Version source order, so that SideBySide pairing cannot reorder clipboard text.
66. As a reviewer, I want empty source Lines to count as Lines, so that clipboard output preserves source structure.
67. As a reviewer, I want yank output joined with newline characters and no trailing newline, so that clipboard text matches the selected Lines exactly.
68. As a reviewer, I want Count and Selection cleared when Presentation queues a clipboard request, so that accepted yank input cannot apply twice.
69. As a reviewer, I want clipboard adapter failure to keep the accepted cleanup, so that asynchronous failure does not restore stale interaction state.
70. As a reviewer, I want a refused yank to consume Count but keep Selection, so that I can inspect and correct the refused range.
71. As a reviewer, I want yank refusal to name the Selected Version and exact cause, so that I can distinguish unavailable content from no source at the target.
72. As a reviewer, I want unavailable Actions to remain visible in help, so that the Keymap stays discoverable with a reason for refusal.
73. As a reviewer, I want inline Comment behavior unchanged in Changes and fetched-whole, so that Selected Version does not reinterpret existing Anchors.
74. As a reviewer, I want WholeFile inline Comments limited to selected-version Hunk Lines, so that blob context and opposite-version Lines cannot create an invalid Anchor.
75. As a reviewer, I want Suggestions limited to new-version Hunk Lines, so that replacement source always targets proposed content.
76. As a reviewer, I want current selected-version ReviewCards inline in Unified WholeFile, so that discussion stays beside its source.
77. As a reviewer, I want current opposite-version ReviewCards in one collapsed File section in Unified WholeFile, so that discussion remains available without mixing source versions.
78. As a reviewer, I want both versions' current ReviewCards on their normal Lines in SideBySide WholeFile, so that each Anchor remains in its native column.
79. As a reviewer, I want File-level and outdated ReviewCards to keep their current placement, so that Selected Version changes only version-specific discussion placement.
80. As a reviewer, I want every ReviewCard projected once, so that dual-version WholeFile cannot duplicate discussion.

## Implementation Decisions

- Add `SelectedVersion` with `old` and `new` values. Presentation owns the value in Preferences and includes it in ReviewProjection and every complete Presentation Frame.
- Selected Version is process state. Do not add a configuration key, command-line option, Session field, SQLite field, or other persistent record.
- New is the default. Layout, Scope, and successful Session replacement preserve the value. Application restart constructs default Preferences and selects new.
- Add `select_old_version` and `select_new_version` Actions. Bind them to `g <` and `g >` through the strict Action-oriented Keymap.
- Add both Actions to configuration override parsing, conflict checks, unbinding, and help grouping. Add no compatibility alias.
- Selecting the current value is an exact no-op. It does not rebuild or revise the Presentation Frame, clear input state, or start File Enrichment.
- Stage an actual version change through the existing preference transaction. Build the candidate Buffer, visual rows, navigation, title targets, and File Tree before changing Preferences.
- Publish an actual version change as one Presentation Frame replacement. Commit Selected Version and clear Count and Selection only after publication succeeds.
- If allocation or projection fails, preserve the prior Preferences, Presentation Frame, Count, Selection, cursor, and pending mouse press.
- Add Selected Version to Buffer build options. Keep Diff responsible only for Files, Hunks, Lines, authoritative line numbers, change status, and Anchor eligibility.
- Keep Changes and fetched-whole Buffer rows unchanged in both Layouts. Add selected-version row ownership as Presentation metadata for source Actions.
- Unified WholeFile projects only the Selected Version. It fills gaps from that version's File Enrichment content and preserves Hunk Line identity.
- Unified WholeFile uses old line numbers for old and new line numbers for new. It has no Hunk headers or Folds.
- SideBySide WholeFile builds old and new complete content independently. It pairs unchanged full-content Lines and uses the existing bounded Hunk matcher for changed runs.
- SideBySide WholeFile does not parse or compute another Diff. ADR-0001 remains authoritative for Hunk identity and Anchor coordinates.
- WholeFile uses the Selected Version's path in the File header. Changes and fetched-whole retain the current display-path rule.
- Blob-sourced full-content context creates non-anchorable Lines. Hunk Lines retain their existing pointers and Anchor eligibility.
- Presentation projects loading, absent, binary, invalid UTF-8, acquisition failure, and empty text as explicit version-specific states. It includes known byte size.
- SideBySide places a version-specific state in only its version column. Usable opposite-version content remains visible.
- Unified WholeFile places selected-version current inline ReviewCards on Hunk Lines. It places current opposite-version inline ReviewCards in one collapsed section per File.
- SideBySide WholeFile keeps current inline ReviewCards on their old or new Hunk Lines. Every ReviewCard appears once.
- File-level and outdated ReviewCard placement does not change.
- Reuse the existing `EnrichFile` command, WorkId, Session Epoch, and File cache policy. Each request continues to acquire both present versions.
- A WholeFile version change starts focused File Enrichment only when required content is pending. Changes and fetched-whole do not start File Enrichment.
- Keep the current one-successor remote prefetch policy. Do not add version-specific concurrency, cancellation, retry, or cache policy.
- Admit each File Enrichment completion by Session Epoch and WorkId. Rebuild the complete Presentation Frame after admission.
- Preserve independent per-version File Enrichment outcomes as required by ADR-0010. One failed version does not suppress usable content from the other version.
- Extend semantic row ownership so a visual row can expose an old candidate, a new candidate, or both. Wrapped rows retain their semantic Line owner.
- Yank resolves candidates from semantic row ownership and Selected Version. It never combines source from both versions.
- Without Selection, yank scans forward from the cursor, skips rows without a candidate, stops at the File boundary, and copies the requested Count or all remaining candidates.
- With Selection, yank ignores Count and limits candidates to the inclusive selected visual rows in the cursor's File.
- Yank deduplicates wrapped rows by semantic Line identity and orders output by Selected Version source line number.
- Yank joins undecorated Line text with `\n` and adds no trailing newline. Empty source Lines count as Lines.
- When Presentation queues a clipboard effect, it clears Count and Selection. A later clipboard failure does not restore them.
- A refused yank consumes Count and keeps Selection. An allocation failure during yank follows the same cleanup rule as a refusal.
- Replace the shared source Boolean in ActionAvailability with typed refusal fields for yank, inline Comment, and Suggestion Actions.
- Yank refusal distinguishes unavailable Selected Version content from no candidate at the cursor or in Selection. Status text names the Selected Version.
- Changes and fetched-whole keep current inline Comment and Suggestion availability. Selected Version changes yank source, not Anchor interpretation.
- WholeFile inline Comment authoring requires a selected-version Hunk Line. Suggestion authoring also requires Selected Version to be new.
- Full-content context, version states, empty File states, and opposite-version Lines refuse inline authoring with typed reasons.
- Keep Selection unavailable on generated and blob-sourced full-content rows. Version selection remains available on those rows.
- Add exact visible rectangles for both title segments to the Presentation Frame. Add old-version and new-version semantic title targets to mouse hit testing.
- Keep title hit testing in Presentation Frame construction. Rendering consumes published rectangles and does not recompute mouse geometry.
- Dispatch a mouse version Action only when primary press and release target the same visible segment on the same Presentation Frame revision.
- An Overlay captures title input. Disabled mouse input, modifiers, drag, motion, unsupported buttons, and input outside a segment do nothing.
- Reserve title width for both segments before truncating path and Scope labels. Clip the control when the DiffPane cannot contain it.
- Accent and bold only the selected title segment. In SideBySide, accent the selected column header and inner gutter edge without changing source styling.
- Capture the focused File and semantic source target before an actual WholeFile version change.
- Cursor restoration first chooses the same Hunk Line in the Selected Version. If absent, it chooses the next selected-version Line, then the nearest prior Line, then the File header.
- Retain an unresolved restoration target while the focused File shows loading. Apply it after matching File Enrichment unless the reviewer moved to another semantic target.
- Changes and fetched-whole preserve cursor position because their Buffer rows do not change.
- M20 uses the existing Presentation state-machine seam from ADR-0012. It adds no second public orchestration seam and no source-specific Presentation branch.
- Activate default keys and visible controls only after complete projection, Actions, ActionAvailability, rendering, mouse hit testing, and deterministic tests work together.

## Testing Decisions

- Good tests assert reviewer-visible behavior, published Presentation state, emitted commands, clipboard text, Action refusal, and rendered cells. Tests do not assert private arena generations, matcher tables, worker scheduling steps, or internal transaction helpers.
- The primary deterministic seam is `Presentation.dispatch` and `Presentation.projection`. Tests drive Actions and typed File Enrichment completions, then inspect one immutable Presentation projection and drained commands.
- Headless rendering is the only secondary integration seam. It verifies terminal cells, title truncation, column accents, and exact mouse rectangles that the Presentation projection cannot prove alone.
- Existing Buffer tests remain useful for pure projection cases. They cover Unified and SideBySide Layouts, WholeFile splicing, File status, independent Status Placeholders, SideBySide matching, ReviewCard placement, and authoritative Hunk Line preservation.
- Existing Presentation tests provide prior art for Count-based yank, Selection cleanup, clipboard completion, Session replacement rollback, File Enrichment admission, stale Session Epoch rejection, cursor restoration, ActionAvailability, and mouse press and release rules.
- Existing Frame tests provide prior art for zero-width, narrow, ordinary, and wide geometry. Existing render tests provide prior art for SideBySide boundaries and independent Status Placeholder cells.
- Existing Keymap and configuration tests verify defaults, override parsing, unbinding, conflict rejection, help grouping, and Leader handling for both new Actions.
- Presentation state tests cross RemoteReview and LocalReview. They prove that the common Diff, Buffer, and File Enrichment pipeline produces equal Selected Version behavior.
- Layout and Scope tests cross Unified and SideBySide with Changes, fetched-whole, and WholeFile. They prove that only WholeFile source rows change with Selected Version.
- File-shape tests cover added, modified, removed, and renamed Files. They verify paths, old and new line numbers, complete gaps, empty content, Hunk identity, and no fallback.
- Content-state tests cover loading, absent, binary, invalid UTF-8, acquisition failure, known size, unknown size, and empty text. SideBySide tests keep usable opposite content visible.
- ReviewCard tests verify selected-version and opposite-version placement in Unified WholeFile, native-side placement in SideBySide, unchanged File-level and outdated placement, and exactly-once projection.
- State-lifetime tests prove the new default, Layout and Scope retention, Session replacement retention, application restart reset, successful replacement reset rules, and complete rollback after failed replacement.
- Version Action tests prove keyboard and mouse parity, exact no-op behavior, one Presentation Frame revision per actual change, Count and Selection cleanup, and selection of unavailable content.
- Cursor tests cover context, removed, added, first, last, missing, and empty targets. They also cover deferred restoration, reviewer movement, wrapping, and nearest valid source offset.
- Yank tests cross both versions and both Layouts. They cover paired rows, unpaired rows, wrapping, Count, Selection, generated rows, File boundaries, empty Lines, source ordering, and no trailing newline.
- ActionAvailability tests cover unavailable selected content, no candidate, non-Hunk WholeFile content, opposite-version content, and old-version Suggestion refusal.
- File Enrichment tests cover focus demand, current one-successor prefetch, remote concurrency, local sequential work, partial success, stale Session Epoch, stale WorkId, launch failure, and refresh.
- Failure tests inject allocation failure at Buffer, visual-row, title-target, clipboard, and File Enrichment admission boundaries. They verify preservation of the prior complete Presentation Frame and the specified input cleanup.
- Rendering tests cross zero, narrow, ordinary, and wide DiffPane geometry. They verify title reservation, clipping, selected-segment accent, SideBySide gutter accent, Pane focus independence, and Highlighting preservation.
- Mouse tests cover same-target activation, Presentation Frame replacement, movement, mismatched release, Overlay capture, disabled mouse input, modifiers, unsupported buttons, and clipped cells.
- The complete hermetic suite must pass through the repository test command. Tests added in new Zig files must join the test import chain, and the reported test count must increase.

## Out of Scope

- M21 Buffer Search and Review Search.
- Persistent Selected Version configuration or storage.
- A command-line option for Selected Version.
- A new Anchor coordinate, Anchor conversion, or change to Bitbucket's Anchor contract.
- A source click that changes Selected Version.
- A mouse gesture for yank.
- A separate retry Action for File Enrichment failure.
- Version-specific File Enrichment commands, cache entries, prefetch, cancellation, or concurrency limits.
- A second Diff or local recomputation from complete old and new File content.
- Changes to remote and local DiffSource acquisition outside the shared File Enrichment contract.
- Implementation work beyond M20.

## Further Notes

- The completed [M20 side-aware version inspection map](map.md) is the decision index for this spec.
- [Define the Selected Version projection](issues/01-choose-old-new-side-inspection-and-yank.md) owns Layout, Scope, unavailable-content, and ReviewCard decisions.
- [Prototype the Selected Version indication](issues/02-prototype-selected-version-indication.md) records the accepted title control and links the prototype asset.
- [Define Selected Version source Actions](issues/03-define-selected-version-source-actions.md) owns version Action, cursor, yank, Count, Selection, and refusal behavior.
- [Define the integrated M20 contract](issues/04-define-integrated-m20-contract.md) owns the complete module contract, dependency order, and acceptance matrix.
- M20 depends on the completed M15 Presentation contract and M17 old-version, SideBySide, wrapping, and File Enrichment work.
