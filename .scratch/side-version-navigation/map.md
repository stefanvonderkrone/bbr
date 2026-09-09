# M20 side-aware version inspection

Label: wayfinder:map

## Destination

An implementation-ready M20 specification and dependency map for explicit old/new File version inspection and source yanking, without implementing the milestone.

## Notes

- Primary domains: Presentation and Diff. Consult `CONTEXT-MAP.md`, `src/tui/CONTEXT.md`, `src/diff/CONTEXT.md`, `TODO.md`, and the integrated M15 and M17 contracts.
- Use `prototype`, `grilling`, `domain-modeling`, `technical-writing`, and `zig` as each ticket requires.
- Call the review-wide old/new choice the **Selected Version**. Do not use side for this choice because side also identifies a SideBySide column and an Anchor coordinate.
- The Selected Version defaults to new. It survives Session replacement within the process but does not persist across application restarts.
- The Selected Version controls WholeFile inspection and side-specific source operations. Changes and fetched-whole scopes keep their normal diff projection.
- A File with no content for the Selected Version shows an explicit unavailable state. Presentation never selects the other version as a fallback.
- Add separate `select_old_version` and `select_new_version` Actions. Bind them to `g<` and `g>` by default.
- Show the Selected Version in the DiffPane title. Accent the matching SideBySide column without treating a source click as a version change.
- Yank copies only Lines from the Selected Version. Count counts copied source Lines, and Selection limits the candidate rows.
- Cover RemoteReview and LocalReview through the common Diff pipeline. Cover Unified and SideBySide Layouts and all three Presentation Scope settings.

## Decisions so far

- [Define the Selected Version projection](issues/01-choose-old-new-side-inspection-and-yank.md): Keep diff scopes unchanged. Project explicit WholeFile versions without fallback. Preserve all review discussion. Restrict authoring to valid selected-version Hunk Lines.
- [Prototype the Selected Version indication](issues/02-prototype-selected-version-indication.md): Put an accented `g< OLD` or `NEW g>` segmented control in the DiffPane title and accent the matching SideBySide column without changing focus or Anchor targeting.
- [Define Selected Version source Actions](issues/03-define-selected-version-source-actions.md): Switch versions atomically with stable cursor restoration, and make yank copy only selected-version Lines in source order with exact Count, Selection, and refusal rules.
- [Define the integrated M20 contract](issues/04-define-integrated-m20-contract.md): Integrate Selected Version through process preferences, atomic Frames, shared File Enrichment, typed source refusals, staged activation, and a dependency-ordered acceptance matrix.

## Not yet specified

None. The four child tickets cover the current route to the M20 specification.

## Out of scope

- Implementing M20. This map ends at an implementation-ready specification.
- Buffer Search and Review Search owned by M21.
- Persistent Selected Version configuration or storage.
- New Anchor coordinates or changes to Bitbucket's Anchor contract.
