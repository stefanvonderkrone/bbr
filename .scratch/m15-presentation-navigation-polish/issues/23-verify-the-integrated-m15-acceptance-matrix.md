# Verify the integrated M15 acceptance matrix

Status: ready-for-human

## What to build

Verify M15 as one coherent Presentation and navigation system after every preceding slice is independently complete. Add deterministic cross-feature coverage at the seams and perform direct-terminal, SSH PTY, and tmux smoke checks. Fix integration defects found within the resolved M15 contract, but do not reopen deferred M20 side-selection behavior or pull later milestone work into scope.

## Acceptance criteria

- [x] Frame atomicity, revision consistency, logical restoration, and rollback hold across resize, disclosure, File isolation/focus, Draft save, File Enrichment, Overlay transitions, and forced allocation failure.
- [x] Successful Session replacement performs the canonical reset and failed replacement preserves Session, Frame, focus, cursors, Directory state, disclosures, ReviewCards, Selection, and transient mouse state.
- [x] Unified and SideBySide Layouts cross Changes, fetched-whole, and WholeFile scopes at zero, narrow, ordinary, and wide dimensions with grapheme-safe output and stable navigation.
- [x] RemoteReview and LocalReview workflows cover every CommentScope, ActionAvailability edge, File/fallback placement, tally, Suggestion restriction, Selection, Count, yank, and clipboard outcome.
- [x] Keyboard-only workflows and accepted mouse equivalents pass across Panes, disclosures, File finder, PullRequest Picker, Overlays, loading states, and ignored mouse inputs.
- [x] Configuration defaults, zero semantics, opt-outs, renamed-key rejection, diagnostics, Theme roles, cache behavior, spinner shutdown, and idle blocking pass as an integrated matrix.
- [ ] Direct-terminal, SSH PTY, and tmux smoke checks are recorded with terminal/environment details and cover framing, Unicode widths, keyboard navigation, mouse behavior where supported, Picker loading, and OSC 52 outcomes. Direct and tmux evidence is recorded below; SSH PTY, live Picker loading, interactive mouse delivery, and tmux-client OSC 52 acceptance remain for human verification in a capable environment.
- [x] The complete automated test suite passes, and any environment-limited smoke check is documented with reproducible commands and observed evidence rather than silently skipped.

## Blocked by

- [15 — Establish the atomic Presentation Frame](15-establish-the-atomic-presentation-frame.md)
- [16 — Carry CommentScope end to end](16-carry-commentscope-end-to-end.md)
- [17 — Project Markdown ReviewCards](17-project-markdown-reviewcards.md)
- [18 — Unify review-content disclosures](18-unify-review-content-disclosures.md)
- [19 — Add framed Panes and the Sidebar File Tree](19-add-framed-panes-and-the-sidebar-file-tree.md)
- [20 — Introduce contextual Actions and purpose-shaped Overlays](20-introduce-contextual-actions-and-purpose-shaped-overlays.md)
- [21 — Add keyboard-parity mouse navigation](21-add-keyboard-parity-mouse-navigation.md)
- [22 — Complete Picker feedback and public configuration](22-complete-picker-feedback-and-public-configuration.md)

## Verification

Verified on 2026-08-07 from `b98d917` on macOS 26.5.2 (Darwin 25.5.0,
arm64), Zig 0.16.0, `C.UTF-8`, OpenSSH 10.2p1, and tmux 3.7.

### Deterministic matrix

The complete hermetic suite passes with 413 tests. The integrated seams are
covered by the following acceptance sequences in addition to the blocking
slices' focused tests:

- `Session disclosures toggle independently persist through rebuilds and reset atomically`
  crosses resize, disclosure, Scope changes, File isolation, Draft save,
  Selection restoration, replacement rollback, and canonical replacement.
- `matching File Enrichment is admitted and reprojects whole-file Buffer`,
  `admitted File Enrichment survives failed Buffer reprojection`, and the
  failing-allocator transaction tests cross enrichment, replacement, Frame
  publication, and rollback.
- `M15 Layout Scope and geometry matrix restores a Unicode source row` crosses
  both Layouts, all three Scopes, and `0x0`, `8x2`, `80x24`, and `240x80`
  geometry while checking revision consistency, logical navigation
  restoration, independent grapheme cell widths, exact preservation of
  `é界👩‍💻`, and every projected ReviewCard body segment for split graphemes.
- `Selection overrides Count for yank and clipboard failure is visible`
  verifies that a two-line Selection takes precedence over Count `9`, both
  registers clear after yank, and adapter failure projects the visible failed
  clipboard outcome.
- Remote/Local ActionAvailability, scope authoring/placement/tallies,
  Suggestion/Selection restrictions, Count/yank/clipboard outcomes, keyboard
  Overlay capture, Picker state/ranking, mouse parity/ignored input, strict
  configuration/default/zero/opt-out behavior, every Theme role, cache
  eviction, scoped spinner shutdown, and idle blocking are covered by their
  named Presentation, Buffer, Config, Theme, File Enrichment, Picker, Render,
  and App tests.

The integration pass found one defect. A failed Session replacement completion
cleared a pending mouse press even though the published Frame rolled back. The
new regression `failed Session replacement preserves a pending mouse press`
failed with `expected 2, found 0`; Session completions now preserve the
interaction revision until a candidate actually publishes. The regression and
complete suite pass after the fix.

Commands:

```sh
zig fmt --check src/tui/presentation.zig
zig build test --summary all
```

Observed: `Build Summary: 8/8 steps succeeded; 413/413 tests passed` (158 core
module tests and 255 executable/TUI tests).

### Direct terminal PTY

Command, run in an allocated 80x24 PTY:

```sh
TERM=xterm-256color LANG=C.UTF-8 LC_ALL=C.UTF-8 zig-out/bin/bbr demo
```

Observed: the alternate screen rendered aligned joined `Files`/`Diff` frames,
box-drawing rules, `▾`, `›`, `●`, `→`, `↳`, and `±` at stable widths. `j`,
`gg`, Tab, `F`, Escape, Enter, and `q` navigated rows/Panes, opened/dismissed
the File finder, confirmed keyboard operation, and restored the terminal. The
application enabled SGR cell-coordinate mouse reporting with
`CSI ?1002;1003;1004;1006 h`. Injected SGR mouse press/release bytes through
the harness produced no input event or redraw, so this environment cannot
claim an interactive mouse outcome; the exact click/wheel/cancellation and
ignored-input outcomes pass at the Frame-derived Presentation seam.

After `ggjjjjjjy`, the terminal emitted this OSC 52 source yank (base64 decodes
to four spaces followed by `const timeout = 30;`):

```text
ESC ]52;c;ICAgIGNvbnN0IHRpbWVvdXQgPSAzMDs= ESC \
```

The offline demo intentionally sets `online = false`, so `p` is unavailable
and cannot leave a Picker visibly loading. The real loading projection,
single-cell spinner, matching-scope tick, stale tick, dismissal/population/
failure/shutdown cleanup, timer cancellation, and idle no-polling behavior pass
in `portable Picker input loads summaries and selects a replacement`, `Picker
tick advances only its visible loading scope`, `shutdown closes Picker and
disposes its late completion`, `loading Picker spinner advances one fixed-width
glyph per scoped tick`, `picker overlay draws the query line and highlights
the selection`, `a loading picker shows its single-glyph spinner beside the
placeholder`, and the App scheduler tests. Reproduce a live visual check where
Bitbucket credentials and a repository are available with:

```sh
BITBUCKET_USERNAME=… BITBUCKET_TOKEN=… BITBUCKET_WORKSPACE=… \
  TERM=xterm-256color zig build run -- <repo-slug> <pr-id>
# press p while the open-PullRequest list is in flight
```

### tmux PTY

Commands:

```sh
tmux new-session -d -s m15-issue23-smoke -x 100 -y 30 \
  'cd /Volumes/Work/t3-code/zig-tui-pull-request-reviewer && TERM=tmux-256color LANG=C.UTF-8 LC_ALL=C.UTF-8 zig-out/bin/bbr demo'
tmux capture-pane -p -t m15-issue23-smoke -S 0
tmux send-keys -t m15-issue23-smoke j j F
tmux capture-pane -p -t m15-issue23-smoke -S 0
```

Observed: tmux reported a `100x30` Pane and `mouse=1`; both captures retained
aligned Unicode Pane frames, disclosure glyphs, tallies, diff gutters, and the
status line. Keyboard navigation advanced from `1/24` to `3/24`, and the File
finder appeared with `src/server.zig` and `README.md`. The session was exited
and removed. A terminal outside tmux is required to confirm whether that
terminal accepts tmux-forwarded OSC 52; the application-level OSC 52 payload
was confirmed in the direct PTY and its success/failure completion is covered
deterministically.

### SSH PTY limitation

Command:

```sh
ssh -o BatchMode=yes -o ConnectTimeout=3 localhost \
  'printf "SSH_TTY=%s TERM=%s LANG=%s\\n" "$SSH_TTY" "$TERM" "$LANG"'
```

Observed exactly: `ssh: connect to host localhost port 22: Connection refused`
(exit 255). No `sshd` process or SSH socket is present, so an SSH PTY cannot be
created on this host. On an SSH-enabled host, reproduce with:

```sh
ssh -t <host> 'cd <checkout> && TERM=xterm-256color LANG=C.UTF-8 zig-out/bin/bbr demo'
```

Repeat the direct-PTY keyboard, mouse-if-forwarded, Picker-with-credentials,
and `y` checks, recording `$SSH_TTY`, `$TERM`, locale, terminal name/version,
and whether the client accepts the OSC 52 payload.
