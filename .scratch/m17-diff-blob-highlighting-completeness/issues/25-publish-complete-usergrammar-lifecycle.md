# 25 — Publish the Complete UserGrammar Lifecycle

**What to build:** Ship the complete trusted UserGrammar management workflow as one CLI and runtime feature. Failed changes must preserve the prior installation and active registry.

**Blocked by:** 24 — Activate UserGrammars Through the Registry.

**Status:** ready-for-agent

- [ ] `grammar install`, `update`, `check`, `list`, `remove`, `enable`, and `disable` are all available together and enforce their specified preconditions.
- [ ] Install activates declared default GrammarMatch rules; enable revalidates conflicts; disable keeps files; remove refuses configured references.
- [ ] Candidate copy, validation, installation replacement, and registry update are atomic in the XDG data directory.
- [ ] A failed install or update preserves the prior working installation and registry, and CLI changes apply only to new bbr processes.
- [ ] Real CLI tests in isolated XDG directories cover folder and archive input, interactive and digest trust, rollback, conflict handling, configuration replacement, fallback, tampering, and inactive invalid installations.
- [ ] Documentation states the native-code risk before installation instructions and makes clear that bbr neither downloads nor compiles UserGrammars.
