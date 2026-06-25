# Jobber Jobs Migration + Calendar Reformat — master record

*Consolidated 2026-06-25. This folder is the single home for everything about the
2026 **Jobber jobs restructure** (re-shaping every client's Jobber jobs into a clean
**Service Call / Service Agreement** model), the **visit-generation rebuild** that
rides on it, and the **Visit Calendar app** + its **two-way Jobber sync**.*

Read this README first — it is the narrative + index. Each section links to the
detailed doc that owns the full spec, live findings, and verification.

---

## The arc, in order

### 1. Why — the old Jobber jobs were a mess
Every client had an inconsistent pile of Jobber jobs (recurring, one-off, paused, legacy
imports) with no clean mapping to how we actually work. Yannick's directive: collapse all
of it into **exactly two job shapes per client/location**.

### 2. The jobs restructure (the "migration")
**Two job shapes, nothing else:**

| Shape | `jobs.title` | Meaning | Recurs? | Line items |
|---|---|---|---|---|
| **Service Call (SC)** | `= 'Service Call'` | ad-hoc / one-off / emergency | no (`frequency_days` 0/NULL) | none — chosen at visit time |
| **Service Agreement (SA)** | `ILIKE 'Service Agreement%'` | recurring agreement for a location | yes (`frequency_days > 0`) | the agreed services (`line_items`, job scope) |

The run: **archive every existing job** for every client → create **one `Service Call`**
job per client → create **Service Agreement** job(s) from the **Airtable "Itemized" sheet**
(Base `app6TThMjeY1PRTrR`, table *Job Line Items* `tblQkj5SIuabDnuXo`). Old pre-restructure
jobs were renamed with an **`[OLD]`** suffix where kept open.

**Carve-outs (do NOT archive/modify):** `021-GRA` (Granada Condo), `032-LG` (La Granja,
Jobber job 3201), and **The Carrot Express (TCE)** keeps its `Warranty of Drainage` job
(TCE ends with `Warranty of Drainage` **+** `Service Call`).

→ Plans: [`jobber-jobs-restructure-plan.md`](jobber-jobs-restructure-plan.md) (execution working doc)
and [`jobber-jobs-service-call-restructure-PLAN.md`](jobber-jobs-service-call-restructure-PLAN.md)
(research-backed plan + open questions). Permanent model + write-API reference:
[`jobber-jobs-visits-lineitems-reference.md`](jobber-jobs-visits-lineitems-reference.md).

### 3. The visit-generation rebuild
Recurring visits are no longer generated from `service_configs` (bare `GT`/`CL`). They are
generated **from the Jobber SA jobs**, carry **line items**, and are typed **Service
Agreement** (auto) or **Service Call** (manual only). Frequency comes from the SA job's
numeric **Frequency** custom field (unit = days). DERM-required is **derived from the line
items** (ADR 018), not from service type.

**Status: ✅ ACTIVATED 2026-06-24.** Generator `scripts/sync/generate_service_agreement_visits.js`
+ daily cron `.github/workflows/sa-visit-generation.yml` (`0 10 * * *` = 06:00 ET, 6-month
rolling horizon) live for ALL clients. Backfilled **676 SA visits / 143 clients / 164 jobs**,
all pushed + GID-linked to Jobber (0 orphans). Excludes test accounts (`112-YA`, `777-YA`,
`000-DH`, null `client_code`). A capped stale-cleanup sweep keeps both sides in sync as SAs
come and go.

→ Spec: [`service-agreement-visit-generation.md`](service-agreement-visit-generation.md) (§9 = live activation notes).

### 4. The Visit Calendar app + its DB layer
The Lovable **Visit Calendar** (calendar.unclogme.app) is the human control surface over
visits. DB layer: `create_calendar_visit` RPC, the `v_calendar_visit` read view, the
**planned-driver** field (`visits.assigned_driver_id`), **ripple reschedule**, **GDO permit**
serving, and a **residential-class guard**.

→ [`jobs-visits-calendar-workflow.md`](jobs-visits-calendar-workflow.md) (how jobs↔visits↔calendar
fit together) and [`2026-06-24_calendar-db-features.md`](2026-06-24_calendar-db-features.md)
(residential guard, ripple reschedule, GDO permits — designed, reviewed, verified).

### 5. Calendar ↔ Jobber two-way sync
- **Inbound (Jobber → DB):** pg_cron poll Edge Functions (`jobber-poll-sync` */5,
  `jobber-upcoming-visits-sync` */15) → `webhook-jobber.handleVisit`. Re-enabled + live.
- **Outbound (DB → Jobber):** `trg_push_visit_*` triggers → `fn_push_visit_to_jobber` (pg_net)
  → `jobber-push-visit` Edge Function (create / move-date / title / delete / **assigned driver**).
  **Source-gated:** only `visit-calendar` / `supabase_cron` visits push; Jobber-born visits do not.

### 6. Crew consolidation
Driver dropdown deduped from 34 rows to the **6 real crew** (`ops.v_calendar_driver` =
`employees WHERE status='ACTIVE'`). Former drivers kept INACTIVE; 20 junk rows hard-deleted.

→ [`2026-06-24_crew-consolidation.md`](2026-06-24_crew-consolidation.md).

### 7. Latest sync fixes (2026-06-25)
Driver-to-Jobber push fix + the OLD-vs-NEW Service-Call duplicate cleanup + the
delete-propagation gap for Jobber-born visits.

→ [`2026-06-25_calendar-jobber-sync-fixes.md`](2026-06-25_calendar-jobber-sync-fixes.md).

---

## Document index

| Doc | What it owns |
|---|---|
| [`jobber-jobs-restructure-plan.md`](jobber-jobs-restructure-plan.md) | Execution working doc for the jobs restructure (resume-cold continuity) |
| [`jobber-jobs-service-call-restructure-PLAN.md`](jobber-jobs-service-call-restructure-PLAN.md) | Research-backed restructure plan + open questions (TCE carve-out) |
| [`jobber-jobs-visits-lineitems-reference.md`](jobber-jobs-visits-lineitems-reference.md) | Permanent model + Jobber write-API reference + 27-item line-item taxonomy |
| [`service-agreement-visit-generation.md`](service-agreement-visit-generation.md) | SA vs SC visit-generation model + activation (§9) |
| [`jobs-visits-calendar-workflow.md`](jobs-visits-calendar-workflow.md) | Canonical jobs↔visits↔calendar workflow (post-restructure) |
| [`2026-06-24_calendar-db-features.md`](2026-06-24_calendar-db-features.md) | Residential guard, ripple reschedule, GDO permits |
| [`2026-06-24_crew-consolidation.md`](2026-06-24_crew-consolidation.md) | Driver-list dedup → the 6 crew |
| [`2026-06-25_calendar-jobber-sync-fixes.md`](2026-06-25_calendar-jobber-sync-fixes.md) | Driver push fix + delete-propagation gap |
| [`2026-06-25_service-call-line-item-prices.md`](2026-06-25_service-call-line-item-prices.md) | SC line-item prices + push to Jobber (visitCreateLineItems) |
| [`2026-06-25_team-multiselect.md`](2026-06-25_team-multiselect.md) | Driver→Team multi-select (0/1/many), `visit_team` + Jobber assignedUsers |
| [`2026-06-25_drawer-lineitem-and-search-fixes.md`](2026-06-25_drawer-lineitem-and-search-fixes.md) | Drawer pre-checks current services+prices; Jobber push dedupe; drift heal; search null-safety |

**Related, kept elsewhere (referenced, not moved):**
`../jobber-write-oauth-setup.md` (write-app OAuth + token-contamination guard),
`../jobber-poll-setup.md` (inbound poll), `../reference/derm_required_by_line_item.md` +
`../decisions/018-derm-required-from-line-items.md` (DERM-required derivation),
`supabase/functions/jobber-push-visit/` (the outbound push Edge Function).

---

## Current status snapshot (2026-06-25)

- ✅ Jobs restructured into SC / SA shapes (carve-outs honored).
- ✅ SA visit generation + daily cron **live** for all clients; 676 visits backfilled, pushed to Jobber.
- ✅ Calendar app DB layer live (RPC, driver, ripple, GDO, residential guard).
- ✅ Two-way Jobber sync live; outbound push now includes the **whole team** (assignedUsers).
- ✅ Crew deduped to 6.
- ✅ **Driver → Team multi-select** (0/1/many, optional) shipped + live-verified; `visit_team`
  join table, pushed to Jobber assignedUsers. See [`2026-06-25_team-multiselect.md`](2026-06-25_team-multiselect.md).
- ✅ **Calendar deletes of Jobber-born visits now propagate** to Jobber (widened push trigger +
  fail-safe Origin gate so sync/reconcile never echoes). See the sync-fixes doc §Issue A.
- 🟡 **PITR enable** on Prod still gated on the 4 apps finishing (see memory `project_pending_pitr_enable`).
