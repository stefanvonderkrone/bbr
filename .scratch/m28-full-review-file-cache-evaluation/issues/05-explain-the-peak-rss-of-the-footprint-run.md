# 05: Explain the peak RSS of the footprint run

Status: needs-triage
Type: research
Blocked by: none
Spec: [M28 spec](../SPEC.md)

## Question

The footprint run in [ticket 02](02-run-the-baseline-on-the-five-pullrequests.md) reports `peak_rss_bytes=855785472`.
That value is 816 MiB.
The File cache holds at most 35,373,616 bytes, which is 33.7 MiB.
So about 780 MiB of the peak has no known owner.

Which owners hold that memory, and how much does each one hold?

This ticket is a research question, not M28 implementation work.
The M28 decision "no change" does not depend on the answer.
The File cache is at most 33.7 MiB of the peak.
Do not investigate it inside M28.

## Candidates

- The Highlighter and the tree-sitter parsers, with their trees and scratch memory.
- The Review Search state. S1 opens no Review Search, so confirm that this state is empty.
- The benchmark harness itself, such as its sample arrays and its HTTP client.
- Allocator memory that the process freed but did not return to the operating system.

The Session and its Diff Buffer are a fifth candidate that the measurement must also cover.

## Measurement

Measure offline first.
Build a Review with a File count and File sizes like PullRequest A.
The local run files of ticket 02 give the File count.
A local Git history or a fixture on `FakeHttpClient` can supply the Files.
Count the live bytes and the peak bytes of each owner with a counting allocator for each owner.
Record the RSS at the same points, so the measurement shows the part that no allocator counts.
Run the measurement against live Bitbucket only if the offline Review does not show the peak.
A live run follows the run guide of ticket 02 and records no PullRequest id.

## Acceptance criteria

- [ ] A table splits the peak RSS by owner, and one row holds the part that no owner counts.
- [ ] The answer states whether the measurement ran offline or live, and why.
- [ ] The answer names the largest owner and states whether it grows with the File count or the File size.
- [ ] The answer states whether the largest owner needs its own ticket.
- [ ] The recorded output holds no PullRequest id, source text, File path, query text, Comment text, or URL.
- [ ] `python3 tools/check_agent_docs.py` passes.
