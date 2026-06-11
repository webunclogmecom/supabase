# Jobber Jobs → "Service Call" Restructure — PLAN (research-backed)

**Status: PLANNING ONLY — nothing executed.** Awaiting Fred/Yannick decisions on the
open questions in §6 before any run. Created 2026-06-09.

**Inputs:** Yannick's instruction (relayed by Fred) + his Airtable base **"list jobs"**
(`app6TThMjeY1PRTrR` / table `tbl5lXLtHKUWilDDj` "Clients", 214 rows) + read-only research
across the Supabase repo and live Prod DB (`wbasvhvvismukaqdnouk`).

---

## 1. The requirement, as stated

> Archive **every** existing Jobber Job for **every** client. Create one Job titled
> **`Service Call`** per client (and each of their Jobber locations). **Exception —
> The Carrot Express (TCE):** keep its existing **`Warranty of Drainage`** Job untouched;
> *only* for TCE keep `Warranty of Drainage` **+** `Service Call`. Every other
> client/location ends with **only `Service Call` active**, all other Jobs archived.

---

## 2. Live scale (Prod, 2026-06-09)

| Metric | Value |
|---|---|
| `public.clients` | 398 |
| `public.jobs` | 1,291 (1,210 active / 81 already archived) |
| `public.properties` | 757 (368 are billing addresses) |
| `public.client_locations` | 407 (only 113 have a `property_id`) |
| Clients with ≥1 active job | 377 (21 have zero active jobs) |
| Active jobs per client | avg **3.21**, max 8; **364 clients have >1 active job** |
| Active jobs on a **service** (non-billing) property | 1,204 / 1,210 |
| Clients with active jobs on **2 distinct properties** | only 7 |
| Existing **active** titles fleet-wide | `Service Call` **340** (+13 casing variants), `Service Agreement` 351, `Warranty of Drainage` 24 |
| Visits pointing at a job | 733 (718 point at a soon-to-be-archived job) |

So "archive all jobs" = **~1,210 manual archives**, and "create Service Call" largely
**recreates titles that already exist** (340 active Service Call jobs today).

---

## 3. The reconciliations that change the plan (read these first)

### 3.1 ⚠️ The Airtable sheet contradicts a "bare Service Call" reading — **CONFIRM INTENT (Q1)**
The sheet (`tbl5lXLtHKUWilDDj` "Clients", **per-location** rows) records each location's
intended job composition as **"Service Agreement…" titles** plus a formal **01–27 line-item
taxonomy** that *explicitly splits* **Service Agreement (01–08)** vs **Service Call (09–27)**.
**No row is currently labeled "Service Call."** So either:
- **(a)** Yannick wants a deliberate pivot: collapse each location to ONE generic
  `Service Call` container job (plausible — visits are now Calendar-app-owned, so the Jobber
  Job is just an anchor, not the recurrence driver), **or**
- **(b)** the sheet's per-location Service-Agreement composition is the real target and
  "Service Call" was shorthand.

These produce very different jobs. **This is the #1 question.**

### 3.2 Archiving is **MANUAL**; creating is scriptable
Jobber's GraphQL exposes **`jobCreate`** (already used in production — we can script the
creates), but **no `jobArchive` mutation exists**. Archiving ~1,210 jobs is therefore a
**manual Jobber-UI sweep** (or possibly `jobClose`, if that's an acceptable substitute — Q5).

### 3.3 Does Jobber even webhook the archive? — **TEST ONE FIRST (Q2)**
There is **no `JOB_ARCHIVE` webhook topic**. An archive *might* surface as a `JOB_UPDATE`
(whose re-queried `jobStatus` = `archived`, which `handleJob` would store), **but the
`*/5` job poll cannot catch it** (it filters on `createdAt` only; Jobber rejects `updatedAt`
filtering on jobs). **If Jobber does not fire `JOB_UPDATE` on archive, our `public.jobs`
status stays stale and `ops.client_jobs` keeps showing the archived jobs as active.** Must be
verified by archiving ONE job and watching `webhook_events_log` before any bulk run.

### 3.4 "Service Call" + "Warranty of Drainage" **largely already exist** → keep, don't mass-create
340 active `Service Call` jobs already exist fleet-wide; **all 23 TCE clients already have
both a `Service Call` and a `Warranty of Drainage` job.** The real operation is closer to
**"keep ONE Service Call per location, archive everything else"** than "create from scratch."
Any create step must **dedup** on the existing Service Call job (and its 3 casing variants)
to avoid duplicates.

### 3.5 TCE is **23 separate clients**, not one
TCE = `client_groups` **group_id=2**, **23** distinct `*-TCE` client records, each its own
Jobber client with its own service property — and **each already has its own
`Warranty of Drainage` job (23 total, one-per-location)**. The caveat must be applied
**per TCE client record**, keyed on the **`-TCE` code suffix / Jobber GID**, NOT a name match.
**Exclude `082-TFC` "The Fresh Carrot of Surfside"** — different brand, no Warranty, not in
the group.

### 3.6 Grain = **per service-property** (recommended)
Jobs link to `client_id` + **`property_id`** (there is **no `client_location_id` on jobs**).
"Per location" ⇒ **one Service Call per (client, non-billing service property)** ≈ **389
service properties / ~394 clients**. Do **not** key off `client_locations` (294/407 have no
property to anchor to) and do **not** create jobs on the 368 billing-only addresses.
**4 clients have no property at all** (2 active: *Express Drain & Sewer Cleaning*, *Pari Pari*)
— they can't get a per-property job until a property exists.

---

## 4. Downstream impact (decide, don't surprise)

| Area | Effect | Severity |
|---|---|---|
| **Recurring visit-generation** | **Already OFF** (no live cron; both generators paused/unscheduled; only the 112-YA test job has a Frequency). So this is a **no-op vs current behavior** — it does NOT break a running pipeline. BUT the *future* SA generator (`generate_service_agreement_visits.js`) keys on title `ILIKE 'Service Agreement%'` + a Frequency custom field; archiving all SA jobs **forecloses that future model** unless it's re-pointed. | Medium — confirm SA model is being retired/re-pointed (Q3) |
| **`derm_required`** | Derived from the **JOB's** line items (`name ILIKE '%pumping%'`). A bare `Service Call` job has no line items ⇒ `derm_required=false`. Conflicts with the DERM-required-by-line-item compliance rule. | Medium — see Q6 |
| **`visits.service_type` / visit line items** | Derived from each **visit's own** Jobber line items, **not** the job ⇒ existing visits **unaffected**. | None |
| **Referential integrity** | Archive ≠ delete; the row persists, so all 4 FKs to `jobs` (visits/invoices/line_items/notes) stay valid. **No orphans.** (A literal DELETE would be blocked by RESTRICT.) | None |
| **`ops.client_jobs` view** | Filters `job_status<>'archived'` + SA/SC titles ⇒ empties of all Service-Agreement categorization once jobs are archived. | Low (cosmetic/view) |
| **Calendar→Jobber push** (`jobber-push-visit`) | `resolveJobGid` auto-targets the single active job when `visit.job_id` is null. Single-Service-Call clients ⇒ cleaner. **TCE (2 active: Warranty + Service Call) ⇒ "ambiguous"** unless `visits.job_id` is set explicitly. | Low–Medium |

---

## 5. Recommended execution shape (WHEN greenlit — not before)

1. **Source of truth for the archive worklist = Jobber/Supabase**, NOT the Airtable sheet
   (the sheet has **no Jobber Job IDs / property IDs** — only 1/214 rows even has a Jobber
   Client ID). The sheet defines *intent per location*; the *job list to archive* comes from
   `public.jobs` + `entity_source_links` (every job has a Jobber GID).
2. **Pre-flight test (§3.3):** archive ONE non-critical job in the Jobber UI, confirm a
   `JOB_UPDATE` lands in `webhook_events_log` and `public.jobs.job_status` flips to `archived`.
   If it does NOT, add a manual full re-pull/reconcile step (the `*/5` poll won't catch it).
3. **Per (client, service property):** ensure **exactly one active `Service Call` job** — keep
   the existing one if present (dedup on title incl. casing variants), else `jobCreate` it via
   the `jobber_write` app. Decide line items / frequency per Q1+Q6.
4. **Archive everything else** for that client/location — **manual UI sweep** (or `jobClose`,
   Q5), keyed on **Jobber GID**, never on title strings.
5. **TCE (23 × `-TCE`, group_id=2):** additionally **keep each location's own
   `Warranty of Drainage`** (whitelist by GID). Exclude `082-TFC`. After: each TCE location =
   `Warranty of Drainage` + `Service Call` (2 active) — note the push-ambiguity in §4.
6. **Verification:** `ops.client_jobs` shows the target end-state; spot-check a TCE + a
   single-location client; decide the `derm_required` handling; confirm no duplicate Service
   Call jobs were created.

---

## 6. Open questions — **RESOLVE BEFORE EXECUTION**

1. **(Yannick) Intent:** bare generic `Service Call` job per location, OR does the sheet's
   per-location Service-Agreement title + line-item composition matter? (§3.1)
2. **(Fred/Yannick + Jobber admin) Webhook test:** does archiving a Jobber Job fire a
   `JOB_UPDATE` so our DB reflects it? (§3.3) — gating for the bulk run.
3. **(Yannick) Visit model:** is the SA-based future recurring generator being **retired**
   (visits fully Calendar-owned) or **re-pointed** off the "Service Agreement" title? (§4)
4. **(Yannick) Grain:** confirm **per non-billing service property** (~389) vs per
   `client_location` vs per client. What about the 4 property-less clients + 14 with only a
   billing address? (§3.6)
5. **(Yannick) Archive mechanism:** acceptable to **`jobClose`** in place of true archive
   (the API has no `jobArchive`), or must it be a manual UI archive? (§3.2)
6. **(Yannick) New job content:** should each `Service Call` job carry line items (from the
   sheet's per-row Line Items) and/or a frequency, or be bare? This decides `derm_required`
   and any future generation. (§4)
7. **(Yannick) Scope of "ALL clients":** include **INACTIVE / PAUSED** clients/locations, or
   only ACTIVE/Recurring? (Airtable has all four statuses.)
8. **(Yannick) TCE confirmation:** keep `Warranty of Drainage` on **all 23 `-TCE`** locations;
   `082-TFC` excluded; confirm whether TCE's *other* current jobs (Grease Trap Pumping,
   Hydrojet Cleaning, Service Agreement, "DO NOT DELETE"/"DO NOT USE" placeholders) are all to
   be archived.

---

## 7. Key evidence (for traceability)

- **Visit-gen:** `generate_service_agreement_visits.js:89-101` (title `ILIKE 'Service Agreement%'`
  + `frequency_days>0`); `service-agreement-visit-generation.md:15,44` (Service Call = manual,
  never auto-gen); pg_cron has **no** visit-gen job; `generate-recurring-visits.yml:19-25` paused
  2026-06-02; only 1 job DB-wide has a Frequency (112-YA #11100534).
- **Job sync:** `webhook-jobber/index.ts:833-890` `handleJob` (`job_status = jobStatus.toLowerCase()`,
  no archive-specific logic); `:1103-1106` topics JOB_CREATE/UPDATE/CLOSED/DESTROY (no ARCHIVE);
  `cron_jobber.js:151-166` jobs cursor = `createdAt` only; 4 FKs to `jobs` with no ON DELETE.
- **API:** Jobber introspection → `jobCreate` true, `jobArchive` **false** (used in prod for creates).
- **Landscape/TCE:** `client_groups` id=2 = 23 `-TCE` clients, each with own active Warranty +
  Service Call; `082-TFC` group_id NULL (different brand); `docs/tce-chain-modeling-decision.md`.
- **Airtable:** base `app6TThMjeY1PRTrR` "list jobs", table `tbl5lXLtHKUWilDDj` "Clients" 214
  per-location rows; fields `Title 1st job`, `Title Job 2`, `Line Items 1st/2nd/3rd job`
  (01–27 taxonomy, 01–08 = Service Agreement, 09–27 = Service Call); **no Jobber Job IDs**
  (1/214 has a Jobber Client ID); no row currently titled "Service Call".
