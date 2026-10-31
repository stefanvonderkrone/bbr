# 07: Run the live M30 outside check

Status: ready-for-human
Blocked by: 06
Spec: [M30 spec](../SPEC.md)

## What to build

A human proves M30 on the largest benchmark PullRequest from M28.
This check needs a Bitbucket Credential and a real terminal, so an agent cannot run it.

## Steps

Run each step in a terminal with 30 rows, then repeat it in a terminal with 80 rows.

1. Open PullRequest A. Its id is in `pullrequests.txt` outside the repository.
2. Add at least two Drafts in Files far apart.
   Make sure that the PullRequest has at least one unresolved and one resolved Thread.
3. Pick five Scroll Marks of different kinds.
   For each one, press its track cell, and make sure that the DiffPane shows its Thread, Draft, or File header.
4. Type a Buffer Search query with hits in several Files.
   Pick three hit marks, and make sure that each one leads to a real hit.
5. Clear the query, and make sure that the hit marks go away.
6. Drag the DiffPane thumb from the top to the bottom.
   Make sure that the DiffPane reaches the first and the last row.
7. Drag the pointer past the bottom of the window and past the top.
   Make sure that the DiffPane pins at the last and the first row.
8. Drag the File Tree thumb from the top to the bottom.
9. Open Review Search with a common query, and drag its list thumb from the top to the bottom.
10. Isolate one long File with `o`, and make sure that the thumb and the marks cover only that File.
11. Switch to the SideBySide Layout and back, and make sure that the thumb follows.
12. Resize the terminal during a drag, and make sure that the drag goes on.
13. Scroll with the wheel, and make sure that the wheel works as before.

## Acceptance criteria

- [ ] Every checked mark leads to a real item of its kind, at 30 and at 80 rows.
- [ ] Every drag reaches the first and the last row of its scroll bar.
- [ ] A drag past the window edges pins the scroll at the end.
- [ ] The thumb and the marks follow File isolation, the Layout switch, and the resize.
- [ ] The wheel works as before.
- [ ] Notes on how readable the marks are in a crowded track are recorded for ticket 08.
- [ ] The results, the terminal sizes, and the bbr commit are recorded under `## Completion` in this ticket.

## Agent notes for the human

An agent wrote these notes from the source and the README.
No agent ran bbr or sent a request to Bitbucket.

### Prepare

1. Check out the M30 commit in a clean checkout, and record it:

   ```sh
   git status --short
   git rev-parse HEAD
   ```

   `git status --short` must print nothing.
2. Build bbr:

   ```sh
   zig build -Doptimize=ReleaseFast
   ```

   The build writes the executable to `zig-out/bin/bbr`.
3. Record the source identity with `zig-out/bin/bbr --version`.
4. Run `zig-out/bin/bbr auth status`. It must exit with `0`.
   Add `--profile <name>` to every command if you do not use the default Profile.
5. Keep mouse input on.
   `[input.mouse].enabled` is `true` by default, so remove a `false` value from `config.toml` for this check.

### Set the terminal size

Most xterm-compatible terminals, such as Terminal.app and iTerm2, take a resize request:

```sh
printf '\e[8;30;120t'   # 30 rows, 120 columns
printf '\e[8;80;160t'   # 80 rows, 160 columns
tput lines
```

`tput lines` must print `30` or `80`.
If the terminal ignores the request, set the window size in the terminal settings.

### Open the PullRequest

```sh
zig-out/bin/bbr pr-webapp <PullRequest A>
```

The M28 benchmark uses the same Repository and PullRequest ID.

### Keys

| Work | Key |
| --- | --- |
| Switch the focus between the File Tree and the DiffPane | `Tab` |
| Open Buffer Search | `/` |
| Accept the Buffer Search query | `Enter` |
| Delete the whole Buffer Search query | `Ctrl-U` |
| Cancel the Buffer Search input | `Esc` |
| Next and previous Search Occurrence | `n` and `N` |
| Open Review Search | `g f` |
| Close Review Search | `Esc` |
| Isolate the File at the cursor, and end the isolation | `o` |
| Switch between the Unified and the SideBySide Layout | `s` |
| Start an inline Draft on a source Line | `i` |
| Save the Draft in the Composer | `Ctrl-S` or `Ctrl-D` |
| Open or close a resolved Thread disclosure | `Enter` on the disclosure row |
| Delete the Draft at the cursor | `D`, then confirm |
| Show the help Overlay | `?` |

A saved Draft stays local.
Do not press `X`, because `X` submits the review.
Use `D` only on your own test Drafts, not on a published Comment.

### What to look for

The DiffPane scroll bar is the right border of the DiffPane.
The thumb is the run of `┃` cells.
Each Scroll Mark is one glyph in a track cell:

| Glyph | Scroll Mark | Style off the thumb |
| --- | --- | --- |
| `◆` | Buffer Search hit | Accent color, bold |
| `✎` | Draft | Draft color, bold |
| `●` | Unresolved Thread | Renamed-status color, bold |
| `✓` | Resolved Thread | Added-status color, dim |
| `━` | File header | Border color |

A cell shows only its highest priority Scroll Mark, in the order of this table.
A Scroll Mark on a thumb cell keeps its glyph in the thumb style.
So a thumb can show `┃`, `◆`, and `●` cells together.

Per step:

- Step 2. Add each Draft with `i` on a source Line, type a short body, and save it.
  Each Draft gives a `✎` mark.
  A collapsed resolved Thread gives one `✓` mark on its disclosure row.
  `Enter` on that row opens the Thread, and its mark then covers the root ReviewCard and its Replies.
- Step 3. A press on a mark cell off the thumb jumps the scroll.
  The thumb then covers the pressed cell.
  The item of the mark must be in the visible DiffPane rows.
  The jump centers the pressed cell's first row when it can.
  So the item can be some rows above or below the middle, because one cell can hold many rows.
- Step 4. The mouse does nothing while the Buffer Search input is open.
  Press `Enter` to accept the query before you press a hit mark.
  A Search Occurrence inside a closed Fold has no hit mark.
- Step 5. The hit marks follow the DiffPane search highlights.
  To clear the query, press `/`, type the query, then press `Ctrl-U` in the same input.
  The source shows that an empty query in a later input falls back to the accepted query.
  That is a reading of the source, not a run.
  If the hit marks and the highlights stay after `/` and `Ctrl-U`, record it, and record whether the highlights also stay.
- Steps 6 to 8. The pointer column does not matter during a Scroll Drag.
  The drag follows the pointer row over the other Pane, the status, and outside the window.
- Step 9. The Review Search Results list scroll bar is the `│` thumb in the padding ring right of the list.
  It shows no Scroll Marks.
- Step 10. With an isolated File, the track shows only the rows of that File.
  Only one `━` File header mark shows.
- Step 12. Resize with the `printf` commands from a second shell, or with the window edge.
- Step 13. Scroll with the wheel over the Pane content.
  The wheel over a track does nothing, as before M30.
  This is by design, so it is not a failure.

### Record

Under `## Completion`, record the bbr commit from `git rev-parse HEAD`, the `--version` output, the terminal program, and both terminal sizes.
For ticket 08, record how readable the marks are in a crowded track.
Record whether the thumb style hides the mark kinds, and whether the `━` marks crowd the border.
