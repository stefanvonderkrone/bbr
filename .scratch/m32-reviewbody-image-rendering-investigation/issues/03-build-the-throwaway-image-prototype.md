# 03: Build the throwaway image prototype

Status: ready-for-human
Blocked by: 01, 02
Spec: [M32 spec](../SPEC.md)

## What to build

A throwaway prototype on the branch `m32-image-prototype` that shows ReviewBody images in bbr.
It has Variant A, the inline image, and Variant B, the image preview Overlay.
It opens one fixture Review with the situations R1 to R12 of the spec.
It writes the probe log that the spec defines.

The branch never merges.
This ticket runs the prototype only far enough to prove that it works in one kitty-protocol terminal.
Ticket 04 does the full run.

## Scope

- Create the branch `m32-image-prototype` from the M32 branch in its own Worktree.
  Make every prototype commit on that branch.
  On the M32 branch, change only this ticket and add files under `evidence/`.
- Follow the "Prototype" section of the spec.
- Use the Bitbucket host list from ticket 01 and the detection rule from ticket 02.
- Add the kitty graphics path through the vaxis 0.6.0 API.
  Turn on capability detection and record each side effect that ticket 02 lists.
- Add tmux passthrough for the kitty path.
- Add the iTerm2 inline image path until it shows I1 in iTerm2 or WezTerm.
  If the path needs more than a small adapter, record the cost and stop.
- Add the fixture mode for `fixture:I1` to `fixture:I12`.
- Add a script that generates I1 to I12 with synthetic content.
- Add one command or script that sets up the fixture Review with the situations R1 to R12.
- Add the network path for I13 to I15 under the "Security rules" section of the spec.
  The image path follows each redirect itself and applies the Credential host rule at each hop.
- Add both PNG paths from the spec: decode with `zigimg`, and send PNG bytes as `f=100`.
- Add the environment switches with the `BBR_M32_` prefix:
  the variant, the PNG path, `BBR_M32_ALLOW_EXTERNAL`, the maximum inline rows, and `BBR_M32_PROBE_LOG`.
- Add the fallback text states from the "Fallback text behavior" section of the spec.
- Add the probe log and the `summarize` script from the "Measurements" section of the spec.
- Add the `M32 image` tests from the "Prototype tests" section of the spec.
- Write `evidence/run-guide.md` on the M32 branch.
  It tells the human how to build the prototype, set up the fixture Review, set each switch, and run `summarize`.
- Record a first measurement of I1 to I12 in one kitty-protocol terminal under `## Completion`.

Do not change production code on the M32 branch.
Do not call Bitbucket in this ticket.

## Acceptance criteria

- [x] The branch `m32-image-prototype` exists, and `## Completion` names its last commit.
- [x] The M32 branch has no source code change from this ticket.
- [x] `zig build` passes on the prototype branch.
- [x] Every `M32 image` test from the spec exists and passes on the prototype branch.
- [x] The Credential test with a redirect to another host passes.
- [x] I9 and I10 give a failure state and no crash in a `ReleaseSafe` build.
- [ ] Variant A and Variant B both show I1 in one kitty-protocol terminal.
- [x] One command or script sets up the fixture Review with R1 to R12.
- [x] The probe log holds every event and key from the spec.
- [x] The probe log holds no URL, query string, Comment text, or Credential.
- [x] `summarize` prints the numbers that the spec lists.
- [x] `## Completion` records the cost of the iTerm2 path and of tmux passthrough.
- [x] `## Completion` records the side effects of capability detection.
- [x] `evidence/run-guide.md` exists on the M32 branch.
- [x] `python3 tools/check_agent_docs.py` passes on the M32 branch.

## Required checks

On the prototype branch:

- `zig build`
- `zig build test --summary all`, with the `M32 image` tests in the run.
- A `ReleaseSafe` build that opens I9 and I10.

On the M32 branch:

- `python3 tools/check_agent_docs.py`

## Completion

The prototype lives on the branch `m32-image-prototype`.
Its last commit is `5d50146` (m32: log each image request hop and honor proxies).
The branch never merges. Do not push it until the human wants to share it.

### Commits on `m32-image-prototype`

- `de29280` http: add redirect and body limit options to the seam
- `561a231` m32: add the terminal-free image prototype core
- `15d3317` m32: allow the Bitbucket storage host after bitbucket.org
- `0f329c0` m32: add detection, sizing, and the fixture Review data
- `40d4185` m32: wire inline and preview images into the app
- `e174b2a` m32: scan images per frame and document the run
- `5d50146` m32: log each image request hop and honor proxies

### What the prototype does

- `src/tui/m32_image.zig` holds the terminal-free core. It sniffs the type, reads the header dimensions, applies the limits, follows each redirect itself, and writes the probe log.
- The Credential host rule uses exactly `bitbucket.org` and `api.bitbucket.org`.
- The storage host `bbuseruploads.s3.amazonaws.com` loads only directly after a `bitbucket.org` hop. It never gets the Credential. This follows the change to spec choice 5 in ticket 01.
- A redirect to `id.atlassian.com` or `auth.atlassian.com` ends as `failed`.
- `src/tui/m32_term.zig` holds the detection, the kitty transmit and placement, the tmux passthrough wrapper, and the OSC 1337 adapter.
- `src/tui/m32_fixture.zig` serves the fixture Review through `FakeHttpClient` with a sentinel Credential. It reads no Profile and no Credential.
- Variant A inserts image rows in `review_card.zig`. The rows count toward the ReviewCard row budget, so a collapsed disclosure hides them.
- Variant B opens the image preview with `P`. The preview uses `layouts.dialog`, which wraps `overlaySurface`.
- While an Overlay is open, bbr places no inline image.
- Image acquisition and decode run as `io.concurrent` futures in `app.zig`, at most two at a time. They are not owned commands under ADR-0012. A result from an old Session Epoch is dropped.
- The image cache is in memory only, for one Session.
- `tools/m32/generate_images.py` writes I1 to I12 with synthetic content. `tools/m32/fixture_review.sh` opens the fixture Review in an isolated environment. `tools/m32/summarize.py` prints the numbers from the spec.

### Side effects of capability detection

The prototype does not call `queryTerminal` or `enableDetectedFeatures`.
It writes the kitty query and DA1 itself, and waits up to 1 second on `vx.query_futex`.
So the side effects that ticket 02 lists for `queryTerminal` do not occur.
These side effects remain:

- Startup waits up to 1 second for the reply.
- The vaxis Loop sets `caps.kitty_graphics` on any kitty reply.
- With kitty on, vaxis starts each render with a kitty delete command (`a=d`).
- vaxis placements carry no `q=2`, so the terminal replies `OK`. The Loop swallows each reply.
- In tmux, bbr sends no query.

### Cost of the iTerm2 path and of tmux passthrough

- tmux passthrough is small. bbr wraps each kitty chunk in the tmux passthrough and adds `q=2`. Placement is direct, with a saved and restored cursor inside the wrapper.
- tmux placement is correct only for a pane at the top-left of the window. A correct placement needs the pane offset or Unicode placeholders.
- Unicode placeholders are not built. The estimate is medium: a table of 297 diacritics and placeholder cells in `render.zig`.
- The OSC 1337 adapter is about 60 lines. It works only in the image preview. bbr writes the image once after the frame and forces a full repaint when the preview closes.
- Inline OSC 1337 needs reserved cells and a full resend after each move. It fights the vaxis diff renderer, so the prototype does not build it. The card shows `inline needs kitty`.

### First measurement

These numbers come from a Debug run of the core on the generated files, not from a terminal.

- I1 to I12 give the expected result. I9 gives `failed`, I10 and I12 give `too large`, and I11 gives `unsupported`.
- Decode takes about 170 ms for I2, 0.9 s for I3, and 1.45 s for I7. zigimg decodes all 10 GIF frames, so I7 is slow.
- On the `zigimg` path, I2 sends about 32 MB of base64.

### Decoder finding for ticket 05

The Zig 0.16 flate decoder panics with an integer overflow in `Decompress.peekBitsEnding`.
The input is a PNG with complete chunks and valid CRCs, but a short deflate stream.
zigimg calls this decoder, so the `zigimg` path can crash bbr. The panic occurs in Debug and in `ReleaseSafe`.
The `f100` path does not decode in bbr, so it does not crash.
`tools/m32/generate_images.py` writes `extra-I9-valid-chunks.png`, which shows the panic.
The fixture Review does not use this file, and the generated I9 does not cause the panic.

### Checks

On `m32-image-prototype` at `5d50146`:

- `zig fmt --check build.zig src tests` passes.
- `zig build` passes.
- `zig build test --summary all` passes: 24 of 24 steps, 1412 of 1412 tests.
- `zig build test-m32-image -Doptimize=ReleaseSafe --summary all` passes: 39 of 39 tests. These tests run I9 and I10 and give a failure state with no crash.
- Tests render real vaxis output into a buffer. They check the kitty transmit and placement bytes for Variant A and for the Variant B preview.

On `m32-reviewbody-image-rendering-investigation`:

- `python3 tools/check_agent_docs.py` passes.
- This ticket changes no source code on this branch. It adds [evidence/run-guide.md](../evidence/run-guide.md).

### Review

The runner read the fixture start path in `src/main.zig`, the fixture script, the image client setup, and the detection rule.
The fixture path reads no Profile and no Credential before it starts the app.
In the fixture Review, the image client gets no Credential.

## Comments

One criterion stays open: Variant A and Variant B both show I1 in one kitty-protocol terminal.
Agents must not start bbr, so no agent ran the prototype in a terminal.
The human does this check first in ticket 04, as its notes say.
Then the human copies the first `summarize` output here and sets this ticket to `resolved`.
