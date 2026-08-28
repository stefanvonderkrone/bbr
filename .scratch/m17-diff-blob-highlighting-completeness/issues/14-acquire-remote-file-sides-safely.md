# 14 — Acquire Remote File Sides Safely

**What to build:** Acquire each expected remote File side from the correct commit and path. Preserve opaque bytes and report path, UTF-8, and Bitbucket failures per side without discarding a successful opposite side.

**Blocked by:** 12 — Add File Content Status and Status Placeholders.

**Status:** done

- [x] Old content uses the destination commit and old path, new content uses the source commit and new path, and absent sides are not requested.
- [x] Git-quoted paths are normalized, repository-relative paths are required, and each path segment is percent-encoded while `/` separators remain intact.
- [x] Spaces, Unicode, quotes, and reserved URL characters work, while malformed and non-repository-relative paths become a typed unavailable reason.
- [x] Successful responses remain opaque bytes until UTF-8 validation; empty bytes are valid text and invalid UTF-8 makes only that side unavailable with its byte size.
- [x] `not_found` and each classified ApiError remain distinct from an absent side, and a successful opposite side stays usable.
- [x] The opt-in credential-gated blob checker compares exact commit, path, type, size, attributes, and raw length and reports skipped fixture classes outside the default suite.
