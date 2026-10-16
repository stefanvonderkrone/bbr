# 12: Credential containment

**What to build:** Secrets never leak through tooling: no Credential value appears in any human- or machine-readable output the program produces.

**Blocked by:** 08 Interactive auth login; 09 Non-interactive auth login; 10 Auth status; 11 Auth logout and local isolation.

**Status:** ready-for-agent

- [ ] No Credential value appears in diagnostics, logs, Authorization headers, token-bearing URLs, stored files beyond the private auth file, or test snapshots.
- [ ] Containment evidence combines omission where code never prints upstream text with redaction tests where it does, spanning diagnostics, logs, headers, URLs, storage, and snapshots.
- [ ] Existing diagnostic-omission and URL-stripping tests receive credit; new tests cover only the gaps and no test exists solely to raise counts.
