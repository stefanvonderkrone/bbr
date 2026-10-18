# Search a review

Find source text in the current Buffer or across the complete changed Files in the Review.

## Sub-features

- `search-buffer` opens incremental Buffer Search and accepts or cancels its query.
- `search-traverse` moves through Buffer Search Occurrences with `n` and `N`.
- `search-review` opens Review Search and jumps to a source occurrence.
- `search-empty` shows a query without matching text.

## How to get to it (user POV)

- In the DiffPane, press `/` for Buffer Search.
- Press `n` or `N` after accepting a Buffer Search query.
- In the DiffPane, press `g` then `f` for Review Search.

## Driving it with control.py

Preconditions:

- Use a fresh baseline run with DiffPane focus.
- Prefix commands with `.agents/skills/verify-bbr/scripts/`.

- Buffer query. Run `control.py keys /`, `control.py text VERIFY_`, and `control.py capture search-buffer-input`.
  Require the query and highlighted occurrences. Run `control.py keys Enter` and `control.py capture search-buffer-accepted`.
- Traverse. Run `control.py keys n` and `control.py capture search-buffer-next`.
  Run `control.py keys N` and `control.py capture search-buffer-previous`.
  Require occurrence selection to move and return. Inspect ANSI highlights, not just source visibility.
- Empty query result. Run `control.py keys /`, `control.py keys C-u`, and `control.py text NOT_IN_FIXTURE_971`.
  Run `control.py capture search-buffer-empty`. Require no matching occurrence.
  Run `control.py keys Escape` and capture the restored query or navigation state.
- Review query. Run `control.py keys g f`, `control.py text VERIFY_NOTES`, and `control.py wait VERIFY_NOTES`.
  Run `control.py capture search-review-results`. Require a `notes.txt` source result and its preview.
  Run `control.py keys Enter` and `control.py capture search-review-opened`.
  Require the Overlay to close and the DiffPane cursor to reach `VERIFY_NOTES` in `notes.txt`.
- Cancel. Open Review Search again with `control.py keys g f`, then run `control.py keys Escape`.
  Run `control.py capture search-review-cancelled`. Require the previous source location to remain selected.

## Gotchas

- Review Search loads complete File versions. Buffer Search does not start File Enrichment.
- A visible query string is not proof of a matching result. Inspect the result path and source preview.
- This fixture has no authored ReviewBody. A journey over Comment, Reply, or Draft text fails until authoring supplies that precondition.
- `Escape` cancels Buffer Search input. It can restore the prior accepted query rather than clear every highlight.
