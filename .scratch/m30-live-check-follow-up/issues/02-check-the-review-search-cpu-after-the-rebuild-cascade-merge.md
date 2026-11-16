# 02: Check the Review Search CPU after the rebuild cascade merge

Status: needs-triage
Blocked by: none
Source: [M30 ticket 07, finding 4](../../m30-viewer-scrollbars/issues/07-run-the-live-m30-outside-check.md#findings)

## Problem

In the 80-row Session of the live M30 outside check, a Review Search for `e` started File Enrichment of the Files.
After that, a worker used 100 percent CPU for more than 25 minutes.
A sample showed repeated `DisclosureBuild.buildBuffer`, `buildVisualRowsWithOptions`, and `SearchProjection.create` calls.
During that time, `o` did not isolate a File. A restart cleared it.
The 30-row Session did not show it.

The branch `enrichment-rebuild-cascade` removes the rebuild cascade after File Enrichment and makes `SearchProjection.create` cheaper.
That it also fixes this case is an inference, not a measurement.

## What to do

- Wait until `enrichment-rebuild-cascade` is merged into `main`. Then repeat the 80-row step on PullRequest A: a Review Search for `e`, then wait for File Enrichment to finish.
- Record the process CPU over time and whether `o` isolates a File.
- If the CPU stays high, take a `sample` and file a defect with the stack.

## Comments

### 2026-11-16 filed

The operator filed this ticket from finding 4 of the live M30 outside check.
