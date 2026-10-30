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
