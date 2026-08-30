# Define the M19 CI gate

Type: grilling
Status: resolved
Blocked by: none

## Question

Which required GitHub Actions checks, runner targets, Zig 0.16.0 installation rules, cache rules, and failure policies must prove `zig build test --summary all` and `zig fmt --check` without moving credential-gated Bitbucket checks into required CI?

## Answer

Replace `Grammar Targets` with one `CI` workflow. Run it for every pull request, every push to `main`, and manual dispatch. Use concurrency keyed by the workflow and pull request or ref, and cancel an older run when a newer commit supersedes it.

Keep the four native M17 targets as required checks:

- `macos-15-intel` for macOS x86_64
- `macos-15` for macOS aarch64
- `ubuntu-24.04` for Linux x86_64
- `ubuntu-24.04-arm` for Linux aarch64

Name the jobs `CI / test (<target>)` so branch protection can require each target. Every target runs the existing RE2 wrapper, dynamic UserGrammar load, UserGrammar CLI lifecycle, and `zig build test --summary all` steps. The Linux x86_64 job also runs `zig fmt --check build.zig src tests`. A separate format job would repeat runner and toolchain setup without adding target coverage.

Install Zig 0.16.0 exactly. Pin the current actions to immutable commits and retain version comments:

- `actions/checkout` v7.0.1 at `3d3c42e5aac5ba805825da76410c181273ba90b1`
- `step-security/setup-zig` v2.2.2 at `1e9fbd457bcc3587b58845344a267f12f151709c`

Do not add an update bot. An action update must select a release, resolve its commit, update the commit and version comment together, and pass all four checks.

Use the setup action's Zig cache with `matrix.target` in the cache key and a 2 GiB limit per target. The target key separates native C and C++ artifacts across architectures. The four limits total 8 GiB, below GitHub's current 10 GiB cache allowance. The public repository uses standard hosted runners, so these jobs do not consume billed runner minutes. Upload no CI artifacts by default.

Set `fail-fast: false` and a 45-minute timeout for each target. Do not use `continue-on-error` or automatic job retries. A compiler download, cache, dependency, runner, format, build, or test failure fails its target check. A maintainer may rerun an infrastructure failure, but branch protection receives no synthetic success.

Set workflow permissions to `contents: read`. Do not provide Bitbucket Credentials or other secrets. Keep `zig build check`, `check-blobs`, `check-mutation`, and other live Bitbucket checks outside GitHub Actions as explicit local opt-ins. They are not required merge checks.

The accepted format command passes in the current worktree. The implementation is complete when all four named checks pass on a pull request and a `main` push, branch protection requires all four, stale runs cancel, and the workflow logs contain no Credential values.
