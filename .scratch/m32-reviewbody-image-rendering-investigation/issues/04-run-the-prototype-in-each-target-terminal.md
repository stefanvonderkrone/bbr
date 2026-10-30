# 04: Run the prototype in each target terminal

Status: ready-for-human
Blocked by: 03
Spec: [M32 spec](../SPEC.md)

## What to build

A human runs the prototype from ticket 03 in each target terminal.
The human records a screenshot of each ReviewCard situation and the probe log of each run.
The human also checks the Bitbucket findings of ticket 01 on a real PullRequest.

This ticket needs the target terminals, the user's Credential, and live network access.
So an agent cannot run it.

## Steps

Before the runs:

1. Follow `evidence/run-guide.md` from ticket 03.
2. Check out the prototype commit that ticket 03 names, and note the commit hash.
3. Record the version of each terminal, tmux, and herdr.

For each column of the protocol matrix in the spec:

1. Open the fixture Review in Variant A.
2. Go through the situations R1 to R12.
   Take one screenshot of each situation.
   For R5, R7, R8, R9, and R11, take a screenshot before and after the change.
3. Repeat the situations with the PNG path set to `f=100`.
4. Open the fixture Review in Variant B, and go through R1, R4, R7, R8, and R9.
5. Run `summarize` on the probe log, and copy its output into `## Completion`.
6. Fill the matrix column with the observed results.
   Mark each cell that differs from ticket 02.
7. Write down how readable each image is at the start size of 12 rows.
   If a different maximum makes the images clearly better, record that value and run R1 to R4 again with it.

For herdr, also do these steps:

1. Run herdr inside Ghostty and inside one other kitty-protocol terminal.
2. Open an herdr popup over an image, then close it.
3. Scroll and resize, and look for stale image copies.
4. Record whether `terminal.kitty_graphics` was on.

For tmux, run it once with `allow-passthrough on` and once with it off.

For the external-load key:

1. Open I13 with `BBR_M32_ALLOW_EXTERNAL` unset.
   Confirm that the test server gets no request.
2. Open I13 with `BBR_M32_ALLOW_EXTERNAL=1`.
   Confirm that the request has no `Authorization` header.

For the Bitbucket check with I15:

1. Pick a real PullRequest with a pasted screenshot in a Comment.
2. Run the prototype against it through a logging proxy that records each request host.
3. Record each request host, its status, and whether it carried the Credential.
   Do not record a URL path, a query string, or Comment text.
4. Work through the checklist of ticket 01, and record each answer.
5. Open the same PullRequest again after one hour and after one day.
   Record whether the image still loads, to check URL expiry.

Store the fixture screenshots in `evidence/` in the M32 directory.
Name each file `<column>-<situation>-<variant>.png`.
Never store a screenshot of a real PullRequest in the repository.

## Acceptance criteria

- [ ] `## Completion` records the prototype commit and every terminal, tmux, and herdr version.
- [ ] Every column of the protocol matrix has a result, or a note that its terminal was not available.
- [ ] `evidence/` has a screenshot of each situation for each column and variant in the steps.
- [ ] `## Completion` has the `summarize` output for each column.
- [ ] The herdr steps are done inside Ghostty and inside one other kitty-protocol terminal.
- [ ] The tmux steps are done with passthrough on and off.
- [ ] The external-load check shows no request with the key off and no Credential with the key on.
- [ ] The Bitbucket check shows every request host and that only Bitbucket hosts got the Credential.
- [ ] Each item of the ticket 01 checklist has an answer.
- [ ] The URL expiry check after one hour and one day is recorded.
- [ ] No recorded text or screenshot holds a real image URL, Comment text, or Credential value.
