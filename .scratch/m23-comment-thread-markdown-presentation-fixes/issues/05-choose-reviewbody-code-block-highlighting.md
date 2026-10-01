# Choose ReviewBody code-block Highlighting

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:grilling
Type: grilling
Status: needs-info
Blocked by: 01, 04

## Question

When can ReviewBody code blocks use the existing Highlighter, and what happens when Highlighting is unavailable?

The user requests syntax colors where possible.
Inspect the existing Highlighter and GrammarMatch interfaces before asking the human to choose a policy.
Decide how a fence language identifier selects a BuiltInGrammar or UserGrammar without a File path.
Decide how indented blocks, unlabelled fences, unsupported identifiers, and Suggestions appear.

Choose when Highlighting runs, which limits apply, and how failures preserve readable literal text.
Keep terminal input responsive and keep published Presentation Frames internally consistent.
Decide whether source foreground roles and the existing Theme are sufficient.
Do not add a new Grammar merely to claim parity with every language named in the guide.

The answer records the supported mapping, fallback, lifetime, and acceptance examples.
