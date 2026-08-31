# Choose the Session load policy

Type: grilling
Status: resolved
Blocked by: 05

## Question

Given the live measurements, should Candidate Session acquisition stay sequential or use bounded fan-out, and what connection ownership, result ordering, cancellation, Session Epoch rejection, fake behavior, and acceptance thresholds define that policy?

## Answer

Remote Candidate Session acquisition uses bounded fan-out only if the live acceptance gate below passes. The bound is two active HTTP requests per Candidate Session. Local Candidate Session acquisition does not change.

One `StdHttpClient` owns the connection pool for one Candidate Session attempt. All branches share that client. The worker must await every started branch before it destroys the client or any branch state.

The scheduler starts PullRequest and Authenticated Account acquisition first. RawDiff is also ready at the start but waits for a slot. Comment acquisition becomes ready after PullRequest acquisition supplies the SourceCommit and destination commit. When Comments and RawDiff are both ready, Comments has priority because Comment pagination can add more requests. Authenticated Account acquisition remains an independent capability. Its failure does not reject the Candidate Session.

Each branch allocates into its own arena. A successful Candidate Session takes ownership of each successful branch arena. A failed branch destroys its arena. Presentation destroys all transferred arenas when it rejects a failed, superseded, or stale Candidate Session.

PullRequest, RawDiff, and Comments are required. The first required failure prevents the scheduler from starting more top-level work. A started branch runs to completion, including redirects and Comment pages. The worker then awaits every started branch. This policy avoids a cancellation channel through Presentation, the Bitbucket Client, and `HttpClient`. A measured long-load problem can reopen branch cancellation later.

Completion order does not change the Candidate Session. Assembly uses the logical order PullRequest, RawDiff, then Comments. If multiple required branches fail, the worker reports the first error in that same order.

A Candidate Session has no Session Epoch before publication. The existing replacement intent identifies its load command. Presentation destroys a completion that does not match the latest intent. A successful publication advances the Session Epoch once. Internal branch completions never publish state.

`HttpClient` must permit concurrent `send` calls up to the caller's bound. The production adapter uses one shared `std.http.Client`, whose connection pool guards shared state. The fake selects responses by request key instead of call order. It records active and maximum request counts under a lock. Test controls can release each response in a chosen order. Existing sequential call-order scripts can remain for tests that make no concurrent calls.

Required CI acceptance covers these cases:

- the scheduler never exceeds two active requests;
- every supported completion order produces the same Candidate Session;
- each required branch failure rejects the Candidate Session and frees all owned memory;
- an Authenticated Account failure preserves a read-only Candidate Session;
- a required failure starts no later top-level work and still awaits started work;
- stale replacement intent destroys the Candidate Session without changing the published Session or Session Epoch;
- a local HTTP test proves that two calls overlap through one `StdHttpClient`, then complete and clean up without a Credential.

CI has no timing threshold and uses no live Credential. Before merge, an opt-in Credential-gated check compares sequential and bounded full loads against PullRequests 1856 and 1726. It runs ten alternating samples per policy and includes PullRequest, RawDiff, Comments, and Authenticated Account acquisition. Bounded loading must reduce median latency by at least 30 percent for each PullRequest, use no more than two connections, and produce no request failures or 429 responses. If any threshold fails, M19 keeps sequential loading and records the evidence.
