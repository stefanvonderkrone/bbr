# Design the live Submission repair Overlay

Type: prototype
Blocked by: none

## Question

How should one live Overlay present a PendingReview's dependency-shaped per-Draft progress and final posted, failed, skipped, and outcome-unknown states; expose classified reasons and reply dependencies; let the reviewer repair or retry only the selected failed Draft and its Reply-descendant subtree; and offer conservative Abandon recovery when a recovered run cannot finish, while preserving Durable Operation behavior across Session replacement?
