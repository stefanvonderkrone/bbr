# 13: Compare M27 Captures with Neovim on real PullRequests

Status: ready-for-human
Blocked by: 12
Spec: [M27 spec](../SPEC.md)

## What to build

A human compares the M27 highlighting in bbr with Neovim on real PullRequests.
Neovim uses the same Grammars and the same queries, so large differences show adaptation errors.
This check needs a Bitbucket Credential, real Repositories, and a human eye, so an agent cannot run it.

## Steps

1. Install Neovim with nvim-treesitter at the commit that the manifest records.
   Install the parsers for every new BuiltInGrammar.
2. Pick real PullRequests or LocalReviews that change Files in these Grammars: Zig, C, C++, C#, PHP, Python, Rust, Swift, Kotlin, Java, Groovy, TOML, Dockerfile, Make, Ruby, HTML, XML, Markdown, and SQL.
   Add an Odin File from any public Repository if no Review has one.
3. Open each Review in bbr with a fixed-color Theme, such as Catppuccin Mocha.
4. Open the same File at the same commit in Neovim with `:Inspect` available.
5. For each File, compare the color role of comments, strings, keywords, functions, types, and constants.
6. In a Markdown File, check headings, inline code, links, and one fenced code block.
7. In an HTML File, check `<script>` and `<style>` content.
8. In a PHP File, check the PHP code and the HTML around it.
9. Open a `.h` File and confirm that the C++ BuiltInGrammar highlights it.
10. Install a UserGrammar for one new extension, and confirm that it takes precedence.
11. Record each difference with the File, the Line, the bbr role, and the Neovim highlight group.

## Acceptance criteria

- [ ] Every new BuiltInGrammar was checked on at least one real File.
- [ ] Markdown, HTML, and PHP Injection show the expected injected highlighting.
- [ ] Each difference is either explained by the Capture classification table or filed as a new ticket.
- [ ] No Neovim-only predicate removal changes a role that a reviewer needs.
- [ ] The Reviews, the bbr commit, the Theme, and the results are recorded under `## Completion` in this ticket.

## Comments

### Instructions for the human

The agent run stopped at this ticket.
Tickets 01 to 12 are resolved on the branch `m27-zig-builtin-grammar`.
Do the steps below, then record the results under `## Completion`.

#### 1. Build bbr

```sh
cd /Volumes/Work/t3-code/m27-zig-builtin-grammar
zig build -Doptimize=ReleaseSafe
./zig-out/bin/bbr --version
```

Record the commit that `git rev-parse HEAD` prints.

#### 2. Set a fixed-color Theme

Add this line to `$XDG_CONFIG_HOME/bbr/config.toml`, or to `~/.config/bbr/config.toml`:

```toml
theme = "catppuccin-mocha"
```

Use the same Theme in Neovim, for example the `catppuccin/nvim` plugin with the `mocha` flavor.

#### 3. Install Neovim with the pinned nvim-treesitter

The nvim-treesitter `main` branch needs Neovim 0.11 or later and the `tree-sitter` CLI on `PATH`.
Use a separate Neovim profile, so your normal setup does not change:

```sh
export NVIM_APPNAME=bbr-m27
D="$HOME/.local/share/$NVIM_APPNAME/site/pack/m27/start"
mkdir -p "$D"
git clone https://github.com/nvim-treesitter/nvim-treesitter "$D/nvim-treesitter"
git -C "$D/nvim-treesitter" checkout a2f694478be07f89c2d03cc17858a8745a400c4b
mkdir -p "$HOME/.config/$NVIM_APPNAME"
cat > "$HOME/.config/$NVIM_APPNAME/init.lua" <<'LUA'
vim.api.nvim_create_autocmd('FileType', {
  callback = function() pcall(vim.treesitter.start) end,
})
LUA
nvim --headless -c 'lua require("nvim-treesitter").install({"zig","c","cpp","c_sharp","php","php_only","python","rust","odin","swift","kotlin","java","groovy","toml","dockerfile","make","ruby","html","xml","markdown","markdown_inline","sql","javascript","css","json","yaml"}):wait(1800000)' -c q
```

The commit is the one that `vendors/tree-sitter/manifest.zig.zon` records in `.nvim_treesitter.commit`.
Each parser revision then equals the bbr manifest `.commit` of that Grammar.

#### 4. Pick the Files

Use real PullRequests if you have them.
Open one with `bbr` and its normal Credential.
Otherwise, make a LocalReview from public files:

```sh
mkdir -p "$TMPDIR/m27-review" && cd "$TMPDIR/m27-review" && git init -q
git commit -q --allow-empty -m base
# Copy one real File for each Grammar into this directory.
# Use real code from public repositories, not a toy sample.
git add -A && git commit -q -m files
/Volumes/Work/t3-code/m27-zig-builtin-grammar/zig-out/bin/bbr local HEAD~1 HEAD
```

Include at least these Files:
`.zig`, `build.zig.zon`, `.c`, `.h`, `.cpp`, `.cs`, `.php` (with HTML around the PHP code), `.py`, a Python script with only a shebang, `.rs`, `.odin`, `.swift`, `.kt`, `.java`, `.groovy`, `Jenkinsfile`, `.toml`, `Dockerfile`, `Makefile`, `.rb`, `Gemfile`, `.html` (with `<script>` and `<style>`), `.xml`, `.svg`, `.md` (with a fenced `zig` block and inline code), and `.sql`.

#### 5. Compare each File

1. Open the File in bbr, and select the new version.
2. Open the same File in Neovim with `NVIM_APPNAME=bbr-m27 nvim <file>`.
3. In Neovim, put the cursor on a token and run `:Inspect`.
   It names the Capture, such as `@keyword.function`.
4. Compare the color of comments, strings, keywords, functions, types, and constants.
5. Use the table "Capture classification" in `.scratch/m27-zig-builtin-grammar/SPEC.md` to map a Capture name to a bbr role.
   A Capture that maps to no role shows in the default foreground in bbr.
   Markdown emphasis, `@none`, and `@diff` stay in the default foreground by design.

#### 6. Check these cases

- Markdown: headings, inline code, links, and a fenced code block.
- HTML: `<script>` content has JavaScript colors, and `<style>` content has CSS colors.
- PHP: the PHP code has PHP colors, and the HTML around it has HTML colors.
- A `.h` File uses the C++ BuiltInGrammar. bbr does not show the Grammar name.
  So use C++-only code in the header, such as a `class` or a `namespace`, and check that it has keyword colors.
- A UserGrammar keeps precedence. Install a UserGrammar for one new extension, for example `.toml`.
  Run `bbr grammar check <bundle>` first. Its output must name the TOML BuiltInGrammar as affected.
  Then install it with `bbr grammar install <bundle>`, and open a `.toml` File.
  The colors must come from the UserGrammar.
  Remove it after with `bbr grammar remove <name>`.

#### 7. What to look for

- A token with a color in Neovim and no color in bbr can show a removed Neovim-only form.
  Search the adapted query in `vendors/tree-sitter/<tag>/queries/highlights.scm` for a `; bbr: removed` comment near that pattern.
- A wrong color can show a wrong row in the Capture classification table.
- An injected region with no color can show an Injection that the adaptation removed.
  Search `vendors/tree-sitter/<host>/queries/injections.scm` for `; bbr: removed pattern`.
- The HTML `style` attribute value `color: red` shows `color` with the CSS tag color.
  tree-sitter-css parses it as a selector. Neovim must show the same.

#### 8. Record the results

Add `## Completion` to this ticket with these items:

- The Reviews or LocalReviews, the bbr commit, and the Theme.
- For each File: the Grammar, and "same" or a list of differences.
- For each difference: the File, the Line, the bbr role, and the Neovim highlight group.
- For each difference: the reason from the Capture classification table, or a link to a new ticket.

Then tick the acceptance criteria that the results prove, and set `Status: resolved`.
After that, set the SPEC `Status: resolved` with the integrated evidence, as `docs/agents/issue-tracker.md` describes.
