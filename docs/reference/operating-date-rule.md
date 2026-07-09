# The Visit-Date Rule (visit_date ↔ start_at)

*Originally the "operating-date rule" (Fred, 2026-07-01). **Revised 2026-07-02 (Fred): the operating-night
concept must NOT move a visit's date** — see "What changed" below. Canonical reference for how a visit's date
relates to its time.*

## The rule (current)
**`visit_date` = the ET CLOCK date of `start_at`** — the day the visit actually ran / is scheduled, exactly as
Jobber displays it. Nothing shifts it.
- **`visit_date`** = `(start_at AT TIME ZONE 'America/New_York')::date`. **Matches Jobber's date.** This is what the
  Calendar, Field Portal, DERM, and reports group by.
- **`start_at` / `end_at`** = the actual UTC instant (displayed in ET).
- **All-day visits** (`start_at` NULL): `visit_date` is authoritative (nothing to derive).

## The operating-night concept (understanding only — does NOT move dates)
UnclogMe runs commercial overnight routes (~8 PM into ~6 AM the next morning), so a single route spans midnight:
the early stops run ~8 PM–midnight, the later stops ~midnight–6 AM of the next clock day, but the crew works them
as **one shift**. That's useful to **understand** which shift did the work — but it is **metadata, not the date**.
A 2:15 AM stop belongs to the previous night's shift *conceptually*, yet its `visit_date` is its real clock date
(the 2:15 AM day), same as Jobber. If a per-shift grouping is ever needed for reporting, derive a **separate**
`operating_night` value — never move `visit_date`.

## What the apps see
**Calendar date = Jobber date, always** — evening AND early-morning visits. A visit that runs Jun 30 at 2:15 AM
shows on **Jun 30** in both the Calendar and Jobber. (No more "prior night" gap.)

## What changed (2026-07-02)
The 07-01 rule derived `visit_date` = the *operating night*, shifting early-AM (00:00–06:00 ET) visits to the
**prior** day. Fred: that shift should never have moved dates — the concept is for understanding the shift, not
relocating the visit. Removed the shift entirely; `visit_date` is now the ET clock date for scheduled **and**
completed visits. Reconciled 130 completed visits back to their clock date (5 from the shift + 125 leftover from
the pre-07-01 UTC `+1` bug). Migrations `2026-07-02_operating_date_scheduled_matches_jobber.sql` (scheduled-only,
superseded) → `2026-07-02b_visit_date_always_clock_date.sql` (final).

## Implemented identically in these places (keep in sync)
- **DB trigger** `public.fn_reconcile_visit_operating_date` / `trg_aa_reconcile_operating_date` — the safeguard:
  any writer's `start_at` change re-derives `visit_date` = ET clock date; a pure date-drag moves `start_at` onto
  the new day at the same ET wall-clock (no shift) and carries `end_at` by the same delta.
- **`supabase/functions/webhook-jobber/index.ts`** → `operatingDateET()` — inbound Jobber sync (returns ET clock date).
- **`supabase/functions/sync-jobber-visit-drift/index.ts`** — drift reconciler. **Timed** visits compare Jobber
  `startAt` to the DB `start_at` (unaffected by this change). **Untimed** (all-day) visits still use the
  overnight-aware tolerance against `visit_date` — an untimed visit has no `start_at` to move, so it's out of
  scope for the "don't move dates" change.
- **`scripts/lib/operating_date_et.js`** → `operatingDateET()` — shared by the two daily reconcile crons
  `scripts/sync/cron_jobber_reconcile_completion.js` + `cron_jobber_reconcile_anomalies.js` (ET clock date, NOT
  `startAt.slice(0,10)` = raw UTC). **Added 2026-07-09** after both crons' raw-UTC slice fought the trigger and
  oscillated evening-ET visits' `visit_date` ±1 day daily (audit `2026-07-09_visit_date_oscillation_handoff.md`).
  **Rule for any reconcile writer:** never write `visit_date` standalone — only co-write it with a `start_at`
  change (a standalone `visit_date` write fires the trigger's date-drag branch and moves `start_at` ±1 day).

## Safeguards
- `trg_aa_reconcile_operating_date` (BEFORE INSERT/UPDATE on `visits`): keeps `visit_date`↔`start_at` consistent.
  `end_at` carry (2026-07-01b): the date-drag branch shifts `end_at` by the same delta (duration preserved); a
  `start_at`-only shift gets a defensive snap if `end_at` would land `≤ start_at`. `visits_end_after_start_chk`
  CHECK blocks `end_at ≤ start_at` from any path.
- `ripple_reschedule_visit` is DST-safe (whole-day shifts in `America/New_York`).

## Querying
Group/filter by `visit_date` for the service date (= Jobber's date). Use `start_at AT TIME ZONE 'America/New_York'`
for the clock time. Never use a bare `start_at::date` (that's UTC — the old `+1` bug).
