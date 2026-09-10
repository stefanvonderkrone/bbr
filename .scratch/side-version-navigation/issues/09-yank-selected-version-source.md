# 09 — Yank Selected Version source

**What to build:** Make yank copy only source Lines from the Selected Version with predictable Count, Selection, ordering, and refusal behavior.

**Blocked by:** 05 — Add the Selected Version foundation. 08 — Publish Selected Version changes atomically.

**Status:** ready-for-agent

- [ ] Unified rows contribute a Line only when that Line exists in the Selected Version.
- [ ] SideBySide rows contribute only the selected column's Line.
- [ ] Wrapped rows contribute one semantic Line, and blob-sourced full-content Lines remain valid candidates.
- [ ] Headers, placeholders, Folds, ReviewCards, and other generated rows contribute no source.
- [ ] Without Selection, yank skips non-candidates, counts candidate Lines, and stops at the current File boundary.
- [ ] If a File ends before Count is met, yank copies all available candidates.
- [ ] With Selection, yank ignores Count and uses only inclusive selected rows from the cursor's File.
- [ ] Yank deduplicates candidates and orders them by Selected Version source line number.
- [ ] Empty source Lines count, output uses `\n` between Lines, and output has no trailing newline.
- [ ] Queuing a clipboard request clears Count and Selection, and later clipboard failure does not restore them.
- [ ] Refusal and yank allocation failure consume Count but preserve Selection.
- [ ] Typed refusal and status text distinguish unavailable Selected Version content from no candidate at the cursor or in Selection.
- [ ] Changes and fetched-whole use the Selected Version instead of the provisional new-first rule.
