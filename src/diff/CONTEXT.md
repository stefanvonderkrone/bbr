# Diff

The parsed, renderable model of a set of changes. Turns unified diff text (plus full file
blobs) from a DiffSource into the Line model that both anchoring and rendering depend on.

## Language

**DiffSource**:
Where the unified diff text comes from: `bitbucket` (a RawDiff from the API) or `local` (a `git diff` between two Refs). Both feed the same parser, so all rendering and comment UI is source-agnostic.
_Avoid_: provider, backend, origin.

**Diff**:
The complete set of changed Files from one DiffSource. The aggregate the whole UI reads from.
_Avoid_: changeset, patch.

**File**:
One changed path within a Diff, carrying distinct old/new paths, its change status (added / modified / removed / renamed), and its Hunks. Old-side Anchors match the old path and new-side Anchors match the new path; the displayed path is the surviving side, or the old path for a removed File. Full old/new file text is fetched lazily and held in a Session-side table index-aligned with the Files.
_Avoid_: buffer (that's the render-side term), document, blob.

**Hunk**:
A contiguous region of change plus its surrounding context lines, as delimited by Bitbucket's diff. Carries the old/new starting line numbers.
_Avoid_: chunk, block, section.

**Line**:
A single row of the model: `{ old_no, new_no, kind, text, in_hunk }`. Either `old_no` or `new_no` is absent depending on `kind`. `in_hunk` is true for a Line from the fetched diff (a Hunk line) and false for a `context` line synthesized from the file blob to fill the gaps in the WholeFile view — **only Hunk lines are Anchor targets**, so a blob-sourced line never captures a comment or Draft.
_Avoid_: row (that's a screen coordinate).

**LineKind**:
What happened to a Line: `context` (unchanged, present on both sides), `added` (green), or `removed` (red).
_Avoid_: unchanged (use `context`), insert/delete, type.

**IntraLineSegment**:
A run of characters within a changed Line tagged `changed` or `unchanged`, computed by a local word-level diff over adjacent removed/added pairs. Drives the emphasized background. Purely cosmetic — never affects anchoring.
_Avoid_: token (that's a highlighting term), span (that's a highlight capture), word.

**Fold**:
A collapsed run of far-from-change `context` Lines in `Changes` scope, shown as an expandable marker. Expansion reveals already-loaded lines; it never refetches.
_Avoid_: collapse, gap, hidden region.

**Buffer**:
The flattened, ordered rows the DiffPane walks. By default it projects the whole Diff — every File in one continuous scroll — but the **isolate** view (`only_file`) projects exactly one File: its header, hunks, folds, intra-line segments, and anchored threads/drafts, and nothing PR-level. The single-File projection is the canonical review unit; the all-files scroll is a navigation convenience. Lives in the buffer-scoped arena and is rebuilt on any view change or PR switch.
_Avoid_: file (that's the domain entity), view, page.

**Layout**:
How a Buffer is arranged on screen: `Unified` (one column, removed above added) or `SideBySide` (old left, new right). One of the two orthogonal view axes.
_Avoid_: mode, split, inline.

**Scope**:
How much of a File a Buffer shows: `Changes` (hunks + context, with Folds) or `WholeFile` (every line of the file, changes inline — the hunks spliced into the file blob). The other orthogonal view axis. The UI cycles a third intermediate — *fetched-whole*, every fetched line with no folds — which is `Changes` unfolded; it's a rendering stop on the way to `WholeFile`, not a distinct model state, and `WholeFile` falls back to it until the blob loads.
_Avoid_: view mode, filter, range.
