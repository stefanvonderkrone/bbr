# Author local Drafts

Write Comments in a LocalReview and retain the PendingReview after the app restarts.

## Sub-features

- `draft-review` authors a Review-level Comment through `C`.
- `draft-file` authors a File-level Comment through `I`.
- `draft-inline` authors an inline Comment through `i`.
- `draft-cancel` closes a Composer without saving.
- `draft-persist` reopens a saved Draft after restart.

## How to get to it (user POV)

- Press `C` in a LocalReview.
- Focus `sample.txt` through `F`, then press `I`.
- Move the DiffPane cursor onto a Hunk source Line, then press `i`.
- Type in the Composer. Press Ctrl-S to save or Escape to cancel.

## Driving it with control.py

Preconditions:

- Use a fresh baseline run. Run `control.py db` and require an empty array.
- Prefix commands with `.agents/skills/verify-bbr/scripts/`.

- Review entry. Run `control.py keys C`, `control.py text VERIFY_REVIEW_DRAFT`, and `control.py capture draft-review-composer`.
  Require an open Composer with the full body. Run `control.py keys C-s` and `control.py wait VERIFY_REVIEW_DRAFT`.
  Run `control.py capture draft-review-saved` and `control.py db`. Require one Draft with that exact body.
- Persistence. Run `control.py restart`, `control.py wait VERIFY_REVIEW_DRAFT`, and `control.py capture draft-review-reopened`.
  Run `control.py db`. Require the same body and local id. Require a visible ReviewCard after restart.
- File entry. Run `control.py keys F`, `control.py text sample`, and `control.py keys Enter`.
  Run `control.py keys I`, `control.py text VERIFY_FILE_DRAFT`, and `control.py capture draft-file-composer`.
  Run `control.py keys C-s`, `control.py wait VERIFY_FILE_DRAFT`, and `control.py capture draft-file-saved`.
  Run `control.py db`. Require a second body and a distinct CommentScope from the Review-level Draft.
- Inline entry. Focus `sample.txt` again through the File finder. Move with `j` until the cursor marks `VERIFY_NEW`.
  Capture that source target. Run `control.py keys i`, `control.py text VERIFY_INLINE_DRAFT`, and `control.py capture draft-inline-composer`.
  Run `control.py keys C-s` and `control.py wait VERIFY_INLINE_DRAFT`.
  Run `control.py capture draft-inline-saved` and `control.py db`. Require the third body and inline CommentScope.
- Cancel. Run `control.py keys C`, `control.py text VERIFY_DISCARD_DRAFT`, and `control.py capture draft-cancel-body`.
  Run `control.py keys Escape` and `control.py db`. Require the three saved bodies and no `VERIFY_DISCARD_DRAFT` row.

## Gotchas

- The DiffPane can focus a File header after the File finder closes. `i` needs a Hunk source Line.
- Enter adds a newline inside a Composer. Ctrl-S saves the body.
- The helper's `db` command is read-only. It must never seed a Draft through SQLite.
- A successful save can still use an in-memory fallback if the database fails. Restart proof detects that failure.
- LocalReview Drafts never submit. The fixture cannot prove Submission, remote Replies, or published Comment mutation.
