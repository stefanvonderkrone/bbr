# 11 — Establish four-target native CI

**What to build:** Every pull request, push to `main`, and manual run reports the complete required result for each supported native target. A target-specific failure blocks merge without exposing a Bitbucket Credential.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] CI exposes four stable jobs named `CI / test (<target>)` for macOS x86_64, macOS aarch64, Linux x86_64, and Linux aarch64 on the specified native runners.
- [ ] Every job uses Zig 0.16.0 and runs the native target check, RE2 wrapper check, dynamic UserGrammar load, UserGrammar CLI lifecycle, and complete test suite.
- [ ] Linux x86_64 also checks the format of build, source, and test inputs.
- [ ] CI runs for pull requests, pushes to `main`, and manual dispatch. A newer run cancels an obsolete run for the same change.
- [ ] One target failure does not cancel the other targets. Each job has a 45-minute timeout, no retry, no `continue-on-error`, and no artifact upload.
- [ ] Required CI has read-only repository permission and receives no Bitbucket Credential.
- [ ] Checkout and Zig setup actions use the specified immutable commits, with version comments beside each commit.
- [ ] Each target has a separate cache key and a 2 GiB cache limit. Native artifacts cannot cross target boundaries.
- [ ] Branch protection requires all four stable job names.
