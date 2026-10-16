# Choose the M26 auth storage safety policy

Label: wayfinder:grilling
Type: grilling
Status: resolved
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

## Answer

New bbr dirs are `0700`. Existing bbr dirs are repaired to `0700` on login and logout. Only the bbr dir is touched, never `XDG_DATA_HOME`, `HOME`, or higher parents. A failed dir repair warns and continues.

`auth.toml` is written with atomic replacement and `0600`. A failed `0600` enforcement warns and keeps the file. Any other write or replace failure exits `1` with nothing saved. An interrupted login keeps the prior valid Credential through the atomic write. Saved TOML Profiles merge, never drop.

Symlinks at the bbr dir and `auth.toml` are followed. A directory, fifo, socket, or device node at `auth.toml`, or a non-directory at the bbr path, refuses with exit `1`. bbr never reads through or replaces those targets. There is no uid ownership check.

Status never chmods or repairs. It reports unsafe storage and exits `1`. Logout attempts the same bbr-dir repair, then refuses directory or special file targets with exit `1`. Logout succeeds when the file is absent.
