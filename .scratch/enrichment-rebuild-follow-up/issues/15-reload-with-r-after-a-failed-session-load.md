# 15: Reload with R after a failed Session load

Status: needs-triage
Blocked by: none

## Summary

This defect comes from `main`. It is not part of the enrichment rebuild cascade.
An earlier review session observed that `R` does not reload when the Session load failed, for example after a 403 when the VPN is off.
The user must quit and start bbr again.
The observation was not written down in a ticket, so the exact reproduction is not recorded.

## What to find

- A reproduction in tmux with a separate `XDG_STATE_HOME`, and the screen and status after `R`.
- Why the reload command does not start a new Session load in this state.
- A test that fails on the current code.

## Comments

### 2026-11-16 filed

The operator filed this defect here so that a later PullRequest owns it.
