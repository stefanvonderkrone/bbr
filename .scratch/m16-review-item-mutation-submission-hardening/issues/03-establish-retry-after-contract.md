# Establish Bitbucket's Retry-After contract

Type: research
Status: resolved
Blocked by: none

## Question

What do Bitbucket Cloud's primary documentation and observable responses establish about rate-limit status codes, `Retry-After` syntax and units, related rate-limit headers, missing or malformed values, and practical retry ceilings that M16's HttpClient, CommentPoster, and clock-free Submission policy must preserve?

## Answer

Bitbucket Cloud documents `429 Too Many Requests` for rate limiting but does not guarantee a `Retry-After` header. When present, parse both HTTP-standard forms: non-negative integer delay-seconds and an HTTP-date. Missing, malformed, or already-expired values fall back to bbr's bounded local backoff. Bitbucket documents no provider-specific retry-duration, attempt-count, or elapsed-time ceiling, so M16 must choose a local ceiling and must never retry earlier than a valid server-requested delay.

Observed `X-RateLimit-Remaining` and `X-RateLimit-Reset` headers are undocumented and therefore diagnostic evidence only, not policy inputs. The comment endpoint schemas omit `429`, no Bitbucket-specific `Retry-After` example or malformed-value rule was found, and the investigation did not deliberately induce a live `429`.

Context: `docs/research/bitbucket-retry-after.md` on branch `research/bitbucket-retry-after`, commit `d8436c4beb8653d63ceecd3360d06b91c7885580`.
