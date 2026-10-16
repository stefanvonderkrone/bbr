# 06: Auth storage safety

**What to build:** Stored Credentials rest on private, atomic, symlink-tolerant storage so an interrupted write never erases a valid Credential and unsafe targets fail loudly.

**Blocked by:** None (can start immediately).

**Status:** done

- [x] New auth directories are created private and the auth directory alone is repaired to private on login and logout, never parents; failed repair warns and continues.
- [x] Profile saves replace the file atomically, keep prior data on interruption or failure, merge the upserted Profile without dropping others, and enforce private file mode with a visible warning when enforcement fails.
- [x] Symlinked auth paths are followed normally; a directory or special file at the file path, or a non-directory at the directory path, refuses with exit `1` and saves nothing.
- [x] Hermetic tests prove modes, atomic-failure preservation, unsafe targets, and symlink following through the shared filesystem interfaces; no test asserts private helpers or buffer sizes.

## Comments

Implemented on `m26-auth-integration` (`ceb8698`). `ensureAuthDir` creates and
repairs only the `bbr` dir to `0700` with warn-and-continue, never parents.
`checkFileTarget` refuses directory and special kinds; symlinks follow to the
target kind. `save` keeps atomic replace, enforces `0600` with a visible
warning, and preserves prior data on failure. `load` refuses unsafe targets.
`removeProfile` and `deleteAuthFile` repair the dir and refuse unsafe targets.
New tests: dir/file modes, repair, dir-at-file refusal, non-dir refusal,
symlinked-dir following. Suite 1113/1113.
