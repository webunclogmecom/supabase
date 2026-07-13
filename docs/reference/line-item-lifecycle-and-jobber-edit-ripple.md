# Line-item lifecycle & Jobber-edit ripple

*Created 2026-07-13. Canonical reference for how `public.line_items` are populated, how a
scheduled vs. completed visit "reflects" a service line, what a Jobber **job** line-item edit
ripples into, and the 2026-07-13 design to propagate such edits to future visits + the
customer work order. Trigger: Diego added a line item to job #99900714 (082-TFC) in Jobber.*

Cross-links: [`jobs-visits-calendar-workflow.md`](../jobber-calendar-job-migration/jobs-visits-calendar-workflow.md) ·
[`derm_required_by_line_item.md`](derm_required_by_line_item.md) · [`integration.md`](../integration.md) ·
ADR 018 (DERM-required by line item).

---

## 1. The four scopes of `public.line_items`

A `line_items` row is scoped to **exactly one** container via one of four FK columns; the other three are NULL:

| Scope | Column set | Written by | Meaning |
|---|---|---|---|
| **Visit** | `visit_id` | `webhook-jobber.handleVisit` (Jobber-mastered visits only) | The services actually recorded on a completed visit. |
| **Job** | `job_id` | `webhook-jobber.handleJob` + `reconcile_jobs.js` (SA jobs) | The recurring SA template — the agreed services for the job. |
| **Invoice** | `invoice_id` | `webhook-jobber.handleInvoice` | The billed lines once a visit is invoiced (frozen). |
| **Quote** | `quote_id` | quote sync | Quote lines (not relevant here). |

Columns: `id, job_id, quote_id, name, description, quantity, unit_price, total_price, taxable, invoice_id, visit_id (+timestamps)`.
Only trigger on the table is `trg_line_items_updated_at` (timestamp) — **the table itself has no ripple logic**;
every real cascade lives on `public.visits`. `line_items` is **not** audited (ADR-010 opt-out), so manual edits leave no `audit.logs` trail.

Service names carry a `NN - ` code prefix (e.g. `01 - Service Agreement - Pumping…`, `27 - GDO Online Reporting`,
`25 - Credit card fee (3.53%)`). DERM-required keys on **pumping** codes 01–04 / 09–11 (ADR 018).

---

## 2. How a visit "reflects" a line item — scheduled vs. completed

**Scheduled (future) visits carry ZERO visit-scoped line items.** They inherit the job's template through a
`COALESCE(visit-scoped, ELSE job-scoped)` fallback in the read views. So whether a scheduled visit "reflects" a
service depends entirely on **which surface reads it**:

| Surface | Read pattern | Reflects a job-scoped line on a scheduled visit? |
|---|---|---|
| Calendar amount / drawer (`ops.v_calendar_visit`, `_detail`) | `COALESCE(sum visit-scoped, sum job-scoped where job_id=v.job_id AND visit_id IS NULL AND invoice_id IS NULL)` | **YES** — inherits the job template automatically. |
| `fn_visit_requires_derm` | unions visit + invoice + **job** scope | **YES** (pumping codes). |
| Field Portal work order (`customer.work_orders.services`) | `line_items WHERE visit_id = v.id`, **completed-only** | **NO** — visit-scoped only; scheduled visits never appear (completed-only) and completed ones show only their own rows. |

`customer.work_orders.services` already **strips the `NN - ` prefix and filters fee lines**
(`credit card|fee|discount|surcharge|convenience|gratuity`) — so a customer sees clean service names, never a card fee.

**Completed visits** get visit-scoped rows **only** via `handleVisit` — and only for **Jobber-mastered** visits.
For DB-mastered visits (`source IN ('supabase_cron','visit-calendar')`) `handleVisit` writes completion fields and
**returns early, before the line-items block and before `set_visit_derm_required`**
(`webhook-jobber/index.ts` L687–713 vs L781–806). Result: DB-side completions materialize **no** visit line items →
the customer work order goes blank. Proof: 082-TFC's newest completed visit 6215 (`supabase_cron`) has zero
visit-scoped line items, whereas the 4 older Jobber-era completed visits each have one.

---

## 3. Sync timing — inbound Jobber → DB

- **`*/5` delta poll** (`sync-jobber-poll`) uses a **`createdAt` cursor** for jobs. Editing an existing job changes
  `updatedAt`, not `createdAt`, so the poll **never re-selects an edited job** → its job-scoped `line_items` go stale.
- **This gap is already closed** by **`reconcile_jobs.js` / `reconcile-jobs.yml` (every 6h)**: for every non-archived
  job it re-fetches Jobber by GID and, for SA jobs, wipe-replaces the job-scoped `line_items` (also fixes
  `job_status`, `frequency_days`, `title`, deletions). So an edited job's **job-scoped** copy self-heals within ≤6h.
- **Completion path** (`sync-jobber-upcoming-visits` / completed-visit poll → `handleVisit`) does **not** close the
  **visit-scoped** gap for DB-mastered visits (early-return above). This is the one real remaining gap.

**Reverse direction (DB → Jobber):** a **direct** `line_items` write does **not** push to Jobber. The push trigger
`fn_push_visit_to_jobber` lives on `visits` and only emits a `lineitems` group when `visits.line_items_rev` (bumped
**only** by `edit_calendar_visit`) or `service_line_item_id` changes. So `edit_calendar_visit` would push visit-scoped
**overrides** into Jobber (replacing the inherited SA lines) on linked visits within the 60-day horizon — **avoid it**
for this work; write `line_items` directly (`app_source='sql'`).

---

## 4. Ripple map — every consumer of `line_items`

Ordered by blast radius. Cascades are gated by `visits.line_items_rev`, not the table — **the ripple depends on the write path.**

| # | Effect | Surface | Severity | Note |
|---|---|---|---|---|
| 1 | Per-visit `amount` = `COALESCE(sum visit-scoped, sum job-scoped)`; rolls into day/month totals. Job-scoped add → all inheriting visits change at once. | `ops.v_calendar_visit` → Calendar | **Critical** | **Footgun:** any *partial* visit-scoped write flips that visit off the job fallback → amount collapses to just the written line. Write the full set if going visit-scoped. |
| 2 | Drawer line list shows the new item (same COALESCE). | `ops.v_calendar_visit_detail` | Medium | Desired (display). |
| 3 | `edit_calendar_visit` → `line_items_rev`++ → push → **replaces** the Jobber visit's inherited SA lines. | visits trigger → Jobber | **High** | Guard: don't route through `edit_calendar_visit`; a raw insert = no rev bump = no push. |
| 4 | `service_type` re-derived (GT>CL>WD, default GT). Codes 25/27 ≠ GT/CL/WD. | `visits.service_type` | Low | No change. |
| 5 | `derm_required` (`fn_visit_requires_derm`, monotonic). Code 27 non-pumping; already TRUE from code 01. | `visits.derm_required` | Medium / none here | Guard: `edit_calendar_visit` with a patch that drops the pumping line on an unlocked visit **demotes** derm to FALSE. |
| 6 | Field Portal work-order `services` (visit-scoped, completed-only). | `customer.work_orders` | Low / **latent gap** | The gap this design fixes. |
| 7 | New/Edit-visit service picker. | `ops.client_service_options` | Low | Cosmetic. |
| 8 | DERM Tracker / Stamp line-item text (invoice/job scoped, completed-only). | `derm.visits`, `derm.v_stamp_unlinked_visits` | Low | Cosmetic. |
| 9 | Truck badge (when `vehicle_id` NULL, min default_vehicle_id by code). | `ops.v_calendar_visit` | Low | Guard: check code 27 doesn't map a different default vehicle. |

Not a cascade: `ops.service_line_items` / `ops.service_options` read the **catalog**, not `line_items`. `sync_state`/push key off `line_items_rev`, not the table.

---

## 5. Design (approved 2026-07-13) — propagate to 082-TFC future visits + fix the class

**Requirements (Fred):** reflect the new line on **both** the internal Calendar **and** the customer work order;
fix the **class** (systemic), not just 082-TFC; customer work order shows **services only** (hide the card fee);
Part B done **phased** (view fallback now + snapshot trigger durable).

**The change (ground truth, Jobber job 148742630 / #99900714, RECURRING SA):**
`01 - Pumping $300`, **`27 - GDO Online Reporting $35` (new, non-pumping → no DERM impact)**, `25 - Credit card fee` recomputed `$10.59 → $11.83`. Job total **$346.83**. DB was stale (2 lines, old fee) at design time.

### Part A — 082-TFC now (job-scoped)
Run `reconcile_jobs.js` for job 1472 so its job-scoped `line_items` match Jobber (adds GDO, corrects fee). All 6 future
scheduled visits (6216 2026-08-08 … 6910 2027-01-05, all `supabase_cron`, all `job_id=1472`) then inherit **$346.83**
in the Calendar amount + drawer via the fallback — **no per-visit writes**. Verify all 6 read $346.83.
*(This is the existing 6h reconcile applied immediately; the inbound gap is already closed — Part A is just a nudge.)*

### Part B1 — view fallback (ship now)
`CREATE OR REPLACE VIEW customer.work_orders`: change `services` from visit-scoped-only to
`COALESCE(visit-scoped array, ELSE job-scoped array where job_id=v.job_id AND visit_id IS NULL AND invoice_id IS NULL)`,
keeping the existing prefix-strip + fee filter. Instantly fixes past + future blank completed visits (incl. 6215):
customer sees **"Pumping…" + "GDO Online Reporting"**, card fee hidden. Mirrors how the Calendar already works.
Trade-off: template semantics (a completed visit shows the job's *current* services, not a frozen snapshot).

### Part B2 — snapshot trigger (durable, post-Jobber source of truth)
Add a DB trigger: on a visit transition to `visit_status='completed'` **with no visit-scoped line items**, materialize
the job's line set as **visit-scoped** rows (a snapshot at completion) **and** re-derive `derm_required`
(`set_visit_derm_required`). Path-independent (fires for `supabase_cron` / `visit-calendar` / RPC completions), closes
both the line-item **and** the derm re-derivation skip in the `handleVisit` early-return. Idempotent (guard on
"no existing visit-scoped rows" + "job has job-scoped rows"). Direct insert → **no** `line_items_rev` bump → **no** Jobber
push. Once B2 ships, B1's fallback only serves legacy gaps. Backfill visit 6215.

### Part C — customer work order
No further change: the view already strips the `NN - ` prefix + filters fees (Fred's "services only"). The verbose
customer-facing label "Service Agreement – Pumping – Grease Trap & Tank Cleaning" stays **as-is** (Fred 2026-07-13: do not shorten).

### Part D — guardrails
Direct `line_items` writes only (`app_source='sql'`); **never** `edit_calendar_visit` (Jobber push-back on 6216/6217).
DERM stays TRUE (code 27 non-pumping, monotonic). Reconcile the **whole** job set to Jobber truth (don't insert only the
$35 and leave the stale fee → DB total would diverge from Jobber). Verify writes by re-reading `ops.v_calendar_visit.amount`
(write results to file + `JSON.parse` — Windows stdout corruption). Claim in `WORKING-NOW.md` before writing — this
touches `visits`/`line_items`/job 1472 (the most-shared surface); confirm Supabase 2 isn't on Calendar-side.

---

## 6. Top risks

1. **Stale-fee trap** — reconcile the full 3-line job set, not just the $35, or DB total ≠ Jobber.
2. **COALESCE amount-collapse** — a partial visit-scoped write silently drops a visit's amount; write the full set.
3. **Unintended Jobber push** — `edit_calendar_visit` overrides inherited SA lines on linked visits; use raw writes.
4. **DERM demotion** — an `edit_calendar_visit` patch dropping the pumping line demotes unlocked visits to FALSE.
5. **Template vs snapshot** — B1 shows current job services on old work orders; B2 fixes with a frozen snapshot.
6. **Falsely-successful raw write** — no push, no audit trail; verify by re-reading the Calendar amount.
7. **Parallel session** — coordinate via `WORKING-NOW.md`.

---

## 7. Docs to create / fix (part of this work)

- **This file** — the missing canonical reference (was absent per the 2026-07-13 doc audit).
- **Fix `docs/integration.md`** — the `JOB_CREATE/JOB_UPDATE` row omits the `handleJob` line-item + customField sync
  (2026-06-23 enhancement); a reader would wrongly conclude a Jobber line-item edit isn't synced.
- **Link** from `jobs-visits-calendar-workflow.md` and root `CLAUDE.md`.
- **Optional ADR 019** if B2 becomes a documented standing behavior (materialize-on-completion).
- App-side (doc-in-both-places): `Building Apps/Visit Calendar/docs/03-data-model.md` + `08-changelog.md`.

## 8. Key code refs

- `webhook-jobber/index.ts`: L522–537 (visit lineItems query), **L687–713 (DB-mastered early-return — skips line_items + derm)**, L781–806 (visit-scoped wipe+replace, `set_visit_derm_required`), L862–970 (handleInvoice), L975–1049 (handleJob job-scoped, SA-only).
- `sync-jobber-poll/index.ts`: L38 (`createdAt`/`completedAt` cursors), L104–107 (createdAt filter).
- `scripts/sync/reconcile_jobs.js` + `.github/workflows/reconcile-jobs.yml` (every 6h — re-pulls SA job line items; closes the inbound edit gap).
- `jobber-push-visit/index.ts`: L185–239 (syncVisitLineItems), L278 (source gate), L390–400 (60d horizon).
- `docs/migrations/2026-06-27_jobber_push_on_purpose.sql` L185–188 (`line_items_rev` → `lineitems` push group); `2026-07-09_work_orders_disposal_facility_services.sql` L72–74 (`services` fee filter + prefix strip).
