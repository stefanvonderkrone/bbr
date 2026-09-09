# Define Selected Version source Actions

Type: grilling
Status: resolved
Blocked by: 01, 02

## Question

How should `select_old_version`, `select_new_version`, and `yank` behave for cursor restoration, Count, Selection, wrapped Lines, paired and unpaired SideBySide rows, unavailable content, and mouse parity?

The answer must replace M15's provisional new-side-first yank rule. It must define which selected-version Lines each visual row owns, how source order remains stable, when Selection clears, what cursor target survives a WholeFile rebuild, and which refusal Presentation reports when no selected-version source is available.

## Answer

`select_old_version` and `select_new_version` set the review-wide Selected Version. The title segments from [Prototype the Selected Version indication](02-prototype-selected-version-indication.md) dispatch these Actions for keyboard and mouse input. Clicking a source Line does not change the Selected Version. Selecting the current value is idempotent and preserves the Count, Selection, cursor, and Presentation Frame.

An actual version change publishes one atomic Presentation Frame. It clears the Count and Selection after publication. Changes and fetched-whole scopes keep their Buffer content, but the title and source Action target change. WholeFile rebuilds according to [Define the Selected Version projection](01-choose-old-new-side-inspection-and-yank.md). An allocation failure preserves the prior Selected Version and complete Presentation Frame, including the Count and Selection, and reports the failure.

WholeFile cursor restoration retains the focused File and the cursor's semantic Line target. Presentation first restores the matching Line in the Selected Version. If that Line does not exist, Presentation chooses the next selected-version Line in source order. If no later Line exists, it chooses the nearest earlier selected-version Line. If the File has no selected-version Lines, it chooses the File header. While File Enrichment shows a loading Status Placeholder, Presentation retains this restoration target. It applies the target when File Enrichment finishes unless the reviewer has moved to another target.

`yank` copies Lines from exactly one version: the Selected Version. It never interleaves old and new source text. Each visual row owns at most one candidate Line for `yank`:

- A Unified row owns its Line only when that Line exists in the Selected Version.
- A SideBySide row owns only its old Line or new Line, as selected. A row with no Line for that version owns no candidate.
- Wrapped visual rows share one semantic Line and contribute that Line only once.
- A blob-sourced full-content context Line is a candidate even though it cannot receive an Anchor.
- A Status Placeholder, `Empty file` placeholder, File header, Hunk header, Fold, ReviewCard, and other Presentation-only row owns no candidate.

Without a Selection, `yank` scans forward from the cursor. It skips rows without a candidate and copies the Count of candidate Lines. A missing Count means one Line. If the File ends before the Count is met, `yank` copies the available candidate Lines. It does not cross the File boundary.

With a Selection, `yank` ignores the Count and limits candidates to the inclusive selected visual rows. If the Selection crosses a File boundary, `yank` copies only candidates from the cursor's File and stops at its boundary. It orders all copied Lines by the Selected Version's source order, independent of Unified removed-and-added grouping or SideBySide pairing. Empty source Lines count as Lines. The clipboard text joins Lines with `\n` and adds no trailing newline.

When Presentation starts a clipboard copy request, `yank` clears the Count and Selection. A later clipboard adapter failure does not restore them. A refused `yank` keeps the Selection but consumes the Count. An allocation failure follows the same cleanup rule as a refusal. Clipboard success and failure keep the existing visible status.

Presentation reports a precise refusal when no candidate exists. The message names the Selected Version and distinguishes unavailable File content from no selected-version source at the cursor or in the Selection. ActionAvailability exposes the same reason. Selecting an unavailable version remains valid because the explicit unavailable state is part of the inspection contract. M20 adds no mouse gesture for `yank`.
