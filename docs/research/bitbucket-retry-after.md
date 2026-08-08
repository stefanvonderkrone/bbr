# Bitbucket Cloud `Retry-After` contract

Research date: 2026-08-08

## Verdict

Treat HTTP `429 Too Many Requests` as Bitbucket Cloud's rate-limit response. If
`Retry-After` is present, parse the standard HTTP field: either a non-negative
decimal number of seconds or an HTTP date. Bitbucket's own documentation does
**not** promise that the field is present, narrow it to the numeric form, or
publish a maximum value or retry-attempt ceiling.

Consequently, a client should:

1. honor a valid `Retry-After` without retrying earlier;
2. accept both standard syntaxes, rather than assuming Bitbucket emits seconds;
3. use its own bounded backoff policy when the field is absent or unusable; and
4. stop automatic retry and surface a resumable failure when its local attempt
   or elapsed-time budget is exhausted. A local ceiling must not turn a longer
   server delay into an earlier retry.

HTTP `503 Service Unavailable` can also carry `Retry-After`, but it describes
service availability, not proof that a Bitbucket rate quota was exceeded.

## Established facts

### Rate-limit status

- `429 Too Many Requests` is the standard status for a user sending too many
  requests in a period. Its response may include `Retry-After`; the field is not
  mandatory. The standard deliberately does not define how a service identifies
  a caller or counts requests. See [RFC 6585, section
  4](https://www.rfc-editor.org/rfc/rfc6585.html#section-4).
- Atlassian's Bitbucket-specific troubleshooting guidance confirms that a
  Bitbucket API rate-limit breach returns `429` (or the message "Rate limit for
  this resource has been exceeded") and says request allowance accrues again
  during a backoff period. It does not mention or guarantee `Retry-After`. See
  [Bitbucket Cloud Rate Limit
  Troubleshooting](https://support.atlassian.com/bitbucket-cloud/kb/bitbucket-cloud-rate-limit-troubleshooting/).
- Bitbucket Cloud publishes hourly REST API limits. It measures unauthenticated
  calls by IP address and authenticated calls by user ID, and describes the
  window as a one-hour rolling window. It also warns that resource/rate limits
  are not part of the API and may change, including dynamically. See
  [Atlassian's Bitbucket Cloud API request limits](https://support.atlassian.com/bitbucket-cloud/docs/api-request-limits/).
- No first-party Bitbucket source found in this investigation documents `403` as
  an alternative rate-limit status. Do not borrow another provider's `403`
  throttling behavior for Bitbucket.
- Bitbucket's pull-request comment operation schemas do not list `429` among
  their per-operation responses: for example, create lists `201`, `403`, and
  `404`, while update lists `200`, `403`, and `404`. This omission cannot mean
  the operations are exempt from Bitbucket's separately documented global API
  limits. See [Bitbucket Cloud pull-request comment
  operations](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-comments-post).

### `Retry-After` syntax and units

The HTTP field grammar is:

```text
Retry-After = HTTP-date / delay-seconds
delay-seconds = 1*DIGIT
```

The numeric form is a non-negative decimal integer measured in **seconds after
the response is received**. The date form is an absolute HTTP date. See [RFC
9110, section 10.2.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3).

Bitbucket's documentation does not refine this grammar. In particular, it does
not say that Bitbucket always emits integer seconds. Atlassian documentation for
Jira or Confluence that says their `Retry-After` value is seconds is scoped to
those products and is not evidence of a Bitbucket-specific promise.

Practical parsing consequences:

- `Retry-After: 120` means wait 120 seconds.
- A valid HTTP date means wait until that instant; a date already in the past
  yields no remaining server-requested delay.
- Negative numbers, fractional numbers, non-dates, empty values, integer
  overflow, and ambiguous combined/multiple values do not match a usable field
  value. The standards provide no recovery algorithm for malformed values.
- Missing and malformed values therefore provide no server deadline. They do
  not justify an immediate retry; the client needs its own fallback backoff.

### Related Bitbucket headers

For endpoints eligible for scaled limits, Atlassian documents these response
headers for access-token and Forge `asApp` requests:

- `X-RateLimit-Limit`: total requests permitted per hour, not remaining calls;
- `X-RateLimit-Resource`: the endpoint resource group; and
- `X-RateLimit-NearLimit`: `true` when less than 20% remains.

These are advisory capacity signals. They do not replace `Retry-After`, and the
published Bitbucket page does not document `X-RateLimit-Remaining` or
`X-RateLimit-Reset`. See [Atlassian's rate-limit response-header
section](https://support.atlassian.com/bitbucket-cloud/docs/api-request-limits/#Scaled-rate-limits).

Two ordinary, unauthenticated requests to `api.bitbucket.org` on 2026-08-08
returned the following additional headers even though the responses were `404`
and `410`, not throttling responses:

```text
X-RateLimit-Limit: 60, 60;w=3600
X-RateLimit-Remaining: 59
X-RateLimit-Reset: 3019
```

A second observation about one minute later showed a reset value of `2957`.
This is consistent with a relative count of seconds, but the sample is too small
and the fields are undocumented for this request class. It does not establish a
contract, and client correctness should not depend on this inferred unit or the
comma-separated `X-RateLimit-Limit` shape.

### What can be concluded about ceilings

No inspected Bitbucket source specifies:

- a maximum `Retry-After` duration;
- a maximum number of retries;
- a maximum total time spent retrying;
- a guarantee that capacity is available when the delay expires; or
- stable quota/window values from which such a maximum can be derived.

The hourly window and published request counts describe quota accounting, not a
retry ceiling. They are also explicitly subject to dynamic change. The standard
numeric grammar has no stated digit bound, and the date form can name a distant
future instant. A finite ceiling must therefore be a product policy.

A safe ceiling has two effects: it limits how long the client will automate the
operation, and it preserves the item for explicit later retry. It must **not**
clamp a server-requested wait downward and then send early. For example, if the
server asks for one hour but the client only automates waits up to five minutes,
the safe result is to pause/fail resumably with the server deadline visible—not
to retry after five minutes.

## Recommended client decision table

| Response | Usable `Retry-After` | Client interpretation |
| --- | --- | --- |
| `429` | yes | Rate-limited; schedule no earlier than the parsed deadline, subject to the local automation budget. |
| `429` | no/malformed | Rate-limited; use bounded exponential backoff with jitter, preserving the failure if the budget ends. |
| `503` | yes | Temporarily unavailable; use the parsed deadline under the same no-earlier-than rule. |
| other retryable `5xx` | absent | Apply the client's ordinary bounded transient-failure backoff; this is not a `Retry-After` fact. |
| `403` | any | Do not classify as Bitbucket rate limiting without stronger response evidence; handle as authorization/forbidden. |

For mutating comment requests, this scheduling policy does not by itself make a
retry safe. An ambiguous transport failure can occur after Bitbucket accepted a
write, so the existing reconcile/deduplicate-before-repost rule remains
necessary.

## Evidence gaps

- Atlassian publishes no Bitbucket-specific `Retry-After` guarantee, examples,
  malformed-value policy, or ceiling.
- The pull-request comment OpenAPI operations omit `429` and rate-limit headers,
  so they cannot answer whether every comment/reply mutation is throttled by the
  same bucket or which headers appear on its `429` response.
- No deliberate rate-limit test was performed. Exhausting a live quota would
  impose avoidable load and could affect other callers sharing the observed
  unauthenticated IP-based bucket.
- The ordinary-response observation establishes only current behavior at one
  edge location and time. It did not observe a `429` and cannot establish the
  presence or representation of `Retry-After` on a throttled Bitbucket response.
