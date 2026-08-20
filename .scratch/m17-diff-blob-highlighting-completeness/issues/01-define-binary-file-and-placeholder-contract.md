# Define the binary File and placeholder contract

Type: grilling
Status: resolved
Blocked by: none

## Question

How does bbr classify binary Files from RawDiff stubs and non-UTF-8 blobs, represent their size and side availability in the Diff model, suppress File Enrichment and Highlighting safely, and render a clear placeholder across Unified/SideBySide Layout and Changes/WholeFile Scope without creating Anchors on unavailable content?

## Answer

- A File is binary when the RawDiff contains a Git binary stub. Otherwise, each old/new side is validated independently; invalid UTF-8 makes only that side unavailable. A valid opposite side remains usable.
- File exposes content status per side: `text`, `binary`, or `unavailable`, plus optional byte size. Parsed textual Hunk/Line metadata remains when present. Binary bytes never enter the Diff model.
- File Enrichment does not fetch or Highlight a side already known to be binary. Unknown text sides follow normal enrichment. UTF-8 validation occurs before ownership transfer. Side failures are typed and non-fatal.
- `Changes` keeps a textual diff stub when available and otherwise shows a clear non-anchorable binary marker. `WholeFile` shows a File-level placeholder instead of blob splicing. SideBySide displays old/new status independently, including explicit missing-side markers for added and removed binary Files.
- Binary/status rows are not Hunk Lines. They cannot receive Anchors, Selection, folds, or Highlighting. File-level and Review-level Comments remain visible.
- Presentation shows byte size when known and `size unavailable` otherwise. It distinguishes binary content, invalid UTF-8, and transport/API failure while keeping the placeholder stable and concise.
