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
One changed path within a Diff, carrying its change status (added / modified / removed / renamed) and its Hunks. Also holds the full old and new blobs used for WholeFile scope and highlighting.
_Avoid_: buffer (that's the render-side term), document, blob.

**Hunk**:
A contiguous region of change plus its surrounding context lines, as delimited by Bitbucket's diff. Carries the old/new starting line numbers.
_Avoid_: chunk, block, section.

**Line**:
A single row of the model: `{ old_no, new_no, kind, in_hunk, segments }`. Either `old_no` or `new_no` is absent depending on `kind`. The unit that Anchors point at.
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
The loaded, rendered model of exactly one File — parsed Lines, folds, intra-line segments, wrapping, and (later) highlight spans. Lives in the buffer-scoped arena and is reset/reused on file switch.
_Avoid_: file (that's the domain entity), view, page.

**Layout**:
How a Buffer is arranged on screen: `Unified` (one column, removed above added) or `SideBySide` (old left, new right). One of the two orthogonal view axes.
_Avoid_: mode, split, inline.

**Scope**:
How much of a File a Buffer shows: `Changes` (hunks + context, with Folds) or `WholeFile` (every line, changes inline). The other orthogonal view axis.
_Avoid_: view mode, filter, range.
