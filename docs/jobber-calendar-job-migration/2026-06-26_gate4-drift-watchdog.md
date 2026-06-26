# Gate #4 — Calendar→Jobber schedule-drift watchdog (`sync-jobber-visit-drift`)

*2026-06-26. Status: **DETECT + LOG LIVE** (cron every 30 min). Auto-heal BUILT + tested but **OFF by default** pending a heal-direction policy.*

## Why it exists

A Calendar/cron visit edit (incl. every row of a `ripple_reschedule_visit` cascade) pushes to
Jobber **fire-and-forget**: `trg_push_visit_update → fn_push_visit_to_jobber → net.http_post →
jobber-push-visit → visitEditSchedule`. If that push silently fails (Jobber userError, token
refresh failure, pg_net drop), **the DB shows date X while Jobber stays on date Y and nothing is
recorded**:

- The update push path writes **no** `visit_sync_flags` row (flags are only written on the
  *create* path — `jobber-push-visit/index.ts:269,272`).
- `net._http_response` has **no `visit_id`** (body returns the Jobber GID, not our id), is 84%
  poll-noise, and purges in **~6 h** (`pg_net.ttl='6 hours'`). Unusable for forensics.
- The inbound poll **never clobbers** a calendar/cron visit's schedule (the `handleVisit`
  loop-guard does a completion-only sync — `webhook-jobber/index.ts:581-603`), so the DB keeps
  the correct date and the divergence is **invisible from DB columns alone**.

The existing `ops.v_calendar_push_health` only finds *unlinked* orphans + explicit flag rows — a
failed reschedule is *linked* (has a GID) and *unflagged*, so it slips through. The **only** way
to catch it is to read Jobber's actual `startAt` and compare. That is gate #4.

## What it does

Pattern-A self-verifying watchdog (pg_cron → Edge Function), modeled on `sync-jobber-upcoming-visits`:

1. **Candidates** — `public.calendar_visit_drift_candidates(p_back_days=7, p_fwd_days=184)`:
   calendar/cron-mastered (`source IN ('visit-calendar','supabase_cron')`), `scheduled`,
   Jobber-**linked**, live (`v_visits_live`) visits in `[today-7, today+6mo]`. (~676 today.) The
   window is **re-scanned in full every run** (level-triggered, no cursor) so a skipped run is
   self-healing.
2. **Pull** Jobber's upcoming visits (`startAt` ≥ today-7), paginated, stopping once every
   candidate GID is seen; map `gid → startAt`.
3. **Compare ET-floored** (mirrors `etParts`/`visitSchedule` in `jobber-push-visit`): untimed
   visit → compare date only; timed → date + ET `HH:MM`. Jobber returns an all-day `startAt` as
   ET-midnight-in-UTC (`04:00Z`), which floors back to the `visit_date` — **verified on visit 6036,
   no false-positive**.
4. **Heal (gated)** — for each drifted visit, `rpc('fn_request_jobber_push', {visit_id,'upsert'})`
   (reuses the proven trigger path: vault `jobber_push_service_key` → `jobber-push-visit`), then
   **re-reads Jobber per GID to confirm convergence**. Idempotent; `op='upsert'` on a linked visit
   only edits schedule/title/team/lines — never creates or deletes. Bounded `MAX_HEAL_PER_RUN=50`.
5. **Log** one `public.sync_log` row, `sync_source='jobber_visit_drift'`:
   `status='attention'` when drift detected + heal off, `'success'`/`'partial'` when healing,
   `'error'` on throw. `details` carries `checked / drift_found / drift_healed / residual_drift /
   read_fail / heal_enabled / drifted_visit_ids`.

## Safe-by-default: why auto-heal is OFF

A state reconcile **cannot tell** a failed *our-push* (DB right → heal DB→Jobber) from a deliberate
*Jobber-side edit* (Jobber right → do **not** clobber). The very first scan (2026-06-26) proved this
matters — it found **3 real divergences**:

| visit | client | DB date | Jobber date | note |
|---|---|---|---|---|
| 5971 | 028-HUM Hummus Achla | 2026-06-25 | 2026-06-26 | scheduled, cron, no app-edit |
| 6458 | 195-MYK Myka Lincoln | 2026-06-25 | 2026-06-26 | scheduled, cron, no app-edit |
| 6496 | 214-MYK Myka Brickell FT | 2026-06-25 | 2026-06-26 | scheduled, cron, no app-edit |

All three are dated **yesterday** in DB but **today** in Jobber — almost certainly **slipped visits
moved forward in Jobber**. Blindly healing DB→Jobber would revert them to *yesterday*, which is
wrong. So the watchdog **surfaces** drift (sync_log `attention`) rather than auto-reverting it.

**To enable auto-heal** once the policy is set ("Calendar is master, always heal DB→Jobber"):
set the Functions secret `DRIFT_HEAL_ENABLED=1` (project-wide) — OR send a per-call `x-heal: 1`
header for a one-off heal. Heal was **validated in isolation** on a controlled induced drift
(visit 6038: DB→Jobber re-push converged Jobber, then reverted net-zero). Before flipping it on,
prefer adding **push-intent attribution** (only heal drift on a visit whose schedule was edited via
our apps recently) so legitimate Jobber-side edits are never clobbered.

## Pieces

| Piece | File |
|---|---|
| Candidate set fn | `docs/migrations/2026-06-26_calendar_visit_drift_candidates.sql` |
| Re-push primitive | `docs/migrations/2026-06-26_fn_request_jobber_push.sql` (`public.fn_request_jobber_push(visit_id, op)`) |
| Edge Function | `supabase/functions/sync-jobber-visit-drift/index.ts` (verify_jwt=false, `config.toml`) |
| Cron (RECORD) | `docs/migrations/2026-06-26_jobber_visit_drift_reconcile_cron.sql` — `jobber-visit-drift-reconcile` `*/30` |

## Operating

- **Watch:** `SELECT status, details FROM sync_log WHERE sync_source='jobber_visit_drift' ORDER BY id DESC;`
  Alert when `details->>'residual_drift'` (heal on) or `details->>'drift_found'` (heal off) stays
  `> 0` across **two consecutive** runs — a transient throttle clears next run; sustained = a real
  divergence to investigate (or, if `read_fail>0`, a Jobber-deleted-but-still-linked visit → that's
  the `cron_jobber_reconcile_anomalies` soft-delete path, not this gate).
- **Manual run:** `POST /functions/v1/sync-jobber-visit-drift` with `x-sync-key` + `x-sync-wait: 1`
  (add `x-heal: 1` to heal that run).

## Compliance

No new business table; reuses `sync_log` + `visit_sync_flags`. No source-prefixed columns — the
DB↔Jobber map is the `entity_source_links` bridge. `fn_request_jobber_push` is SECURITY DEFINER,
service_role-only. Heal never writes `visits.derm_required` (structurally cannot demote DERM) and
never hard-deletes (`op='upsert'` only). ADR 010: view/function/cron only → audit opt-out, stated
in each migration header. Built from the verified design in
`docs/superpowers/specs/` workflow (2026-06-26).
