Type: task
Status: resolved
Blocked by: none

# Benchmark Review Search File Concurrency

## Question

Which separate remote and local File concurrency limits make Review Search acquisition fastest without unnecessary load?

Extend the benchmark harness to compare limits of 1, 2, 4, and 8 Files. Use representative large real PullRequests for remote acquisition and large committed LocalReviews for local acquisition. Measure first-File and complete acquisition latency, request or process concurrency, failures, `429` responses, and retained memory. Choose the smallest safe limit within 10 percent of the fastest median complete acquisition time. Record the fixtures and measurements without recording Credentials or source content.

## Progress

The opt-in `zig build bench-file-acquisition` harness runs local limits five times and remote limits three times in rotating order. It pauses ten seconds between remote runs. It reports median first-File latency, median complete latency, maximum concurrent reads, failures, `429` responses, and median retained bytes. The harness sorts Files by display path before acquisition and uses the production remote and local File Enrichment paths.

### Local measurements

ReleaseFast measurements from 2026-09-20:

| LocalReview | Files | Limit | First File (ms) | Complete (ms) | Max processes | Failures | `429` | Retained bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `80a9fc64..09ffc95f` | 54 | 1 | 18 | 894 | 1 | 0 | 0 | 3,661,002 |
| `80a9fc64..09ffc95f` | 54 | 2 | 10 | 467 | 2 | 0 | 0 | 3,661,002 |
| `80a9fc64..09ffc95f` | 54 | 4 | 11 | 297 | 4 | 0 | 0 | 3,661,002 |
| `80a9fc64..09ffc95f` | 54 | 8 | 16 | 148 | 8 | 0 | 0 | 3,661,002 |
| `09ffc95f..6bf23523` | 82 | 1 | 16 | 1,130 | 1 | 0 | 0 | 4,424,016 |
| `09ffc95f..6bf23523` | 82 | 2 | 17 | 537 | 2 | 0 | 0 | 4,424,016 |
| `09ffc95f..6bf23523` | 82 | 4 | 11 | 340 | 4 | 0 | 0 | 4,424,016 |
| `09ffc95f..6bf23523` | 82 | 8 | 10 | 217 | 8 | 0 | 0 | 4,424,016 |

Limit 8 is the only local limit within 10 percent of the fastest median on both fixtures. It caused no failures and did not increase retained memory.

### Remote measurements

The first run completed before the shared Bitbucket request quota was consumed:

| PullRequest | Files | Limit | First File (ms) | Complete (ms) | Max requests | Failures | `429` | Retained bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pr-webapp/1726` | 16 | 1 | 264 | 4,560 | 2 | 0 | 0 | 573,248 |
| `pr-webapp/1726` | 16 | 2 | 240 | 2,168 | 4 | 0 | 0 | 587,700 |
| `pr-webapp/1726` | 16 | 4 | 246 | 1,087 | 8 | 0 | 0 | 613,942 |
| `pr-webapp/1726` | 16 | 8 | 245 | 566 | 15 | 0 | 0 | 611,206 |

Limit 8 is the only remote limit within 10 percent of the fastest median on this fixture. PullRequest `pr-webapp/1856` was discarded because it contains only one changed File.

The second run used a recovered Bitbucket quota:

| PullRequest | Files | Limit | First File (ms) | Complete (ms) | Max requests | Failures | `429` | Retained bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pr-webapp/2112` | 32 | 1 | 282 | 9,735 | 2 | 0 | 0 | 7,329,956 |
| `pr-webapp/2112` | 32 | 2 | 293 | 4,831 | 4 | 0 | 0 | 7,002,164 |
| `pr-webapp/2112` | 32 | 4 | 283 | 2,463 | 8 | 0 | 0 | 8,553,780 |
| `pr-webapp/2112` | 32 | 8 | 252 | 1,407 | 16 | 0 | 0 | 7,258,762 |

Bitbucket applies a [1,000-request rolling hour](https://support.atlassian.com/bitbucket-cloud/docs/api-request-limits/). Run large remote fixtures in separate recovered quota windows so the benchmark itself does not cause `429` responses.

## Answer

Use a File concurrency limit of 8 for both remote PullRequests and LocalReviews. Limit 8 is the smallest limit within 10 percent of the fastest median complete acquisition time on all four fixtures. Every accepted run completed without a failure or `429` response.

One modified remote File reads its old and new sides concurrently. A File limit of 8 can therefore produce up to 16 concurrent remote requests. Local File acquisition produced at most 8 concurrent Git processes. Retained memory followed fixture content and did not increase consistently with concurrency.
