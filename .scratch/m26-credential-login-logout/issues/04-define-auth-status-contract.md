# Define the M26 auth status contract

Label: wayfinder:grilling
Type: grilling
Status: open
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
