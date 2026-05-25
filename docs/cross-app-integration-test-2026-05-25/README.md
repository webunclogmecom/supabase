# Cross-App Integration Test — 2026-05-25

Comprehensive end-to-end test of the four Lovable apps integrated with the
UnclogMe Supabase Prod canonical (`wbasvhvvismukaqdnouk`).

## Apps in scope

| App | Reads from | Writes to | Status |
|---|---|---|---|
| **Admin Review** | Sandbox-1 `ubtlwpcyntelgbykdatn` | Prod `wbasvhvvismukaqdnouk` | LIVE at grease-buddy-dash.lovable.app |
| **DERM Tracker** | Prod `derm.*` schema | Prod `public.*` | LIVE at derm.unclogme.app |
| **Field Portal** | Prod `customer.*` schema (read-only) | — (read-only) | LIVE at fp.unclogme.app |
| **Visit Calendar** | mock data only | — | PROTOTYPE — not wired to Supabase, excluded from matrix |

## Goal

Test like a human: write in one app, verify DB, verify it appears in the
other app(s). Catch any propagation/caching/architecture gaps that don't
show up in single-app tests.

## Folder layout

- `README.md`        — this file, plan overview
- `01-snapshot.json` — captured pre-test DB state (so restore works)
- `02-test-matrix.md` — every planned test, expected outcomes
- `03-execution-log.md` — running log of test results as they happen
- `04-findings.md`   — issues found, what surfaced
- `05-fixes.md`      — code/data fixes applied during the run
- `99-restore.sql`   — final SQL to put DB back exactly how it was
- `probes/`          — disposable probe scripts (deleted at end)

## Run discipline

1. Take snapshot first. Any row I'll touch gets its pre-state stashed.
2. Execute tests in matrix order. Each test:
   - Action in App A (browser or DB)
   - Verify in DB (audit row + table state)
   - Verify in App B (browser, real UI)
   - Record result in 03-execution-log.md
3. Fix anything broken inline (don't pause for confirmation per user ask).
4. Run restore.sql at end. Verify post-restore matches pre-snapshot.
5. Final report + cleanup.

## Failure mode tracking

If context compresses mid-run, the next session can:
- Read README.md → know the plan
- Read 02-test-matrix.md → know what's done vs pending
- Read 03-execution-log.md → know last successful step
- Run 99-restore.sql → safely restore if needed
- Continue from the first incomplete row in matrix
