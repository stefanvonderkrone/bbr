# Contain the exposed Credential

Type: task
Status: resolved
Blocked by: none

## Question

Rotate the API token reported in plaintext `opencode.jsonc`, remove every tracked or local plaintext copy, and record a safe environment or system-keychain injection procedure without reading, printing, logging, or copying the Credential value into this tracker. Record only sanitized locations, completed containment actions, and any follow-up facts needed by the M19 specification.

## Answer

The user revoked both exposed Atlassian tokens. The user removed `.env`, `test.sh`, and the two `opencode.jsonc` backup files. A sanitized scan found no plaintext Credential field in `~/.config/opencode/opencode.jsonc`.

The replacement Bitbucket token lives in macOS Keychain under the `bbr-bitbucket-token` service. The ignored executable `run-bbr` reads it with `security find-generic-password`, exports it as `BITBUCKET_TOKEN` for the `bbr` process, and keeps the value out of shell history and repository files. Verification confirmed the Keychain item exists, the wrapper passes `bash -n`, and the removed plaintext files remain absent.
