# CLI rules

This document holds the checked rules for `bbr api`, stdout and stderr output, and the XDG config paths. The parts that no check covers are in [`CODING_STANDARDS.md`](../../CODING_STANDARDS.md).

## XDG base directory reads

Only `src/xdg.zig` reads `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `XDG_STATE_HOME`. Other code calls `xdg.configHome`, `xdg.dataHome`, `xdg.stateHome`, or `xdg.configFile`. These functions ignore an empty or relative base.

Enforcement: `tools/check_xdg_reads.py`, run by `zig build test`. The check skips `test` blocks, `env.put(` lines, and comments.

## Streaming stdout and stderr writers

A stdout or stderr writer uses `writerStreaming`. `std.Io.File.writer` writes at absolute offsets from 0. Thus it overwrites earlier text in a redirected file, and later writers overwrite its text. Code uses `stdout()` and `stderr()` only as `.writerStreaming(`, or as `.handle` on one side of `==` or `!=`. This way, no alias and no File built from the handle can hide a positional writer.

Enforcement: `tools/check_stdio_writers.py`, run by `zig build test`. `zig fmt --check`, also run by `zig build test`, removes the spaces that could split the call chain. `tests/redirected_output_cli_test.py`, run by `zig build test-cli`, checks the bbr text in a file that holds earlier output.

## One stdout writer

Only `src/stdout.zig` makes a stdout writer. Other code writes stdout through `bbr.stdout.write`, `bbr.stdout.print`, or `bbr.stdout.writeAll`.

A failed write returns its cause, not `error.WriteFailed`. When the reader closes the pipe, the cause is `error.StdoutClosed`. For example, `head` closes the pipe after enough lines. On that error, `main` in `src/main.zig` and in `src/benchmark/main.zig` ends with exit 0 and no message. A site that reports its own errors returns `error.StdoutClosed` without a report. Examples are `bbr api`, `bbr grammar`, and `bbr auth status`. Every other write failure still fails.

Enforcement: `tools/check_stdio_writers.py`, run by `zig build test`, names the functions to use. The tests in `src/stdout.zig`, run by `zig build test`. `tests/broken_pipe_cli_test.py`, run by `zig build test-cli`, writes into a closed pipe and into a descriptor that refuses writes.

## One row for each bbr api verb

A `bbr api` verb is one row of `verbs` in `src/api/cli.zig`. The row names its `value_flags` and `switch_flags` and leaves out the global flags. These parts derive from the rows:

- the value pairing in `parseGlobal`
- the diagnostic verb lookup
- the `bbr completion` scripts

The help usage shows exactly the flags of the row. `skills/bbr/VERBS.md` has one bullet for each verb. Agents copy commands from `skills/bbr/SKILL.md` and `skills/bbr/VERBS.md` without `--help`. Each command passes `parseGlobal`, the verb lookup, and the real verb handler without an option error. This checks flag values and required flags, not just flag names. The handler uses `FakeHttpClient` and `TestOutput`, so it sends no real request and opens no real file. Success and errors after option parsing pass the check, such as `Forbidden` or `FileNotFound` for `--body-file`.

The check reads each `bbr api` command in prose, a code span, or a fence, with its `\` line breaks. It removes shell quote delimiters without shell expansion. It also reads each code span that starts with a known verb and has arguments, and the `example` of each row. A span that starts with a lowercase name and has a `--` word must name a known verb. The name can contain dashes. Bare verb names are references, not complete commands. A verb that does not start with a lowercase letter is a placeholder or a usage synopsis, such as `VERB` or `[--profile NAME]`. An unknown verb that starts with a lowercase letter fails the check when it has a dash or the command has a `--` word. Any other flag in a code span is a flag of some row.

Each handler checks its options before it reads a file or sends a request. This is a coding rule. Only create-comment has a test for the order, and no check covers a new handler. The copied-command check stops at the first file or HTTP error. Its fake client returns HTTP 403, so a request ends with `Forbidden`. The check does not validate input-file contents, Bitbucket state, response data, or later requests.

Enforcement: the `@compileError` calls of the `flag_sets` block in `src/api/cli.zig` give a compile error for a global flag in a row, for a repeated flag, and for a flag that takes a value in one row and is a switch in another. The tests "every verb's help usage shows exactly the flags of its row", "skills/bbr/VERBS.md lists every bbr api verb once", and "every command in the bbr skill parses through its CLI handler" in `src/api/cli.zig`, run by `zig build test`. The test "create-comment checks inline options before reading the body" in `src/api/comments.zig` checks missing or conflicting line flags with a missing body file and no HTTP call.

## Concurrency default in the help

A `bbr api` verb with `--concurrency` states in its help the default that its parser uses. The help gets the text from `workspaces.concurrencyHelp` or `workspaces.pagingHelp`. These functions take the default as an argument, so no help text holds a concurrency digit.

Enforcement: the test "every verb with --concurrency names its default in the help" in `src/api/cli.zig`, and the tests whose names contain "concurrency default" in `src/api/workspaces.zig`, `src/api/repositories.zig`, `src/api/branches.zig`, and `src/api/pullrequests.zig`. `zig build test` runs them.

## Default Reviewers on a PullRequest write

`--default-reviewers` on `create-pull-request` and `update-pull-request` reads the PullRequest Author and the Default Reviewers before the POST or PUT. Thus a failed read sends no write. The sent reviewers never include the Author. A `--reviewer` value that names the Author prints a warning on stderr and leaves stdout to the result.

Enforcement: the tests whose names start with "--default-reviewers", and the test "a failed Author or Default Reviewer read sends no PullRequest write", in `src/api/cli.zig`. `zig build test` runs them.
