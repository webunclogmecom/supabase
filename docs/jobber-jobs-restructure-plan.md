# Jobber Jobs Restructure — Execution Plan (working doc)

*Created 2026-06-22 · Status: planning complete, one-client test in progress*
*Continuity note: this doc exists so the build can resume cold after a token-limit/compaction. Read it fully before acting.*

## Goal
Rebuild every client's Jobber jobs cleanly. Three actions:
1. **Archive ALL existing Jobber jobs** for **every** client (any status: active/paused/recurring/etc.) **EXCEPT the exceptions below**.
2. Create **one "Service Call" job per client** (EVERY client) — **one-off**, **no line items**, **no Frequency**, **no schedule** (manual; client calls → unscheduled visit). Title literally `Service Call`.
3. For clients present in the **Airtable Itemized sheet** only, create their **Service Agreement job(s)** (1 or 2 per client) from the sheet data.

## Exceptions — DO NOT archive or modify
- **021-GRA** (Granada Condo) — Itemized `notes`: "@fred do not update this job it is fine on jobber".
- **032-LG** (La Granja 36 street) — Itemized `notes`: "@fred do not update this job (3201) it is fine on jobber bc we go a few times a month and we invoice him only once a month". Existing Jobber job # = **3201** (use as a structural reference example).

## Source of truth — Airtable Itemized sheet
Base `app6TThMjeY1PRTrR`, table **Job Line Items** `tblQkj5SIuabDnuXo`. One row = one line item on one job. Group by **Client + Job #**.
Field IDs:
- Client = `fld9cDOTqZ2YTneTV` (formula "NNN-XX Name")
- Job # = `fldP9aDmcYR0LVjXF` (formula "Job #1" / "Job #2")
- Line Item = `fldCooAqmsts7jGt7` (singleSelect; the "NN - …" string IS the Jobber line-item Name)
- Price = `fldafF07VSuw8ydjv` (currency → Unit Price)
- Job Frequency = `fldkltOBaQTerLxgT` (number → the "Frequency" custom field, in days)
- notes = `fldThTgxmduHRxjBM` (→ line-item Description)
- Title 1st job = `fldOE78PzwtivTxL2` (lookup) / Title Job 2 = `fldu0RfKIxyqWpYuH` (lookup) → the job Title
Main/Clients sheet `tbl5lXLtHKUWilDDj`: **Jobber Client ID** = `fldFHYqlb9XjbyA4x` (EMPTY on ~213/214 → must resolve the Jobber client by NNN-XX code / name via the Jobber API, not this field).

## Grouping (verified 2026-06-22)
- 143 clients have SA jobs → **163 SA jobs** (123 one-job clients, 20 two-job, 287 line items).
- All 163 job **titles are reconciled** with their line items (title audit passed 163/163 on 2026-06-22).

## Job spec (confirmed via 001-VIN Jobber screenshots)
**Service Agreement job:**
- Job type = **Recurring**
- Title = the Job Title (e.g. "Service Agreement - Grease Trap Pumping, Tank Cleaning & Warranty of Drainage")
- Custom field **Frequency** (number, days) = Job Frequency
- Repeats = **"As needed - we won't prompt you"** (no auto-scheduled visits — our system owns visits)
- Schedule: Ends after **2 Years**
- Billing type = **Visit based**; Invoice frequency = **"After each visit is completed"**
- Line items: per row → Name = Line Item label, **Quantity 1**, Unit Price = Price, Description = notes, **Non-taxable**
- (A "GT size" custom field also exists on the job template; leave 0 unless populated)

**Service Call job:** Job type = **One-off**, Title = `Service Call`, no line items, no Frequency, no schedule.

## Line-item taxonomy (01–27) — for reference
01 GT Pump+Tank · 02 GT Pump+Tank+Warranty · 03 Grey Water · 04 Lift Station+Tank · 05 Main Line Cleaning · 06 Aux Cleaning · 07 Tank Cleaning · 08 Warranty of Drainage · 09–24 one-off Service Calls · 25 CC fee 3.53% · 26 ACH fee 1% · 27 GDO Online Reporting.
Fees (25/26) and GDO (27) **ARE included as line items** on the SA job when present in the sheet (per Fred 2026-06-22; see 001-VIN = 02 $425 + 25 $15 = $440).

## Jobber API (DISCOVERED 2026-06-22 — all verified live)
- Helper: `scripts/sync/lib/jobber.js` `gql()` uses the **READ app token** from `.env` (`JOBBER_ACCESS_TOKEN`, app `fbd14714…`), auto-refreshes on 401. **This token HAS `write_jobs` + `write_clients` + `write_custom_field_configurations`** — so use it directly for job creation (broadest scopes). (Write app `jobber_write` `2600594d…` also has `write_jobs`/`write_scheduled_items` but fewer scopes.) Tokens in DB `webhook_tokens` (one row per app); invariant: row's JWT `app_id` == its `client_id`.
- **`jobCreate(input: JobCreateAttributes)` EXISTS.** Key input fields: `propertyId!` (the client's PROPERTY GID, not clientId), `title`, `timeframe`{startAt, durationUnits(DurationUnit), durationValue}, `scheduling`{createVisits!, notifyTeam!, recurrence(ICalendarRule), startTime, endTime}, `invoicing!`{invoicingType(BillingStrategy!), invoicingSchedule(BillingFrequencyEnum!), recurrence}, `lineItems`[JobCreateLineItemAttributes], `customFields`[CustomFieldCreateInput].
  - `JobCreateLineItemAttributes`: name!, unitPrice!, quantity!, description, taxable, saveToProductsAndServices!, (totalPrice, sortOrder).
  - `CustomFieldCreateInput`: customFieldConfigurationId + valueNumeric (for Frequency/GT size).
  - Enums: BillingStrategy = FIXED_PRICE | **VISIT_BASED**; BillingFrequencyEnum = ON_COMPLETION | PERIODIC | **PER_VISIT** | NEVER.
- **"As needed - we won't prompt you" recurring = jobType RECURRING with `recurrenceSchedule: null`** + a visit window (start + 2 years). Reference job **3201** (032-LG): jobType RECURRING, billingType VISIT_BASED, visitSchedule start 2025-03-12 / end 2027-03-12, recurrenceSchedule **null**. (3201's invoice billingFrequency=PERIODIC monthly is 032-LG's SPECIAL case; standard per 001-VIN = VISIT_BASED + PER_VISIT "after each visit".)
- **NO `jobArchive` mutation.** Job mutations: jobCreate, jobEdit, jobClose(jobId, input:{modifyIncompleteVisitsBy}), jobReopen, jobCreate/Edit/DeleteLineItems, jobCreate/Edit/DeleteNote, jobClose. Archive (client/request/customFieldConfig) exists but **not for jobs**, and **no jobDelete**. ⇒ "Archive all existing jobs" canNOT be done via API. Options: (a) `jobClose` each old job via API (marks Closed, stops visits — but shows "Closed" not "Archived"); (b) manual/UI archive (Jobber bulk). DECISION PENDING from Fred.
- Custom-field config GIDs: **Frequency** (ALL_JOBS, days) = `Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvbk51bWVyaWMvMzc0MzUxNA==`; **GT size** (ALL_JOBS, Gallon) = `Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvbk51bWVyaWMvMzA3MDM0MQ==`.
- Resolve client by code/name: `clients(first, searchTerm)` → node{ id, companyName, properties[ {id} ] (NOTE: `properties` is a plain list, not a connection — no `nodes`), jobs(first){nodes{id jobNumber title jobStatus jobType billingType}} }. Read one job: `job(id:)`.
- **031-KRU (test client):** client GID `Z2lkOi8vSm9iYmVyL0NsaWVudC85NjE0NTkzOA==`, property GID `Z2lkOi8vSm9iYmVyL1Byb3BlcnR5LzEwMzIzNTk2OQ==`, 8 existing recurring jobs.

## Test plan (one client, 2 jobs) — IN PROGRESS
Pick a 2-job client (candidate **031-KRU**, the worked example). Steps: read its current Jobber jobs → archive them → create `Service Call` (one-off) → create its 2 SA jobs from the sheet → **verify in the Jobber UI via Chrome** (secure.getjobber.com) AND via API. Revert (unarchive/delete) if the test is rejected.

## Full rollout order (after test approved)
1. Group Itemized → SA specs; pull full Clients list (Service Call = all clients).
2. Resolve each client's Jobber client GID.
3. Per non-exception client: archive existing active jobs; create `Service Call`.
4. Per Itemized client: create SA job(s).
5. Verify counts + spot-check UI. Hard-deleting a pushed job orphans things → prefer archive.

## TEST RESULT (031-KRU, 2026-06-22) — jobCreate WORKS + UI-VERIFIED
Created via `jobCreate` (read-app token, write_jobs scope), all verified by **API readback AND the live Jobber UI in Chrome** (`secure.getjobber.com/clients/96145938`, browser confirmed Chrome not Brave via `navigator.brave===undefined` / brands `["Google Chrome",...]`). Jobs render at the top of the client's Jobs list with correct titles + amounts: #99900557 = **$900.00** (04 $450 + 02 $450), #99900558 = **$540.00** (06), #99900559 Service Call = **$0.00**, all "Action Required" (no scheduled visits — as designed). The client's **8 OLD jobs still appear alongside** (archiving not yet done — API limit #2).
- **#99900557** "Service Agreement - Grease Trap & Lift Station Pumping & Tank Cleaning" — RECURRING, VISIT_BASED/PER_VISIT, Frequency=30, line items 04 $450 + 02 $450. gid `…MTQ4NzIyOTM0`.
- **#99900558** "Service Agreement - Auxiliary Line Cleaning" — RECURRING, VISIT_BASED/PER_VISIT, Frequency=21, line 06 $540. gid `…MTQ4NzIyOTM2`.
- **#99900559** "Service Call" — RECURRING as-needed, VISIT_BASED/PER_VISIT, no line items, no Frequency. gid `…MTQ4NzIyOTM4`.
Exact create payload that works (per SA job): `{ propertyId, title, timeframe:{startAt, durationUnits:"YEARS", durationValue:2}, scheduling:{createVisits:false, notifyTeam:false}, invoicing:{invoicingType:"VISIT_BASED", invoicingSchedule:"PER_VISIT"}, lineItems:[{name, quantity:1, unitPrice, taxable:false, saveToProductsAndServices:false}], customFields:[{customFieldConfigurationId:FREQ, valueNumeric:freq}] }`. Service Call = same minus timeframe/lineItems/customFields.

### Two API limits — RESOLVED by Fred 2026-06-22
1. **No ONE_OFF via API** — `jobCreate` always yields RECURRING. **DECISION: accept recurring-as-needed via API** (matches the account's existing Service Call jobs). No manual UI needed.
2. **Archiving = `jobClose` via API.** **DECISION (Fred):** close old jobs with `jobClose`. **A closed job AUTO-ARCHIVES once it has no active invoice reminders** (confirmed live — all 7 returned `jobStatus:"archived"` immediately). If a close fails due to active invoice reminders → resolve those first, then archive from the job's Actions menu (UI). **If a job has incomplete (non-COMPLETED) visits → DO NOT force-close (the only enum options destroy them); instead list the client + visits for Fred.**

### jobClose mechanics (verified live)
- `jobClose(jobId: EncodedId!, input: { modifyIncompleteVisitsBy: IncompleteVisitDecisionEnum! })` → `{ job{ jobNumber jobStatus } userErrors{ message } }`.
- `IncompleteVisitDecisionEnum` has only **2** values, BOTH destructive to incomplete visits: `DESTROY_ALL`, `COMPLETE_PAST_DESTROY_FUTURE`. The param is **required**.
- **Safe-close rule:** only auto-close jobs whose visits are ALL `COMPLETED` (or zero visits). Completed visits are untouched by either enum (no-op), so history is preserved and `jobStatus` returns `archived`. Reversible via `jobReopen(jobId)`.
- **Skip rule:** any job with a visit whose `visitStatus != 'COMPLETED'` (UPCOMING/etc.) → skip + report (closing would destroy that visit).
- **Throttling:** Jobber rejects a single query whose ESTIMATED cost exceeds the 10000 max bucket (e.g. `client.jobs(first:50){visits(first:60)}` = un-runnable, "available=10000, waiting" then THROTTLED). Read jobs WITHOUT large nested visit lists, or page small; close by known GID with a ~2s delay between mutations.

### ARCHIVE TEST RESULT (031-KRU, 2026-06-22) — jobClose WORKS + UI-VERIFIED
Closed **7 old jobs** (all had only COMPLETED visits) → all returned `jobStatus:"archived"`, zero userErrors: #3102, #10000413, #99900543, #10000412, #21, #10000145, #10000051.
**Skipped 1 old job — #10000350 "Service"** — it has an UPCOMING visit (gid `…MjE5MjIyMDE0NA==`, **2026-07-01 02:00 ET**). Listed for Fred; not closed.
**Live Jobber UI (Chrome) after, "Status | Active" filter → exactly 4 active jobs:** the 3 new (#99900557 $900 / #99900558 $540 / #99900559 Service Call $0) + the skipped #10000350. The 7 archived jobs no longer appear in the active list. **End-to-end flow (archive old + create new) fully validated on one 2-job client.**

### Cleanup TODO
- 112-YA (test client) has 3 throwaway test jobs from shape-validation: #99900554, #99900555, + 1 more (gid `…MTQ4NzIyNjM4`). Close/delete via UI (jobClose needs IncompleteVisitDecisionEnum).

## ROLLOUT COMPLETE (2026-06-23)
Full live run via `_rollout.js --execute` (resumable/idempotent; passed 2 adversarial workflow reviews — 14 findings all fixed; dry-run; single-client live test on 009-CN). **0 errors, createdLog crosscheck matched.**
- **181 clients processed** (universe 189 in-scope; +140-TCY +210-KAY added 2026-06-23 after Fred's corrections).
- **181 Service Calls + 159 SA jobs created** (recurring as-needed; SA from the Itemized sheet; line-item names = full "NN - …" strings; Frequency custom field set).
- **663 old jobs closed** → **623 fully archived** + **40 closed-but-`requires_invoicing`** (won't auto-archive until their outstanding invoicing is resolved, then archive from Actions menu — per Fred's note).
- **19 jobs SKIPPED** (had a pending visit; closing would destroy it) across 18 clients — incl. the hand-done 031-KRU #10000350.
- **Resolved on 2026-06-23 per Fred:** `140-TYO`→Jobber `140-TCY` (Airtable code typo, override added) and `210-KAY` (back on Jobber) — both processed. `207-CN Casa Neos BAR` was **deleted** by Fred (dropped from progress).
- **Still need manual handling (in the PDF, §3 "Needs Manual Handling"):**
  - **Wynd 28** (216–220-WYN: Pasta/Presidente/CU4/Nino Gordo/Pari Pari) = 5 tenants under ONE Jobber client "Wynd 28" (`clients/126142048`); no per-tenant Jobber client → restructure can't attach per-tenant jobs. Existing Wynd 28 jobs left untouched. Decide structure.
  - **2 multi-property → needs_review (not mutated):** 119-ME, 128-MF (no SA jobs). Decide which property gets the Service Call before processing.
- Deliverables: `C:\Users\FRED\Downloads\Jobs_Not_Closed_Pending_Visits_2026-06-23.pdf` (§1 pending-visit skip-list + §2 closed-pending-invoicing). Audit records: `_rollout_progress.json`, `_rollout_created.jsonl`, `_rollout_summary.json`, `_rollout_skiplist.json`, `_rollout_needs_invoicing.json` (in Supabase/). Exceptions 021-GRA + 032-LG untouched.
- **Follow-ups for ops:** (a) invoice+archive the 40 requires_invoicing jobs; (b) handle the 19 pending-visit jobs (reschedule/complete/cancel visit → close); (c) decide the 8 unresolved + 2 multi-property.

## VISIT MIGRATION (2026-06-22 ET — pending-visit rescue, per Fred)
For the SKIPPED jobs, future/today pending visits whose service maps to a Service Agreement were **migrated to the new SA job** (preserving the visit's **Instructions** + schedule), then the old job closed. Rules: migrate if visit ET-date ≥ today AND service matches an SA job; **leave** Service Call/Emergency visits, genuinely past-dated visits, and clients with no SA job. Visit API (read-app token HAS `write_scheduled_items`): `visitCreate(jobId,input:{visits:[{title,instructions,schedule:{startAt,endAt}}]})` + `visitDelete(visitIds)`; `LocalDateTimeAttributes={date,time,timezone}`.
- **Migrated 4** (Grease Trap Pumping → client's GT Service Agreement, then old job closed): **092-TCE** #9201, **104-PV** #10401, **168-AVA** #10000217 (old job→requires_invoicing), **186-PV** #10000229. New visits verified on the SA jobs with original timestamps.
- **Left + flagged (one-off tasks, NOT SA services):** 093-KC #10000315 "Adjust lids", 106-ALC #99900552 "pick up hummus achla money" — PDF §1 carries a Note: decide complete/reschedule/move-to-Service-Call. (Auto-matcher's "only-one-SA" fallback would have mis-filed these → required real keyword match.)
- After migration: **skip-list = 15** (was 19), **needs-invoicing = 41** (was 40, +168-AVA old job). Scratch result files: `_visit_migrate_plan.json`, `_visit_migrate_results.json`.
- **GOTCHA — `visitCreate` does NOT carry `assignedUsers` (fixed 2026-06-23):** the migration payload `{title,instructions,schedule}` recreated the 4 visits **unassigned** — the original crew was silently dropped. Any future pending-visit rescue MUST capture the old visit's `assignedUsers` *before* `visitDelete`, then re-apply on the new visit via **`visitEditAssignedUsers(visitId, input:{ assignedUserIds:[EncodedId!]! })`** (replace-set). Backfilled the 4: 092-TCE/104-PV/186-PV → Aaron Driver; 168-AVA → Grecia + Ishad Knight + Aaron Driver. (Other migrated visit fields — title, schedule, instructions — *do* carry over correctly.)

## 2026-06-24 — second archive pass (visits since completed)
Re-checked all non-archived Jobber jobs for archiving (Fred). **Reliable keep-rule:** `#999` number + not `[OLD]` + SA/SC title = the 402 real jobs — NEVER touched (verified 0 leaked into the candidate set). Candidates = 60 `[OLD]`-tagged + 6 untagged-old `#100xxxxx` duplicates whose client already has a `#999` replacement (119-ME, 128-MF, #10000709, 112-YA #11100534). `jobClose(COMPLETE_PAST_DESTROY_FUTURE)` on the 52 with all-COMPLETED visits:
- **8 newly archived** (+2 already archived) — fully off the active list.
- **44 closed but `requires_invoicing`** — Jobber won't archive a job with uninvoiced completed work; ops must invoice → then archive from the Actions menu (same blocker as the 2026-06-23 rollout's 40).
- **12 skipped** — still have a non-COMPLETED (LATE/UPCOMING/UNSCHEDULED) visit; complete/reschedule/cancel it first, then re-run.
- **4 orphan-risk clients left untouched** (021-GRA, 032-LG, 053-PV, 145-NON — only an old `#100xxxxx` SA+SC pair, no `#999` replacement; need replacement jobs or a keep decision).
DB `job_status` reconciled to Jobber for the archived ones (status changes don't auto-sync — see `reference_jobs_sync_gaps`). The archive pass is idempotent + resumable (re-run skips already-archived).

## Status log
- 2026-06-22: plan finalized; titles audited clean (163/163); API discovered; **jobCreate validated on 112-YA then 031-KRU (3 jobs created OK)**.
- 2026-06-22: **Chrome UI verify DONE** — all 3 new 031-KRU jobs confirmed live in the Jobber web UI (Chrome, not Brave) with correct titles/amounts.
- 2026-06-22: **Fred decisions logged** — Service Call = recurring-as-needed via API; old jobs = `jobClose` via API (auto-archives), skip+list jobs with incomplete visits.
- 2026-06-22: **ARCHIVE leg tested + UI-verified on 031-KRU** — 7 old jobs closed→archived, 1 skipped (#10000350, upcoming visit 2026-07-01). UI shows only the 3 new + 1 skipped active. **FULL one-client test PASSED. Ready for rollout pending Fred's go.**

## Full-rollout build notes (ready to implement)
Per-client algorithm (skip exceptions 021-GRA, 032-LG entirely):
1. Resolve Jobber client GID by NNN-XX code / name (`clients(first,searchTerm)`), get its property GID.
2. Read existing jobs (cheap query — no big nested visit lists). For each job, fetch its visits in a SECOND small/paged query to classify.
3. **Close** every job whose visits are all COMPLETED (or none) via `jobClose(COMPLETE_PAST_DESTROY_FUTURE)`; **skip + record** any job with a non-COMPLETED visit.
4. **Create Service Call** (recurring as-needed, no line items/freq) for EVERY client.
5. **Create SA job(s)** for Itemized clients from the sheet (the validated jobCreate payload).
6. ~2s delay between mutations; chunk to respect the cost bucket; write a per-client result JSON (closed[], skipped_incomplete[], created[]).
7. Output a consolidated **"incomplete-visit skip list"** (client + job + visit + date) for Fred to handle manually.
- Order within a client: create new jobs is independent of closing old (new GIDs differ); during rollout, close-old-then-create-new is cleanest so the "Active" list ends with only the new set + any skipped-old.
