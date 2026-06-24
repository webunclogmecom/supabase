# Service Agreement vs Service Call — visit generation model

**Source:** Fred, verbal explanation 2026-06-02. **Status:** ✅ **ACTIVATED 2026-06-24** — generator + daily cron live for ALL clients (no longer 112-YA-only).

> **Activation (2026-06-24):** the generator (`scripts/sync/generate_service_agreement_visits.js`) + the daily cron (`.github/workflows/sa-visit-generation.yml`, cron `0 10 * * *` = 06:00 ET) are LIVE. Backfilled **676 SA visits across 143 clients / 164 jobs**, all pushed + GID-linked to Jobber (0 orphans; `ops.v_calendar_push_health` clean; 0 duplicates). **Rolling horizon = 6 months** (`--horizon-months=6`). Pre-activation hardening (commit before backfill): `derm_required` seeded via canonical `fn_line_item_requires_derm` (not crude name match), `service_type` derived from line items (no NULLs → fixes ops views + the rebound-duplicate vector), client-status guard (`ACTIVE`/`RECURRING` only), and `jobber-push-visit` now retries on Jobber `THROTTLED`/429. The old `service_configs`-based generator (`generate-recurring-visits.yml`) is **retired/superseded** by this. **Test / non-serviceable accounts are excluded from generation** (`EXCLUDED_CLIENT_CODES` = `112-YA`, `777-YA` (Yan's test restaurants), `000-DH` (Homestead Dump), plus any null-`client_code` client) — the exclusion applies even to an explicit `--client` run. The 6 cron visits accidentally generated for 112-YA on 2026-06-24 were soft-deleted (and `visitDelete`'d from Jobber).

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

*Created 2026-06-02 per Fred's request to persist this across context limits; §8 added 2026-06-03 from the live 112-YA probe; §9 (agreed design) added 2026-06-03; §10 (drawer redesign) added 2026-06-03. Memory pointer: `project_service_agreement_visit_model.md`.*
