# `service_type` — the canonical service vocabulary (current as of 2026-08-03)

**Read this before touching anything named `service_type` or `service_kind`.** It replaces a pile of
scattered assumptions, several of which were wrong for months.

---

## 1. The vocabulary

`service_type` holds the **real service names**. The legacy `GT` / `CL` / `WD` / `LS` codes were
retired on 2026-08-03 and **cannot be written any more** — both CHECK constraints reject them (`23514`).

| Table | Domain | Notes |
|---|---|---|
| `public.service_line_items` | the full catalogue taxonomy (11 values) | the source of truth |
| `public.visits` | the full taxonomy, **or NULL** | NULL = not derivable, and is honest |
| `public.service_configs` | `Pumping`, `Cleaning`, `Warranty of Drainage` only | NOT NULL; a config describes a *recurring* service |

The eleven catalogue values:

```
Pumping · Cleaning · Warranty of Drainage · Unclogging · Camera Inspection
Dye Test · Assessment · Labor · Parts · Labor BUS · Dump Offload
```

⚠ **`Dump Offload` (code 28) is real and live on 30 visits.** Writing a CHECK constraint from "the
three recurring services" silently rejects it. This has been a trap twice.

**The authority is the catalogue sheet's column G**
(`19ArflSwdhcpnu1U6Lii5q2VFmDLjwskurDCghN0aanE`). Verified 20/20 against the DB. Column F = reason,
**G = service type**, H = equipment, I = method. That sheet is why **Lift Station is `Pumping`** —
code 04 "Lift Station & Tank Cleaning" reads Pumping there. The equipment distinction lives in
`location_target`, not in the service type.

---

## 2. 🛑 `service_kind` means TWO DIFFERENT THINGS. This is the single biggest trap here.

| Object | What its `service_kind` means | Status |
|---|---|---|
| `public.service_line_items.service_kind` | was the service taxonomy | **DROPPED 2026-08-03** — use `service_type` |
| `ops.v_calendar_visit.service_kind` | **`SA` / `SC`** — Service Agreement vs Service Call | **ALIVE, heavily used, do not touch** |
| `ops.v_calendar_visit_detail.service_kind` | same SA/SC classifier | alive |
| `derm.v_stamp_unlinked_visits.service_kind` | same SA/SC classifier | alive |
| `derm.v_stamp_row_candidate_visits.service_kind` | same SA/SC classifier | alive |

`ops.v_calendar_visit.service_kind` is the **most-read column in the `ops` schema**: 16 distinct app
queries, up to 4,186 calls each, and the Visit Calendar **equality-filters** on it.

**⇒ A find-and-replace on `service_kind` will destroy the SA/SC classifier in four views with no
error.** A name sweep reports 10 objects "referencing service_kind" when only 7 ever read the
catalogue column; the other three build their own SA/SC value via a CASE. **Only rewrite
`sli.`-qualified references, and inspect every unqualified one by hand.**

This is also why `visits.service_type` was **not** renamed to `service_kind`: the name was already
taken, with a different vocabulary, in a view the Calendar filters on.

---

## 3. `ops.fn_service_group`'s third argument is `location_target`, NOT `service_type`

```sql
ops.fn_service_group(p_reason, p_kind, p_type)   -- p_type receives location_target
```

The parameter is still *named* `p_type` because `CREATE OR REPLACE FUNCTION` cannot rename a parameter
while callers depend on it. It splits `PUMPING_GT` from `PUMPING_OTHER`, and after the rename
`service_type` reads `Pumping` for **both** grease trap and lift station, so it can no longer
discriminate. `location_target LIKE 'Grease Trap%'` is provably equivalent to the old test.

**Passing `service_type` again collapses ~1,006 Calendar chips into `PUMPING_OTHER` with no error.**
Callers: `ops.v_calendar_visit`, `ops.client_service_options`.

---

## 4. What each app sees

- **Field Portal** renders `customer.scheduled_visits.service_type` **raw to customers**. There is no
  display map in the app; whatever the DB holds is what a customer reads. Currently Pumping 722 /
  Cleaning 42 / NULL 3.
- `customer.scheduled_visits.service_type` is scalar `text`; `customer.work_orders.service_type` is
  `text[]`. Same name, different type, and the FP bundle discriminates with `Array.isArray`. **Do not
  unify them.**
- **`ops.client_service_options` is DEAD** — no app reads it. Its two PostgREST queries are frozen at
  329 and 227 calls (`stats_since` 2026-06-23) and exercising the Client App job editor does not move
  them. The Client App reads `service_line_items`, `jobs` and `line_items` directly.
- The job-editor payload now carries **one** service field:
  `code · requires_derm · service_group · service_line_item_id · service_type · title · unit_price`.

---

## 5. How to tell whether something is actually used

`pg_stat_statements` (in the **`extensions`** schema, not `public`) records PostgREST queries with
every column named explicitly, so it is an exact record of what apps request:

```sql
select calls, stats_since, query from extensions.pg_stat_statements
 where query like 'WITH pgrst_source%' and query like '%"your_column"%' order by calls desc;
```

⚠ **It has no last-call timestamp.** A call count cannot distinguish "live" from "historical" — the
329/227 counts above looked live and were four months stale. **The decisive test is to exercise the
feature and watch whether the counter moves.**

⚠ **Bundle scanning is not a substitute, and it fails silently.** The Client App's chunks are
referenced by `<link rel="modulepreload">`, **not** `<script src>`; seeding a walk from script tags
finds one 21 KB `~flock.js` and returns a confident zero. Seed from modulepreload links, or from
`performance.getEntriesByType('resource')` after exercising the feature, and **always assert a
positive control** (a known string present, a non-trivial literal count).

---

## 6. Retired, and why (do not resurrect)

- **`LS` folded into `Pumping`.** All 15 LS visits were completed, 0 scheduled, 0 future. 13 of 15 job
  titles read "Lyft station cleaning". The catalogue sheet classifies Lift Station as Pumping.
- **The 7 `LS` `service_configs` rows were hard-deleted** (Fred's explicit rule-#6 sign-off, 2026-08-03).
  All were empty, and all 7 collided on `UNIQUE (client_id, service_type)` once LS and GT both mapped
  to Pumping. `service_configs` has no `deleted_at`, so there was no soft-delete path. Recoverable from
  `audit.logs.old_row`.
- **`CL` was a catch-all and the rename carried that imprecision forward.** Only 53 of 151 derivable
  CL visits were actually Cleaning; 94 contained no Cleaning at all (Unclogging 40, Labor 39, Dump
  Offload 8, Pumping 4, Warranty 2, Assessment 1). This was renamed 1:1 **on purpose**, to keep the
  migration behaviour-preserving and provable. **The CL accuracy problem still exists, now under the
  name "Cleaning". It is a separate, unfixed data-quality issue.**
- GT needed no cleanup: 1,102 of 1,116 derivable GT visits were Pumping (98.7%).

---

## 7. Known consequences that are expected, not bugs

Folding LS into Pumping pulled 15 previously-excluded visits into `ops.v_calendar_visit`:

- **057-BAY gained an observed cadence where it had none** (none → 32 days); **083-SHUL 57 → 42 days**;
  168-AVA unchanged.
  ⚠ An earlier note circulated as "057-BAY 2→3, 083-SHUL 57→42, 168-AVA 12→9". **Those numbers were
  wrong** — from a simulation that omitted the `days_since_prev BETWEEN 5 AND 200` filter the live CTE
  carries, which discards 057-BAY's consecutive-day lift-station gaps entirely.
- **14 completed "Lyft station cleaning" visits flipped their SA/SC chip from `SC` to `SA`**, because
  `observed_job_cadence` had excluded LS so those jobs had no median gap and fell to the `ELSE 'SC'`
  branch. Found only by a key-by-key `to_jsonb` diff — see [[reference_diff_by_key_not_by_column_list]].
- The same 15 visits now join the client's Pumping config and show its `frequency_days`,
  `amount_estimated` and `equipment_size_gallons`. All are completed; **zero scheduled, zero future**,
  so nothing about dispatch or lateness changed.

---

## 8. Pre-existing defect, still open

`ops.v_calendar_visit`'s three cadence CTEs (`observed_cadence`, `observed_price`,
`observed_job_cadence`) have **no `deleted_at IS NULL` filter**, so ~530 soft-deleted rows already sit
inside every median and observed price. Unrelated to this migration, deliberately not fixed by it (all
2,408 rows were migrated uniformly so it would not surface as an apparent cadence regression).

---

## Migrations

| File | What |
|---|---|
| `2026-08-03_1730_service_type_phaseA_expand.sql` | widen both CHECKs to accept both vocabularies |
| `2026-08-03_1745_service_type_phaseB_migrate.sql` | 2,202 visits + 263 configs + catalogue + 13 objects, one transaction |
| `2026-08-03_1530_service_type_phaseC1_narrow_checks.sql` | narrow the CHECKs to the real names |
| `2026-08-03_1545_service_type_phaseC2_drop_service_kind.sql` | drop the duplicate catalogue column |
| `2026-08-03_1615_collapse_duplicate_service_field.sql` | remove the duplicate from the app payloads |

Analysis: [service-type-vs-service-kind.md](service-type-vs-service-kind.md) ·
Plan + full audit: [../plans/2026-08-03_service_type_vocabulary_migration_plan.md](../plans/2026-08-03_service_type_vocabulary_migration_plan.md)
