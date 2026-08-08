# Define the rate-limit and retry policy

Type: grilling
Blocked by: 03, 08

## Question

Given Bitbucket's verified headers and observed behavior, how should HttpClient parse and own retry metadata, CommentPoster report it, Submission combine server delay with its pure backoff and attempt ceiling, and the live Submission Overlay explain waiting, exhaustion, and selective repair without introducing wall-clock policy into the state machine?
