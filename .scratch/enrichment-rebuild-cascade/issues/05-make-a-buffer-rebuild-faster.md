# 05: Make a Buffer rebuild faster

Status: needs-triage
Blocked by: none

## Summary

Every disclosure toggle, File isolation, Layout switch, resize, Draft change, and File Enrichment result rebuilds the whole Buffer on a worker.
Tickets 01 to 04 reduce how often a rebuild runs.
This ticket reduces the cost of one rebuild.

On PullRequest A, one rebuild costs about 0.15 seconds of CPU.
PullRequest A has 593 Files and about 111,700 Buffer rows.
The local Review `bbr local fb701b1 1836261` in this repository has 479 Files and 187,827 Buffer rows, so its rebuilds cost more.

## Evidence

The runner measured the rebuild time on 2026-11-11 on `main` at commit `3b29039`, with temporary timing logs.
Over 689 enrichment rebuilds on PullRequest A, the mean was 0.15 seconds, and the maximum was 1.0 second.

A CPU sample of the rebuild worker during the same run split the samples in this way:

| Function | Samples |
| --- | --- |
| `frame.buildVisualRowsWithOptions` | 487 |
| `render.nextVaxisGrapheme`, inside the visual row build, with `gwidth` and the grapheme iterator | 266 |
| `presentation.DisclosureBuild.buildBuffer` | 174 |
| `buffer.buildSearchCandidates` | 172 |
| `buffer.buildWithComments`, mostly the `AnchorKey` hash map | 145 |
| `presentation.SearchProjection.create` | 87 |
| `search.scan` | 79 |

The numbers come from one sample before tickets 01 to 03.
They show where the time goes, but they are not a baseline for this ticket.

## Possible directions

These are guesses. The triage must measure them before it picks one.

- The visual row build measures the cell width of each grapheme of each row again, with the same text on each rebuild.
  A cache of the row widths could skip that work for rows whose text did not change.
- A rebuild builds the Buffer, the visual rows, the search candidates, and the search projection again for all Files.
  A rebuild that changes one File could reuse the parts of the other Files.
- The Buffer build uses hash maps that grow during the build. A size known before the build could avoid the growth.

## Next step

Triage the ticket. Pick a fixed workload and a benchmark that measures one rebuild, for example an extension of `zig build bench` or the local Review above.
Measure a baseline, find the largest cost, and set a target.

## Comments
