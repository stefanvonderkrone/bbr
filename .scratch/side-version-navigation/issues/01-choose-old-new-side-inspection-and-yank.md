Type: grilling
Status: resolved

# Define the Selected Version projection

## Question

How should the review-wide Selected Version project old or new File content across Unified and SideBySide Layouts and all Presentation Scopes?

Resolve the exact Buffer content for each Layout and Scope combination. Define added, removed, renamed, binary, invalid UTF-8, loading, and acquisition-failure behavior. Define whether inline Comment and Suggestion authoring changes when WholeFile shows the old version. Preserve the common Diff pipeline and the existing Anchor contract.

## Comments

- 2026-08-06: Deferred from M15 at the human's request. M15 keeps the simple new-side-first yank rule and does not add explicit side switching.

## Answer

The Selected Version changes only version-specific inspection. Changes and fetched-whole scopes keep their current Buffer content in both Layouts. They also keep their File paths, Status Placeholders, and authoring behavior. The DiffPane title still identifies the Selected Version. SideBySide accents its matching column.

WholeFile uses these projections:

- Unified shows one continuous sequence from the Selected Version. Each source row shows only that version's line number. Hunk headers and Folds are absent. Hunk Lines retain their context, removed, or added styling. Full-content context Lines remain neutral and cannot receive Anchors.
- SideBySide shows both complete versions. It pairs unchanged full-content Lines. It uses the existing Hunk matcher for removed and added Lines. It does not compute another diff. The Selected Version marks the active column and controls version-specific Actions.
- A renamed File header uses the path from the Selected Version.

WholeFile never substitutes one version for the other. A loading, absent, binary, invalid UTF-8, or failed version produces a Status Placeholder. The Status Placeholder names the version and the exact state. It includes the byte size when known. Valid content with zero Lines produces a distinct `Empty file` placeholder. In SideBySide, usable content remains visible beside the other version's Status Placeholder.

A version change publishes the applicable loading placeholder while focused File Enrichment runs. Unfocused Files show loading placeholders until focus starts File Enrichment. The existing prefetch policy can also start File Enrichment. An acquisition failure remains visible until `R` refreshes the Session. M20 adds no separate retry Action.

Unified WholeFile weaves current inline ReviewCards from the Selected Version at their Hunk Lines. It puts current opposite-version inline ReviewCards in a collapsed per-File section. Those ReviewCards keep reply, edit, delete, disclosure, and re-anchor Actions. File-level ReviewCards remain at the File header. Outdated ReviewCards remain in the existing Outdated disclosure. SideBySide keeps current inline ReviewCards on their normal old or new Hunk Lines.

Inline Comment authoring in WholeFile requires a selected-version Hunk Line. Suggestion authoring also requires the new version. Full-content context Lines cannot receive an Anchor, Selection, Comment, or Suggestion. Status Placeholders and the `Empty file` placeholder have the same restriction. RemoteReview and LocalReview use this Diff and Presentation contract.
