# Bitbucket's diff is the authoritative line model

We parse Bitbucket's own unified diff (and its line numbers) as the source of truth for
files, hunks, and line numbering, rather than recomputing a diff locally from the two file
blobs. Bitbucket anchors inline comments by file path + old/new line number; if our local
diff diverged from theirs (whitespace, rename detection, EOL/binary quirks), a comment we
POST would silently land on the wrong line in the Bitbucket UI.

## Consequences

We still compute one thing locally — the **intra-line** (word-level) diff over adjacent
removed/added pairs — but only to drive cosmetic change emphasis, where divergence is
harmless. Anchoring correctness is thereby structurally guaranteed, not tested-for.
