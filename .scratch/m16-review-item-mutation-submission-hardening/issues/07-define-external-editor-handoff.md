# Define the external-editor handoff

Type: grilling
Blocked by: 04

## Question

How should the Composer's contextual `Ctrl-E` Action resolve `$EDITOR`, create and clean up a secure temporary file, transfer prefilled UTF-8 content, suspend and restore vaxis and the terminal, distinguish unchanged/cancelled/failed edits, return accepted bytes through `Composer.seed`, and expose deterministic commands and completions without making Presentation perform process or terminal I/O?
