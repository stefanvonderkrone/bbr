# Choose the external-editor configuration language

Type: grilling
Status: resolved
Blocked by: 07

## Question

What exact public TOML table and key should name the External Edit returned-file byte limit, whose settled semantics are a 1 MiB default, a required positive value, and refusal to read or apply an oversized result; and what configuration diagnostic and documentation wording keep that local safety bound distinct from any undocumented Bitbucket Comment character limit?

## Answer

Expose the returned-file safety limit as:

```toml
[external_edit]
max_bytes = 1048576
```

`External Edit` is the settled interaction name, so `[external_edit]` states the scope without confusing the external program with the Composer. Within that table, `max_bytes` follows the existing scoped-budget naming convention and accurately describes the bytes bbr will accept back; `max_file_bytes` would incorrectly suggest a general limit on either temporary file.

Default `max_bytes` to 1 MiB (`1048576`) and require a positive integer. An explicit zero produces `External Edit byte limit must be greater than zero` with `help: use max_bytes = 1048576 for the default`. Keep the strict configuration parser's established diagnostic shapes for the other failures: expect a positive integer byte count for malformed or negative values, report `External Edit byte limit is too large` on `usize` overflow, reject duplicate `max_bytes`, reject unknown External Edit keys with a `use max_bytes` hint, and include `[external_edit]` in the valid-table hints. Add no aliases for alternate spellings.

Document the setting in the sample configuration and with this user-facing contract:

> `[external_edit].max_bytes` limits the number of bytes bbr will read back from the temporary file after External Edit. It defaults to 1 MiB and must be greater than zero. If the file is larger, bbr leaves the Composer unchanged and reports that External Edit was not applied. This is a local safety limit, not a Bitbucket Comment character limit; bbr does not assume an undocumented Bitbucket limit.

The runtime oversized-result diagnostic should name the configured bound while preserving the settled non-fatal outcome, for example `External edit not applied: returned file exceeds the 1048576-byte limit`. Measure the raw returned file in bytes before allocating or reading it in full; do not reinterpret the setting as a character count or as validation of what Bitbucket will accept.
