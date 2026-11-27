# Buffer Search follow-ups

## Notes

This effort holds known faults on `main` at `b6b31d6a`.
The work of [the query edit clear order ticket](../query-edit-clear-order/issues/01-clear-before-the-maintenance-steps-of-a-query-edit.md) found them and did not fix them.
Its sections "OCR round 2", "OCR round 5", "OCR round 6", and "CodeRabbit round 2" name them.
Each ticket here starts as `needs-triage`.
Triage writes the red test.
Then it moves the ticket to `ready-for-agent`.

Ticket 01 is not only a Buffer Search fault. Ticket 02 is not a Buffer Search fault.
They come from the same review, so they live in this effort too.

| Ticket | Fault | File |
| --- | --- | --- |
| 01 | An accepted disclosure build, such as a fold toggle, removes a queued cache update and keeps its pending marker. | [01-keep-the-pending-cache-update-in-step-with-its-queued-build.md](issues/01-keep-the-pending-cache-update-in-step-with-its-queued-build.md) |
| 02 | A refused maintenance File Enrichment shows `action_refused` at once and counts as a success. | [02-defer-the-refusal-of-a-maintenance-file-enrichment.md](issues/02-defer-the-refusal-of-a-maintenance-file-enrichment.md) |
| 03 | An accept after a failed Buffer Search input keeps the old preview and clears the failure message. | [03-accept-a-failed-buffer-search-input-with-its-restore-and-its-message.md](issues/03-accept-a-failed-buffer-search-input-with-its-restore-and-its-message.md) |

Ticket 03 holds two faults of the source ticket.
Both faults have one cause.
A failure of the input work drops the batch and keeps no record of the failure.
So the accept of an input without a batch cannot know that a restore is due. It also cannot know which message says why.
The source ticket also gave both faults to one follow-up ticket.
Both fixes change the same branch of `acceptBufferSearch` and the same accept rule in `docs/rules/tui-state.md`.

## Decisions so far

None.
