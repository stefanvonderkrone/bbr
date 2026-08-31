# Define the integrated M19 contract

Type: grilling
Status: resolved
Blocked by: 01, 02, 04, 06, 08, 10

## Question

How should the accepted M19 decisions fit into repository CI, bbr version identity, Credential handling, Bitbucket transport, Candidate Session acquisition, Presentation Actions, documentation, and test seams, and what dependency-ordered implementation slices and acceptance matrix make M19 executable without reopening product or architecture decisions?

## Answer

M19 lands as eight independently mergeable slices. Each slice leaves required CI green. The Candidate Session fan-out slice is the only conditional slice: live evidence must pass before that slice merges.

### 1. Establish the required CI gate

Replace `.github/workflows/grammar-targets.yml` with `.github/workflows/ci.yml`. The workflow runs for every pull request, every push to `main`, and manual dispatch. Add concurrency by workflow plus pull request or ref, with cancellation of superseded runs.

Keep four native jobs named `CI / test (<target>)`:

- `macos-x86_64` on `macos-15-intel`;
- `macos-aarch64` on `macos-15`;
- `linux-x86_64` on `ubuntu-24.04`;
- `linux-aarch64` on `ubuntu-24.04-arm`.

Every job installs Zig 0.16.0 and runs the native-target check, RE2 wrapper, dynamic UserGrammar load, UserGrammar CLI lifecycle, and `zig build test --summary all`. The Linux x86_64 job also runs `zig fmt --check build.zig src tests`. Use `fail-fast: false`, a 45-minute timeout, `contents: read`, and no Credentials or live checks.

Pin `actions/checkout` and `step-security/setup-zig` to the commits in [Define the M19 CI gate](./02-define-the-ci-gate.md). Keep their release versions in comments. Use target-keyed setup-zig caches with a 2 GiB limit per target. Upload no artifact. Configure branch protection to require all four named jobs.

### 2. Add reproducible bbr version identity

Put the pure metadata validation and CalVer formatting logic in one build-time module with hermetic tests. `build.zig` chooses one complete metadata source, computes one version string, and injects that string into the executable. `bbr --version` handles the argument before Credential, config, database, network, or terminal initialization and writes `bbr <version>` to standard output.

Explicit metadata mode starts when any of these variables exists and requires all four:

- `SOURCE_DATE_EPOCH`: non-negative Unix seconds for the commit's UTC committer time;
- `BBR_VERSION_COMMIT`: the full 40-character lowercase hexadecimal commit hash;
- `BBR_VERSION_SEQUENCE`: `0` for a development build or a positive release sequence;
- `BBR_VERSION_DIRTY`: exactly `0` or `1`.

Git mode reads the same values from `HEAD`. It derives dirty state from tracked changes and untracked files under `build.zig`, `build.zig.zon`, `build/`, `src/`, `tests/`, `vendors/`, and `.github/workflows/`. Ignored files and documentation do not mark the binary dirty. An annotated exact tag `vYYYY.M.D-N` supplies a positive release sequence. No matching tag supplies sequence `0`. Reject malformed or conflicting exact release tags.

Format development builds as `YYYY.M.D-0+g<12-char-hash>`, release builds as `YYYY.M.D-N+g<12-char-hash>`, and dirty builds with a final `.dirty`. Keep `build.zig.zon` at `0.0.0` before the first release and at the latest hashless release version after that.

Tests cover both metadata sources, every accepted format, partial explicit metadata, invalid values, malformed tags, conflicting tags, missing Git data, dirty input classes, and ignored files. Parse every produced value with `std.SemanticVersion`.

### 3. Add release validation without publishing

Add `.github/workflows/release.yml`, triggered by `v*` tag pushes. This workflow validates a release but publishes no binaries, archives, or release records.

The job fetches complete tag history and checks that:

- the triggering tag is annotated and points directly at `HEAD`;
- its date matches the UTC date of the `HEAD` committer timestamp;
- its sequence is the next sequence for that date;
- exactly one release tag matches `HEAD`;
- the checkout is clean;
- `build.zig.zon` matches the hashless tag version;
- Git metadata produces the expected `bbr --version` line;
- a source copy without `.git`, built with the complete explicit environment, produces the same line.

Use the same pinned checkout and Zig actions as required CI. Keep release validation Credential-free.

### 4. Close the transport and Credential work

Keep `StdHttpClient` as the only production `HttpClient` adapter. Keep `initDefaultProxies` at the production construction sites. Add hermetic coverage for uppercase and lowercase proxy environment names, invalid proxy configuration, no direct fallback after a configured proxy failure, transport-error separation, and existing `ApiError` classification. Diagnostics can name a transport error and a Credential-free request location. They must not contain Authorization values, token-bearing URLs, or proxy-auth values.

Add `docs/m19-operations.md`. Document the three required environment variables and a macOS Keychain launch pattern. The example uses `<email>`, `<workspace>`, `<keychain-account>`, and `<keychain-service>` placeholders. It sets `BITBUCKET_USERNAME` and `BITBUCKET_WORKSPACE`, reads `BITBUCKET_TOKEN` with `security find-generic-password`, and starts `zig build run -- "$@"`. The guide does not commit or name the user's ignored `run-bbr`. It does not include `BITBUCKET_URL`, which bbr does not read.

The guide states that the wrapper keeps the token out of repository files and shell history, but remains a macOS-specific bridge until M26. It also documents the opt-in direct connectivity check and the rule that live checks never run in required CI.

Update ADR-0003 to record the measured no-libcurl decision. Preserve `HttpClient` so a future measured proxy requirement can reopen the adapter choice without changing the Bitbucket client.

### 5. Gate bounded Candidate Session fan-out before merge

Develop this slice on an unmerged branch. Add a private sequential or bounded acquisition policy so the same full Candidate Session loader can benchmark both policies. Production selects one fixed policy. Do not add a user setting.

The bounded scheduler follows [Choose the Session load policy](./06-choose-the-session-load-policy.md): at most two requests, one shared `StdHttpClient`, branch-owned arenas, logical result assembly, deterministic failure priority, complete awaiting of started work, and no branch cancellation. Local Candidate Session acquisition does not change.

Extend the `HttpClient` contract to permit concurrent `send` calls up to the caller's bound. Extend `FakeHttpClient` with request-keyed responses, locked active and maximum counts, and test-controlled completion order. Keep call-order scripts only for tests that do not make concurrent calls.

Add an opt-in benchmark command that alternates ten sequential and ten bounded full loads for PullRequests 1856 and 1726. It measures PullRequest, RawDiff, Comments, and Authenticated Account acquisition. Record median latency, connection count, failures, and 429 responses without recording Credential data.

The slice merges only if bounded loading reduces median latency by at least 30 percent on both PullRequests, uses at most two connections, and produces no failures or 429 responses. If any condition fails, discard the fan-out implementation, keep production sequential, and record the failed gate in the M19 evidence. Do not merge dormant fan-out code.

### 6. Add the Reviewer Verdict Bitbucket contract

Add `ReviewerVerdict` with `approved`, `changes_requested`, and `no_verdict`. Extend PullRequest acquisition with the PullRequest Author UUID and enough translated reviewer data to derive the Authenticated Account's current Reviewer Verdict. The Bitbucket context performs this translation and does not expose Atlassian's participant shape to Presentation.

Add typed client operations for these endpoints:

- Approved: `POST /approve`;
- Changes Requested: `POST /request-changes`;
- No Verdict from Approved: `DELETE /approve`;
- No Verdict from Changes Requested: `DELETE /request-changes`.

A target POST changes the existing verdict directly. Before each mutation, fetch the current PullRequest and compare its SourceCommit with the command's expected SourceCommit. Send no mutation on a mismatch. After every definite success or uncertain result, reacquire the SourceCommit and Reviewer Verdict. Never retry a verdict mutation automatically.

Return a typed outcome that distinguishes success, reconciled success, definite `ApiError`, stale SourceCommit, and unresolved outcome. A `401` invalidates the Authenticated Account identity. Keep transport failures distinct from `ApiError`.

Hermetic client tests cover all four endpoint shapes, current-verdict derivation, author identity, every `ApiError`, stale preflight refusal, uncertain-result reconciliation, changed SourceCommit during mutation, and malformed responses. Add an explicit live mutation check only behind a destructive opt-in gate.

### 7. Add Reviewer Verdict Actions through Presentation

Add three configurable Actions with default keys `g a`, `g c`, and `g n`. They set Approved, Changes Requested, and No Verdict. They use no confirmation Overlay.

Candidate Session publication carries PullRequest state, PullRequest Author UUID, Authenticated Account UUID, and current Reviewer Verdict. A missing Authenticated Account remains a usable read-only Candidate Session.

Add a persistent status-bar segment immediately after the PullRequest title. Show `Approved`, `Changes requested`, `No verdict`, or `Verdict unavailable`. Omit the segment for a LocalReview. Keep the value outside `ReviewHeader` because `ReviewHeader` remains display metadata and does not own review policy.

Presentation alone computes `ActionAvailability`. Refuse a verdict Action when the review is local, the PullRequest is not open, identity or verdict data is unavailable, the Authenticated Account is the PullRequest Author, the requested verdict already matches, or the global remote-write lane is busy. Keep unavailable Actions visible in help with a precise reason.

Model a verdict change as a PullRequest-qualified Durable Operation in the global remote-write lane. Add one typed command that owns the desired verdict and expected SourceCommit. The adapter can perform preflight, mutation, and reconciliation as one external operation, then returns one typed completion. Session switching does not cancel it. A completion updates the visible verdict only through a complete Candidate Session replacement for the same visible PullRequest. A replacement failure preserves the old Session and the qualified operation result.

Deterministic Presentation tests cover all availability reasons, key resolution, lane exclusion, stale refusal, definite failure, uncertain reconciliation, Session switching, stale completion rejection, successful replacement, replacement failure, status-bar projection, and cleanup. PTY coverage remains a thin smoke check.

### 8. Close documentation and integrated evidence

Update `README.md`, `FEATURES.md`, and `TODO.md` only after the behavior they describe lands. The README documents `bbr --version`, required CI, the Credential guide, fixed `StdHttpClient` policy, optional live checks, bounded loading only if its gate passed, and Reviewer Verdict keys. Mark M19 complete only after every unconditional row below passes and the fan-out row has either passing evidence or a recorded no-go result.

Do not create a new ADR for CI, CalVer, or Reviewer Verdict. Their issue resolutions and user documentation are sufficient. Update ADR-0003 because its stated future libcurl choice now has measured evidence.

### Integrated acceptance matrix

| Area | Required evidence |
| --- | --- |
| CI | Four required native jobs pass on a pull request and `main`; Linux x86_64 runs format; stale runs cancel; branch protection requires all four; logs contain no Credential values. |
| Version | Hermetic metadata and formatter tests pass; two wall-clock and time-zone builds match; Git and explicit metadata produce the same line; `bbr --version` performs no other startup work. |
| Release | A valid annotated tag passes the tag workflow; wrong date, reused or skipped sequence, dirty checkout, package mismatch, and source-archive mismatch each fail. No artifact is published. |
| Credential | Sanitized scans find no plaintext token in tracked or local configuration covered by the containment task; the guide uses placeholders; the ignored local wrapper retrieves the token from Keychain. |
| Transport | Proxy and error-separation tests pass on all native targets; direct live connectivity passes when opted in; sanitized logs contain no Credential or proxy-auth values. |
| Candidate Session | Required scheduler, ownership, completion-order, failure, cleanup, stale-intent, and local overlap tests pass. Before merge, both representative PullRequests pass the live gate. Otherwise production remains sequential and the no-go evidence is recorded. |
| Reviewer Verdict client | Endpoint, parsing, SourceCommit, error, and reconciliation tests pass without a Credential. The destructive live check remains explicit and local. |
| Reviewer Verdict Presentation | Availability, command, Durable Operation, Session replacement, status label, failure, and cleanup tests pass through the Presentation seam. |
| Full repository | `zig fmt --check build.zig src tests` and `zig build test --summary all` pass. Existing live checks remain opt-in and Credential-gated. |

Merge and decline remain durable non-goals. M19 does not add a libcurl adapter, a bbr Credential store, required live CI, user-configurable load concurrency, or release artifact publishing.
