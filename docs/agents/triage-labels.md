# Triage Labels

The skills use five canonical triage roles. Local issue files record the corresponding string in their `Status:` line.

| Canonical role | Local status | Meaning |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | Maintainer needs to evaluate this issue |
| `needs-info` | `needs-info` | Waiting on the reporter for more information |
| `ready-for-agent` | `ready-for-agent` | Fully specified and ready for an AFK agent |
| `ready-for-human` | `ready-for-human` | Requires human implementation |
| `wontfix` | `wontfix` | Will not be actioned |

When a skill mentions a triage role, use the corresponding local status from this table.
Use `resolved` for new completion updates.
The completion statuses `done` and `completed` are historical aliases for `resolved`.
Completion statuses are not triage roles.
