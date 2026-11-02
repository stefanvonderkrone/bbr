# 01: Port the HTTP Credential fixes to main

Status: needs-triage
Blocked by: none

## Problem

Three paths on main can send the Credential to a host that is not Bitbucket.
The code predates M32. The M32 review verified the first and the third path with loopback tests.

1. `StdHttpClient.send` in `src/http/std_client.zig` puts every request header, also `authorization`, into the `std.http` `extra_headers`.
   It lets std follow three redirects for a request without a body.
   Zig 0.16 keeps `extra_headers` on a redirect to another host and on a redirect from `https` to `http`.
   A loopback test printed `second-host-got-authorization=true`.
2. `listPages` and the Workspace Member pagination in `src/bitbucket/client.zig` follow each `next` link from the response body.
   They send the `authorization` header to that URL with no scheme, host, or port check.
3. When a proxy refuses `CONNECT`, std falls back to a plain proxy connection.
   That connection sends the `https` URL and the `authorization` header in clear text.
   A fake proxy test showed this.

Review findings: X-2, M24-3, M32I-1, M32I-14, and M32I-15 in `/Volumes/Work/t3-code/review-all-branches.md`.

## Trap

Do not move the Credential into `privileged_headers`.
Zig 0.16 `sendHead` writes `extra_headers` but never writes `privileged_headers` (`std/http/Client.zig:990-1073`).
So every request then has no Credential, and Bitbucket answers 401.
The M32 review verified this with a mutation.
A `FakeHttpClient` test cannot see this trap, because `FakeHttpClient` replaces `StdHttpClient` completely.

## Reference

The never-merging branch `m32-image-prototype` has the fixes as three commits.
Port the behavior and the tests. Do not cherry-pick, because the prototype branch carries prototype code.

| Commit | Subject | Behavior |
| --- | --- | --- |
| `6cf853e` | http: follow redirects without leaking Authorization | `StdHttpClient` sets `redirect_behavior = .unhandled` and follows at most three hops itself. A hop to another scheme, host, or port drops the `authorization` header. A hop from `https` to `http` fails with `error.InsecureRedirect`. |
| `c69aea2` | http: refuse an https request on a plain proxy fallback | `StdHttpClient` closes a plain proxy connection for an `https` request before it sends, and returns `error.InsecureProxy`. |
| `ba24a6e` | bitbucket: follow next links only on the API origin | Pagination and Workspace Member cursor pages stop with `error.MalformedResponse` when a `next` link has another scheme, host, or port than the API base URL. |

## Acceptance criteria

- [ ] `StdHttpClient` sets `redirect_behavior = .unhandled` and follows each redirect hop itself.
- [ ] Each hop checks the scheme, the host, and the port. A hop to another authority sends no `authorization` header.
- [ ] A hop from `https` to `http` fails with an error and sends no request.
- [ ] A hop to the same authority keeps the `authorization` header, so Bitbucket API requests still authenticate.
- [ ] An `https` request on a plain proxy fallback fails before bbr writes the request.
- [ ] `listPages` and the Workspace Member pagination accept a `next` link only with the API base URL scheme, host, and port.
- [ ] A loopback server test in `src/http/std_client.zig` sends `authorization` to `localhost`, redirects to `127.0.0.1`, and asserts that the second connection has no `authorization` line.
- [ ] A loopback server test in `src/http/std_client.zig` asserts that the first request carries the `authorization` line. This test fails when the Credential moves into `privileged_headers`.
- [ ] A fake proxy test in `src/http/std_client.zig` refuses `CONNECT` and asserts that the proxy never receives the Credential value.
- [ ] A `FakeHttpClient` test in `src/bitbucket/client.zig` returns a `next` link on another host and asserts an error and no second request.
- [ ] Each new guard has one mutation run that removes the guard and shows the test fails.
- [ ] `AGENTS.md` gets a rule that names the loopback tests as its enforcement.
- [ ] `zig build test` passes.

## Triage questions

- M24-3 also asks for a page cap and a body size cap on `listPages`. Decide if this ticket owns them.
- The m24 branch changes `listPages` (`missingShapeField`). Decide if this ticket waits for the m24 merge.

## Comments

### 2026-11-02

The M32 review fix run filed this ticket.
M32 records the redirect finding but does not fix production code, so this ticket owns the fix.
