Type: task
Status: open
Blocked by: none

# Benchmark Review Search File Concurrency

## Question

Which separate remote and local File concurrency limits make Review Search acquisition fastest without unnecessary load?

Extend the benchmark harness to compare limits of 1, 2, 4, and 8 Files. Use representative large real PullRequests for remote acquisition and large committed LocalReviews for local acquisition. Measure first-File and complete acquisition latency, request or process concurrency, failures, `429` responses, and retained memory. Choose the smallest safe limit within 10 percent of the fastest median complete acquisition time. Record the fixtures and measurements without recording Credentials or source content.
