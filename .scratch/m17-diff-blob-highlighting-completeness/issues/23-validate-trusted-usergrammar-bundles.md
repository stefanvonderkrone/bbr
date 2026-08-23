# 23 — Validate Trusted UserGrammar Bundles

**What to build:** Validate a local UserGrammar folder or archive and report whether its exact native payload is compatible and safe to install, without activating it.

**Blocked by:** 21 — Execute BuiltInGrammar Match Predicates; 22 — Track Locals for BuiltInGrammars.

**Status:** ready-for-agent

- [ ] Folder and `.tar.gz` candidates accept only manifest-declared regular files and reject links, duplicate entries, extra files, unsafe paths, and digest mismatches.
- [ ] Validation checks Grammar identity, version, target, tree-sitter ABI, exported symbol, payload digests, Highlighting query, optional locals query, predicates, regexes, and default GrammarMatch rules.
- [ ] Interactive validation reports native-code risk, the canonical SHA-256 digest, Grammar identity, matches, and affected BuiltInGrammars before trust.
- [ ] Non-interactive trust accepts only an exact `--trust-sha256` digest, and changed bytes require a new trust decision.
- [ ] Checking a candidate does not activate or modify any installed UserGrammar or registry state.
