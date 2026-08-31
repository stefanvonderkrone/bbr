# M19 operational hardening and product gates

Status: ready-for-agent

## Problem Statement

bbr has a stable review workflow, but several operational and product decisions remain outside the implemented contract. Required CI does not yet prove the full native target set. Builds have no reproducible source identity. Credential use needs documented containment. Corporate network support, Candidate Session fan-out, and PullRequest lifecycle Actions still depend on measured decisions.

Without one integrated contract, changes in these areas can weaken Credential safety, add unsupported dependencies, produce non-reproducible binaries, or let remote mutations act on a changed SourceCommit.

## Solution

M19 adds four required native CI checks, reproducible CalVer build identity, release validation, safe Credential operations guidance, and tested transport behavior. It keeps `StdHttpClient` as the only production `HttpClient` adapter because the representative corporate environment needs no proxy.

M19 gates two-request Candidate Session fan-out on a live latency threshold. It also adds a three-state Reviewer Verdict for remote, open PullRequests. Merge and decline remain non-goals.

The implementation uses existing high-level seams. Presentation owns Reviewer Verdict behavior. The Bitbucket client and Candidate Session loader use `HttpClient`. Pure build-time logic owns version metadata validation and formatting. GitHub Actions supplies native acceptance evidence.

## User Stories

1. As a maintainer, I want every pull request checked on four native targets, so that target-specific failures block a merge.
2. As a maintainer, I want every push to `main` checked on four native targets, so that the protected branch remains buildable.
3. As a maintainer, I want to start CI manually, so that I can repeat native checks without a source change.
4. As a contributor, I want superseded CI runs cancelled, so that obsolete commits do not consume runner capacity.
5. As a contributor, I want every native job to use Zig 0.16.0, so that local and CI results use the supported compiler.
6. As a security reviewer, I want third-party CI actions pinned to immutable commits, so that an upstream tag change cannot alter required CI.
7. As a maintainer, I want all native jobs to finish after one target fails, so that one run reports the complete target result.
8. As a contributor, I want format checks in required CI, so that formatting failures block a merge.
9. As a security reviewer, I want required CI to run without a Bitbucket Credential, so that untrusted code cannot access live Bitbucket data.
10. As a maintainer, I want live Bitbucket checks to remain explicit local opt-ins, so that required CI stays hermetic.
11. As a maintainer, I want bounded target-specific caches, so that native artifacts do not cross architectures or exhaust the repository cache allowance.
12. As a user, I want `bbr --version` to identify the exact source revision, so that I can report the build that produced a result.
13. As a release engineer, I want clean builds of one revision to have one version on all targets, so that build time and time zone do not change identity.
14. As a release engineer, I want version dates derived from the UTC commit date, so that the date describes the source revision.
15. As a release engineer, I want same-day releases to use an ordered sequence, so that each release has a unique CalVer.
16. As a developer, I want dirty builds marked in the version, so that local source changes are visible in diagnostics.
17. As an archive builder, I want complete explicit metadata to replace Git metadata, so that a source copy without Git data keeps the same version.
18. As a developer, I want partial explicit metadata rejected, so that the build never combines two metadata sources.
19. As a release engineer, I want malformed or conflicting release tags rejected, so that a release cannot claim an ambiguous identity.
20. As a user, I want `bbr --version` to skip Credential, config, database, network, and terminal startup, so that version inspection always works offline.
21. As a release engineer, I want tag pushes validated without artifact publication, so that M19 proves release identity before distribution starts.
22. As a release engineer, I want a release tag checked against the commit date and daily sequence, so that tags follow the CalVer contract.
23. As a release engineer, I want the package version checked against the release tag, so that package metadata and executable identity agree.
24. As a release engineer, I want Git and source-copy builds compared, so that explicit metadata reproduces the Git-derived version.
25. As a user, I want a documented macOS Keychain launch pattern, so that the Credential does not enter repository files or shell history.
26. As a security reviewer, I want Credential examples to use placeholders, so that documentation cannot expose a real Credential.
27. As a security reviewer, I want logs and diagnostics to omit Authorization values, proxy authentication, and token-bearing URLs, so that failures do not disclose Credentials.
28. As a user, I want bbr to read the existing Credential environment variables, so that M19 does not create a second Credential store before the login milestone.
29. As a user in the representative corporate environment, I want direct HTTPS through `StdHttpClient`, so that bbr works without a new transport dependency.
30. As a user with standard proxy environment variables, I want `StdHttpClient` to load them, so that supported proxies need no bbr-specific setting.
31. As a security reviewer, I want a configured proxy failure to stop the request, so that bbr does not bypass the configured network route.
32. As a maintainer, I want transport failures distinct from `ApiError`, so that retry and diagnostic policy uses the real failure class.
33. As a maintainer, I want `HttpClient` preserved as the transport seam, so that a future measured proxy requirement can replace the adapter locally.
34. As a user, I want remote Candidate Sessions to load faster when live evidence proves the gain, so that review startup waits less.
35. As a maintainer, I want fan-out limited to two active requests, so that one Candidate Session has bounded connection pressure.
36. As a maintainer, I want completion order to produce the same Candidate Session, so that network timing cannot change review data.
37. As a user, I want Authenticated Account acquisition failure to preserve a read-only Candidate Session, so that identity failure does not block review reading.
38. As a user, I want a required acquisition failure to preserve the published Session, so that a failed replacement does not corrupt visible review state.
39. As a maintainer, I want stale Candidate Session results destroyed, so that an old replacement intent cannot change the current Session Epoch.
40. As a maintainer, I want the fan-out implementation removed when the live gate fails, so that dormant concurrency code does not remain in production.
41. As a reviewer, I want to set Approved from bbr, so that I can record a positive Reviewer Verdict without leaving the review.
42. As a reviewer, I want to set Changes Requested from bbr, so that I can record blocking review feedback without leaving the review.
43. As a reviewer, I want to set No Verdict from bbr, so that I can remove my current Approved or Changes Requested verdict.
44. As a reviewer, I want my current Reviewer Verdict visible beside the PullRequest title, so that I can see the remote decision state.
45. As a reviewer, I want unavailable Reviewer Verdict Actions to remain visible with a reason, so that I know why bbr refuses the Action.
46. As a PullRequest Author, I want bbr to refuse a verdict on my own PullRequest, so that the client does not offer an invalid review decision.
47. As a reviewer, I want bbr to compare the current SourceCommit before a verdict mutation, so that my decision does not target a changed PullRequest.
48. As a reviewer, I want uncertain verdict outcomes reconciled before another mutation, so that a lost response does not cause a blind retry.
49. As a reviewer, I want a verdict mutation to continue when I switch Sessions, so that Session navigation does not cancel authorized remote work.
50. As a reviewer, I want one global remote-write lane, so that Submission, Comment mutation, and Reviewer Verdict operations do not race.
51. As a reviewer, I want a successful verdict change to reload the visible PullRequest, so that the Session reflects Bitbucket's reconciled state.
52. As a local reviewer, I want Reviewer Verdict Actions refused with a clear reason, so that local review never attempts a remote mutation.
53. As a reviewer, I want merge and decline absent from bbr, so that the tool remains focused on review decisions rather than PullRequest lifecycle control.

## Implementation Decisions

- M19 lands as eight ordered, independently mergeable slices. Each slice keeps required CI green. Candidate Session fan-out is conditional and merges only after the live gate passes.
- Required CI replaces the current native grammar workflow with one CI workflow. It runs for pull requests, pushes to `main`, and manual dispatch.
- Required CI has four jobs named `CI / test (<target>)`. Targets are macOS x86_64 on `macos-15-intel`, macOS aarch64 on `macos-15`, Linux x86_64 on `ubuntu-24.04`, and Linux aarch64 on `ubuntu-24.04-arm`.
- Every native job installs Zig 0.16.0 and runs the existing native target check, RE2 wrapper check, dynamic UserGrammar load, UserGrammar CLI lifecycle, and complete test suite. Linux x86_64 also checks formatting for build, source, and test inputs.
- CI uses `fail-fast: false`, a 45-minute job timeout, read-only repository contents permission, and no automatic retries or `continue-on-error`. Each job uploads no artifact.
- CI pins checkout v7.0.1 to commit `3d3c42e5aac5ba805825da76410c181273ba90b1`. CI pins setup-zig v2.2.2 to commit `1e9fbd457bcc3587b58845344a267f12f151709c`. Version comments remain beside the pins.
- Setup-zig caches use the native target in the key and a 2 GiB limit per target. Branch protection requires all four named jobs.
- A pure build-time module validates metadata and formats the version. The build selects one complete metadata source and injects one version string into the executable.
- Explicit metadata mode starts when any version metadata variable exists. It requires `SOURCE_DATE_EPOCH`, `BBR_VERSION_COMMIT`, `BBR_VERSION_SEQUENCE`, and `BBR_VERSION_DIRTY` together.
- `SOURCE_DATE_EPOCH` is a non-negative Unix timestamp for the UTC committer time. `BBR_VERSION_COMMIT` is a full 40-character lowercase hexadecimal hash. `BBR_VERSION_SEQUENCE` is zero for development or a positive release sequence. `BBR_VERSION_DIRTY` is exactly zero or one.
- Without explicit metadata, Git supplies the `HEAD` committer timestamp, full commit hash, exact release tag, and dirty state. The build never combines partial explicit metadata with Git data.
- Git dirty detection includes tracked changes and untracked files in build inputs, source, tests, vendors, and CI workflows. Ignored files and documentation do not mark the binary dirty.
- Release tags are annotated and use `vYYYY.M.D-N`. An exact valid tag supplies a positive release sequence. An untagged build uses sequence zero. The build rejects malformed or conflicting exact tags.
- Development versions use `YYYY.M.D-0+g<12-character-hash>`. Release versions use `YYYY.M.D-N+g<12-character-hash>`. Dirty versions append `.dirty` to build metadata.
- The package version remains `0.0.0` before the first release. After the first release, development commits retain the latest hashless release version. A release commit matches the hashless tag version.
- `bbr --version` is handled before all other startup work. It writes `bbr <version>` and exits successfully.
- A separate release-validation workflow runs on `v*` tag pushes. It publishes no binary, archive, release record, or other artifact.
- Release validation fetches complete tag history. It requires one annotated triggering tag that points directly at `HEAD`, matches the UTC committer date, uses the next sequence for that date, and agrees with the package version.
- Release validation requires a clean checkout. It compares Git-derived output with output from a source copy that has no Git data and receives complete explicit metadata.
- `StdHttpClient` remains the only production `HttpClient` adapter. M19 adds no libcurl dependency.
- Production keeps standard uppercase and lowercase proxy environment support through `initDefaultProxies`. M19 adds no proxy keys to bbr configuration.
- Invalid or unsupported configured proxy data produces a sanitized configuration or transport failure. bbr does not retry the request through a direct connection.
- Transport failures remain distinct from Bitbucket `ApiError` values. Diagnostics can include a transport error name and a Credential-free request location.
- Operations documentation describes the three required Credential environment variables and a macOS Keychain launch pattern. Examples use placeholders and never name the user's local wrapper.
- Required CI receives no Credential. Direct connectivity, blob, Comment mutation, Reviewer Verdict mutation, and other live checks remain explicit local opt-ins.
- The external-dependency ADR records the measured no-libcurl decision. `HttpClient` remains the replacement boundary for a future measured need.
- Remote Candidate Session acquisition keeps sequential loading unless bounded loading passes the live acceptance gate. Production uses one fixed policy and exposes no user setting.
- Bounded acquisition permits at most two active requests per Candidate Session. One `StdHttpClient` owns the shared connection pool for the attempt.
- The scheduler starts PullRequest and Authenticated Account acquisition first. RawDiff waits when both slots are active. Comments become ready after PullRequest acquisition supplies current commit data. Comments take priority over RawDiff when both are ready.
- PullRequest, RawDiff, and Comments are required. Authenticated Account acquisition is independent and can fail without rejecting a read-only Candidate Session.
- Each acquisition branch owns one arena. A successful Candidate Session takes successful branch arenas. Failed, superseded, stale, and rejected candidates destroy all owned arenas.
- The first required failure stops later top-level work. Every started branch completes and is awaited before shared client or branch state is destroyed. M19 adds no branch cancellation protocol.
- Candidate Session assembly always uses PullRequest, RawDiff, and Comments logical order. Multiple required failures use that order to select the reported failure.
- Internal acquisition completions never publish state. The current replacement intent admits or rejects the complete Candidate Session. Successful publication advances the Session Epoch once.
- `HttpClient` permits concurrent sends up to the caller's bound. The production adapter shares one guarded connection pool.
- `FakeHttpClient` supports request-keyed responses, locked active and maximum request counts, and test-controlled completion order. Existing call-order scripts remain only for sequential tests.
- The opt-in benchmark alternates ten sequential and ten bounded complete loads for representative PullRequests 1856 and 1726. It records median latency, connection count, failures, and 429 responses without Credential data.
- Bounded loading merges only if it reduces median latency by at least 30 percent on both PullRequests, uses at most two connections, and produces no failure or 429 response. A failed gate leaves production sequential and removes dormant fan-out code.
- Bitbucket defines `ReviewerVerdict` as Approved, Changes Requested, or No Verdict. The Bitbucket context translates Atlassian participant data and does not expose the wire shape to Presentation.
- PullRequest acquisition includes PullRequest state, PullRequest Author UUID, and enough translated reviewer data to derive the Authenticated Account's current Reviewer Verdict.
- Approved uses `POST /approve`. Changes Requested uses `POST /request-changes`. No Verdict deletes the endpoint that represents the current Approved or Changes Requested verdict.
- A target POST can replace the existing Reviewer Verdict directly. Before mutation, the adapter fetches the current PullRequest and compares its SourceCommit with the expected SourceCommit.
- A SourceCommit mismatch sends no mutation and requires explicit refresh. After definite success or uncertain outcome, the adapter reacquires SourceCommit and Reviewer Verdict.
- Reviewer Verdict operations never retry automatically. Each new mutation requires fresh reviewer intent.
- The typed result distinguishes success, reconciled success, definite `ApiError`, stale SourceCommit, and unresolved outcome. A `401` invalidates the cached Authenticated Account identity.
- Presentation adds configurable Actions for Approved, Changes Requested, and No Verdict. Default keys are `g a`, `g c`, and `g n`. These Actions use no confirmation Overlay.
- The status bar shows Approved, Changes requested, No verdict, or Verdict unavailable immediately after the PullRequest title. LocalReview omits the segment. ReviewHeader remains display metadata and does not own review policy.
- Presentation alone computes Reviewer Verdict `ActionAvailability`. It refuses an Action for a LocalReview, a PullRequest that is not open, missing identity or verdict data, the PullRequest Author, an unchanged target verdict, or a busy global remote-write lane.
- Reviewer Verdict change is a PullRequest-qualified Durable Operation. It shares the global remote-write lane with Submission and published Comment mutation.
- Presentation emits one typed command with the desired Reviewer Verdict and expected SourceCommit. The terminal adapter owns preflight, mutation, and reconciliation as one external operation and returns one typed completion.
- Session switching does not cancel a Reviewer Verdict Durable Operation. The operation reports a PullRequest-qualified result.
- A successful or reconciled change prepares a complete Candidate Session replacement when the same PullRequest remains visible. Replacement failure preserves the old Session and the qualified result.
- Merge and decline remain durable non-goals. M19 adds no merge endpoint, decline endpoint, confirmation workflow, or merge strategy UI.
- Product and operations documentation changes only after each related behavior lands. M19 closes only after all unconditional acceptance rows pass and fan-out has passing evidence or a recorded no-go result.

## Testing Decisions

- Tests assert external behavior. They do not assert private scheduler phases, arena indices, worker implementation, connection-pool internals, or private Presentation state.
- The primary product seam is Presentation. Tests dispatch owned inputs, inspect emitted typed commands, return typed completions, and inspect immutable projections and cleanup.
- The build identity seam is the pure build-time metadata validator and formatter. Hermetic tests cover both metadata sources, all accepted formats, partial and invalid metadata, malformed and conflicting tags, missing Git data, dirty input classes, and ignored files.
- Every produced version parses with Zig's `std.SemanticVersion`. Reproducibility checks compare clean builds under different wall-clock times and time zones. Git and explicit metadata for one revision produce the same output.
- Release workflow tests or controlled validation runs cover a valid annotated tag, wrong date, reused sequence, skipped sequence, dirty checkout, package mismatch, conflicting tags, and source-copy mismatch. The workflow publishes nothing.
- The remote acquisition seam is `HttpClient`. Hermetic tests cover uppercase and lowercase proxy variables, invalid proxy configuration, no direct fallback, transport-error separation, and existing `ApiError` classification.
- `FakeHttpClient` tests drive every supported completion order and required branch failure. Tests prove the two-request bound, stable Candidate Session assembly, deterministic failure priority, complete awaiting, and memory cleanup.
- Candidate Session tests prove that Authenticated Account failure preserves read-only review, stale replacement intent preserves the published Session, and successful publication advances the Session Epoch once.
- A local Credential-free HTTP test proves that two calls overlap through one `StdHttpClient`, complete, and clean up.
- The opt-in live fan-out gate runs before merge. It measures complete sequential and bounded Candidate Session loads for both representative PullRequests and applies the 30 percent, two-connection, zero-failure, and zero-429 thresholds.
- Bitbucket client tests cover Reviewer Verdict derivation, PullRequest Author identity, all four mutation endpoint shapes, every `ApiError`, malformed responses, stale preflight refusal, uncertain reconciliation, and a SourceCommit change during mutation.
- Reviewer Verdict Presentation tests cover key resolution, each `ActionAvailability` refusal, global lane exclusion, stale refusal, definite failure, uncertain reconciliation, Session switching, stale completion rejection, successful replacement, replacement failure, status projection, and cleanup.
- Existing Presentation integration tests are prior art for typed input, command, completion, projection, Durable Operation, Session replacement, and allocator-failure behavior.
- Existing `FakeHttpClient` Bitbucket client tests are prior art for request contracts, pagination, response classification, and Credential-free fixtures.
- Existing native grammar jobs are prior art for the four operating-system and architecture targets. M19 keeps their RE2, dynamic UserGrammar, and CLI lifecycle checks inside the required jobs.
- PTY coverage remains a thin smoke test. Required correctness tests do not need a terminal, live Bitbucket access, sleep, or timing thresholds.
- Full repository acceptance runs the format check and `zig build test --summary all`. All four required native jobs must pass.

## Out of Scope

- M19 does not implement a bbr Credential store, login, status, or logout command. That work remains in the Credential login milestone.
- M19 does not put live Bitbucket checks or Credentials in required CI.
- M19 does not publish release binaries, source archives, GitHub releases, or other artifacts.
- M19 does not add libcurl or another production HTTP adapter.
- M19 does not add bbr-specific proxy configuration.
- M19 does not add user-configurable Candidate Session concurrency.
- M19 does not add branch cancellation for in-progress acquisition.
- M19 does not add merge or decline Actions.
- M19 does not expand LocalReview behavior.
- M19 does not include later review search, File read state, Browser, or Credential management milestones.

## Further Notes

- The exposed Atlassian tokens were revoked. Plaintext copies identified during containment were removed. The replacement token is stored in macOS Keychain and enters bbr through an ignored local launcher.
- The representative corporate environment has no proxy, proxy authentication, or TLS interception requirement. A direct live `StdHttpClient` check reached Bitbucket Cloud.
- The endpoint probe measured median latency reductions of 47.6 percent and 72.4 percent with two connections. The implementation still requires the full Zig loader gate because the probe did not prove concurrent `std.http.Client` behavior.
- Live checks must never record Credential values, Authorization headers, proxy authentication, or token-bearing URLs in logs, fixtures, issues, or assets.
- The implementation order is CI, version identity, release validation, transport and Credential guidance, conditional fan-out, Reviewer Verdict client, Reviewer Verdict Presentation, then integrated documentation and evidence.
