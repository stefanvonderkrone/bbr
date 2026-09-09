# Define Selected Version source Actions

Type: grilling
Status: ready-for-human
Blocked by: 01, 02

## Question

How should `select_old_version`, `select_new_version`, and `yank` behave for cursor restoration, Count, Selection, wrapped Lines, paired and unpaired SideBySide rows, unavailable content, and mouse parity?

The answer must replace M15's provisional new-side-first yank rule. It must define which selected-version Lines each visual row owns, how source order remains stable, when Selection clears, what cursor target survives a WholeFile rebuild, and which refusal Presentation reports when no selected-version source is available.
