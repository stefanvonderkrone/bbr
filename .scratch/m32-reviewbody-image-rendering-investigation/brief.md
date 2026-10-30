# M32 ReviewBody image rendering investigation: brief

Status: ready-for-agent
Milestone: M32

This brief records the `in-your-own-words` restatement and the `sharpen` pass for M32.
The requirements live in the M32 section of [TODO.md](../../TODO.md).
The vocabulary lives in [the Review glossary](../../src/review/GLOSSARY.md) and [the Presentation glossary](../../src/tui/GLOSSARY.md).

## In my own words

Reviewers paste screenshots into Comments: UI bugs, layout problems, and expected results.
M23 shows such an image only as a label, its alternative text, and its destination.
The reviewer must open the browser to see what the Comment is about.

The goal is a decision, not a feature.
M32 finds out whether bbr can show these images in the terminal well enough to be useful.
It also finds out how bbr gets the images safely, and what the reviewer sees when a terminal cannot show images.
The result is a recorded decision that a later milestone implements.

## Expert approach

- Raw sources: the kitty graphics protocol specification, the iTerm2 inline image protocol, the tmux passthrough documentation, the libvaxis image API, and the Bitbucket Cloud Comment and attachment API.
- Method: test each terminal with one fixed set of images and one fixed set of ReviewCard situations.
  The situations are a long Thread, nested Replies, a collapsed disclosure, scrolling, and resize.
  Compare an inline image with a separate image preview in front of a human.
- Outside check: run the prototype in each target terminal and record a screenshot of each situation.
  On a real PullRequest with pasted screenshots, confirm that bbr sends the Credential only to Bitbucket hosts.
  A logging proxy or the `HttpClient` fake shows every request host.

## Decisions

The user made these decisions on 2026-10-30.

1. **Target terminals: Ghostty, kitty, WezTerm, iTerm2, tmux, herdr, and terminals without an image protocol.**
   Ghostty and kitty use the kitty graphics protocol.
   WezTerm supports parts of the kitty protocol and the iTerm2 protocol.
   iTerm2 supports only its own protocol.
   tmux needs passthrough.
   herdr parses the kitty graphics protocol itself and draws the images in a compatible outer terminal.
   The user added herdr on 2026-10-30.
   Apple Terminal and other terminals get a text fallback.
2. **A config key allows external image loads.**
   bbr always loads Bitbucket-hosted images, and sends the Credential only to Bitbucket hosts.
   bbr loads an image from another host only when the config allows it.
   The default is off, as the user confirmed on 2026-10-30, because an external load reveals the reviewer's IP address and can be a tracking pixel.
3. **Output: a decision document and a throwaway prototype.**
   The prototype lives in a branch or a scratch directory and never merges.
   A human reviews inline images against a separate preview.
   A later milestone implements the selected behavior.

## Specification changes

- Added: the per-terminal protocol matrix (decision 1).
  libvaxis implements the kitty graphics protocol.
  iTerm2 support needs another protocol path, so the investigation records its cost.
- Added: the external-load config key and the Credential host rule (decision 2).
- Added: the investigation must find out how Bitbucket Cloud stores pasted Comment images.
  It must record whether the image URLs need the Credential and whether they expire.
- Added: tmux needs a separate test, because passthrough can misplace images or leave stale images after a scroll.
- Added: herdr needs a separate test.
  herdr sets `HERDR_ENV=1`, and its `terminal.kitty_graphics` setting is on by default.
  herdr has no tmux-style passthrough, because it renders the kitty images itself.
  Public reports describe stale image copies after a scroll and slow image output in herdr.
  The test covers scroll, resize, an herdr popup over an image, and herdr inside Ghostty and inside another kitty-protocol terminal.
- Added: bbr must detect tmux and herdr from the environment, because a multiplexer can pass on the outer terminal's `TERM_PROGRAM`.
  The investigation records a detection rule for each multiplexer.
- Kept: every M32 TODO line, including acquisition latency, decoding, memory limits, cache lifetime, sizing, aspect ratio, Reply indentation, and ReviewCard disclosure.

## Open questions

None.

## Next step

After approval, write `SPEC.md` and the research tickets in this directory.
