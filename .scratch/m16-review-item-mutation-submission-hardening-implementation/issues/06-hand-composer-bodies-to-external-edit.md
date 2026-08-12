# 06 — Hand Composer bodies to External Edit

**What to build:** Let a reviewer press `Ctrl-E` inside any Composer to edit its exact current body with the configured external program. bbr securely hands over the terminal, validates the returned file, restores the TUI, and atomically reseeds the still-open Composer without saving or publishing the Review item.

**Blocked by:** 01 — Canonicalize Review identity and command correlation.

**Status:** ready-for-human

- [x] `Ctrl-E` resolves to External Edit only in the Composer Interaction Context and leaves the existing DiffPane binding unchanged.
- [x] Presentation emits one correlated command containing the exact Composer body snapshot, refuses Composer input while pending, and accepts only the matching completion.
- [x] Editor resolution uses the first non-empty `GIT_EDITOR`, `VISUAL`, or `EDITOR`; missing configuration or `/bin/sh` is a non-fatal Composer footer result.
- [x] The adapter creates an exclusive owner-only temporary directory and `0600` Markdown file and writes exact bytes without BOM, newline insertion, or normalization.
- [x] The adapter exits the alternate screen, restores cooked terminal mode, runs the editor synchronously with inherited stdio and working directory, then recreates input, restores mouse mode and geometry, and fully redraws before queued dispatch resumes.
- [x] Changed content is accepted only after exit code zero, raw-byte size validation, UTF-8 validation, and NUL rejection; unchanged, cancelled, and failed outcomes remain distinct.
- [x] Composer reseed is atomic and preserves the old body on allocation failure; every non-fatal outcome keeps the Composer open with a specific footer message.
- [x] Cleanup is attempted on every ordinary path; accepted content survives cleanup-only failure with the retained path reported, while terminal restoration failure exits nonzero and reports the retained file.
- [x] Configuration exposes only `[external_edit].max_bytes`, defaults to 1048576, rejects zero and invalid values precisely, and documents it as a local returned-file limit.
- [ ] Deterministic Presentation and adapter tests cover correlation, stale completion, editor precedence, safe shell arguments, permissions, exact bytes, validation, process outcomes, cleanup, and restoration failure; an opt-in PTY smoke verifies the real terminal handoff. Automated coverage is present; the real-terminal PTY smoke remains for human verification.
