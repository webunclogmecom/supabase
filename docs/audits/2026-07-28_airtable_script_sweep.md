# Airtable script sweep — and two weekly jobs that were lying about their results

**Date:** 2026-07-28 · **Ask (Fred):** "clean up those 36 airtable scripts."
**Origin:** handed over by the @Supabase session after it fixed `check_client_code_available.js`, which
had been printing `[Airtable] (none)` on every run — "checked and clear" when it had checked nothing.
That session flagged "10 more scripts." The real surface was **69 files**.

---

## What was actually there

`grep -rl "api.airtable.com" scripts/` returned **69 files**:

| Bucket | Count | Disposition |
|---|---|---|
| `**/_archive/` | 23 | already dead, left alone |
| `_`-prefixed one-offs | 10 | already dead, left alone |
| **No prefix, sitting beside scripts we run** | **36** | **this sweep** |

Of those 36: **34 archived**, **2 kept and hardened**.

Only **one** was genuinely imported by live code (`scripts/populate/lib/sources.js`, required by
`populate.js:52`). Every other cross-reference was a comment or a doc mention, verified with
`git grep "require(...)|from '...'"` before moving anything, so the archive move could not break a
runtime import.

Archived with `git mv` into the existing `_archive/` convention, **not deleted** — the history and the
method in these probes is often the only record of how a past incident was diagnosed.

### The 2 kept

- **`scripts/sync/geocode_missing_properties.js`** — driven by a live weekly workflow. Airtable was
  Tier 2 of a 4-tier chain (Jobber → Airtable → Samsara → Google). Removed the tier, its SQL join, its
  `stats` key, and the `Airtable: 0` summary line. That summary line was the same false-clear bug: a
  permanent `0` that reads as "checked, none found." Chain is now Jobber → Samsara → Google.
  **Verified by running it** (`--dry-run`, 285 properties, resolving via Google), not just
  `node --check` — per the @Supabase session's lesson that a syntax check misses a dangling reference
  that only fires on one path.
- **`scripts/populate/lib/sources.js`** — kept because `populate.js` imports `pullAirtable` by name, so
  deleting the export breaks that script at load. Body replaced with a **throw**. The old body would
  have returned `clients=0 visits=0 derm=0 …` (the fetch helper returns `[]` on non-200) and handed
  `populate.js` an empty-but-valid dataset. On the *initial-population* path, that reads as "Airtable
  had nothing to add" rather than "Airtable is gone," with the whole warehouse as blast radius.

---

## ⚠ The real finding: two weekly jobs reporting success while doing nothing

The scripts were the symptom. Chasing their callers found two scheduled workflows in this state.

### 1. `weekly-drift-audit.yml` — RED for 6+ weeks, nobody watching. **Deleted.**

Ran Sundays 13:30 UTC. Four steps, all comparing the DB against Airtable, the last one being
`audit_client_code_drift.js --heal`, which **writes `clients.client_code`**.

Run history: `failure` on 07-26, 07-19, 07-12, 07-05, 06-28, 06-21. Six consecutive weeks.

The cause is not Airtable, it is **schema drift**: step 1 dies on
`column p.zone does not exist` (confirmed: `properties.zone` has 0 rows in `information_schema`). The
job aborts at step 1, so **the `--heal` write has not run in at least six weeks.**

Two things worth keeping:

- **The heal could not have corrupted anything even if it had run.** Its gate is
  `if (atCodes.has(pre))` — it writes only when Jobber's prefix appears in the Airtable code set. With
  Airtable dead, `airtableCodes()` returns an empty `Set` (line 78 is `for (const rec of (r.records || []))`
  — it swallows any error and returns empty rather than throwing), so the gate never opens. **Fails
  safe.** But it fails safe by never checking, which is the problem, not the mitigation.
- **A real capability is now gone.** This workflow existed to catch renumber drift — the 2026-06-17
  221-MP→224-MP incident (`docs/audits/fixes/2026-06-17_client_code_drift.md`). Its whole design was
  two-source agreement (Jobber prefix == Airtable "Client Code #3" != DB). **That is unbuildable now:
  one of the two sources no longer exists.** Deleting the workflow does not lose detection that was
  working; it stops a red badge from standing in for a check nobody has. **Open item for Fred: client_code
  renumber drift is currently undetected and needs a Jobber-only redesign** (Jobber alone was explicitly
  judged unsafe to auto-heal — see the script's own header — so a redesign likely means report-only).

### 2. `weekly-geo-backfill.yml` — GREEN every week, geocoding zero. **Not fixed: needs a secret.**

Runs Sundays 13:00 UTC in execute mode. Last run (07-26) processed **281 properties and resolved
none** — `✗ … no source resolved` for every single one — then **exited 0, reported success.**

Cause: **`GOOGLE_API_KEY` is not a repo secret.** Confirmed against `gh secret list` (present:
`AIRTABLE_*`, `JOBBER_*`, `SAMSARA_*`, `PROD_DB_URL`, …; `GOOGLE_API_KEY` absent). Tier 4 bails on
`if (!process.env.GOOGLE_API_KEY) return null`, Tier 3 (Samsara) is a stub that returns `null`
unconditionally, Tier 1 resolves few, so everything falls to "unresolved" and the script still exits 0.

The same 285 addresses resolve fine locally, where `.env` has a working key — so this is purely the CI
secret. **Action is Fred's** (adding a secret is not something this session does). Until then the job is
decorative and ~281 properties stay without coordinates.

---

## Standing rule this establishes

A dead source must **throw**, never return empty. Every instance found here degraded identically:
`return null` / `|| []` / `if (status !== 200) return null` on an upstream that no longer exists. The
result is always the same shape of lie — a green check, a `0`, or an `(none)` that a human reads as
"verified clean" when nothing was verified. It is the same trap root `CLAUDE.md` already documents for
`audit.logs` silence on unaudited tables, and the same one the 2026-06-26 "DERM feed is retired" note
fell into. Absence of a bad result is not evidence the check ran.

**Corollary, from this sweep specifically:** a scheduled job's *status badge* is not evidence either.
One job was red for six weeks and one was green while doing nothing, and both went unnoticed because
nobody reads a weekly badge. Prefer jobs that fail loudly on a missing dependency over jobs that
degrade quietly.
