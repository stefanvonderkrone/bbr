# Choose the M26 auth storage safety policy

Label: wayfinder:grilling
Type: grilling
Status: open
Blocked by: none
Parent: ../map.md

## Question

How must M26 handle auth directory permissions and unsafe filesystem targets while preserving TOML Profiles and prior valid Credentials?

The milestone requires a `0700` parent directory, a `0600` auth file, atomic replacement, and refusal of unsafe non-regular targets.
Both inspected bbr directories were `0755`. The saved fallback auth file was `0600`.
Current code uses default directory permissions and does not explicitly enforce the directory or target requirements.
Choose whether login repairs existing directory permissions or refuses unsafe permissions.
Define which directories bbr can change without changing unrelated XDG parent directories.
Specify treatment of symlinks, directories, special files, and unexpected ownership at the auth directory and file.
Define the required behavior on permission or replacement failure and on interrupted login.
Set expectations for read-only status and logout when storage is unsafe.
The TOML format is settled. Do not reopen a JSON migration.

Coverage: the storage item in the original review table. Storage failure evidence feeds the completion contract.

References:

- `src/bitbucket/auth.zig`, `load`, `save`, `upsertProfile`, and logout helpers.
- `TODO.md`, M26 storage requirement and measured permission evidence.
- The installed Zig standard library for filesystem behavior. Follow the `zig` skill before making API claims.
