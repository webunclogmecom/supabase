# Gate #4 — Calendar↔Jobber schedule-drift reconciler (`sync-jobber-visit-drift`)

*2026-06-26, revised **2026-07-08** (time-refinement adopt + RPC hardening — see below). Status:
**LIVE** (cron every 30 min). Two-way: HEAL failed-our-pushes (DB→Jobber), ADOPT Jobber-side edits
and same-date time refinements (Jobber→DB, audited as `jobber`), SURFACE ambiguous conflicts.
Reconcile writes on by default; kill-switch available.*

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
| **HEAL** (DB→Jobber) | a schedule audit UPDATE set the **current DB value** — BOTH halves: `new_date` = `visit_date` AND `new_start_at` = `start_at` as instants (tightened 2026-07-08: adopts are `app_source='jobber'`-invisible to `visit_last_schedule_edit`, so after an adopt the time half no longer matches and HEAL must not re-push a mixed office-date + adopted-time) — AND Jobber holds the **exact pre-edit value** → our push failed | re-push via `fn_request_jobber_push` (vault key → jobber-push-visit), re-read to confirm |
| **ADOPT** (Jobber→DB) | **no** schedule audit UPDATE → we never touched it → a driver/Diego scheduled it in Jobber → Jobber authoritative | pull Jobber's schedule into DB via `adopt_visit_schedule_from_jobber` |
| **ADOPT / time_refinement** (Jobber→DB, **NEW 2026-07-08** — Yan's stale-Calendar report) | we DID edit it, but the last office edit was **date-bearing** (`old_date ≠ new_date`, e.g. a bulk day-shift) AND Jobber's ET **clock date** still equals `visit_date` AND Jobber's start is **timed** → the date intent agrees; the residual is dispatch re-timing the stop in Jobber after our push landed → Jobber owns route times | same adopt RPC; ids logged in `details.time_refined_visit_ids` |
| **SURFACE** (review) | anything else ambiguous — incl. early-AM (<06:00 ET) Jobber re-times (clock-date guard: the BEFORE trigger stores the ET **clock** date per Fred 2026-07-02, so adopting one would silently flip `visit_date` +1), Jobber all-day re-flags of a timed DB visit (never wipe an office time), pure time-only office edits with a third Jobber value, and `audit_read_fail` (transient `visit_last_schedule_edit` error — never falls through to the unguarded adopt) | log only, never auto-resolve |

**2026-07-08 incident + hardening** (migration `2026-07-08_adopt_schedule_concurrency_confirm_and_7048.sql`):
Yan reported the Calendar day view ≠ Jobber (order + times). The 07-06 Calendar bulk +1-day shift
landed in Jobber, then dispatch re-timed 13 stops (Jul 8–10) inside Jobber → every one surfaced as
`jobber_value_unexpected` forever (both-sides-edited). Fleet sweep vs live Jobber (242 linked
scheduled visits): exactly those 13, zero others. The time_refinement class above drains them (13
adopted in one run, drift 0 after). Shipped with it, per 2-skeptic adversarial review:
- **Optimistic concurrency** on `adopt_visit_schedule_from_jobber` (`p_expected_visit_date` /
  `p_expected_start_at` / `p_enforce_expected`): the fn adopts from a minutes-old snapshot; if the
  office dragged the visit mid-run the RPC now refuses (adoptFail → fresh retry) instead of
  clobbering the newer office edit.
- **`sync_state='confirmed'` finisher** in the RPC: the adopt UPDATE flips `sync_state='pending'`
  (the mark trigger is NOT gated by the suppress GUC) and nothing confirmed it, so the */3-min
  `resolve-stale-visit-sync-pending` cron **blind-re-pushed the adopted schedule to Jobber ~3–6 min
  later** — silently reverting any dispatch edit made in that window, with zero trace. The finisher
  (sync_state-only UPDATE — trips no push/mark/date trigger) kills that echo.
- Grants tightened (PUBLIC EXECUTE leak from 06-26 revoked; service_role only).
- Phantom visit 7048 (169-TCE, deleted upstream in Jobber) soft-deleted → `read_fail` 1→0 and the
  Jobber pagination early-break works again.
- `details` keys: `adopted_visit_ids` renamed **`adoptable_visit_ids`** (it always listed adoptable),
  new **`time_refined_visit_ids`**, new surfaced reason **`audit_read_fail`**.

**Known divergence (flagged, not fixed here):** `adoptTarget`'s early-AM −1 mapping and CLAUDE.md's
operating-date section still describe the pre-2026-07-02 trigger behavior; the live trigger Branch 3
stores the ET **clock** date ("must NOT move the date", Fred 2026-07-02). Inert under the clock-date
guard. Also latent: `cron_jobber_reconcile_anomalies.js` case 2 compares the raw UTC date-slice with
no source guard — a clobber lane for DATE-level drift that should be aligned with this fn's rules.

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
