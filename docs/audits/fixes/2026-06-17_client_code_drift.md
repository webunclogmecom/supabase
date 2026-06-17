# client_code drift — `221-MP` stranded; two-source self-heal added (2026-06-17)

## Incident
The DB held `client_code = '221-MP'` / name `MR. Pasta FACTORY` for client id 459
(Jobber `…140173911`). Both upstreams actually say **`224-MP`**: Airtable
`Client Code #3 = 224-MP "Mrs. Pasta factory"` (status Recurring) and the Jobber
company name `"224-MP MR. Pasta FACTORY"`. The stale `221-MP` collided with
`221-YAS "YASU"`, and a missing-recurring report built off the DB `client_code`
inherited the bad code (surfaced by Yannick).

## Root cause — why no webhook/cron healed it
A **mutable-key matching** flaw; both sync paths fail on a renumber:

- **webhook-jobber** parses the `NNN-XX` prefix from the Jobber company name but
  only wrote `client_code` **when it was missing** (it must not blindly overwrite —
  see "why not Jobber-only" below). So when Jobber's prefix was corrected to
  `224-MP`, the existing `221-MP` was left.
- **webhook-airtable** writes Airtable's code, but client 459 has **no Airtable
  ESL link**. Its only fallback is to match an unlinked client by
  `client_code = <AT code>` — i.e. it looked for a DB row with code `224-MP`, the DB
  had `221-MP`, the match missed, and the whole AT event was **dropped**
  ("No client linked to Airtable record … skipping"). Circular: to fix the code it
  first has to find the row, but the only key it can use *is* the wrong code.
- No cron compared codes against the stable identity, so nothing noticed.
  (Compounding: Airtable's "Jobber Client ID" field is empty on 213/214 rows, so the
  AT sync has no stable key to fall back to.)

## Why not just heal from the Jobber company name?
Because Jobber's prefix is frequently **typo'd / truncated** by Yan. A live sweep
found 7 such cases where the **DB already matches Airtable** and only the Jobber
company name is off — healing from Jobber alone would have *corrupted* them:

| client | DB (= Airtable) | Jobber company-name prefix |
|---|---|---|
| 125 Mutra | `133-MUT` | `133-MU` |
| 151 54 Warehouse LLC | `146-54W` | `146-54` |
| 302 Tacos yoyo | `140-TYO` | `140-TCY` |
| 322 Shaulson / Bayshore | `057-SLS` | `057-BAY` |
| 333 Pummarola | `132-PUM` | `132-PU` |
| 363 JZ Steak House | `199-JZ` | `199-STK` |
| 455 True Barista (GT) | `213-TRUE` | `213-TRU` |

These are Jobber-side data entry to clean up; the DB/Airtable are correct, so the DB
is left untouched.

## Fix
1. **DB corrected** (one-off): client 459 `221-MP → 224-MP` (audited). `221` collision
   resolved; `224-MP` was free.
2. **Reconciliation probe** `scripts/probes/audit_client_code_drift.js` rewritten to
   heal on **two-source agreement only**: it matches DB→Jobber by the **stable GID**
   (`entity_source_links`) and heals `client_code` **only when the Jobber prefix ==
   an Airtable `Client Code #3` AND both differ from the DB**. Jobber-only typos are
   reported, never written. `--heal` applies the safe ones.
3. **Cron**: added as a `--heal` step to `.github/workflows/weekly-drift-audit.yml`
   (the one exception to that workflow's audit-only contract — the two-source heal is
   unambiguous).
4. **webhook-jobber** left as set-`client_code`-only-if-missing (it sees only Jobber,
   so it can't safely overwrite); the comment now points at this probe. The poll cron
   replays through it, so brand-new Jobber-only clients still get a code.

## Verification (2026-06-17)
After the DB fix, the probe reports **0 agreement-drifts** across 403 Jobber-linked
clients — `221-MP` was the only true DB drift. The 7 Jobber-name typos above are
flagged (DB already canonical). The missing-recurring report was re-sourced directly
from live Airtable + Jobber (recurring status live-verified 41/41).

## Follow-up for ops (Yan)
Clean up the 7 Jobber company-name prefixes so they match the canonical code
(`133-MUT`, `146-54W`, `140-TYO`, `057-SLS`, `132-PUM`, `199-JZ`, `213-TRUE`).
Non-urgent — DB + Airtable are already correct.
