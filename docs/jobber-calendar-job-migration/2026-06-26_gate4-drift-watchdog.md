# Gate #4 — Calendar→Jobber schedule-drift watchdog (`sync-jobber-visit-drift`)

*2026-06-26. Status: **LIVE** (cron every 30 min). Detects drift + **heals only a provable failed-our-push**
(audit-gated, on by default, kill-switch available); Jobber-side edits are surfaced, never reverted.*

## Why it exists

A Calendar/cron visit edit (incl. every row of a `ripple_reschedule_visit` cascade) pushes to
Jobber **fire-and-forget**: `trg_push_visit_update → fn_push_visit_to_jobber → net.http_post →
jobber-push-visit → visitEditSchedule`. If that push silently fails, **the DB shows date X while
Jobber stays on date Y and nothing is recorded**:

- The update push path writes **no** `visit_sync_flags` row (flags are create-path only).
- `net._http_response` has **no `visit_id`**, is mostly poll-noise, and purges in **~6 h**.
- The inbound poll **never clobbers** a calendar/cron visit's schedule (`handleVisit` loop-guard,
  `webhook-jobber:581-603`), so the DB keeps the date and the divergence is **invisible from DB
  columns alone**. `ops.v_calendar_push_health` only finds *unlinked* orphans — a failed reschedule
  is *linked* + *unflagged*, so it slips through.

The only way to catch it is to read Jobber's actual `startAt` and compare. That is gate #4.

## Heal policy — "Calendar is master, but drivers/Diego use Jobber" (Fred, 2026-06-26)

Drivers complete visits in Jobber, and Diego sometimes reschedules/edits there — those are
**legitimate** and must **never be reverted**. So a blind DB→Jobber heal is unsafe. The heal is
**direction-safe by construction**: it re-pushes DB→Jobber **only** when the **audit trail proves it
was our push that failed** — a `visit_date`-changing `audit.logs` UPDATE set the **current DB date**
AND Jobber still holds the **exact pre-edit value** (`public.visit_last_schedule_edit`). Any other
Jobber value (a Jobber-side move/time assignment) does **not** match → it is **surfaced** in
`sync_log`, never healed. (Completed visits are out of scope — only `scheduled` visits are checked,
and completions already sync inbound. Client edits are Jobber-mastered already.)

Heal of the safe class is **ON by default**; kill-switch: env `DRIFT_HEAL_DISABLED=1` (or per-call
`x-no-heal: 1`) → detect-only.

## What it does

Pattern-A self-verifying watchdog (pg_cron → Edge Function), modeled on `sync-jobber-upcoming-visits`:

1. **Candidates** — `public.calendar_visit_drift_candidates(7, 184)`: calendar/cron-mastered,
   `scheduled`, Jobber-**linked**, live visits in `[today-7, today+6mo]` (~676). Re-scanned in full
   every run (level-triggered, self-healing — no cursor).
2. **Pull** Jobber upcoming `startAt` (≥ today-7), paginated, stopping once all candidate GIDs seen.
3. **Compare ET-floored, OVERNIGHT-AWARE** (mirrors `etParts`/`visitSchedule`):
   - **Untimed** visit (`start_at IS NULL`): `visit_date` is the logical **operating date**. A Jobber
     start in the **early-AM (< 06:00 ET) of the next clock day** is the overnight execution of that
     operating date (commercial trucks run 10pm–3am) → **NOT drift**. (Without this, every overnight
     visit false-flags — e.g. visit 6496, a 3:00 AM run of the 06-25 operating date.)
   - **Timed** visit: compare Jobber `startAt` to the DB `start_at` (date + ET `HH:MM`) — **not** to
     `visit_date` — so a correctly-stored timed overnight visit isn't false-flagged.
4. **Classify** each drift via `public.visit_last_schedule_edit` (reads `audit.logs`): **our failed
   push** (Jobber == pre-edit value) → *healable*; else → *surfaced* (`no_our_edit` /
   `jobber_value_unexpected`).
5. **Heal** the healable class via `rpc('fn_request_jobber_push')` (vault key → jobber-push-visit,
   the proven trigger path) + **re-read Jobber to confirm convergence**. Idempotent; `op='upsert'`
   on a linked visit only edits schedule/title/team/lines. Bounded `MAX_HEAL_PER_RUN=50`.
6. **Log** one `public.sync_log` row, `sync_source='jobber_visit_drift'`: `status='attention'` when
   anything still needs eyes (unhealed failed-push OR jobber-origin drift), else `'success'`.
   `details`: `heal_enabled / checked / drift_found / healable / drift_healed / residual_drift /
   jobber_origin / jobber_origin_visits / read_fail / healable_visit_ids`.

## Verified (2026-06-26)

- **Overnight fix:** visit 6496 (untimed, 3:00 AM = overnight of 06-25) no longer flagged.
- **Classification / no false revert:** visits **5971** (untimed 06-25 vs Jobber 06-26 9:30 AM —
  `no_our_edit`) and **6458** (timed; DB 06-25 midnight vs Jobber 06-26 2:00 AM — `jobber_value_unexpected`,
  we'd moved it via `sql`) are **surfaced, `healable=0`, `healed=0`** — Jobber-side state untouched.
- **Heal:** an induced failed-our-push on visit 6038 (DB→11-25, Jobber stuck on 11-20, audit proves
  ours) classified `healable=1`, healed (Jobber → 11-25), the 2 jobber-origin untouched, then
  reverted net-zero (DB + Jobber).

## Open review items (surfaced, not auto-resolved)

`sync_log` currently shows **2 jobber-origin drifts** to eyeball: **5971** (028-HUM) and **6458**
(195-MYK) — both DB operating-date 06-25 vs a Jobber 06-26 slot. Likely a driver/Diego scheduled them
in Jobber; if Jobber is right, our DB should adopt the Jobber date (a future **Jobber→DB adopt** step,
intentionally NOT automated yet — it writes canonical data from a Jobber-side edit).

## Pieces

| Piece | File |
|---|---|
| Candidate set fn | `docs/migrations/2026-06-26_calendar_visit_drift_candidates.sql` |
| Re-push primitive | `docs/migrations/2026-06-26_fn_request_jobber_push.sql` |
| Heal safety discriminator | `docs/migrations/2026-06-26_visit_last_schedule_edit.sql` |
| Edge Function | `supabase/functions/sync-jobber-visit-drift/index.ts` (verify_jwt=false) |
| Cron (RECORD) | `docs/migrations/2026-06-26_jobber_visit_drift_reconcile_cron.sql` — `jobber-visit-drift-reconcile` `*/30` |

## Operating

- **Watch:** `SELECT status, details FROM sync_log WHERE sync_source='jobber_visit_drift' ORDER BY id DESC;`
  Alert when `details->>'residual_drift'` (a failed-our-push that the re-push couldn't fix) or
  `details->>'jobber_origin'` stays `> 0` across **two** runs.
- **Manual run:** `POST /functions/v1/sync-jobber-visit-drift` with `x-sync-key` + `x-sync-wait: 1`
  (add `x-no-heal: 1` to detect-only).
- **Disable heal:** set Functions secret `DRIFT_HEAL_DISABLED=1`.

## Compliance

No new business table; reuses `sync_log` + the `entity_source_links` bridge. No source-prefixed
columns. `fn_request_jobber_push` / `visit_last_schedule_edit` are SECURITY DEFINER, service_role-only.
Heal never writes `visits.derm_required` (cannot demote DERM) and never hard-deletes (`op='upsert'`
only). ADR 010: view/function/cron only → audit opt-out per migration header.
