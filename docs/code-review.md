# Code review with Open Code Review

Open Code Review (`ocr`) selects the files of a change and the review rules for each file.
bbr uses it in delegation mode: the coding agent reviews the change, so `ocr` needs no model provider and no API key.

## Run a review

Ask the `ocr-review` agent to review workspace changes, a commit, or a branch.
The agent follows the `open-code-review-delegate` skill in `.agents/skills/`.
The permissions of the agent in `opencode.jsonc` deny edits and every shell command except `ocr`, `cat`, and the read-only `git --no-pager` commands of the skill.

## Install the CLI

The review needs the `ocr` CLI, version 1.14.0, on `PATH`.
Install the release binary for the host from the [v1.14.0 release](https://github.com/alibaba/open-code-review/releases/tag/v1.14.0), and check it against `sha256sum.txt`.
Do not install the npm package, because it updates itself ([Open Code Review installation](https://github.com/alibaba/open-code-review/blob/v1.14.0/pages/src/content/docs/en/installation.md)).
The troubleshooting section of the skill tells the agent to install the npm package. The prompt of the agent overrides that advice, and its shell permissions block `npm`.

## Review rules

`.opencodereview/rule.json` holds the review rules, and `ocr delegate rule <path>` shows the rule for a file.
Do not edit `rule.json` directly. Edit `.opencodereview/build_rules.py` and run `python3 .opencodereview/build_rules.py`.
