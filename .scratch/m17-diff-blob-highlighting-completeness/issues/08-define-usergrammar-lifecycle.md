# Define the UserGrammar lifecycle

Type: grilling
Status: resolved
Blocked by: 07, 11

## Question

What is the complete UserGrammar workflow for installation, update, removal, trust, ABI compatibility, query validation, ordered GrammarMatch configuration, compiled/query cache ownership and invalidation, and failure recovery, while preserving hermetic BuiltInGrammar delivery and the public Highlighter seam?

## Answer

### Bundle and trust

- A UserGrammar is a local prebuilt bundle. bbr does not download Grammar sources or compile them. `bbr grammar install` accepts either a folder or a `.tar.gz` archive with the same logical content.
- `grammar.toml` declares the stable Grammar name, bundle version, target OS and architecture, tree-sitter ABI version, exported language symbol, payload paths and SHA-256 digests, Highlighting query, optional locals query, and default GrammarMatch rules. The loader rejects undeclared files, duplicate archive entries, links, unsafe paths, target mismatches, and malformed metadata before it loads native code.
- bbr computes one canonical SHA-256 over the manifest-declared paths and bytes. Interactive installation shows the Grammar identity, GrammarMatch rules, affected BuiltInGrammars, executable-code warning, and digest before confirmation. Non-interactive installation requires `--trust-sha256 <digest>`. One command installs one bundle, so the argument never applies ambiguously to separate payload files.
- Trust applies only to that exact digest. bbr stores the trusted digest and verifies installed payloads at startup. A changed payload disables the UserGrammar until the user installs and trusts the changed bundle. A local path does not imply trust.
- A native UserGrammar executes in the bbr process with bbr's memory and the user's permissions. M17 does not claim sandboxing. User documentation must state this before the install procedure. M27 researches Wasm Grammars and confined helper processes as possible replacements.

### CLI and storage

- The lifecycle commands are `bbr grammar install <bundle>`, `update <name> <bundle>`, `check <bundle-or-name>`, `list`, `remove <name>`, `enable <name>`, and `disable <name>`. Install refuses an existing name. Update requires an existing name. Check does not activate a bundle.
- Installation activates the bundle's default GrammarMatch rules. Disable keeps the installation but restores matching BuiltInGrammars. Enable revalidates conflicts before activation. Removal refuses while `config.toml` still references the UserGrammar.
- Store each UserGrammar under `$XDG_DATA_HOME/bbr/grammars/<name>/`, with the standard `$HOME/.local/share` fallback. Copy a candidate into a sibling temporary directory. Validate trust, compatibility, queries, and registry conflicts before an atomic rename and registry update. An install or update failure preserves the prior installation and active registry entry.

### Validation and matching

- After trust confirmation, load the declared symbol and verify the actual tree-sitter ABI. Validate the Highlighting and optional locals queries atomically with the predicate and RE2 profile defined by [Define the tree-sitter query predicate contract](07-define-tree-sitter-query-predicate-contract.md) and [Choose the query regex engine](11-choose-query-regex-engine.md). Invalid ABI, symbols, Captures, predicates, regexes, or query syntax reject the complete candidate.
- GrammarMatch keeps this category precedence: exact filename, compound suffix, simple extension, then shebang. Within a category, explicit `config.toml` rules precede installed defaults in installation order, which precede BuiltInGrammar rules.
- If `config.toml` supplies any GrammarMatch rules for one UserGrammar, those rules replace all bundle defaults for that UserGrammar. Conflicts between active UserGrammars are invalid.
- An active, trusted UserGrammar automatically takes precedence over an overlapping BuiltInGrammar. Installation reports every affected BuiltInGrammar before confirmation. No separate replacement flag exists. Disable, removal, or runtime failure restores the matching BuiltInGrammar without configuration repair.

### Cache and failure recovery

- A successful install writes a validation receipt keyed by the canonical bundle digest and the bbr and tree-sitter runtime versions. Startup verifies payload digests. It repeats full validation when a payload or runtime identity changes.
- `TreeSitterHighlighter` owns the private Grammar registry, loaded dynamic-library handles, compiled queries, and regexes. It loads an active validated UserGrammar on the first matching File, then reuses that state for the process lifetime. CLI changes apply to new bbr processes. M17 adds no live reload or serialized compiled-query cache.
- An active missing, tampered, incompatible, or invalid UserGrammar produces a precise startup configuration error. An inactive invalid installation appears as invalid in `bbr grammar list` but does not block startup.
- Runtime UserGrammar failure leaves File content usable. Highlighting retries the matching BuiltInGrammar when one exists, then falls back to plain text. A failed update keeps the previous working UserGrammar.

### Documentation and acceptance

- Document the complete user workflow: obtain a platform bundle, inspect and trust it, install and activate it, override GrammarMatch rules, check status, update, disable, enable, remove, and recover from validation or runtime failure. State that SHA-256 proves identity and integrity, not safety.
- End-to-end tests run the real CLI in isolated XDG directories with platform-native fixture libraries. Cover folder and archive installation, interactive and digest trust, automatic activation, BuiltInGrammar precedence and fallback, update rollback, disable and enable, removal, tamper detection, target and ABI rejection, query rejection, runtime fallback, configuration replacement rules, validation receipts, and first-use process caching.
- Measure install validation and first-use load in the end-to-end fixture. Do not add persistent compiled-query caching without representative evidence that these costs delay the user workflow.
