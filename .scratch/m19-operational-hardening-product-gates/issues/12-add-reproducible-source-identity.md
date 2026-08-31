# 12 — Add reproducible source identity

**What to build:** Each `bbr` binary reports one reproducible CalVer identity for its source revision. Clean Git builds and complete source-copy builds produce the same identity, while dirty source is visible.

**Blocked by:** 11 — Establish four-target native CI.

**Status:** ready-for-agent

- [ ] Pure build-time logic validates metadata and formats every accepted version as a valid Zig `std.SemanticVersion`.
- [ ] Explicit metadata mode starts when any version metadata variable exists. It requires `SOURCE_DATE_EPOCH`, `BBR_VERSION_COMMIT`, `BBR_VERSION_SEQUENCE`, and `BBR_VERSION_DIRTY` together.
- [ ] Explicit metadata rejects a negative timestamp, a commit other than 40 lowercase hexadecimal characters, an invalid sequence, and a dirty value other than zero or one.
- [ ] Git metadata uses the `HEAD` committer time in UTC, the full commit hash, an exact release tag, and the defined dirty input classes. Ignored files and documentation do not mark a build dirty.
- [ ] The build rejects malformed or conflicting exact tags. An annotated `vYYYY.M.D-N` tag supplies a positive sequence, while an untagged build uses sequence zero.
- [ ] Development, release, and dirty versions follow the specified CalVer and build-metadata forms with a 12-character source hash.
- [ ] The build selects exactly one complete metadata source and injects one version string into the executable.
- [ ] `bbr --version` writes `bbr <version>` and exits successfully before Credential, config, database, network, or terminal startup.
- [ ] Hermetic tests cover valid and invalid metadata, dirty input classes, missing Git data, conflicting tags, wall-clock and time-zone changes, and Git-to-explicit reproduction.
