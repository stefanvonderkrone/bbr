# M19 operations and product contract

M19 defines the required build gates, source identity, Credential handling, HTTP policy,
Candidate Session acquisition, and Reviewer Verdict Actions. Required checks are hermetic.
Live Bitbucket checks remain explicit local opt-ins.

## Required CI

`.github/workflows/ci.yml` runs for each pull request, each push to `main`, and each manual
dispatch. Branch protection requires these stable jobs:

- `CI / test (macos-x86_64)`
- `CI / test (macos-aarch64)`
- `CI / test (linux-x86_64)`
- `CI / test (linux-aarch64)`

Each job uses Zig 0.16.0 on a native runner. Each job checks the native target, the RE2 wrapper,
dynamic UserGrammar loading, the UserGrammar CLI lifecycle, and `zig build test --summary all`.
The Linux x86_64 job also runs `zig fmt --check build.zig src tests`.

Required CI has read-only repository access. It receives no Bitbucket Credential, runs no live
check, and uploads no artifact. A newer run cancels an obsolete run for the same change. A failure
on one target does not cancel the other targets.

## Build identity

`bbr --version` prints `bbr <version>` and exits before Credential, config, database, network, or
terminal startup. The version uses the UTC date of the source commit, a release sequence, and the
first 12 characters of the source commit hash:

```text
YYYY.M.D-0+g<hash>
YYYY.M.D-N+g<hash>
YYYY.M.D-N+g<hash>.dirty
```

Git builds read the commit time, hash, exact annotated release tag, and source-input dirty state.
Source-copy builds require all four explicit values:

- `SOURCE_DATE_EPOCH`
- `BBR_VERSION_COMMIT`
- `BBR_VERSION_SEQUENCE`
- `BBR_VERSION_DIRTY`

If one explicit value exists, all four values are required. The build never combines explicit and
Git metadata. Documentation changes and ignored files do not mark a build dirty.

## Release validation

`.github/workflows/release.yml` runs for a `v*` tag push. It requires an annotated
`vYYYY.M.D-N` tag that points directly at `HEAD`. The tag date must match the commit's UTC date, and
the sequence must be the next sequence for that date.

The workflow also checks the clean checkout, `build.zig.zon`, `bbr --version`, and a source-copy
build without `.git`. Git metadata and explicit metadata must produce the same version. Release
validation publishes no binary, archive, source copy, GitHub release, or other artifact.

## Credential handling

Remote operations read one Credential from these environment variables:

- `BITBUCKET_USERNAME` contains the Atlassian account email.
- `BITBUCKET_TOKEN` contains the Atlassian API token.
- `BITBUCKET_WORKSPACE` contains the Bitbucket Workspace.

bbr does not store a Credential and has no login flow. Do not put these values in repository files
or command arguments. Diagnostics omit Credential data, Authorization values, proxy authentication,
and token-bearing URLs.

On macOS, a local wrapper can read the token from Keychain and start bbr:

```sh
#!/bin/sh
BITBUCKET_USERNAME='<email>' \
BITBUCKET_TOKEN="$(security find-generic-password -w -s '<keychain-service>' -a '<keychain-account>')" \
BITBUCKET_WORKSPACE='<workspace>' \
exec zig build run -- "$@"
```

Replace each placeholder. Keep the wrapper outside the repository, and do not enable shell tracing.
This wrapper keeps the token out of repository files and shell history. It remains a macOS-specific
bridge until M26.

## HTTP and proxy policy

`StdHttpClient` is the only production `HttpClient` adapter. It loads `HTTP_PROXY`, `HTTPS_PROXY`,
and `ALL_PROXY`, including lowercase forms, through `initDefaultProxies`. bbr has no proxy setting.

Invalid proxy URLs and unsupported proxy schemes stop the operation. A non-empty `NO_PROXY` or
`no_proxy` value also stops the operation when a proxy is configured because Zig does not apply the
bypass list. A bypass-only environment permits direct access. A configured proxy failure never
retries through a direct connection. Transport failures remain distinct from Bitbucket `ApiError`
values.

M19 adds no libcurl adapter. `HttpClient` remains the replacement boundary if a measured proxy
requirement later needs another adapter.

## Candidate Session acquisition

Remote Candidate Session acquisition uses one `StdHttpClient` connection pool and at most two
active requests. PullRequest, RawDiff, and Comments acquisition is required. Authenticated Account
acquisition is independent, so its failure can still produce a read-only Candidate Session.

Comments wait for PullRequest commit data and take priority over RawDiff when both can start.
Acquisition reports required failures in PullRequest, RawDiff, and Comments order. Every started
request completes before shared state is destroyed. The scheduler does not cancel branches, and
users cannot configure its concurrency. Local Candidate Session acquisition is unchanged.

The live gate ran on 2026-09-01 with ten alternating sequential and bounded loads per PullRequest:

| PullRequest | Sequential median | Bounded median | Reduction | Maximum connections | Failures | 429 responses |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1856 | 2,220 ms | 1,417 ms | 36% | 2 | 0 | 0 |
| 1726 | 2,045 ms | 1,256 ms | 38% | 2 | 0 | 0 |

Both PullRequests passed the required 30% reduction. Production therefore uses bounded acquisition.

## Reviewer Verdict Actions

For an open remote PullRequest, the status bar shows `Approved`, `Changes requested`, `No verdict`,
or `Verdict unavailable`. LocalReview shows no Reviewer Verdict segment.

The default configurable Actions are:

- `g a` sets Approved.
- `g c` sets Changes Requested.
- `g n` sets No Verdict.

The Actions use no confirmation Overlay. Presentation refuses an Action for a LocalReview, a closed
PullRequest, missing identity or verdict data, the PullRequest Author, an unchanged target verdict,
or a busy remote-write lane. The help Overlay keeps each unavailable Action visible with its reason.

A verdict change is a PullRequest-qualified Durable Operation. It checks SourceCommit before the
mutation and never retries the mutation automatically. Submission, published Comment mutation, and
Reviewer Verdict changes share one global remote-write lane. Session replacement does not cancel
authorized work or project its result into another PullRequest.

M19 adds no merge Action or decline Action.

## Optional live checks

Set the three Credential variables before a remote check. Use only a disposable PullRequest for a
destructive check.

```sh
zig build check -- <repository> <pull-request-id>
BBR_ALLOW_LIVE_ACQUISITION_GATE=1 zig build check-acquisition
BBR_ALLOW_LIVE_MUTATION=1 zig build check-mutation -- <repository> <pull-request-id>
BBR_ALLOW_LIVE_MUTATION=1 zig build check-verdict -- <repository> <pull-request-id>
```

`check-verdict` refuses a PullRequest opened by the Authenticated Account. It changes the Reviewer
Verdict, reacquires the PullRequest, and restores the initial verdict. Cleanup makes a best-effort
restore after a failure. Required CI never runs these commands.
