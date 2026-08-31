# 13 — Validate release identity

**What to build:** A release tag push proves that the tag, package, executable, and source-copy build describe one source revision. Validation publishes no artifact or release record.

**Blocked by:** 12 — Add reproducible source identity.

**Status:** ready-for-agent

- [ ] A separate workflow runs for `v*` tag pushes and fetches complete tag history.
- [ ] Validation requires one annotated triggering tag that points directly at `HEAD` and matches `vYYYY.M.D-N`.
- [ ] The tag date matches the UTC committer date. Its sequence is the next sequence for that date, with no reuse or skip.
- [ ] The package version and executable hashless version match the release tag.
- [ ] Validation rejects a dirty checkout, malformed or conflicting tags, a wrong date, a reused or skipped sequence, and a package mismatch.
- [ ] Validation builds from Git metadata and from a source copy without Git data. Complete explicit metadata produces the same executable version.
- [ ] Controlled tests or validation fixtures cover each accepted and rejected release case.
- [ ] The workflow uploads no binary, archive, source copy, release record, or other artifact.
