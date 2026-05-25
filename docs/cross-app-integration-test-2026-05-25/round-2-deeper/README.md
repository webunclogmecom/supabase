# Round 2 — Deeper Tests

Picks up where round 1 left off. Two new dimensions:

1. **NULL field audit** — for every field each app exposes, count how often
   it's NULL across all eligible visits, then trace each high-NULL field
   to root cause (data missing, view doesn't expose, mapping broken).
2. **Remaining cross-app combinations** — every test deferred from the
   round 1 matrix executed.

Same discipline as round 1: snapshot any rows touched, restore at end,
document findings + fixes inline.

## Folder layout

- `README.md` — this
- `01-null-audit.md` — comprehensive null-field results per app/table
- `02-remaining-tests.md` — execution log for deferred + new tests
- `03-fixes.md` — fix log
- `99-restore.sql` — restore script for any new rows touched
- `probes/` — disposable
