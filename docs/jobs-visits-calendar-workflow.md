# Jobs ↔ Visits ↔ Calendar — the workflow (canonical)

*Last updated 2026-06-23. Covers the Jobber Jobs restructure/migration + how jobs, visits, and
the Calendar App fit together. Companion: [`service-agreement-visit-generation.md`](service-agreement-visit-generation.md),
[`reference/derm_required_by_line_item.md`](reference/derm_required_by_line_item.md). App-side mirror lives in
`Building Apps/Visit Calendar/docs/`.*

## 1. The jobs model (post-restructure)

Every client's work in Jobber (and mirrored in `public.jobs`) is now exactly one of two shapes:

| Type | `jobs.title` | Meaning | Recurs? | Line items |
|------|--------------|---------|---------|------------|
| **Service Call (SC)** | `= 'Service Call'` | ad-hoc / one-off work | no (`frequency_days` 0/NULL) | none — services chosen at visit time |
| **Service Agreement (SA)** | `ILIKE 'Service Agreement%'` | recurring agreement | yes (`frequency_days > 0`) | the agreed services, in `line_items` (job scope) |

- **Archived** jobs (`job_status = 'archived'`) are excluded everywhere.
- Old pre-restructure jobs were renamed with an **`[OLD]`** suffix (kept open only where they
  still hold a pending visit, so the visit survives) — never treated as SC/SA. Filter
  `title NOT ILIKE '%[OLD]%'`.
- **Frequency** = numeric Jobber **custom field "Frequency"** (unit = days), synced to
  `jobs.frequency_days`. `0` = skip (no generation).

## 2. The 2026-06-23 restructure / migration (what happened)

1. **Jobber Jobs restructure** — archived every client's legacy jobs and created a clean
   **Service Call** per client, plus **Service Agreement** jobs (titles + line items + Frequency)
   from the Itemized sheet for recurring clients. Exceptions held: 021-GRA, 032-LG.
2. **Residential cleanup** (174 uncoded clients): the 30 serviced in 2026 got a new Service Call;
   all 174 had their old jobs archived; 2 with pending visits preserved. (`_residential_cleanup.js`
   + `_res_reconcile.js`.)
3. **PDF clients** (couldn't auto-close due to pending visits): old jobs tagged `[OLD]`, new SC/SA
   verified/created, so Diego migrates the pending visits onto the clean jobs. PDF = the migration map.
4. **Job line-item sync** — the SA jobs' agreed services existed only in Jobber (the jobs poll is
   `createdAt`-cursored and does **not** fetch `lineItems`). `scripts/sync/sync_job_line_items.js`
   pulled them into `public.line_items` (job scope) — 162/170 SA jobs, 287 line items.

> **Sync gap — FIXED 2026-06-23 (see [[reference_jobs_sync_gaps]]):** the createdAt-cursored jobs poll
> fetched neither `lineItems`, `customFields`(Frequency), nor status changes/deletions. Now closed:
> (a) `webhook-jobber.handleJob` fetches `lineItems` + `customFields`, maps Frequency→`frequency_days`,
> and syncs job-scoped line items (SA-only, per the rule) — the real-time path; (b)
> `scripts/sync/reconcile_jobs.js` (daily cron `reconcile-jobs.yml`) reconciles every non-archived
> job's status + frequency + line items + detects deletions (Jobber null → archived) — the catch-up.
> `sync_job_line_items.js` is superseded by `reconcile_jobs.js`.

### Line-item rule (Fred 2026-06-23)
**Every Service Agreement job carries line items (its agreed services); no Service Call job carries
line items** (services are chosen per-visit). Enforced by `handleJob` + `reconcile_jobs.js` (wipe
job-scoped line items, re-insert only for SA). Verified: 0 SC jobs have line items. The 7 pre-restructure
SA jobs that lack line items in Jobber (032-LG, 053-PV, 119-ME, 128-MF, 145-NON, Line Barthes, + the
archived Wynd phantom) are edge cases needing Itemized-sheet line items or archival — flagged to Fred.

## 3. Visit ↔ job ↔ service ↔ location

- **A visit belongs to a job** via `visits.job_id`. SA visits recur per `frequency_days`; SC visits
  are manual one-offs.
- **Services = line items** from the canonical `public.service_line_items` taxonomy (codes 01–27):
  SA items **01–08**, SC items **09–24**, fees 25/26, GDO reporting 27.
  - `visits.service_line_item_id` = the primary service; the full set lives in `line_items`
    (visit scope).
  - `visits.service_type` (GT/CL/WD/LS, or NULL) is derived from the primary service.
  - **DERM required** iff any chosen service is a pumping item (`service_line_items.requires_derm`,
    codes 01–04 / 09–11) → `visits.derm_required`.
- **Location grain** — a visit hits one **property** (address) + one or more **`client_locations`**
  (tenant/manhole) via `visit_locations` (M:N). Single-site clients default to `'Main'`.
- **Soft-delete** — always filter `visits.deleted_at IS NULL`.

## 4. The Calendar App = single source of truth for visits

`calendar.unclogme.app` (Lovable `6533c3ee…`) reads/writes Prod `wbasvhvvismukaqdnouk` **through the
`ops` schema** (schema-per-app: apps never query `public` directly).

### DB layer backing the redesigned "Create Visit" form (built 2026-06-23)

| Object | Purpose |
|--------|---------|
| `ops.client_service_options` (view) | per client: each non-archived SC/SA job + `job_kind`, `frequency_days`, `property_id`, and (for SA) its agreed `services` JSON (line_items → service_line_items by the leading `NN -` code, schedulable only). Migration `2026-06-23_client_service_options_view.sql`. |
| `ops.service_line_items` (view) | the 27-item catalog (form reads `reason='Service Call'` for the SC multi-select). |
| `ops.client_locations` (view) | the location picker. |
| `public.create_calendar_visit(...)` (RPC) | **atomic** create: inserts the visit (`source='visit-calendar'`, `visit_status='scheduled'`, derived `service_type` + `derm_required`, job's `property_id`) + visit-scoped `line_items` + `visit_locations` (form choice overrides the auto-seed). SECURITY DEFINER (`line_items` has no anon INSERT). Migration `2026-06-23_create_calendar_visit_rpc.sql`. |
| `ops.create_calendar_visit(...)` (wrapper) | so the app's ops-schema client can call it. Migration `2026-06-23_ops_calendar_form_exposure.sql`. |

### Create Visit flow
client picker → that client's SC/SA cards (SA shows frequency + agreed services; SC = pick from the
SC catalog) → DERM badge if any service is pumping → property/location (default Main) → date/time/
instructions/truck → `rpc('create_calendar_visit')`. Diego uses this (and, near-term, the migration
PDF) to create the pending visits onto the clean SC/SA jobs.

## 5. Calendar → Jobber push (LIVE for all clients — 2026-06-23)

A created/edited/cancelled visit (`source IN ('visit-calendar','supabase_cron')`) fires
`trg_push_visit_insert` / `trg_push_visit_update` → `fn_push_visit_to_jobber` → `jobber-push-visit`
Edge Function. **GO-LIVE 2026-06-23 (Fred): the 112-YA-only gate was removed** — the push now fires
for **all clients** (migration `2026-06-23_widen_jobber_push_all_clients.sql`). Smoke-tested
end-to-end on a real client (026-HAP): create → Jobber visit on the schedule + GID linked → cancel →
Jobber visit removed + ESL unlinked.

**Safe with Jobber inbound ON:** `webhook-jobber.handleVisit` has a loop-guard — when the inbound
poll sees a Jobber visit GID-linked to a `source='visit-calendar'` row it skips the clobber and
preserves the calendar-mastered row (no source-flip, no loop). So Calendar stays the master.

> Still gated: only `source IN ('visit-calendar','supabase_cron')` push — inbound `source='jobber'`
> visits never re-push. Only NEW inserts / qualifying field-changes push; existing rows aren't
> retro-pushed. The SA visit-generation cron (`sa-visit-generation.yml`, `source='supabase_cron'`)
> is still **disabled** — enabling it is the remaining go-live step.

## 6. Status / follow-ups
- ✅ Jobber push gate widened to all clients (go-live 2026-06-23, smoke-tested on 026-HAP).
- ✅ Durable jobs-sync fix: `handleJob` (lineItems + Frequency) + `reconcile_jobs.js` (daily cron `reconcile-jobs.yml`).
- ✅ Wynd 28 phantoms (#10000712 SA / #10000713 SC, deleted in Jobber) archived in DB.
- ✅ `webhook-jobber` deployed (Supabase CLI) with the `handleJob` edit; no CI auto-deploy.
- ✅ Service Calls — every active/recurring client has one (0 missing, re-checked 2026-06-23).
- ✅ Itemized re-check (2026-06-23, fresh from Airtable base `app6TThMjeY1PRTrR` — Clients `tbl5lXLtHKUWilDDj`
  + Job Line Items `tblQkj5SIuabDnuXo`): created the newly-spec'd SA for **147-OST** (#99900937, freq 60).
- ⏳ Enable the SA visit-generation cron (`sa-visit-generation.yml`) — the remaining go-live step.
- 🟡 4 clients have an SA *title* but **no line items in the Itemized sheet** → can't build the SA without
  fabricating; need Fred to add their Job Line Items rows: **213-TRUE, 232-AC** (2 of the 7 pending-visit
  clients), **107-PV, 030-KGC**.
- 🟡 New Airtable rows not in Jobber: **207-CN "Casa Neos BAR"** (Recurring +SA, no Jobber client → needs a
  Jobber client before any job can be created); the 5 Wynd tenants (216–220-WYN) are `client_locations` under
  the single Wynd 28 Jobber client (no separate jobs); `000-` / `095- ZZZ…` / `115-aziz test` = junk/test.
- ℹ️ The 7 pending-visit `[OLD]` jobs are left open until their visits complete (Fred 2026-06-23), then close.
