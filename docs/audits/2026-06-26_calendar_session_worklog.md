# Calendar + Jobber + Audit-Trail work session — 2026-06-25/26

This work-log documents the Calendar↔Jobber two-way integration hardening session that ran
**2026-06-24 → 2026-06-26** in the Supabase repo (42 commits in window). The session delivered
six requested feature threads plus supporting cross-feature work (Jobber-push edge function,
Service-Agreement line-item editing, Team multi-select, audit-trail Phase 1, doc consolidation,
and audits). It also captures a live 112-YA lifecycle smoke test, one pre-existing bug that the new
attribution work made visible, and a stale UI copy string to fix.

> **Scope note.** Every claim below is grounded in the session commit/migration inventory.
> Two of the six features live partly or wholly in the Lovable Calendar project
> (`Building Apps/Visit Calendar`), which has no local git history; for those, only the
> DB-side contract they rely on can be reconstructed from this repo (see *Uncertainties* at the end).
> The only other git repo under the working directory — `Building Apps/unclogme-pdf-service` — had
> **no commits in the 06-24..06-26 window** (latest commit `5d3cc7c` dates to 2026-06-06), so it
> contributed nothing to this session.

---

## Feature 1 — Drawer "Open in Jobber" button moved to header + Jobber icon

**What changed.** The visit drawer's "Open in Jobber" action was moved to the drawer header and given
a Jobber icon. This is a **Lovable UI-only change** with **no Supabase commit** in this window.

**Why.** The drawer needs a consistent, discoverable deep-link out to Jobber for the underlying job.

**DB-side basis.** The deep link uses the **JOB's** `jobberWebUri` (the `secure.getjobber.com/work_orders/<id>`
URL). A `Visit` has **no** `jobberWebUri` of its own — the contract is documented at
`docs/jobber-calendar-job-migration/service-agreement-visit-generation.md` §8.3 (lines 113-118).

| Item | Detail |
| --- | --- |
| DB-side basis (doc) | `service-agreement-visit-generation.md` §8.3 (lines 113-118) |
| Supabase commit | none (Lovable UI-only) |

**How it was verified.** The DB-side deep-link contract (job `jobberWebUri`) is verified by the
referenced doc section. The button-move + icon itself is a published Lovable change; its exact UI diff
cannot be reconstructed from this repo (no local git history for the Calendar app).

---

## Feature 2 — Cascade-to-Jobber ripple reschedule (verified net-zero, job 1377)

**What changed.** A cascade/ripple reschedule was built: moving a visit re-anchors the job's forward
visit chain at the job's `frequency_days` and pushes each affected visit to Jobber. Implemented as a
`public` RPC plus an `ops`-schema wrapper so the Calendar app can call it through its ops PostgREST
client (schema-per-app pattern).

**Why.** When an operator reschedules an anchor visit, the subsequent recurring visits should ripple
forward to preserve cadence, and those changes must propagate to the Jobber schedule.

| Commit | Date | What | File |
| --- | --- | --- | --- |
| `d429ece` | 2026-06-24 | `public.ripple_reschedule_visit` RPC (dry-run-verified, not yet wired); re-anchors forward chain at `jobs.frequency_days`, fan-out cap 24, scope `source IN (visit-calendar, supabase_cron)` | `2026-06-25_ripple_reschedule_visit_rpc.sql` |
| `fcc03a6` | 2026-06-24 | `ops.ripple_reschedule_visit` wrapper for the Calendar app's ops PostgREST client | `2026-06-25b_ops_ripple_reschedule_visit.sql` |
| `8af992b` | 2026-06-26 | Docs: ripple reschedule confirmed LIVE-wired + Jobber-verified | `jobs-visits-calendar-workflow.md` (record) |

**How it was verified.** The deployed Calendar bundle (`index-C5_bbv1U.js`) calls
`rpc('ripple_reschedule_visit')` with `p_dry_run`. It was **Jobber-verified live on job 1377**
(041-MB, Marie Blachere): anchoring the visit +3 days re-anchored all 3 forward visits at the job
frequency, each pushed exactly once via `visitEditSchedule` (3× `200 OK`), then **reverted net-zero**.
This marked ripple-reschedule rollout gates 2 + 3 done.

---

## Feature 3 — Gate #4 drift watchdog (`sync-jobber-visit-drift`)

**What changed.** A new edge function, `sync-jobber-visit-drift`, was created and matured over three
commits into a **two-way HEAL / ADOPT / SURFACE reconciler** that runs on a 30-minute cron. It compares
DB visit schedules against Jobber and is **on by default**, with a kill-switch.

**Why.** Gate #4 of the Calendar↔Jobber rollout: detect and reconcile schedule drift between the DB and
Jobber (our failed pushes, Jobber-side edits, and genuinely ambiguous conflicts).

| Commit | Date | What | Files |
| --- | --- | --- | --- |
| `be8709f` | 2026-06-26 | NEW edge fn (detect + log only, heal gated OFF); candidates fn, HTTP-push helper, cron registration, config.toml entry | `functions/sync-jobber-visit-drift/index.ts`; `2026-06-26_calendar_visit_drift_candidates.sql`; `2026-06-26_fn_request_jobber_push.sql` (SECURITY DEFINER); `2026-06-26_jobber_visit_drift_reconcile_cron.sql`; `config.toml` `[functions.sync-jobber-visit-drift] verify_jwt=false` |
| `4235171` | 2026-06-26 | Direction-safe audit-gated HEAL + overnight-aware compare; rewrites `index.ts` | `functions/sync-jobber-visit-drift/index.ts`; `2026-06-26_visit_last_schedule_edit.sql` (read-only fn over `audit.logs` to find our last `visit_date` edit) |
| `020aba0` | 2026-06-26 | Adds Jobber→DB ADOPT; `index.ts` becomes fully two-way (see Feature 4) | `2026-06-26_adopt_visit_schedule_from_jobber.sql`; `functions/sync-jobber-visit-drift/index.ts` |
| `adbf547` | 2026-06-26 | Docs: refresh cron RECORD header to two-way + on-by-default | `2026-06-26_jobber_visit_drift_reconcile_cron.sql`; canonical doc `2026-06-26_gate4-drift-watchdog.md` |

**Reconciler behavior.**
- **HEAL** — DB→Jobber, for our own failed push (re-pushes the DB value).
- **ADOPT** — Jobber→DB, for a Jobber-side edit (see Feature 4; push-suppressed, audited).
- **SURFACE** — ambiguous case: *we* edited **and** Jobber holds another value → flag, do not auto-resolve.

**Overnight-aware compare.** An untimed `visit_date` is compared against a **06:00 ET cutoff** so the
10pm–3am execution of an operating date is **not** miscounted as drift.

**Access / kill-switch.** The function is registered `verify_jwt=false` (invoked by pg_cron with an
`x-sync-key`). Reconcile writes are **ON by default**; the kill-switch is env `DRIFT_HEAL_DISABLED=1`
(or request header `x-no-heal:1`).

**How it was verified.** Canonical feature doc `docs/jobber-calendar-job-migration/2026-06-26_gate4-drift-watchdog.md`
records Status **LIVE**, cron every 30 minutes. (One surfaced/ambiguous conflict — visit 6458, 195-MYK —
remains OPEN per MEMORY.md; it was out of scope for this session's code work — see *Uncertainties*.)

---

## Feature 4 — Jobber→DB adopt with audit (`app_source='jobber'`)

**What changed.** The drift reconciler's **ADOPT** path writes Jobber-side schedule edits back into the
DB through a dedicated migration, `adopt_visit_schedule_from_jobber`, which writes to the already-audited
`public.visits` table with the push suppressed (so adopting a Jobber value does not bounce back to Jobber).
These writes are **audited as `app_source='jobber'`**.

**Why.** When a human edits a visit's schedule directly in Jobber, the DB should adopt that value rather
than fighting it — but the change must be attributed to Jobber, not silently merged.

| Commit | Date | What | File |
| --- | --- | --- | --- |
| `020aba0` | 2026-06-26 | `adopt_visit_schedule_from_jobber` (writes to audited `public.visits`, push-suppressed); makes the reconciler two-way (HEAL / ADOPT / SURFACE) | `2026-06-26_adopt_visit_schedule_from_jobber.sql`; `functions/sync-jobber-visit-drift/index.ts` |

**How it was verified.** The ADOPT path is wired through the reconciler and audited `app_source='jobber'`;
documented in the gate #4 feature doc (`2026-06-26_gate4-drift-watchdog.md`) and the refreshed cron record
header (`adbf547`).

---

## Feature 5 — Activity "who did it" attribution (P1 / P2a / P2b)

**What changed.** The Activity tab gained real "who did it" attribution, shipped in three phases on top of
the audit-trail Phase 1 foundation. A "Show Jobber sync changes" toggle was added, defaulting **ON**.

**Why.** The Activity history previously could not name the person behind a Calendar edit, nor cleanly
distinguish Calendar-app edits from Jobber-side changes and system/cron activity.

**Design + foundation.**

| Commit | Date | What | Files |
| --- | --- | --- | --- |
| `49f7927` | 2026-06-25 | Design spec: Activity History / Audit Trail (v1) | `specs/2026-06-25-audit-trail-activity-history-design.md` |
| `8cee69b` | 2026-06-25 | Audit Trail Phase 1 backend: `get_record_history` RPC + render config | `2026-06-25_audit_trail_phase1.sql` (txid capture, `audit.entity_render_config`, `audit.render_value`, `public.get_record_history` RPC, index) |
| `886f6b0` | 2026-06-25 | Mark Audit Trail Phase 1 backend as shipped in the spec | spec |
| `f905580` | 2026-06-25 | Wire Calendar UI to backend: expose `ops.service_line_items.unit_price` + `ops.get_record_history` | `2026-06-25_ops_service_line_items_unit_price.sql` |
| `0e33241` | 2026-06-26 | NEW spec: Activity-tab "who did it" attribution design (P1/P2a/P2b plan; 4-lens adversarial review returned GO-WITH-CHANGES) | `specs/2026-06-26-activity-who-did-it-attribution-design.md` |

**Phase work.**

| Commit | Date | Phase | What | File |
| --- | --- | --- | --- | --- |
| `022ca5a` | 2026-06-26 | P1 + P2a | Seeds `public.employees.email`; Calendar edits show the person, Jobber changes show "Changed in Jobber". Label rule: human apps → `'Edited in '\|\|initcap(app_source)`; `'%-cron'`/`'jobber-reconcile'` → `'System (Jobber sync)'` | `2026-06-26_activity_attribution_p1_p2a.sql` |
| `5d3c37a` | 2026-06-26 | P2b | `webhook-jobber/index.ts` adds a dedicated `supabaseJobber` client (`x-app-source:jobber` + `x-actor-name` from `createdBy.name.full` / `completed_by`), used **only** for `handleVisit` visit-table writes; the shared singleton stays headerless to preserve ADR-016 attribution for clients/jobs/invoices/etc. | `2026-06-26_activity_attribution_p2b.sql` (read+capture layer only); `functions/webhook-jobber/index.ts` |

- **P1** — Calendar person attribution via the editor's `jwt_claims` email → `public.employees` (Fred + Yannick
  seeded).
- **P2a** — Jobber label: Jobber-side changes surface as "Changed in Jobber"; cron/system sources roll up to
  "System (Jobber sync)".
- **P2b** — Name the Jobber actor by stamping `x-app-source:jobber` + `x-actor-name` on a per-write client
  inside `webhook-jobber`'s `handleVisit`, so visit-table writes carry the human's name from
  `createdBy.name.full` / `completed_by`. Operation-specific labels come from `get_record_history`.

**"Show Jobber sync changes" default ON.** The toggle defaults ON via `get_record_history p_hide_system=false`
(`specs/2026-06-26-activity-who-did-it-attribution-design.md` line 67). This is a **Lovable UI change**,
already published; **no separate migration**.

**How it was verified.** The audit-trail Phase 1 backend (`get_record_history`, render config) was verified on
visit 6804. The attribution labels were live-checked in the 112-YA smoke test below (Calendar person vs.
"Changed in Jobber" vs. "by Yannick").

---

## Feature 6 — `delete_calendar_visit` soft-delete RPC

**What changed.** `delete_calendar_visit` became a **true soft-delete RPC**: it sets `deleted_at=now()`
(canonical soft delete) rather than ever hard-deleting. Views read `v_visits_live WHERE deleted_at IS NULL`.
The delete is attributed to the deleter, and it fires `trg_push_visit_update` to delete the visit in Jobber
per the Origin fail-safe. Apps call `ops.delete_calendar_visit`; Lovable's "Delete visit" was rewired to it.

**Why.** Deletes must be reversible and auditable (never hard-delete — Rule 6), and a Calendar delete must
propagate to Jobber regardless of the visit's source.

| Commit | Date | What | File |
| --- | --- | --- | --- |
| `76f0df9` | 2026-06-25 | Precursor: propagate Calendar deletes to Jobber for ANY-source visit (fail-safe) | `2026-06-25_propagate_calendar_deletes_to_jobber.sql` (doc: `2026-06-25_calendar-jobber-sync-fixes.md`) |
| `8c1e86d` | 2026-06-26 | `public.delete_calendar_visit(bigint)` soft-delete (`deleted_at=now()`), attributed to deleter, fires `trg_push_visit_update`, never hard-deletes (Rule 6); apps call `ops.delete_calendar_visit`; Lovable rewired | `2026-06-26_delete_calendar_visit_soft.sql` |

**How it was verified.** Live-verified in the 112-YA smoke test below: visit 6822 was soft-deleted
(`deleted_at` set), disappeared from `v_visits_live`, attributed to "Fred", and its Jobber GID returned
"Visit not found".

---

## 112-YA lifecycle smoke test (2026-06-26)

A full create → complete → delete lifecycle was exercised on client 112-YA and checked end-to-end:

- **Visit 6822** was created, completed, and deleted — **all three actions attributed to "Fred"**:
  - **create** → logged as `created`
  - **complete** → `status -> completed`
  - **delete** → soft-delete (`deleted_at` set)
- After delete, visit 6822 was **gone from `v_visits_live`**, and its **Jobber GID `2231076082`** now
  returns **"Visit not found"** (the delete propagated to Jobber).
- The **other** 112-YA visit, **6806**, correctly showed **"by Yannick"** — confirming per-actor
  attribution distinguishes the two operators.

This exercised Features 5 (attribution) and 6 (soft-delete + Jobber delete propagation) together.

---

## Known issue surfaced: Calendar completions reverted by Jobber inbound poll

During the smoke test, a **pre-existing** bug became visible: a completion made in the Calendar is
**reverted ~18 seconds later** by `handleVisit` (the Jobber inbound poll), with the reverting write
attributed `app_source='jobber'`.

- **Pre-existing.** The revert behavior already existed; the P2b attribution work (Feature 5) only made it
  **visible and correctly labeled** — it now shows as "Changed in Jobber" instead of the previous generic
  "System". P2b did **not** introduce the revert.
- **Fix in design.** A two-way **completion-reconciliation** fix is being designed per Fred's clarified
  requirements: completions are **bidirectional**, and the **Calendar is a valid completion source** (so a
  Calendar completion should not be clobbered by the inbound Jobber poll).

---

## Stale copy to fix

The delete-confirmation dialog copy is now stale. It still says the delete will be
**"reversed by setting visit_status back from cancelled"** — that describes the **old** behavior. The new
mechanism is a `deleted_at` **soft-delete** (Feature 6). The dialog text should be updated to match the
soft-delete model.

---

## Appendix — supporting cross-feature work in the window

These commits supported the six features but are not themselves a requested feature thread:

- **Edge fn `jobber-push-visit`** (`c624391`, `6a7354d`, `9f4ce32`, `057454a`, `c61cfb1`, `4c76184`):
  idempotent line-item sync (fix dup/missing); push Service-Call line items (`visitCreateLineItems`); push
  assigned driver on create + update; drawer line-item display fix + push dedupe; push crew to Jobber
  `assignedUsers`; lift the SA push skip (v19 pushes SA per-visit overrides).
- **Service-Agreement line-item editing** (`bfcecc6`, `dc1a16d`, `2953fba`, `55e98c4`, `4c76184`, `8da2d0a`):
  spec `2026-06-25-sa-visit-line-item-editing-design.md` + migrations
  `2026-06-25_calendar_visit_line_item_prices.sql`, `2026-06-25_edit_calendar_visit_rpc.sql`,
  `2026-06-26_edit_visit_arbitrary_line_items.sql` (`edit_calendar_visit` accepts a full arbitrary line-item
  list incl. ACH / credit-card fees). Drawer redesign (read-first, section-level edit) live-verified.
- **Team multi-select (Driver → Team)** (`c61cfb1`, `eea4c63`): migrations `2026-06-25_visit_team.sql`
  (visits carry 0/1/many crew) + `2026-06-25_visit_team_backfill_from_driver.sql`; doc
  `2026-06-25_team-multiselect.md` (SHIPPED + live-verified on `calendar.unclogme.app`); pushed to Jobber
  `assignedUsers`.
- **2026-06-24 Calendar/DB trio** (`e6a548b`, `ae1b013`/`f2f2c4e`, `163b00f`/`1f1df6d`, `31c330d`, `68e858a`):
  `clients_class_source` guard (manual `client_class` protected from the Jobber poll's `isCompany`
  re-derive) + stale-SA cleanup sweep + SA anchor fix + GDO permit PDF ingest (backfill 75; 123/145 ACTIVE
  linked) + `gdo-permits` public bucket + `visit_assigned_driver` RPC; doc `2026-06-24_calendar-db-features.md`.
- **Crew consolidation** (`6082981` doc; reorg in `55990a7`): driver dropdown reconciled from 34 rows to the
  6 real crew (`ops.v_calendar_driver = employees WHERE status='ACTIVE'`); doc `2026-06-24_crew-consolidation.md`.
- **Security — secret redaction** (`bfb747f`): `2026-06-25_audit_redact_webhook_token_secrets.sql` redacts
  Jobber OAuth secret values leaked into `audit.logs` from `webhook_tokens` (Phase 0 of the audit-trail spec;
  keeps the trigger).
- **Doc consolidation** (`55990a7`): merged Jobber-jobs-migration + Calendar-reformat docs into
  `docs/jobber-calendar-job-migration/` (new `README.md`), updated 2 workflow `.yml` paths + `CLAUDE.md` +
  2 migration paths.
- **Audits** (`2dcfafe`, `eea4c63`): `docs/audits/2026-06-25_app_timezone_et_audit.md` (all apps display ET,
  no browser-zone leak) + `docs/audits/2026-06-25_today_work_audit.md` (GREEN).

---

## Uncertainties / out of scope for this log

- **Feature 1** (Open-in-Jobber button move + Jobber icon) and the **"Show Jobber sync changes" default-ON**
  toggle live in the Lovable Calendar project (`Building Apps/Visit Calendar`), which has **no local git
  history**. Their exact UI diffs cannot be reconstructed from this repo — only the DB-side contract they
  rely on (job `jobberWebUri`; `get_record_history p_hide_system=false`).
- The gate #4 doc notes **1 surfaced/ambiguous conflict (visit 6458, 195-MYK)** still OPEN per MEMORY.md.
  This session captured the code/migrations but did **not** resolve that conflict (out of scope).
- Per the `jobs-visits-calendar-workflow` record, the **pg_net push watchdog** was the one remaining
  ripple-reschedule rollout gate after gates 2 + 3 were marked done. Its current status was **not**
  independently re-verified in this read-only inventory.
