# M19 operational hardening and product gates

Label: wayfinder:map

## Destination

An implementation-ready M19 specification and dependency map that resolves CI policy, bbr version identity, Credential containment, corporate proxy support, Session load concurrency, and remote PullRequest lifecycle Actions without implementing the milestone.

## Notes

- Primary domains: Bitbucket and Presentation. Consult `CONTEXT-MAP.md`, `src/bitbucket/CONTEXT.md`, `src/tui/CONTEXT.md`, `TODO.md`, ADR-0003, and ADR-0012.
- Use `research`, `grilling`, `domain-modeling`, `technical-writing`, and `zig` as each ticket requires.
- Keep live Bitbucket checks opt-in and Credential-gated. Never record Credential values, Authorization headers, or token-bearing URLs in issues, assets, logs, fixtures, or command output.
- This map plans M19. It does not implement M19, except that exposed-Credential containment is an explicit security exception and must run when its task reaches the frontier.
- Preserve `HttpClient` as the Bitbucket transport seam. Add a libcurl adapter only when measured corporate proxy requirements exceed `std.http.Client` support.
- Treat parallel Session loading and approve, merge, or decline Actions as measured product gates, not assumed deliverables.

## Decisions so far

- [Contain the exposed Credential](./issues/01-contain-the-exposed-credential.md): Both exposed Atlassian tokens are revoked, plaintext copies are removed, and `bbr` receives its replacement token from macOS Keychain.
- [Define the M19 CI gate](./issues/02-define-the-ci-gate.md): Require four native macOS and Linux checks with exact Zig and action pins, bounded target caches, one Linux format step, and no live Credentials.
- [Research Bitbucket PullRequest lifecycle Actions](./issues/07-research-bitbucket-lifecycle-actions.md): Gate every Action on the current SourceCommit, confirm high-impact Actions, and reconcile uncertain results before retry.
- [Identify the corporate proxy requirement](./issues/03-identify-the-corporate-proxy-requirement.md): The representative environment needs no proxy, and `StdHttpClient` reached Bitbucket Cloud through direct HTTPS.

## Not yet specified

- The dependency-ordered implementation slices and integrated acceptance matrix depend on the CI, version identity, proxy, loading, and lifecycle-Action decisions.
- Documentation changes depend on the selected Credential injection and transport policies.

## Out of scope

- Implementing M19, except immediate containment of the exposed Credential.
- Replacing the M26 `bbr auth` login and logout milestone with an M19 credential store.
- Live Bitbucket checks in required CI.
- M18 LocalReview expansion and M20-M26 product work.
