# Service Agreement vs Service Call — visit generation model

**Source:** Fred, verbal explanation 2026-06-02. **Status:** ✅ **ACTIVATED 2026-06-24** — generator + daily cron live for ALL clients (no longer 112-YA-only). **⚙ MOVED INTO THE DATABASE 2026-08-01** — see the box directly below; the GitHub workflow and the Node script no longer exist.

> ## ⚙ 2026-08-01 — generation now runs IN POSTGRES, not GitHub Actions
>
> `scripts/sync/generate_service_agreement_visits.js` and
> `.github/workflows/sa-visit-generation.yml` are **DELETED**. Everything below that
> describes *what* gets generated is still accurate; only the *where* changed.
>
> | Now | Was |
> |---|---|
> | `public.fn_generate_sa_visits(p_client_id, p_horizon_months, p_dry_run)` | a 288-line Node script |
> | pg_cron `sa-visit-generation`, `0 10 * * *` | GitHub Actions, same cron |
> | pg_cron `sa-visit-promote`, `20 * * * *` | the script's PROMOTE loop |
> | `client.generate_visits_for_client(id)` — per-client, from the Client App | *(did not exist)* |
>
> **Why.** Two sessions measured it independently and agreed: @Supabase found the
> script made **305 sequential Management-API round-trips** per run (152 jobs × 2
> per-job queries + 1) at ~0.5–0.7s each = the whole 150–210s runtime; @Supabase 2
> ran the same logic as one SQL statement — **12.688 ms**, `shared hit=5979`, zero
> I/O. The script was never slow, the transport was. Moving to a Deno edge function
> would have preserved the round-trip design and inherited a wall-clock limit it
> never needed.
>
> **Verified before cutover:** the SQL dry run planned **byte-identical output** to
> the JS dry run — 80 visits, zero differences in either direction, per
> `(job_id, visit_date)`.
>
> ⚠ **But that diff proves almost nothing on its own**, which @Supabase 2 caught:
> live data exercises only anchor branch 1 (149 jobs) and branch 2 (1 job).
> **Branches 3 (`job_start_at`), 4 (`today+freq`) and the not-started guard fire on
> ZERO live jobs** — so a faithful port and a port that deleted those three paths
> would produce identical output. And those are exactly the paths the new Client App
> button runs. They are covered instead by **synthetic fixtures in a rolled-back
> transaction** (in the `2026-08-01_1450` migration), asserting the exact planned
> dates — including that a completed **CL** visit must not anchor a **GT** agreement.
>
> **Three deliberate behaviour changes:**
> 1. **Cleanup runs only on the full sweep** (`p_client_id IS NULL`). It was gated on
>    the `--all` CLI flag, so per-client and full-run semantics already differed *by
>    accident of a flag*. Cleanup soft-deletes future visits, which pushes
>    `visitDelete` to Jobber — the per-client button must never reach it.
> 2. **The function returns a structured result** (generated / skipped / per-job skip
>    reason), not void. The not-started guard means "new client, fresh SA job, press
>    Generate" legitimately produces nothing, and a button that silently does nothing
>    is a bug report.
> 3. **PROMOTE is its own cron.** It re-pushes visits that rolled into Jobber's
>    60-day window as days pass — a fact about the passage of time, not about
>    generation, and it must run on days when nothing is generated. Removing it also
>    took the last HTTP call out of the generation path, which is what lets
>    generation be **one transaction** — so its `sync_log` row cannot report success
>    for work that rolled back.
>
> **`sync_log.sync_source = 'sa-visit-generation'`** now exists. Before this, SA
> generation appeared in neither `sync_log` nor `cron.job`, so anyone auditing
> pg_cron would have concluded it was dead.
>
> 🛑 **Generation is INSERT-only and must stay that way.** Re-spacing visits after a
> frequency change is a separate, *destructive* concern (it moves visits already
> pushed to Jobber, possibly already on a driver's route). Folding it in would let
> the per-client button silently reschedule booked work.
>
> ### 🛑 And before anyone builds re-spacing: `frequency_days` is JOBBER-MASTERED
>
> The cadence lives in a Jobber **numeric custom field labelled `Frequency`**
> (config `…/3743514`). Both `webhook-jobber` and `sync-jobber-job-drift` read it, so
> **a DB-only write to `jobs.frequency_days` is reverted within 30 minutes.**
> Measured on job 1593 (191-TEN), from `audit.logs`:
>
> ```
> 12:16:07  app_source=sql      20 -> 21    (raw SQL write)
> 12:45:10  app_source=jobber   21 -> 20    <- reverted 29 minutes later
> ```
>
> Over 30 days: `client-app` 18 frequency writes, `sql` 2, `jobber` **1** — and that
> one jobber write *is* the revert. It is the only one because it is the only time
> anyone wrote the DB without also writing Jobber.
>
> ⚠ **The revert is invisible**: no error, no `sync_log` row, and `audit.logs` shows
> it as an ordinary `app_source='jobber'` write.
>
> `fn_generate_sa_visits` reads `jobs.frequency_days`, so a cadence change that never
> reaches Jobber will appear to work, generate once against the new value, and then
> silently revert. **Any re-spacing feature must write Jobber** — via
> `save-client-job` (which already sets that config GID, which is why the Client
> App's 18 writes were never reverted) or a direct `jobEdit`.
>
> ⚠ **191-TEN is NOT a usable re-spacing test case** — it was re-spaced by hand on
> 2026-07-31 (29 `ripple_reschedule_visit` calls from the Visit Calendar) and every
> future gap is now exactly 21 days. Pick another from the at-horizon set.

> **Activation (2026-06-24):** the generator (`scripts/sync/generate_service_agreement_visits.js`) + the daily cron (`.github/workflows/sa-visit-generation.yml`, cron `0 10 * * *` = 06:00 ET) are LIVE. Backfilled **676 SA visits across 143 clients / 164 jobs**, all pushed + GID-linked to Jobber (0 orphans; `ops.v_calendar_push_health` clean; 0 duplicates). **Rolling horizon = 6 months** (`--horizon-months=6`). Pre-activation hardening (commit before backfill): `derm_required` seeded via canonical `fn_line_item_requires_derm` (not crude name match), `service_type` derived from line items (no NULLs → fixes ops views + the rebound-duplicate vector), client-status guard (`ACTIVE`/`RECURRING` only), and `jobber-push-visit` now retries on Jobber `THROTTLED`/429. The old `service_configs`-based generator (`generate-recurring-visits.yml`) is **retired/superseded** by this. **Test / non-serviceable accounts are excluded from generation** (`EXCLUDED_CLIENT_CODES` = `112-YA`, `777-YA` (Yan's test restaurants), `000-DH` (Homestead Dump), plus any null-`client_code` client) — the exclusion applies even to an explicit `--client` run. The 6 cron visits accidentally generated for 112-YA on 2026-06-24 were soft-deleted (and `visitDelete`'d from Jobber). **Stale-cleanup sweep (2026-06-24):** on each `--all` run the generator also soft-deletes any future `supabase_cron` visit whose SA job no longer qualifies (archived/deleted, Frequency removed, retitled/[OLD]-tagged, or client set inactive) — which pushes a `visitDelete` to Jobber, keeping both sides in sync as SAs come and go. Generation + cleanup share ONE `JOB_PREDICATE` so they can't drift; the sweep is capped at `MAX_CLEANUP=40` (aborts + alerts above that, to avoid a mass-delete from a bulk data error).

This is the NEW model for how recurring visits are generated and what data they carry. It **replaces** the old generator that produced bare `GT`/`CL` visits from `service_configs.frequency_days`. From now on, visits are generated from **Jobber jobs** and carry **line items**.

---

## 1. Two job/visit types

Every visit is one of two types (this replaces the old `GT`/`CL`/`WD`/`LS` `service_type`):

| Type | What it is | Created how | Line items allowed |
|---|---|---|---|
| **Service Call** | Client calls us to come out (ad-hoc / one-off / emergency). | **MANUALLY only** — we never auto-generate these. | only **Service-Call** line items |
| **Service Agreement** | A recurring agreement with the client for a specific location. | **Auto-generated** from the job's frequency. | only **Service-Agreement** line items |

**Hard rule:** A Service Agreement can carry ONLY service-agreement line items; a Service Call can carry ONLY service-call line items. (Plus the few shared/standalone items — see below.)

---

## 2. The 27 line items (the service taxonomy)

The 27 line items (the taxonomy from the Calendar form + Fred's Google Sheet) are categorized:

- **~16** are **Service-Call** line items.
- **8** (the FIRST 8 of the 27) are **Service-Agreement** line items.
- **A few standalone/shared** (e.g. **GTO / GDO online reporting**, around items #25–27) can appear in **either** a Service Call OR a Service Agreement — they're just add-on line items.

> Canonical list + the per-item Service-Call vs Service-Agreement vs shared categorization lives in Fred's Google Sheet (the same 27-item sheet referenced in `reference_derm_required_by_line_item.md`). **TODO: capture the exact categorization (which of the 27 are SA vs SC vs shared) into a reference table here / in the DB.**

---

## 3. Jobs in Jobber are the source of truth for generation

Going forward, **Jobber jobs drive visit generation** (not `service_configs`):

- Fred creates **specific jobs per client**, named starting with **"Service Agreement …"** or **"Service Call …"**.
- **Only ACTIVE jobs matter.** Every other (old/generic) job is being **ARCHIVED**. **Archived jobs are ignored entirely** — not useful to us.
- Each active job carries:
  - a **FREQUENCY** (e.g. every 60 days), and
  - its **product/service LINE ITEMS** (the line items on the job).

**Generation:** for each active **Service Agreement** job → read its frequency + line items → generate a visit every `frequency` days, each visit carrying the job's line items. **Service Call** jobs are NOT auto-generated (manual only).

---

## 4. Worked example — 112-YA (Yan's Restaurant, Fred's "Jan's")

- Job: **"Service Agreement Pumping"**
- Frequency: **60 days** → generate a visit every 60 days.
- Line items (3, all Service-Agreement-category except the shared reporting one):
  1. Service Agreement Pumping — Grease Trap
  2. Service Agreement Cleaning — Mainline Cleaning
  3. GTO online reporting  *(the shared standalone item)*

So the generated visits for 112-YA are **Service Agreement (Pumping)** visits, every 60 days, each showing those 3 line items in the Calendar.

> **TEST WITH 112-YA ONLY.** No other client has this set up yet. Do NOT generate for any other client until Fred sets them up. Be careful.

---

## 5. Calendar app changes

- **Visit type label** is no longer `GT`/`CL` — it is **"Service Agreement [Pumping/…]"** or **"Service Call"**.
- The **visit drawer** (right-side panel that opens when you click a visit) must show:
  - the **line items** (from the job),
  - the **Jobber Job ID** — rendered as a **clickable link** that opens the job in Jobber in a **new tab**,
  - the **frequency**,
  - the **scheduled date / time**,
  - **a link to the specific scheduled visit in Jobber** (the visit, or the client's visits/schedule) — placed near the bottom.

---

## 6. Jobber URL research (TODO — be thorough)

Need the canonical Jobber web-URL patterns for the drawer links:
- **Job URL** — open a job by id (known base: `https://secure.getjobber.com/clients/<clientId>`; jobs likely `…/jobs/<jobId>` or `…/work_orders/<id>` — VERIFY).
- **Visit URL** — open a specific scheduled visit, or fall back to the client's visits/schedule view.
- Jobber GraphQL exposes the GIDs (base64 `gid://Jobber/Job/<n>`, `gid://Jobber/Visit/<n>`); the numeric id decodes from the GID and maps to the secure.getjobber.com web URL.

---

## 7. Open implementation questions (to design with Fred / decide)

- **Data model:** how to store line items per visit (a `visit_line_items` table referencing the 27-item catalog?), the SA/SC type, the Jobber job link (frequency, job GID) — all 3NF, referenced not copied.
- **Generator rewrite:** read active Jobber Service-Agreement jobs (status + frequency + line items) → generate visits with line items. Where does the frequency live on the Jobber job (recurrence schedule field)?
- **service_type migration:** how `visits.service_type` (GT/CL/…) maps to the new SA/SC + line-item model.
- The generator (`generate-recurring-visits.yml`) is currently **PAUSED** (2026-06-02) — it will be re-enabled once this is built.

---

## 8. Confirmed Jobber technical details (2026-06-03 probe — 112-YA)

Probed live via the read OAuth app (`scripts/probes/probe_112ya_service_agreement*.js`, artifacts in `docs/audits/2026-06-03/`).

### 8.1 Where the frequency lives (CONFIRMED — a Job custom field)
**The NEW model's frequency is a numeric Job CUSTOM FIELD — NOT Jobber's native recurrence.** Fred adds two numeric custom fields to each Service Agreement / Service Call job:
- **`Frequency`** (unit `days`) — the generation interval. 112-YA #11100534 = **60**. `Frequency = 0` → no auto-generation (e.g. the Service Call job, which is 0).
- `GT size` (unit `Gallon`) — grease-trap size metadata (0 = unset on 112-YA).

Read via `job.customFields` → a `CustomFieldUnion` list; the frequency entry is `... on CustomFieldNumeric { id label unit valueNumeric }` where `label = "Frequency"`. **It's a simple integer-day interval — NO RRULE expansion needed** (just add `valueNumeric` days each cycle). A `Frequency` of 0 (or missing) ⇒ skip generation.

> The OLD jobs instead used Jobber's native recurrence (`job.visitSchedule.recurrenceSchedule.calendarRule`, an iCalendar RRULE e.g. `FREQ=DAILY;INTERVAL=60` / `FREQ=MONTHLY;BYDAY=1MO`). The new SA/SC model does **not** use `recurrenceSchedule` — read the `Frequency` custom field. (Custom-field union member types available: CustomFieldNumeric / Text / Dropdown / TrueFalse / Area / Link — each with `label` + a typed `value*` field.)

GraphQL version header `X-JOBBER-GRAPHQL-VERSION: 2026-04-16`. `Job` also exposes `jobType` (RECURRING/ONE_OFF) and `jobStatus` (`action_required`, `archived`, …).

### 8.2 Job selection logic (CONFIRMED)
Active Service-Agreement job = **`jobType = RECURRING` AND `jobStatus != 'archived'` AND `title` starts with "Service Agreement"**. The **title prefix is the real discriminator** (status alone is not — old leftover jobs are also `action_required`). "Service Call …" jobs are skipped (manual). Worked for 112-YA: selects only #11100534 (SA) + #99900535 (SC, skipped); correctly excludes the archived "Service Agreement" #10000363 and the mis-named "Grease Trap Service Agreement" #10000178.

### 8.3 Deep-link URLs (CONFIRMED)
`Job` and `Client` expose **`jobberWebUri`** (NON_NULL String, "URI for the record in Jobber Online"):
- Job: `https://secure.getjobber.com/work_orders/<numericJobId>` (e.g. `…/work_orders/146650142`; numericJobId = decoded GID `gid://Jobber/Job/146650142`).
- Client: `https://secure.getjobber.com/clients/<numericClientId>` (e.g. `…/clients/106567404`).
- **`Visit` has NO `jobberWebUri`** (`undefinedField` error). And our generated visits don't exist in Jobber until the office mirrors them, so there is no per-visit Jobber URL to link to initially. **Drawer "open in Jobber" should use the JOB's `work_orders` URL** (it shows the job's schedule/visits). A true per-visit link only becomes possible after a visit is pushed to Jobber and gets its own Visit GID.
- Store the job's `jobberWebUri` (or the numeric job id) when generating, so the drawer link needs no live Jobber call.

### 8.4 112-YA actual state (as of 2026-06-03) — READY (frequency = Job custom field)
| Job # | type/status | title | recurrence | line items / visits |
|---|---|---|---|---|
| **#11100534** | RECURRING / action_required | **"Service Agreement - Pumping"** | **`Frequency` custom field = 60 days** (native recurrence null) | `01 - Service Agreement - Pumping - Grease Trap` · `05 - Service Agreement - Cleaning - Main Line Cleaning` · `27 - GDO Online Reporting`; **0 visits** |
| #99900535 | RECURRING / action_required | "Service Call" | — | no line items (manual — skip) |
| #10000152 | RECURRING / action_required | "GT & CLeaning" (old) | **"Every 60 days"** `FREQ=DAILY;INTERVAL=60` | "Grease Trap Pumping"; 0 visits |
| #10000178 | RECURRING / action_required | "Grease Trap Service Agreement" (old) | "Monthly on the 1st Monday" `FREQ=MONTHLY;BYDAY=1MO` | GT Pumping + Warranty + Unclogging; **2 visits, last 2026-06-01** |
| #10000363 | RECURRING / **archived** | "Service Agreement" (old) | — | ignore (archived) |
| #10000344 | RECURRING / archived | "1 Year service" | — | ignore |
| #10000065 | ONE_OFF / action_required | "Cath Bassin cleaning" | — | ignore (one-off) |

- **The new SA job #11100534 is READY:** correct name + line items + **`Frequency` custom field = 60 days** (`GT size` = 0). Its native `recurrenceSchedule` is null — the generator ignores that and reads the `Frequency` custom field. (The old job #10000152 separately carries a native "Every 60 days" recurrence, which the new model does not use.)
- **Line items are taxonomy-numbered** (`01 - …`, `05 - …`, `27 - …`) → the leading number maps directly to the 27-item catalog (SA = 01–08, shared #27 = GDO Online Reporting). DERM-required when a "Pumping" item is present (here `01 … Grease Trap`).
- Old recurring jobs are still `action_required` (not yet archived) and #10000178 still owns 112-YA's real recent visit (2026-06-01). Fred's cleanup (archive the old ones, configure the new ones) is **in progress, not complete**.

---

## 9. Agreed design (2026-06-03, Fred approved) — Calendar app = source of truth

**Pipeline:** **FETCH** (Jobber → DB) → **GENERATE** (DB → visits, our cron) → **PUSH** (visits → Jobber, later).

1. **Jobber = config store.** Each agreement is a **non-recurring** Jobber job titled "Service Agreement …" carrying its **line items** (the services) + a numeric **"Frequency" custom field** (days). Jobber's native recurrence stays **off** (so Jobber does not auto-generate visits). Service Call jobs = manual, never generated.
2. **FETCH (Jobber → DB):** a sync (`scripts/sync/fetch_service_agreement_jobs.js`) pulls each active "Service Agreement" job's Frequency (custom field) + line items + metadata into **our DB** — the generator reads config from our DB, not live from Jobber. Writes `jobs.frequency_days` + `line_items` (by `job_id`). Idempotent. **112-YA scoped** for now.
3. **GENERATE (DB → visits):** the cron generator (rewrite of `cron_generate_recurring_visits.js`) reads jobs from the DB where the title marks a service agreement **and** `frequency_days > 0`, and creates a visit every `frequency_days` days from the anchor through the horizon. `visit_status='scheduled'`, `source='supabase_cron'`, `title=` job title, `job_id=` the job, `derm_required=true` if any line item is a Pumping item. Idempotent (±window). Calendar app **owns** these visits (Jobber visit-inbound stays off).
4. **PUSH (visits → Jobber):** generated visits later mirrored back via the existing `jobber-push-visit` path (deferred; manual interim).

**Schema:** add `jobs.frequency_days INTEGER` (Jobber sync-only → audit opt-out per ADR 010). `service_kind` (service_agreement / service_call) and the `…/work_orders/<id>` job link are **derived in a view** (3NF — not stored). Line items referenced via `line_items.job_id` (backfilled by the fetch).

**Resolved choices:** (1) add `jobs.frequency_days` — yes. (2) Anchor = last completed service + frequency, else today. (3) Horizon = ~12 months, rolling. (4) Scope = **112-YA only**; build → test → fix errors iteratively until clean (Fred: "we'll most likely make changes").

**Jobber cleanup (Fred, manual):** turn native recurrence **off** on #11100534 to stop its 53 auto-generated visits.

---

## 10. Visit drawer — semantic redesign (2026-06-03, Fred approved)

The old SERVICE box was GT/CL-model-centric (`Service type: GT`, `GT size`, a `service_configs` frequency) — vestigial under the SA/SC model, where the **badge** is the kind and the **line items** are the work. Reframed. The drawer reads `ops.v_calendar_visit_detail`. SERVICE-section rows, in order:

- **Type** — a colored chip: **`SA`** (green) when `service_kind='service_agreement'`, **`SC`** (blue) when `service_call`. Replaces the old "Service type: GT" row. (Header keeps the full "Service Agreement"/"Service Call" badge.)
- **Job #** — `jobber_job_number` (the Jobber job number, e.g. 11100534) rendered as a **link** opening `jobber_job_url` in a new tab.
- **Frequency** — `Every N days` (`agreement_frequency_days`) for SA; **"On request"** for SC.
- **DERM** — **"Required"** (amber) when `derm_required` is true, else "Not required" (gray). *NEW — compliance flag, driven by Pumping line items.*
- **Hours** — access/service window (unchanged).
- **Amount** — unchanged.
- ~~GT size~~ — **removed** (GT-model-specific + unset).

The **SERVICES** line-items list, the header badge, and the bottom "Open job in Jobber" button are unchanged. View change: add `jobber_job_number` (= `jobs.job_number`).

---

## 11. Creating a new Service Agreement via the Jobber API (2026-07-01)

Diego's 4 new SAs (243-FE, 244-URI, 241-WYN, 242-WYN) were the first created **programmatically via the Jobber write API** — previously all SA jobs were made by hand in the Jobber console. `scripts/sync/jobber_create_canonical_jobs.js` only creates **bare container** jobs (title + property + invoicing, no line items / Frequency), so the full setup used a one-off `jobCreate` carrying everything:

```
mutation($input: JobCreateAttributes!){ jobCreate(input:$input){ job{ id jobNumber jobType } userErrors{ message path } } }
input = {
  propertyId: <real Jobber Property GID>,        // NOT the client GID; 3 of 4 clients had no synced property → read live from client.properties
  title: "Service Agreement - Grease Trap Pumping & Tank Cleaning",   // MUST start with "Service Agreement"
  invoicing: { invoicingType: VISIT_BASED, invoicingSchedule: PER_VISIT },
  lineItems: [{ name: "01 - Service Agreement - Pumping - Grease Trap & Tank Cleaning", unitPrice: <price>, quantity: 1, saveToProductsAndServices: false }],  // free-text line item, no product id
  customFields: [{ customFieldConfigurationId: "Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvbk51bWVyaWMvMzc0MzUxNA==", valueNumeric: <freq> }]   // "Frequency" (days), config 3743514
}
```

- `jobCreate` returns **jobType RECURRING automatically** (no `scheduling` needed) with **0 auto-visits** — exactly what the generator wants (the reference SA jobs are also RECURRING with a null native recurrence).
- The line item is a **free-text** row (`name` starts `01 - …`), quantity 1, `unitPrice`; no `productOrServiceId` needed. `saveToProductsAndServices: false`.
- After create, the JOBS poll syncs the job + `line_items` + `frequency_days` into the DB (~5 min); then `generate_service_agreement_visits.js --client=<code> --execute` builds the series and pushes in-horizon visits.
- **Anchor caveat:** the generator anchors at (last-completed-of-same-type + freq) or (today + freq), NOT the requested first-service date. To honor a specific first date, `ripple_reschedule_visit(<first_visit_id>, <target_date>)` shifts the whole series by the delta.
- `fetch_service_agreement_jobs.js` couldn't see these via its anon-REST job-link map (PostgREST's 1000-row default drops the newest `entity_source_links`) — moot here, since the poll had already set `frequency_days` + `line_items`.
- Jobs created 2026-07-01: #99900973 (244-URI $420/30d), #99900974 (243-FE $1/60d), #99900975 (241-WYN $2320/30d), #99900976 (242-WYN $2320/30d). First visits set to Jul 2 / Jul 1 / Jul 1 / Jul 22.

---

*Created 2026-06-02 per Fred's request to persist this across context limits; §8 added 2026-06-03 from the live 112-YA probe; §9 (agreed design) added 2026-06-03; §10 (drawer redesign) added 2026-06-03; §11 (API creation) added 2026-07-01. Memory pointer: `project_service_agreement_visit_model.md`.*
