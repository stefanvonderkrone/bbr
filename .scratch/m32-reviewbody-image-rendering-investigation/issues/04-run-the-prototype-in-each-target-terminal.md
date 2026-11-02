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
3. Repeat the situations with the PNG path set to `f=100`.
4. Open the fixture Review in Variant B, and go through R1, R4, R7, R8, and R9.
5. Run `summarize` on the probe log, and copy its output into `## Completion`.
6. Fill the matrix column with the observed results.
   Mark each cell that differs from ticket 02.
7. Write down how readable each image is at the start size of 12 rows.
   If a different maximum makes the images clearly better, record that value and run R1 to R4 again with it.

For herdr, also do these steps:

1. Run herdr inside Ghostty and inside one other kitty-protocol terminal.
2. Open an herdr popup over an image, then close it.
3. Scroll and resize, and look for stale image copies.
4. Record whether `terminal.kitty_graphics` was on.

For tmux, run it once with `allow-passthrough on` and once with it off.

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

For each column, run these three passes:

```sh
# Pass 1: Variant A, PNG decode in bbr.
BBR_M32_VARIANT=inline BBR_M32_PNG_PATH=zigimg \
  BBR_M32_PROBE_LOG="$TMPDIR/m32-<column>-a-zigimg.log" tools/m32/fixture_review.sh

# Pass 2: Variant A, PNG bytes to the terminal.
BBR_M32_VARIANT=inline BBR_M32_PNG_PATH=f100 \
  BBR_M32_PROBE_LOG="$TMPDIR/m32-<column>-a-f100.log" tools/m32/fixture_review.sh

# Pass 3: Variant B, situations R1, R4, R7, R8, and R9 only.
BBR_M32_VARIANT=preview \
  BBR_M32_PROBE_LOG="$TMPDIR/m32-<column>-b.log" tools/m32/fixture_review.sh
```

After each pass, run `summarize` on its log:

```sh
python3 tools/m32/summarize.py --terminal <column> "$TMPDIR/m32-<column>-a-zigimg.log"
```

Add these switches for each column:

| Column | Where to run | Extra switches and steps |
| --- | --- | --- |
| Ghostty | A new Ghostty window. | None. |
| kitty | A new kitty window. | None. |
| WezTerm | A new WezTerm window. | None. Also run pass 3 with `BBR_M32_PROTOCOL=iterm2` to test OSC 1337. |
| iTerm2 | A new iTerm2 window. | None for the kitty path. Also run pass 3 with `BBR_M32_PROTOCOL=iterm2` to test OSC 1337. |
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

Keep one pane in the window, because placement is correct only for a pane at the top-left.
Also run pass 1 without `BBR_M32_TMUX_IMAGES`, and confirm that bbr shows the M23 text.
Stop the server after the column with `tmux -L m32 kill-server`.

#### herdr

1. Start herdr in Ghostty, then in the second kitty-protocol terminal.
2. In a herdr pane, run `echo "$HERDR_ENV $TERM_PROGRAM"`, and record the output.
3. Record whether `terminal.kitty_graphics` is on in your herdr configuration. It is on by default.
4. Run the three passes.
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
- Whether an image returns after an External Edit (`Ctrl-e` in the Composer).

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

#### Bitbucket check with I15

Only the human runs this check, because it uses the Credential.

1. Pick a real PullRequest with a pasted screenshot in a Comment.
2. Build the prototype with `zig build -Doptimize=ReleaseSafe`.
3. Start it on the PullRequest as you start bbr every day, with your normal Profile.
   Add `BBR_M32_PROBE_LOG="$TMPDIR/m32-i15.log"` before the command.
4. Run `summarize` on the log. Each network image prints one line for each hop.
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

The research of ticket 01 predicts that a pasted image in a private Repository does not load with the Credential.
Then I15 shows `failed`, and the hop lines show the status and the sign-in host.
That result is evidence for ticket 05, not a prototype fault.

### Change log of the run notes

On 2026-11-02, the M32 prototype alignment run removed both proxy steps (M32I-10, M32P-7).
The I15 check now uses only the probe log, which records each host and `credential_sent`.
The C4 request in [bitbucket-comment-images.md](../research/bitbucket-comment-images.md) now reads the Credential from a `--netrc-file`.
So the token is not in the argv of `curl`.
