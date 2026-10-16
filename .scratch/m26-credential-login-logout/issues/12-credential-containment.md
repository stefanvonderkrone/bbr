# 12: Credential containment

**What to build:** Secrets never leak through tooling: no Credential value appears in any human- or machine-readable output the program produces.

**Blocked by:** 08 Interactive auth login; 09 Non-interactive auth login; 10 Auth status; 11 Auth logout and local isolation.

**Status:** done

- [x] No Credential value appears in diagnostics, logs, Authorization headers, token-bearing URLs, stored files beyond the private auth file, or test snapshots.
- [x] Containment evidence combines omission where code never prints upstream text with redaction tests where it does, spanning diagnostics, logs, headers, URLs, storage, and snapshots.
- [x] Existing diagnostic-omission and URL-stripping tests receive credit; new tests cover only the gaps and no test exists solely to raise counts.

## Comments

Implemented on `m26-auth-integration` (`ceb8698`). Containment holds by
omission: login, status, and API paths print only classified error names,
never upstream bodies, headers, URLs, or token values. Status prints the
token source, never the token. The harness asserts secrets never echo
(terminal transcript, `--stdin` errors, status output). Existing
diagnostic-omission and URL-stripping tests keep their credit; no test
exists only for counts. Suite 1113/1113.
