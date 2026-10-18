# Inspect a local diff

Review committed changes without a Credential. Choose a File and inspect its old and new content.

## Sub-features

- `diff-launch` opens the explicit BaseRef and SourceRef as a LocalReview.
- `diff-finder` focuses a File through the File finder.
- `diff-sidebar` focuses a File through the Sidebar.
- `diff-layout` switches Unified and SideBySide Layouts.
- `diff-scope` cycles Scope and isolates one File.
- `diff-version` selects old and new File content.

## How to get to it (user POV)

- Run `bbr local main review` from the seeded WorkingCopy.
- Press `F`, type a path, and press Enter.
- Press Tab to focus the Sidebar. Use arrows and Enter to focus a File.
- In the DiffPane, press `s`, `f`, `o`, `h`, or `l` to change the projection.

## Driving it with control.py

Preconditions:

- Use a fresh baseline run and a successful doctor check.
- Prefix each command below with `.agents/skills/verify-bbr/scripts/`.

- Launch proof. Run `control.py capture diff-launch`. Require `main`, `review`, `sample.txt`, `VERIFY_OLD`, and `VERIFY_NEW`.
- Finder entry. Run `control.py keys F`, `control.py text sample`, and `control.py capture diff-finder-query`.
  Require the query and `sample.txt` result. Run `control.py keys Enter` and `control.py wait VERIFY_NEW`.
  Run `control.py capture diff-finder-result`. Require the source text and no finder Overlay.
- Sidebar entry. Run `control.py keys Tab`, `control.py keys Home`, and `control.py capture diff-sidebar-choice`.
  Require Sidebar focus. Select `notes.txt` with arrows if needed, then run `control.py keys Enter`.
  Run `control.py wait VERIFY_NOTES` and `control.py capture diff-sidebar-result`.
  Require the added File's content. Do not use a fixed number of Tabs to guess focus.
- Return to the modified File. Run `control.py keys F`, `control.py text sample`, and `control.py keys Enter`.
  Run `control.py wait VERIFY_NEW` and `control.py capture diff-unified`.
- Layout. Run `control.py keys s` and `control.py capture diff-side-by-side`.
  Require old content on the left and new content on the right. Run `control.py keys s` to restore Unified.
- Scope. Run `control.py keys f` and `control.py capture diff-scope-unfolded`.
  Run `control.py keys f` and `control.py capture diff-scope-whole`.
  Require `line 01` and `line 40` after scrolling through WholeFile. Require the changed line to remain marked.
- Isolation. Run `control.py keys o` and `control.py capture diff-isolated`.
  Require one File in the DiffPane. Run `control.py keys o` to restore all Files.
- Version. Run `control.py keys h` and `control.py capture diff-old-version`.
  Run `control.py keys l` and `control.py capture diff-new-version`.
  Inspect ANSI attributes and the selected-version indicator. Both versions can remain visible in the Diff.

## Gotchas

- The startup DiffPane can already contain both Files. Visible text alone does not prove File focus.
- `h` and `l` collapse and expand in the Sidebar. Confirm DiffPane focus before a version check.
- `notes.txt` has no old version. Use `sample.txt` to verify both Selected Versions.
- `f` cycles Changes, fetched-whole, and WholeFile. File Enrichment can finish after the first draw.
- The fixture has no Remote default Ref. The omitted-BaseRef startup path fails with this fixture.
  Keep that failure distinct from the explicit-Ref path. Do not claim default-Ref discovery as verified.
