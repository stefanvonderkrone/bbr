# Define the M26 auth status contract

Label: wayfinder:grilling
Type: grilling
Status: resolved
Blocked by: 02, 03
Parent: ../map.md

## Question

What must `bbr auth status` report, validate, and return for each Credential state under the accepted source policy?

The milestone requires source, account email, Workspace, and validation result without the token.
Choose whether status always validates live or distinguishes local inspection from live validation through an explicit option.
Define source reporting for stored Profiles and environment overrides using the resolved Credential source decision.
Distinguish a configured email from an account identity proven by Bitbucket.
Specify safe output and exit status for missing Credentials, invalid storage, authentication failure, forbidden Workspace access, and transport failure.
Define Profile selection and whether status can modify storage. Avoid treating a network failure as proof of invalid Credentials.

Prerequisites:

- [Choose the M26 Credential source policy](./02-choose-credential-source-policy.md) determines source reporting and selection.
- [Choose the M26 auth storage safety policy](./03-choose-auth-storage-safety-policy.md) determines treatment of unsafe storage.

Coverage: the command-group and status-output items in the original review table.
This ticket specifies one command within the existing command implementation handoff.

References:

- `TODO.md`, M26 auth command and status requirements.
- `src/main.zig`, current dispatch and login validation.
- `src/bitbucket/client.zig`, account and Workspace probes.
- `src/bitbucket/CONTEXT.md`, Credential, Profile, and Authenticated Account.

## Answer

`bbr auth status [profile]` always validates live. There is no local-only mode and no `--validate` flag. It runs the same two probes as login: `GET /user` for the Authenticated Account UUID and the Workspace repository check. Unknown arguments are usage errors with exit `1`.

Selection follows the source policy: positional Profile, then `--profile`, then `BBR_PROFILE`, then the Active Profile, then `default`, with per-field env overlay. There is no `--workspace` override on status. Status never writes storage and never chmods.

On success it reports the Profile name, the configured email, the Workspace, per-field file versus env source markers, the proven account UUID, and separate account and Workspace validation results. The token never prints in any form. Exit `0` only when both probes pass.

Failures exit `1` with distinct reports: missing Credential hints `bbr auth login`; malformed or unsafe storage reports without repair; `401` reports invalid Credential; forbidden or invisible Workspace reports separately; transport, rate-limit, and server failures report as transport and never as invalid Credentials.
