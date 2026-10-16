# 06: Auth storage safety

**What to build:** Stored Credentials rest on private, atomic, symlink-tolerant storage so an interrupted write never erases a valid Credential and unsafe targets fail loudly.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] New auth directories are created private and the auth directory alone is repaired to private on login and logout, never parents; failed repair warns and continues.
- [ ] Profile saves replace the file atomically, keep prior data on interruption or failure, merge the upserted Profile without dropping others, and enforce private file mode with a visible warning when enforcement fails.
- [ ] Symlinked auth paths are followed normally; a directory or special file at the file path, or a non-directory at the directory path, refuses with exit `1` and saves nothing.
- [ ] Hermetic tests prove modes, atomic-failure preservation, unsafe targets, and symlink following through the shared filesystem interfaces; no test asserts private helpers or buffer sizes.
