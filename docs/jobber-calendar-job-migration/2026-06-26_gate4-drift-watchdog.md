# Gate #4 — Calendar↔Jobber schedule-drift reconciler (`sync-jobber-visit-drift`)

*2026-06-26. Status: **LIVE** (cron every 30 min). Two-way: HEAL failed-our-pushes (DB→Jobber),
ADOPT Jobber-side edits (Jobber→DB, audited as `jobber`), SURFACE ambiguous conflicts. Reconcile
writes on by default; kill-switch available.*

## Why it exists

A Calendar/cron visit edit (incl. every row of a `ripple_reschedule_visit` cascade) pushes to
Jobber **fire-and-forget**. If that push silently fails, **the DB shows date X while Jobber stays on
date Y and nothing is recorded** — the update push path writes no `visit_sync_flags` row,
`net._http_response` has no `visit_id` + ~6h TTL, and the inbound poll never clobbers a calendar/cron
visit's schedule (`webhook-jobber:581-603`), so the divergence is **invisible from DB columns alone**.
`ops.v_calendar_push_health` only finds *unlinked* orphans — a failed reschedule is *linked* +
*unflagged*. The only way to catch it is to read Jobber's actual `startAt` and compare.

## Heal/adopt policy — "Calendar is master, but drivers/Diego use Jobber" (Fred, 2026-06-26)

Drivers complete visits in Jobber and Diego sometimes reschedules there — those are **legitimate** and
must **never be reverted**. So each drift is classified from the **audit trail** and handled by
**direction**:

| Class | Condition (from `audit.logs`) | Action |
|---|---|---|
| **HEAL** (DB→Jobber) | a `visit_date` audit UPDATE set the **current DB date** AND Jobber holds the **exact pre-edit value** → our push failed | re-push via `fn_request_jobber_push` (vault key → jobber-push-visit), re-read to confirm |
| **ADOPT** (Jobber→DB) | **no** `visit_date` audit UPDATE → we never touched it → a driver/Diego scheduled it in Jobber → Jobber authoritative | pull Jobber's schedule into DB via `adopt_visit_schedule_from_jobber` |
| **SURFACE** (review) | we edited it AND Jobber holds **some other** value (ambiguous conflict) | log only, never auto-resolve |

Completed visits are out of scope (only `scheduled` checked; completions sync inbound). Client edits
are Jobber-mastered already.

**The ADOPT write is (per Fred) AUDITED as coming from Jobber.** It runs through a supabase client
with header `X-App-Source: jobber`, so `audit.logs.app_source='jobber'` and the visit's Activity
history shows "updated from Jobber". It is also **push-suppressed**: the RPC sets a transaction-local
GUC `app.suppress_jobber_push='on'` that `fn_push_visit_to_jobber` checks and returns early on, so
adopting *from* Jobber never echoes *back* to Jobber (DB-only, even if the target were wrong).

Reconcile writes (heal + adopt) are **ON by default**; kill-switch: env `DRIFT_HEAL_DISABLED=1` (or
per-call `x-no-heal: 1`) → detect-only.

## What it does (per run)

1. **Candidates** — `public.calendar_visit_drift_candidates(7, 184)`: calendar/cron-mastered,
   `scheduled`, Jobber-linked, live visits in `[today-7, today+6mo]`. Re-scanned in full every run
   (level-triggered, self-healing).
2. **Pull** Jobber upcoming `startAt`/`endAt` (≥ today-7), paginated, stopping once all candidate GIDs seen.
3. **Compare ET-floored + OVERNIGHT-AWARE**: an untimed visit's `visit_date` is the logical operating
   date; a Jobber start in the **early-AM (< 06:00 ET) of the next clock day** is the overnight
   (10pm–3am) execution of that operating date → **NOT drift**. Timed visits compare to the DB
   `start_at` (clock time we pushed), not `visit_date`.
4. **Classify** via `public.visit_last_schedule_edit` (reads `audit.logs`) → heal / adopt / surface.
5. **Reconcile** (if enabled): heal DB→Jobber, adopt Jobber→DB; surface the rest.
6. **Log** one `public.sync_log` row, `sync_source='jobber_visit_drift'`: `status='attention'` when
   anything still needs eyes (failed heal, failed adopt, or a surfaced conflict), else `'success'`.
   `details`: `reconcile_enabled / checked / drift_found / healable / healed / adoptable / adopted /
   jobber_origin_surfaced / surfaced_visits / residual / read_fail / healable_visit_ids /
   adopted_visit_ids`.

## Verified (2026-06-26)

- **Overnight fix:** visit 6496 (untimed, 3:00 AM = overnight of 06-25) no longer flagged.
- **Heal:** induced failed-our-push on visit 6038 (DB→11-25, Jobber stuck on 11-20, audit proves ours)
  → `healable`, healed (Jobber → 11-25), reverted net-zero.
- **Adopt suppress + push intact:** `adopt_visit_schedule_from_jobber(6038, …)` moved DB only (Jobber
  untouched); a subsequent normal edit still pushed (Jobber moved) — recreated `fn_push_visit_to_jobber`
  is intact; reverted net-zero.
- **Adopt live + attribution:** the watchdog adopted visit **5971** (untimed 06-25, no audit edit,
  Jobber 06-26 9:30 AM) → DB → 06-26 9:30, **Jobber untouched**, audit row `app_source='jobber'`
  (06-25 → 06-26). The ambiguous **6458** (we'd moved it via `sql`, Jobber holds a 3rd value) stayed
  **surfaced**, not auto-resolved.

## Open review items (surfaced, not auto-resolved)

`sync_log` shows **1 jobber-origin conflict**: **6458** (195-MYK) — we set 06-25 via a script, Jobber
holds 06-26. Ambiguous (which side wins?), so the reconciler logs it for a human. (5971 was adopted +
resolved 2026-06-26.)

## Pieces

| Piece | File |
|---|---|
| Candidate set fn | `docs/migrations/2026-06-26_calendar_visit_drift_candidates.sql` |
| Re-push primitive (heal) | `docs/migrations/2026-06-26_fn_request_jobber_push.sql` |
| Heal classifier | `docs/migrations/2026-06-26_visit_last_schedule_edit.sql` |
| Adopt RPC + push-suppress guard | `docs/migrations/2026-06-26_adopt_visit_schedule_from_jobber.sql` |
| Edge Function | `supabase/functions/sync-jobber-visit-drift/index.ts` (verify_jwt=false) |
| Cron (RECORD) | `docs/migrations/2026-06-26_jobber_visit_drift_reconcile_cron.sql` — `jobber-visit-drift-reconcile` `*/30` |

## Operating

- **Watch:** `SELECT status, details FROM sync_log WHERE sync_source='jobber_visit_drift' ORDER BY id DESC;`
  Alert when `details->>'residual'` or `details->>'jobber_origin_surfaced'` stays `> 0` across two runs.
- **Manual run:** `POST /functions/v1/sync-jobber-visit-drift` with `x-sync-key` + `x-sync-wait: 1`
  (add `x-no-heal: 1` to detect-only).
- **Disable all reconcile writes:** Functions secret `DRIFT_HEAL_DISABLED=1`.

## Compliance

No new business table; reuses `sync_log` + the `entity_source_links` bridge. No source-prefixed
columns. RPCs are SECURITY DEFINER, service_role-only. Heal never writes `visits.derm_required` and
never hard-deletes (`op='upsert'`). Adopt writes `visits` (audited, ADR 010) attributed `app_source
='jobber'` (ADR 016) and is push-suppressed. The `fn_push_visit_to_jobber` recreate preserves the
Origin delete fail-safe + cancel op verbatim, adding only the suppress guard.
