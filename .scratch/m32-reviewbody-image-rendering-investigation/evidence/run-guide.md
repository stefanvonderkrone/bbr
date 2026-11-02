# M32 prototype run guide

This guide tells the human how to build and run the M32 image prototype.
Ticket 04 uses it in each target terminal.
The prototype is throwaway code on the branch `m32-image-prototype`.
The branch never merges.

## Before the first run

You need Zig 0.16.0, Python 3, and macOS `sips`.
The image generator uses `sips` to write the JPEG image I3.

Get the prototype in its own Worktree:

```sh
git worktree add /Volumes/Work/t3-code/m32-image-prototype m32-image-prototype
cd /Volumes/Work/t3-code/m32-image-prototype
git log -1 --format='%h %s'
```

The first command fails if the Worktree already exists.
In that case, change to the directory and run the last command.
Record the commit hash in ticket 04.

The fixture script builds a `ReleaseSafe` binary for you.
To build it by hand, run `zig build -Doptimize=ReleaseSafe`.
To run the offline prototype tests, run `zig build test-m32-image --summary all`.

## Open the fixture Review

The fixture Review holds the situations R1 to R12 and the images I1 to I14.
It is offline, and it reads no Profile and no Credential.

```sh
BBR_M32_VARIANT=inline BBR_M32_PROBE_LOG="$TMPDIR/m32-<column>-a.log" tools/m32/fixture_review.sh
```

The script does these steps:

1. It builds the `ReleaseSafe` binary.
2. It writes I1 to I12 into a new temporary directory.
3. It sets a temporary `HOME` and temporary XDG directories.
4. It removes the Bitbucket environment variables.
5. It starts bbr on the fixture Review.

The terminal variables, such as `TERM`, `TERM_PROGRAM`, `TMUX`, and `HERDR_ENV`, pass through.
So the detection rule sees the real terminal.

Quit bbr with `q` when no Overlay is open.

## Switches

Set each switch before the script.

| Variable | Values | Default |
| --- | --- | --- |
| `BBR_M32_VARIANT` | `inline` for Variant A, `preview` for Variant B | `inline` |
| `BBR_M32_PROTOCOL` | `auto`, `kitty`, `iterm2`, `none` | `auto` |
| `BBR_M32_TMUX_IMAGES` | `1` turns on kitty images through tmux passthrough | off |
| `BBR_M32_MAX_ROWS` | the maximum rows of an inline image | `12` |
| `BBR_M32_PNG_PATH` | `zigimg` decodes in bbr, `f100` sends the PNG bytes | `zigimg` |
| `BBR_M32_ALLOW_EXTERNAL` | `1` allows external `https` hosts | off |
| `BBR_M32_I13_URL` | the I13 URL in the fixture | `https://localhost:8443/I1.png` |
| `BBR_M32_PROBE_LOG` | the probe log path | a file in the temporary directory |

With `auto`, bbr follows the detection rule of ticket 02.
In a plain terminal and in herdr, bbr sends a kitty query and DA1, and waits up to 1 second.
In tmux, bbr sends no query. It uses kitty images only with `BBR_M32_TMUX_IMAGES=1`.
bbr never selects `iterm2` itself. Set `BBR_M32_PROTOCOL=iterm2` to test OSC 1337.
The iTerm2 path works only in Variant B. In Variant A, the card shows `inline needs kitty`.

## Keys

| Key | Action |
| --- | --- |
| `P` | In Variant B, open the image preview. The image on the cursor row opens first. Otherwise the first image of the card opens. |
| `Esc`, `q`, or `P` | Close the image preview. |
| `Enter` on a disclosure footer | Expand or collapse a ReviewCard (R5) or a resolved Thread (R6). |
| `Ctrl-e` and `Ctrl-y` | Scroll the DiffPane one row (R7). |
| `]` and `[` | Jump to the next or the previous File (R11). |
| `R` | Refresh the Session (R11). |
| `?` | Open the help Overlay (R9). |
| `r` | Open the Composer (R9). |
| `F` | Open the File Finder (R9). |
| `v`, a Motion, then `y` | Select and yank (R10). |
| `gf` | Open Review Search (R12). |
| `/` | Open Buffer Search (R12). |

## Situations in the fixture Review

| Id | Where | What to check |
| --- | --- | --- |
| R1 | Comment on `src/m32/first.zig` line 3, and the Review-level Comment. | Size, aspect ratio, and position in the card. |
| R2 | Comment on `first.zig` line 10. It holds I6, I8, and I5 with prose between them. | Order, spacing, and the row count. |
| R3 | Thread on `first.zig` line 20 with 12 Replies. | Output bytes and frame time while the cursor moves. |
| R4 | Thread on `first.zig` line 30. A Reply chain 10 deep has images at depth 1, 3, and 10. | Width at each Reply indentation. The rails and the Anchor Indicator stay visible. |
| R5 | Comment on `first.zig` line 40. The image is below the 6-row budget. | The image hides and shows with the disclosure. No stale image stays. |
| R6 | Resolved Thread on `first.zig` line 50. | No image shows while the Thread is hidden. |
| R7 | Comment on `first.zig` line 60 with the tall I4. | Clipping at the top and the bottom. No image over the status or a Pane border. |
| R8 | Resize the terminal while an image shows. | New size, new position, and no stale copy. |
| R9 | Open `?`, `r`, `F`, or a herdr popup over an image. | The Overlay covers the image. The image returns after close. |
| R10 | Select over an image card with `v`, and yank with `y`. | The clipboard gets the M23 text, not image data. |
| R11 | Comment on `src/m32/second.zig` line 5, and a File-level Comment. Jump with `]` and `[`, and refresh with `R`. | The image frees and returns. No stale copy. |
| R12 | Search for `shot`, `R3 reply`, or `R4 depth`. | The Search Occurrence maps to the authored text. |
| States | Comment on `first.zig` line 70 with I9 to I14. | The fallback state after each M23 image text. |

The expected states for line 70 are these:

- I9, the truncated PNG, shows `failed`.
- I10, the decompression bomb, shows `too large`.
- I11, the SVG file, shows `unsupported`.
- I12, the PNG above the byte limit, shows `too large`.
- I13 shows `blocked` while `BBR_M32_ALLOW_EXTERNAL` is off.
- I14, the relative reference, shows `failed`.

## Probe log and summarize

Use one probe log for each column and variant, so that each summary stays separate.

```sh
python3 tools/m32/summarize.py --terminal <column> "$TMPDIR/m32-<column>-a.log"
```

The summary prints these numbers:

- The acquisition latency median and maximum for each image.
- The decode time median and maximum for each image.
- The output bytes of the first transmit and of one placement.
- The peak retained memory and the peak RSS.
- The output bytes and the paint time of each frame.
- The request hosts of each network image, one line for each hop.

A probe line holds no URL, no Comment text, and no Credential.
A host outside the known list shows as `other`.

The probe log is the only tool that shows the request hosts.
Never put a proxy in front of bbr, and never set `http_proxy` or `https_proxy` for a run.
A proxy with a trusted TLS-intercepting root decrypts the `Authorization` header.
On Zig 0.16, a proxy that refuses one CONNECT gets the later requests in clear text.

## Known gaps

- A File Jump or a scroll does not free a kitty image in the terminal. bbr frees an image only when its rows leave the Buffer, on Session replacement, or when the preview closes.
- tmux placement is correct only for a pane at the top-left of the window. Use one pane in the tmux window.
- On the `zigimg` path, I2 sends about 32 MB of base64 from the main thread. Compare with `BBR_M32_PNG_PATH=f100`.
- Card rows reserve no image rows until bbr knows the image size. The layout moves once for each image.
- Quit waits until running image jobs end.
- I13 needs a certificate that the system trusts. A self-signed certificate gives `failed`.
- The Zig 0.16 flate decoder can panic on a PNG with complete chunks and a short deflate stream. The file `extra-I9-valid-chunks.png` in the image directory shows it. The fixture Review does not use this file.
