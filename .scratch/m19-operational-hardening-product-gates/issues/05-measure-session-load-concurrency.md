# Measure Session load concurrency

Type: task
Status: resolved
Blocked by: none

## Question

What reproducible live measurements compare the current sequential PullRequest, RawDiff, and Comment acquisition with bounded parallel acquisition, including connection reuse, extra TLS handshakes, total latency, request failures, and Bitbucket rate-limit behavior?

## Answer

Measurements ran on 2026-08-31 from the representative macOS environment against two `pr-webapp` PullRequests. The probe used curl 8.7.1 with HTTP/1.1 and redirects enabled. It discarded response bodies and loaded the Credential from macOS Keychain through curl's standard-input config.

Each sequential run requested the PullRequest, RawDiff, and first Comment page with `pagelen=100` in one curl process. Each bounded run requested the same resources with `--parallel-max 2`. PullRequest 1856 used 10 runs per mode. PullRequest 1726 used 5 runs per mode.

| PullRequest | Sequential median | Two-connection median | Reduction |
| --- | ---: | ---: | ---: |
| 1856 | 2.115 s | 1.109 s | 47.6% |
| 1726 | 2.505 s | 0.692 s | 72.4% |

The sequential runs opened one connection and reused it for the other two requests. The bounded runs opened two connections. The third request reused the first available connection. The median TLS setup time for the extra connection was 31 ms.

All 90 measured responses ended with status 200. No request failed. No run received status 429, `Retry-After`, or an advertised remaining-rate value. This sample shows no rate-limit effect from two-way fan-out, but it does not establish Bitbucket's rate-limit ceiling.

The response sizes stayed stable for each PullRequest. PullRequest 1856 returned 5,609 bytes, 641 bytes, and 84,966 bytes. PullRequest 1726 returned 22,513 bytes, 13,935 bytes, and 39,132 bytes. An unmodified `StdHttpClient` control fetched and parsed the PullRequest and Comments five times with no failure and a 1.36 s median.

The curl probe models the live endpoint and HTTP/1.1 connection costs. It does not prove that concurrent calls through Zig's `std.http.Client` are safe. It also excludes the independent Authenticated Account request and local parsing. `Choose the Session load policy` must set the implementation and acceptance policy from these measurements.
