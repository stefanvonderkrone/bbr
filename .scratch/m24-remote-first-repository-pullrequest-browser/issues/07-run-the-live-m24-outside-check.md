# 07: Run the live M24 outside check

Status: ready-for-human
Blocked by: 06
Spec: [M24 spec](../SPEC.md)

## What to build

A human proves M24 on the real Workspace.
This check needs a Bitbucket Credential and real Repositories, so an agent cannot run it.

## Steps

Shape check:

1. Run `bbr check-browser` with no argument.
2. Run `bbr check-browser <repo-slug>` on a Repository with an approved PullRequest and a PullRequest with changes requested.
3. Compare the printed counts with the Bitbucket web UI.

Startup:

1. On a branch with one open PullRequest, run `bbr`. Make sure that its review Session opens.
2. On a branch with no open PullRequest, run `bbr`. Make sure that the Browser opens with the Repository expanded and focused.
3. In a directory outside Git, run `bbr`. Make sure that the plain Browser opens with no note.
4. Run `bbr detect` in each of the three places, and record each outcome line.
5. Press `q` during the Detecting Frame. Make sure that bbr exits.

Browser:

1. Delete `$XDG_STATE_HOME/bbr/browser-cache.json`.
   Measure the time from `bbr` outside Git to the first Browser frame with rows.
2. Quit and run `bbr` again. Measure the time to the first frame with cached rows.
3. Route bbr through an HTTPS proxy that logs requests.
   Expand every Repository one by one, and count the requests.
4. Make sure that no response is a `429`.
5. Open a PullRequest with Enter, press `b`, and make sure that the expansion, Selection, and scroll are the same.
6. Press `s` twice, and make sure that the cursor stays on the same row.

## Acceptance criteria

- [ ] `bbr check-browser` shows participant counts that match the web UI, or the gap is recorded.
- [ ] Each startup place opens the outcome that the spec requires.
- [ ] Each `bbr detect` line matches the TUI outcome.
- [ ] The cold and cached times to the first Browser frame are recorded.
- [ ] The request count for a full expansion is recorded, and no `429` occurs.
- [ ] The return with `b` and both Sort changes keep the Browser state.
- [ ] The results, the Workspace, and the bbr commit are recorded under `## Completion` in this ticket.

## Comments

### Agent handoff for the human

The agents finished tickets 01 to 06 on branch `m24-remote-first-repository-pullrequest-browser`.
The hermetic suite passes with 1440 tests.
No agent called the live Bitbucket API on purpose.
Ticket 06 notes one accidental run of plain `bbr` with piped output.
That run made no Summary Cache file.

Prepare the build:

```sh
cd /Volumes/Work/t3-code/m24-remote-first-repository-pullrequest-browser
zig build
export BBR=$PWD/zig-out/bin/bbr
git rev-parse --short HEAD
```

Record the commit from the last command under `## Completion`.
Use your normal Credential, for example a saved profile or `--profile <name>`.

Shape check:

```sh
$BBR check-browser
$BBR check-browser <repo-slug>
echo "exit: $?"
```

- Each command prints the Repository count, the PullRequest count, and the participant fields that it saw.
- A non-zero exit means that a required field is missing. Record the missing field.
- If the output says that the participant fields are unproven, no PullRequest had a participant. Use a Repository with reviewed PullRequests.
- Compare the approval and changes-requested counts with the Bitbucket web UI.
- Record the result in `src/bitbucket/IMPLEMENTATION.md`. It now marks the participant shape as unproven.

Startup, in three places:

```sh
cd <WorkingCopy on a branch with one open PullRequest> && $BBR detect && $BBR
cd <WorkingCopy on a branch with no open PullRequest> && $BBR detect && $BBR
cd /tmp && $BBR detect && $BBR
```

- `bbr detect` writes to stderr. Expect `resolved: open <repo> #<id>`, then `resolved: browser <repo> expanded`, then `resolved: browser`.
- The TUI must open the same outcome. The first place shows "Detecting PR for <branch>…" for a short time.
- Press `q` in the Detecting Frame. bbr must exit at once.

Browser timing:

```sh
rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/bbr/browser-cache.json"
cd /tmp && time $BBR   # quit with q when the first rows show
cd /tmp && time $BBR   # cached rows must show before the network completes
ls -l "${XDG_STATE_HOME:-$HOME/.local/state}/bbr/browser-cache.json"
```

- `time` measures the full run. Quit with `q` as soon as rows show, and note the time to the first rows by eye or with a screen recording.
- The file mode must be `-rw-------`.
- The file must hold no token, no description, and no URL.

Request count:

```sh
HTTPS_PROXY=http://127.0.0.1:8080 $BBR   # for example with mitmproxy: mitmdump -p 8080
```

- bbr reads `HTTPS_PROXY` through `initDefaultProxies`. A proxy with TLS interception needs its CA in the system trust store.
- Expand every Repository one by one with `l` or Enter. Count the requests in the proxy log.
- No response may be a `429`. At most two PullRequest list requests may be in flight at one time.

Return and Sort:

- Press Enter on a PullRequest entry. Its review Session opens.
- Press `b`. The expansion, the Selection, and the scroll must be the same as before.
- Press `s` two times. The cursor must stay on the same entry after each press.

When all checks pass, add `## Completion` with the results, the Workspace, and the commit.
Then set this ticket and the SPEC to `Status: resolved`.
