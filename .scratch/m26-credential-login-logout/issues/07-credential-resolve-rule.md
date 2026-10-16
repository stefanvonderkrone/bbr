# 07: Credential resolve rule

**What to build:** Every remote entry point resolves one Credential from per-field environment overlay on the selected Profile, so partial exports keep working and complete exports survive broken storage.

**Blocked by:** 06 Auth storage safety.

**Status:** done

- [x] Empty environment values count as missing; partial sets fill the rest from the file; complete sets resolve without the file and bypass absent, malformed, or unreadable files.
- [x] File errors surface only when the environment cannot complete the Credential; otherwise resolution succeeds silently.
- [x] Profile selection order is positional arg, `--profile`, `BBR_PROFILE`, Active Profile, then `default`; a complete environment set needs no base Profile.
- [x] One resolve path serves remote review, auth status, and API commands; the API Workspace flag overrides only the Workspace field after the shared resolve.
- [x] Hermetic tests prove precedence, empty-means-missing, partial fill, complete-without-file, and broken-file rescue; existing TOML round-trip tests receive credit, not duplicates.

## Comments

Implemented on `m26-auth-integration` (`ceb8698`). `resolve` keeps per-field
environment overlay with empty-means-missing. A complete environment set
bypasses absent, malformed, and unreadable files and needs no base Profile.
File errors propagate only when the environment is incomplete. Profile order
(positional, `--profile`, `BBR_PROFILE`, Active, `default`) and the API
single-field Workspace override are unchanged. New tests: complete-env rescue
and incomplete-env error surfacing. Suite 1113/1113.
