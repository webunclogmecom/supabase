# The Operating-Date Rule (visit_date ↔ start_at)

*Owner-confirmed (Fred, 2026-07-01). Canonical reference for how a visit's date relates to its time.*

## The model
UnclogMe runs **commercial overnight routes**: a route scheduled for night **D** is worked from roughly
**8 PM that evening into ~6 AM the next morning**. A single route therefore spans the midnight boundary —
the early clients are visited ~8 PM–midnight (clock date D), the later clients ~midnight–6 AM (clock date D+1),
**but every one of them belongs to operating night D**.

So:
- **`visit_date`** = the **operating night the route is FOR** (the business "service date"). This is what the
  Calendar, Field Portal, DERM, and reports group by.
- **`start_at` / `end_at`** = the **actual UTC instant** the visit ran (displayed in ET). These can legitimately
  fall in the early morning of D+1.

## The derivation (ONE rule everywhere)
`OVERNIGHT_CUTOFF = 06:00 ET`. Given `start_at`:

| `start_at` in ET | `visit_date` |
|---|---|
| NULL, or exactly **00:00:00** (placeholder / all-day) | the ET date as-is (operating date stands) |
| **00:00:01 – 05:59** (early-AM) | the **PRIOR** ET date (prior night's route) |
| **06:00 – 23:59** (daytime / evening) | that ET date |

Implemented identically in three places (keep them in sync):
- `supabase/functions/webhook-jobber/index.ts` → `operatingDateET()` (inbound Jobber sync)
- `supabase/functions/sync-jobber-visit-drift/index.ts` → `adoptTarget()` (drift reconciler)
- DB trigger `public.fn_reconcile_visit_operating_date` / `trg_aa_reconcile_operating_date` (the safeguard)

## What the apps see (important for the office)
- **Evening visits** (8 PM–midnight): operating night = clock date → **Calendar date = Jobber date.** They agree.
- **Early-morning visits** (after midnight, before 6 AM): operating night = the **prior** clock date.
  → The **Calendar shows the prior night**, while **Jobber shows the later clock date**. This is **intentional**,
  not a sync error. Example: a visit that ran **Jun 30 at 2:15 AM** is part of the **Jun 29** night's route, so the
  Calendar shows it on **Jun 29** and Jobber shows **Jun 30 2:15 AM**. Do not "reconcile" that one-day gap — it's correct.

## Safeguards (2026-07-01)
- **`trg_aa_reconcile_operating_date`** (BEFORE INSERT/UPDATE on `visits`, fires first): keeps the
  `visit_date`↔`start_at` pair consistent for any writer (edge fn, Lovable PATCH, scripts). Bidirectional /
  intent-aware: a write that changes `start_at` re-derives `visit_date`; a pure date-drag (date changed, time not)
  moves `start_at`'s calendar day onto the new operating night while **preserving the ET wall-clock time**.
- **`handleVisit` +1 bug fixed**: it used to take the UTC date-slice of Jobber's `startAt`, pushing every
  ≥~8 PM-ET visit one day forward (the 081-TCE / 5846 class, 126 historical rows).
- **`ripple_reschedule_visit` is DST-safe**: it shifts whole days in the `America/New_York` zone (round-trip),
  so a reschedule across a March/November DST boundary keeps the ET wall-clock instead of drifting an hour.

## Querying
Always group/filter by **`visit_date`** for the business/service date. Use `start_at AT TIME ZONE 'America/New_York'`
only when you need the actual clock time. Never derive a date with a bare `start_at::date` (that's UTC) — use the
rule above.
