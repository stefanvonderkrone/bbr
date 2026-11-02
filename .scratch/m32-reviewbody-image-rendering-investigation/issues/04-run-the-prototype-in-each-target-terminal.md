# 04: Run the prototype in each target terminal

Status: ready-for-human
Blocked by: 03
Spec: [M32 spec](../SPEC.md)

## What to build

A human runs the prototype from ticket 03 in each target terminal.
The human records a screenshot of each ReviewCard situation and the probe log of each run.
The human also checks the Bitbucket findings of ticket 01 on a real PullRequest.

This ticket needs the target terminals, the user's Credential, and live network access.
So an agent cannot run it.

## Steps

Before the runs:

1. Follow `evidence/run-guide.md` from ticket 03.
2. Check out the prototype commit that ticket 03 names, and note the commit hash.
3. Record the version of each terminal, tmux, and herdr.

For each column of the protocol matrix in the spec:

1. Open the fixture Review in Variant A.
2. Go through the situations R1 to R12.
   Take one screenshot of each situation.
   For R5, R7, R8, R9, and R11, take a screenshot before and after the change.
   The prototype has one PNG path: it sends the PNG bytes to kitty with `f=100`.
3. Open the fixture Review in Variant B, and go through R1, R4, R7, R8, and R9.
4. Run `summarize` on the probe log, and copy its output into `## Completion`.
5. Fill the matrix column with the observed results.
   Mark each cell that differs from ticket 02.
6. Write down how readable each image is at the start size of 12 rows.
   If a different maximum makes the images clearly better, record that value and run R1 to R4 again with it.

For herdr, also do these steps:

1. Run herdr inside Ghostty and inside one other kitty-protocol terminal.
2. Open an herdr popup over an image, then close it.
3. Scroll and resize, and look for stale image copies.
4. Record whether `terminal.kitty_graphics` was on.

For tmux, run it once with `allow-passthrough on` and once with it off.
Use two panes side by side in the tmux window, with bbr in the right pane.
The prototype builds no Unicode placeholders, so mark the kitty placement cells of the tmux columns `not tested`: the rows `U=1`, scroll, resize, Overlay, and selected path.
Record whether the image leaks into the left pane.

For the external-load key:

1. Open I13 with `BBR_M32_ALLOW_EXTERNAL` unset.
   Confirm that the test server gets no request.
2. Open I13 with `BBR_M32_ALLOW_EXTERNAL=1`.
   Confirm that the request has no `Authorization` header.

For the Bitbucket check with I15:

1. Pick a real PullRequest with a pasted screenshot in a Comment.
2. Run the prototype against it with `BBR_M32_PROBE_LOG` set and no proxy.
   The probe log records each request host and `credential_sent`.
3. Record each request host, its status, and whether it carried the Credential.
   Do not record a URL path, a query string, or Comment text.
4. Work through the checklist of ticket 01, and record each answer.
5. Open the same PullRequest again after one hour and after one day.
   Record whether the image still loads, to check URL expiry.

Store the fixture screenshots in `evidence/` in the M32 directory.
Name each file `<column>-<situation>-<variant>.png`.
Never store a screenshot of a real PullRequest in the repository.

## Acceptance criteria

- [ ] `## Completion` records the prototype commit and every terminal, tmux, and herdr version.
- [ ] Every column of the protocol matrix has a result, or a note that its terminal was not available.
- [ ] `evidence/` has a screenshot of each situation for each column and variant in the steps.
- [ ] `## Completion` has the `summarize` output for each column.
- [ ] The herdr steps are done inside Ghostty and inside one other kitty-protocol terminal.
- [ ] The tmux steps are done with passthrough on and off.
- [ ] The external-load check shows no request with the key off and no Credential with the key on.
- [ ] The Bitbucket check shows every request host and that only `bitbucket.org` image path hops got the Credential.
- [ ] Each item of the ticket 01 checklist has an answer.
- [ ] The URL expiry check after one hour and one day is recorded.
- [ ] No recorded text or screenshot holds a real image URL, Comment text, or Credential value.

## Comments

### Agent notes for the human run

The M32 runner wrote these notes after ticket 03.
No agent ran the prototype, because agents must not start bbr.
So no terminal has shown an image yet. This run is the first real observation.

#### Inputs

- The run guide is [evidence/run-guide.md](../evidence/run-guide.md). It lists the switches, the keys, and where each situation lives.
- The prototype is the branch `m32-image-prototype`. Ticket 03 names its last commit.
- The fixed image set I1 to I14 is in the "Fixed image set" section of the [spec](../SPEC.md). The script generates I1 to I12. I13 and I14 are references in the fixture Review.
- The ReviewCard situations R1 to R12 are in the run guide.
- The protocol matrix and the cells that you check are in [terminal-image-protocols.md](../research/terminal-image-protocols.md). Each such cell has the mark **T04**.
- The Bitbucket checks C1 to C10 are in [bitbucket-comment-images.md](../research/bitbucket-comment-images.md).

#### Two open checks of ticket 03

Do these checks first, in Ghostty or kitty, then set ticket 03 to `resolved`.

1. Variant A shows I1 in the R1 card.
2. Variant B shows I1 in the image preview after `P` on the R1 card.
3. Copy the `summarize` output of this run under `## Completion` in ticket 03, as the first measurement.

#### Record the versions

Run each command that applies, and copy the output under `## Completion`.

```sh
cd /Volumes/Work/t3-code/m32-image-prototype && git log -1 --format='%h %s'
/Applications/Ghostty.app/Contents/MacOS/ghostty --version
kitty --version
wezterm --version
defaults read /Applications/iTerm.app/Contents/Info.plist CFBundleShortVersionString
defaults read /System/Applications/Utilities/Terminal.app/Contents/Info.plist CFBundleShortVersionString
tmux -V
herdr --version
```

#### Commands for each column

Run every command from `/Volumes/Work/t3-code/m32-image-prototype`.
Replace `<column>` with the slug of the column.
The slugs are `ghostty`, `kitty`, `wezterm`, `iterm2`, `tmux-ghostty`, `tmux-iterm2`, `herdr-ghostty`, `herdr-kitty`, and `apple-terminal`.

For each column, run these two passes:

```sh
# Pass 1: Variant A.
BBR_M32_VARIANT=inline \
  BBR_M32_PROBE_LOG="$TMPDIR/m32-<column>-a.log" tools/m32/fixture_review.sh

# Pass 2: Variant B, situations R1, R4, R7, R8, and R9 only.
BBR_M32_VARIANT=preview \
  BBR_M32_PROBE_LOG="$TMPDIR/m32-<column>-b.log" tools/m32/fixture_review.sh
```

After each pass, run `summarize` on its log:

```sh
python3 tools/m32/summarize.py --terminal <column> "$TMPDIR/m32-<column>-a.log"
```

The prototype decodes no pixels, so the `BBR_M32_PNG_PATH` switch is gone.
The "Limits and expected states" section of the run guide lists the state of each image.
On kitty, I3 (JPEG) shows `unsupported`, and I7 (10-frame GIF) shows `too large`.

Add these switches for each column:

| Column | Where to run | Extra switches and steps |
| --- | --- | --- |
| Ghostty | A new Ghostty window. | None. |
| kitty | A new kitty window. | None. |
| WezTerm | A new WezTerm window. | None. Also run pass 2 with `BBR_M32_PROTOCOL=iterm2` to test OSC 1337. |
| iTerm2 | A new iTerm2 window. | None for the kitty path. Also run pass 2 with `BBR_M32_PROTOCOL=iterm2` to test OSC 1337. On iTerm2, I3 shows in the preview, and I7 shows `too large`. |
| tmux in Ghostty | See "tmux" below. | `BBR_M32_TMUX_IMAGES=1` |
| tmux in iTerm2 | See "tmux" below. | `BBR_M32_TMUX_IMAGES=1` |
| herdr in Ghostty | See "herdr" below. | None. |
| herdr in kitty | See "herdr" below. Use WezTerm or iTerm2 if kitty is not available, and add a column for it. | None. |
| Apple Terminal | A new Terminal window. | None. Expect the M23 text and no state. The probe log must show no acquisition line. |

Also run pass 1 once in Ghostty with `BBR_M32_PROTOCOL=none`.
Confirm that the cards show only the M23 text and that the log has no acquisition line.

#### tmux

Use a separate tmux server without your tmux configuration:

```sh
tmux -L m32 -f /dev/null new-session -s m32
```

Inside it, run the passes once with passthrough on and once with it off:

```sh
tmux -L m32 set -g allow-passthrough on
tmux -L m32 set -g allow-passthrough off
```

Use two panes side by side in the tmux window, with bbr in the right pane.
The prototype builds no Unicode placeholders, so mark the kitty placement cells of the tmux columns `not tested`: the rows `U=1`, scroll, resize, Overlay, and selected path.
Record whether the image leaks into the left pane.
bbr deletes only its own placements by id, from a random base id, so it never clears the images of the left pane.
Also run pass 1 without `BBR_M32_TMUX_IMAGES`, and confirm that bbr shows the M23 text.
Stop the server after the column with `tmux -L m32 kill-server`.

#### herdr

1. Start herdr in Ghostty, then in the second kitty-protocol terminal.
2. In a herdr pane, run `echo "$HERDR_ENV $TERM_PROGRAM"`, and record the output.
3. Record whether `terminal.kitty_graphics` is on in your herdr configuration. It is on by default.
4. Run the two passes.
5. Open a herdr popup over an image, then close it (R9).
6. Scroll and resize, and look for stale image copies (R7, R8).
7. Nested cases: run pass 1 in tmux inside a herdr pane, and in herdr inside a tmux session. Record what shows.

#### What to record for each column

- One screenshot of each situation, as the steps of this ticket say.
- The `summarize` output of each pass.
- The filled matrix column, with each cell that differs from ticket 02 marked.
- How readable each image is at 12 rows. If another value is clearly better, rerun R1 to R4 with `BBR_M32_MAX_ROWS=<value>`, and record the value.
- Any stale image copy, an image over a border, a rail, the Anchor Indicator, or the status, and any flicker.
- The startup delay. bbr waits up to 1 second for the kitty query reply.
- Whether an image returns after an External Edit (`Ctrl-e` in the Composer). The probe log has one `event=free` line with `reason=external_edit` for each sent image.
- The `event=proxy` line. It must say `result=direct`. With `result=invalid`, every remote image shows `failed`.

#### Screenshots

Use the macOS window capture from a second terminal:

```sh
EV=/Volumes/Work/t3-code/m32-reviewbody-image-rendering-investigation/.scratch/m32-reviewbody-image-rendering-investigation/evidence
screencapture -i -o -w "$EV/<column>-<situation>-<variant>.png"
```

Click the bbr window after the command starts.
Use `a` or `b` for the variant, for example `ghostty-R5-a-before.png`.
Another way is `Cmd-Shift-4`, then `Space`, then a click on the window.
Never store a screenshot of a real PullRequest.

#### External-load check with I13

Make a trusted local `https` server with `mkcert`:

```sh
brew install mkcert && mkcert -install
mkdir -p "$TMPDIR/m32-i13" && cd "$TMPDIR/m32-i13"
mkcert localhost
python3 /Volumes/Work/t3-code/m32-image-prototype/tools/m32/generate_images.py images
python3 - <<'PY'
import http.server, ssl, functools
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_request(self, code="-", size="-"):
        auth = "yes" if self.headers.get("Authorization") else "no"
        print(f"request status={code} authorization={auth}", flush=True)
server = http.server.HTTPServer(("localhost", 8443), functools.partial(Handler, directory="images"))
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("localhost.pem", "localhost-key.pem")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
```

1. Run pass 1 without `BBR_M32_ALLOW_EXTERNAL`. I13 must show `blocked`, and the server must print no line.
2. Run pass 1 with `BBR_M32_ALLOW_EXTERNAL=1`. I13 must show the image, and the server must print `authorization=no`.

If I13 shows `failed` with the key on, the Zig TLS check probably does not trust the `mkcert` root. Record it.
If the server does not reply in 20 seconds (`max_fetch_ms`), I13 shows `failed`, and the probe log has `status=timeout`.

Only the fixture Review lets I13 reach `localhost:8443`.
On a real PullRequest, `BBR_M32_ALLOW_EXTERNAL=1` loads only a public host name on port 443.
bbr blocks an IP literal, `localhost`, a name without a dot, and every other port.

#### Bitbucket check with I15

Only the human runs this check, because it uses the Credential.

1. Pick a real PullRequest with a pasted screenshot in a Comment.
2. Build the prototype with `zig build -Doptimize=ReleaseSafe`.
3. Start it on the PullRequest as you start bbr every day, with your normal Profile.
   Add `BBR_M32_PROBE_LOG="$TMPDIR/m32-i15.log"` before the command.
4. Run `summarize` on the log. Each network image prints one line for each hop.
   bbr sends the Credential only to `https://bitbucket.org/repo/<segment>/images/<segment>`.
   Every other Bitbucket URL, `api.bitbucket.org` included, shows `blocked` and sends no request.
   A hop line names the host, the host class, the status, and `credential_sent`.
   A host outside the known list shows as `other`.
5. Confirm that `credential_sent=true` appears only on `bitbucket_org` hops.
6. Confirm that the summary shows `event=proxy result=direct`.
7. Work through the checks C1 to C10 of ticket 01, and record each answer.
8. Open the same PullRequest after one hour and after one day. Record whether the image still loads.

Never put a proxy in front of bbr for this check, and never set `http_proxy` or `https_proxy`.
A proxy with a trusted TLS-intercepting root decrypts the `Authorization` header.
On Zig 0.16, a proxy that refuses one CONNECT gets the later requests in clear text.
The probe log already shows each host and `credential_sent`, so this check needs no proxy.
The brief names a logging proxy as one way to see each request host (brief.md line 29).
This ticket uses the other way that line names, the probe log, so do not use the proxy.

The research of ticket 01 predicts that a pasted image in a private Repository does not load with the Credential.
Then I15 shows `failed`, and the hop lines show the status and the sign-in host.
That result is evidence for ticket 05, not a prototype fault.

### Prototype findings not fixed

The M32 prototype fix run left two review findings open on purpose.

- M32P-16, the `postEvent` part. The review asked bbr to release the job and the slot when `postEvent` fails.
  `postEvent` fails only when its task is cancelled (vaxis `Loop.zig:112`, `queue.zig:42-47`).
  `app.zig` never cancels an image task. Quit waits for each image task (`app.zig:209`), and `max_fetch_ms` now bounds that wait.
  The human sees nothing from this path.
  Decision: no fix, because the path cannot happen.
  The External Edit part of M32P-16 is fixed in `8343b29`.
- M32P-9, the DNS part. A public name that resolves to a private address still loads with `BBR_M32_ALLOW_EXTERNAL=1`.
  std http resolves the name itself, so a check before the request can be bypassed.
  The human run uses public hosts only.
  Decision: record it for the production design.

M32P-15 has a fix in `da08e54`, but no test proves the absence of the race.
The build has no thread sanitizer step, and no single-threaded test can show the race.

The human run depends on these prototype fix commits, from `git log --oneline 5d50146..da08e54`:

- `4f11f32` m32: send PNG bytes to kitty and drop zigimg PNG decode (M32P-1)
- `a6c0dee` m32: reject JPEG and GIF on kitty instead of decoding (M32P-2)
- `f9b80a6` m32: limit images to one frame before transmit (M32P-3, M32P-13)
- `35afdb9` m32: cap image entries and retained bytes per Session (M32P-5, M32P-6)
- `c69aea2` http: refuse an https request on a plain proxy fallback (M32P-4)
- `6cf853e` http: follow redirects without leaking Authorization (X-2)
- `ba24a6e` bitbucket: follow next links only on the API origin (M32I-15, X-2)
- `0d032b7` m32: send the Credential only to bitbucket.org image paths (M32I-3)
- `4ff1d3a` m32: test userinfo, port, and encoded host rejection (M32P-8)
- `3081887` m32: prove the Epoch check drops stale image results (M32P-12)
- `a4dec6d` m32: allow only public names on port 443 as external images (M32P-9)
- `1fdd4e1` m32: log the image proxy setup and send nothing on a bad one (M32P-10)
- `5caf6c5` m32: fail a remote image after max_fetch_ms (M32P-11)
- `1ef02bf` m32: delete tmux placements by id from a random id base (M32P-14)
- `8343b29` m32: free sent image ids when External Edit returns (M32P-16)
- `da08e54` m32: write the cell size under the Runtime lock (M32P-15)

### Change log of the run notes

On 2026-11-02, the M32 prototype alignment run removed both proxy steps (M32I-10, M32P-7).
The I15 check now uses only the probe log, which records each host and `credential_sent`.
The C4 request in [bitbucket-comment-images.md](../research/bitbucket-comment-images.md) now reads the Credential from a `--netrc-file`.
So the token is not in the argv of `curl`.

On 2026-11-02, the same run aligned the notes and the run guide with the hardened prototype at `da08e54`.
The Variant A pass is one pass now, because the `BBR_M32_PNG_PATH` switch is gone.
The run guide lists the `m32.Limits` values and the expected state of each image.
It also names the Credential path rule, the external host rule, the `event=proxy` line, and `reason=external_edit`.
I14 shows `failed` on the card, and its acquisition line has `status=relative` (M32I-11).

On 2026-11-02, the same run replaced "Keep one pane" with the two-pane tmux wording (M32I-4).
One pane hides the pane leak that the brief wants the tmux test to find.

On 2026-11-02, the same run added "Prototype findings not fixed" with the M32P-16 and M32P-9 decisions and the fix commits.
