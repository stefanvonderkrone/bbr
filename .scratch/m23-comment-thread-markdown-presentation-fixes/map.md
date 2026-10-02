# M23 Comment thread and Markdown presentation fixes

Label: wayfinder:map

## Destination

An agreed, implementation-ready specification for M23 Comment thread and Markdown presentation fixes.
The map ends when behavior, Bitbucket facts, and acceptance criteria leave no open implementation decisions.

## Notes

- This map plans M23. It does not implement the application or produce the final specification during charting.
- The source milestone is [M23 in TODO.md](../../TODO.md).
- The Markdown target is the user-selected [Bitbucket Markdown syntax guide](https://confluence.atlassian.com/bitbucketserver/markdown-syntax-guide-776639995.html).
- That guide describes Data Center. The application uses Bitbucket Cloud REST API 2.0.
- Research must identify Cloud differences rather than assume the two products have the same Markdown behavior.
- The guide expands the original milestone beyond inline styles and lists. Terminal presentation decisions remain open.
- M23 retains the original Reply indentation, emoji conversion, and raw authored Markdown yank requirements.
- Reply presentation covers published Replies, Draft Replies, and mixed published and Draft ancestry.
- Explore the existing `y` Action copying a complete raw body from any ReviewCard row.
- Search must accept both displayed emoji characters and their authored shortcodes.
- Investigate code-block syntax colors through existing Highlighting. Code-block text remains literal.
- Primary contexts are Review, Presentation, Bitbucket, and Highlighting.
- Read `CONTEXT-MAP.md` and the relevant `CONTEXT.md` files. Consult ADR-0012 for the Presentation seam.
- Use `grilling` and `domain-modeling` for decision tickets. Use `research` for external facts.
- Use `prototype` when a terminal example is needed to choose behavior.
- Use `technical-writing` and `unslop` for tracker files. Use `zig` when reasoning about Zig interfaces.
- Tracker operations follow [the local issue tracker](../../docs/agents/issue-tracker.md).
- An open ticket uses `Status: ready-for-agent` or `Status: needs-info`. A claim uses `Status: claimed`.
- A resolution appends `## Answer` to its ticket and changes its status to `resolved`.
- Child tickets carry a relative `Parent:` link. Dependencies use `Blocked by:` identifiers within this directory.
- Research assets also live on separate `research/m23-*` branches through temporary worktrees.
- Research can resolve in parallel. Charting does not resolve human decision tickets.

## Decisions so far

- [Research Bitbucket Cloud Markdown compatibility](./issues/01-research-bitbucket-cloud-markdown-compatibility.md): Cloud names Python-Markdown, not CommonMark, and exact list and fence parity remains unobserved.
- [Research Bitbucket Cloud emoji shortcodes](./issues/02-research-bitbucket-cloud-emoji-shortcodes.md): Cloud publishes no definitive catalog. An Atlassian fixture supplies candidate Unicode mappings, not complete Cloud compatibility.
- [Choose nested Reply presentation](./issues/03-choose-nested-reply-presentation.md): Group parent subtrees with published-first siblings. Reduce the viewport-dependent unit before capping indentation to preserve body width.
- [Choose raw ReviewBody yank behavior](./issues/07-choose-raw-reviewbody-yank-behavior.md): Copy complete bodies or mixed selected logical lines. Both modes respect Selected Version and preserve authored bytes.

## Not yet specified

- Terminal examples can expose interactions between deep Reply ancestry and complex Markdown bodies.
- The live fixture work depends on the compatibility policy and the evidence gaps it selects for verification.
- The acceptance contract can expose missing decisions when it combines search, disclosure, clipboard, and Highlighting behavior.

## Out of scope

- Implementing M23 during this planning effort.
- Adding Bitbucket Server or Data Center transport support. The guide is a presentation reference.
- Other milestones, including the Repository Browser and durable File read state.
- Changing authored Comment or Draft bytes to match their presentation.
