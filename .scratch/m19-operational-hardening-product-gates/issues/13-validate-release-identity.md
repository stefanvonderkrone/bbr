# 13 — Validate release identity

**What to build:** A release tag push proves that the tag, package, executable, and source-copy build describe one source revision. Validation publishes no artifact or release record.

**Blocked by:** 12 — Add reproducible source identity.

**Status:** done

- [x] A separate workflow runs for `v*` tag pushes and fetches complete tag history.
- [x] Validation requires one annotated triggering tag that points directly at `HEAD` and matches `vYYYY.M.D-N`.
- [x] The tag date matches the UTC committer date. Its sequence is the next sequence for that date, with no reuse or skip.
- [x] The package version and executable hashless version match the release tag.
- [x] Validation rejects a dirty checkout, malformed or conflicting tags, a wrong date, a reused or skipped sequence, and a package mismatch.
- [x] Validation builds from Git metadata and from a source copy without Git data. Complete explicit metadata produces the same executable version.
- [x] Controlled tests or validation fixtures cover each accepted and rejected release case.
- [x] The workflow uploads no binary, archive, source copy, release record, or other artifact.
