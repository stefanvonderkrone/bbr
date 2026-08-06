# Choose Comment scopes and default Actions

Type: grilling
Status: resolved
Blocked by: 13

## Question

Given Bitbucket's verified Comment capabilities, which scopes should M15 expose and how should `i`, `I`, and `C` map to inline, File-level, and Review-level Comment authoring, including Composer labels, Action names, help text, and a replacement binding for the recovery-only `link_existing_comment` Action?

## Answer

Expose all three root Comment scopes in both RemoteReview and LocalReview, using the following default bindings and configurable Action names:

- `i` → `inline_comment`
- `I` → `file_comment`
- `C` → `review_comment`

Remove the ambiguous existing `comment` Action and its lowercase `c` binding without an alias. Breaking default-key and configuration changes are acceptable during initial development, and retaining `c` would weaken the deliberate `i` / `I` / `C` scope ladder.

Use scope-explicit Composer labels and help text:

- `Inline Comment on {path}:{line/range}` / `new inline comment`
- `File-level Comment on {path}` / `new file-level comment`
- `Review-level Comment` / `new review-level comment`

Target each Action from the focused Pane. `inline_comment` is available only in the DiffPane and uses its valid current Line or Selection. `file_comment` uses the Sidebar cursor's File when the Sidebar is focused, or the DiffPane cursor's File when the DiffPane is focused; it is unavailable on a Directory. `review_comment` is available from either Pane whenever a Review is loaded.

Review-level is the canonical domain scope, replacing PullRequest-level. It belongs to either kind of Review; Bitbucket still maps a Review-level root to an omitted `inline` field. This corrects the vocabulary in [Choose the File-level Comment model](13-choose-file-level-comment-model.md) without changing its remote wire contract.

Move the recovery-only `link_existing_comment` Action from `C` to the mnemonic multi-chord `gC`. It remains visible according to the existing ActionAvailability rules and is only useful for an `outcome_unknown` Draft; the common single-key `C` belongs to Review-level authoring.
