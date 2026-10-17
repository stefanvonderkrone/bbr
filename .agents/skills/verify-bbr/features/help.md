# Inspect keyboard help

Find the active Keymap and inspect why a remote-only Action cannot run in a LocalReview.

## Sub-features

- `help-open` opens the keybinding help Overlay.
- `help-dismiss` returns to the Review without changing its state.
- `help-local-availability` explains unavailable remote-only Actions.

## How to get to it (user POV)

- Press `?` in the Review.
- Press Escape to dismiss help.
- Press `X` in a LocalReview to inspect the Submission refusal.

## Driving it with control.py

Preconditions:

- Use a fresh baseline run.
- Prefix commands with `.agents/skills/verify-bbr/scripts/`.

- Open help. Run `control.py capture help-before`, `control.py keys ?`, and `control.py capture help-open`.
  Require an Overlay with `open File finder`, `search Buffer`, and the configured chords.
  Inspect subdued remote-only Actions in the ANSI capture.
- Dismiss help. Run `control.py keys Escape` and `control.py capture help-dismissed`.
  Require the DiffPane and the original selected File without the help Overlay.
- Availability. Run `control.py keys X` and `control.py capture help-local-submit-refusal`.
  Require a local-only refusal message. Run `control.py db` and require no Draft rows.

## Gotchas

- A user's custom Keymap can change the help text. The private empty config keeps defaults for this journey.
- Help captures input. Dismiss help before invoking Submission.
- An unavailable Action's explanation proves availability policy only. It does not prove remote Submission.
