# Define the external-editor handoff

Type: grilling
Status: resolved
Blocked by: 04

## Question

How should the Composer's contextual `Ctrl-E` Action resolve `$EDITOR`, create and clean up a secure temporary file, transfer prefilled UTF-8 content, suspend and restore vaxis and the terminal, distinguish unchanged/cancelled/failed edits, return accepted bytes through `Composer.seed`, and expose deterministic commands and completions without making Presentation perform process or terminal I/O?

## Answer

Treat `Ctrl-E` as a Composer-only External Edit Action. Presentation emits an owned, correlated External Edit command containing a unique handoff identity and an exact snapshot of the current Composer body, marks that Composer as awaiting completion, and accepts only the matching typed completion. While pending, no Composer input is accepted. Production executes this command synchronously at the terminal adapter boundary; deterministic tests inspect the command and dispatch scripted completions without environment, filesystem, process, terminal, thread, or PTY access. Presentation performs none of that I/O.

Resolve the first non-empty editor command in this order: `GIT_EDITOR`, `VISUAL`, then `EDITOR`. Treat all three identically. If none is set, complete non-fatally with `External edit unavailable: none of GIT_EDITOR, VISUAL, or EDITOR is set`. Interpret the selected value with `/bin/sh -c`, append the temporary-file path as a separately passed and safely quoted positional argument, and inherit the editor's stdin, stdout, stderr, and working directory. A missing `/bin/sh` is likewise non-fatal and produces `External edit unavailable: /bin/sh was not found` without creating a file or suspending the terminal.

Before handing over the terminal, create an exclusively named, owner-only temporary directory and an exclusive `0600` Markdown file within it. Write the current Composer body byte-for-byte: no BOM, trailing newline, or newline normalization. Do not suspend the terminal until editor resolution and file preparation succeed. Then stop the vaxis input loop, disable mouse reporting when enabled, exit the alternate screen, restore cooked terminal mode, and synchronously run the editor with inherited stdio. Existing workers may finish and queue completions, but bbr dispatches none and issues no further commands until External Edit completes. Afterward, recreate the Tty and input loop, re-enter the alternate screen, restore mouse mode, dispatch current geometry, and force a complete redraw before ordinary queued events resume.

Accept returned content only when the editor exits with code `0`, the bytes differ from the original snapshot, the file does not exceed the configured External Edit byte limit, and the result is valid UTF-8 containing no NUL byte. The limit defaults to 1 MiB and zero is invalid; its exact public TOML table/key spelling is deliberately deferred to [Choose the external-editor configuration language](15-choose-external-editor-configuration-language.md). Empty and whitespace-only valid content may enter the still-open Composer, whose existing save validation continues to refuse a blank body.

Classify a successful exit with identical bytes as `unchanged`. Classify termination by `SIGINT` or `SIGTERM` as `cancelled`. Classify a nonzero exit, any other signal, a stopped or unknown child outcome, spawn/read/validation/size failure, or adapter failure as `failed`. Only an accepted changed result owns bytes for Presentation. Apply those bytes through an atomic `Composer.seed`: reserve sufficient capacity before replacing anything, so allocation failure preserves the original body and reports failure rather than partially clearing it.

Keep the Composer open after every non-fatal outcome and project one non-modal footer message until the next Composer Action: `External edit applied`, `External edit unchanged`, `External edit cancelled`, or `External edit not applied: <specific reason>`. Invalid UTF-8, NUL content, an oversized file, missing editor configuration, missing shell, process failure, and allocation failure each name their reason. No second Overlay and no global-status-only result is used.

Attempt file and directory cleanup on every ordinary path. If valid changed content was accepted but cleanup alone fails, still apply it and show `External edit applied; temporary file remains at <path>`. A failure to restore the terminal is fatal: make one final best-effort restoration attempt, deliberately retain the temporary file, report its path on the primary screen, and exit nonzero rather than dispatching the result into a partially restored TUI.
