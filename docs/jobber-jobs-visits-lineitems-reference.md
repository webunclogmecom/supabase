# Jobber Jobs / Visits / Line Items — model + write API (permanent reference)

Built 2026-06-01 for the **Calendar → Jobber write-back** (Phase 2). Everything here was verified against
Jobber's **live GraphQL schema** (introspection with our `jobber_write` token) + a real job read — not guessed.
Endpoint `https://api.getjobber.com/api/graphql`, header `X-JOBBER-GRAPHQL-VERSION: 2026-04-16`
(**empirically confirmed valid** — every read/introspection here returned 200; ignore third-party claims that only `2025-04-16` exists).

---

## 1. The line-item taxonomy (our canonical service list)

Source: [Google Sheet](https://docs.google.com/spreadsheets/d/19ArflSwdhcpnu1U6Lii5q2VFmDLjwskurDCghN0aanE/edit).
These 27 items are **already implemented in Jobber as line-item names** (confirmed: a real job's line item is literally
`"01 - Service Agreement - Pumping - Grease Trap"`). **Column B is the Visit title.**

| Col | Meaning |
|---|---|
| **A** | `Requires DERM reporting` — **Y/N**. Drives `visit.derm_required` + the DERM app's "DERM required" vs "Not DERM required". |
| **B** | **Full line-item name = the Visit title** (e.g. `09 - Service Call - Pumping - Grease Trap & Tank Cleaning`). |
| **C** | `#` — numeric service id (01–27). |
| **D** | Reason — `Service Agreement` (recurring/contracted) or `Service Call` (ad-hoc). |
| **E** | Type — `Pumping` / `Cleaning` / `Unclogging` / `Warranty of Drainage` / `Camera Inspection` / `Dye Test` / `Assessment` / `Labor` / `Parts` / fee / `GDO Online Reporting`. (Maps to our `service_type`: Pumping≈GT, Cleaning≈CL.) |
| **F** | Where — `Grease Trap & Tank Cleaning` / `Grey Water` / `Lift Station & Tank Cleaning` / `Main Line` / `Aux` / `Tank` / `Residential` / `Commercial`. |
| **G** | Method — `Manual` / `Hydrojet`. |
| **H** | Free-text examples — **ignore**. |

| # | Title (col B) | DERM | Reason | Type | Where | Method |
|---|---|:--:|---|---|---|---|
| 01 | Service Agreement - Pumping - Grease Trap & Tank Cleaning | **Y** | Service Agreement | Pumping | Grease Trap & Tank Cleaning | |
| 02 | Service Agreement - Pumping - Grease Trap, Tank Cleaning & Warranty of Drainnage | **Y** | Service Agreement | Pumping | Grease Trap, Tank Cleaning & Warranty | |
| 03 | Service Agreement - Pumping - Grey Water | **Y** | Service Agreement | Pumping | Grey Water | |
| 04 | Service Agreement - Pumping - Lift Station & Tank Cleaning | **Y** | Service Agreement | Pumping | Lift Station & Tank Cleaning | |
| 05 | Service Agreement - Cleaning - Main Line Cleaning | N | Service Agreement | Cleaning | Main Line Cleaning | |
| 06 | Service Agreement - Cleaning - Aux Cleaning | N | Service Agreement | Cleaning | Aux Cleaning | |
| 07 | Service Agreement - Cleaning - Tank Cleaning | N | Service Agreement | Cleaning | Tank Cleaning | |
| 08 | Service Agreement - Warranty of Drainage | N | Service Agreement | Warranty of Drainage | | |
| 09 | Service Call - Pumping - Grease Trap & Tank Cleaning | **Y** | Service Call | Pumping | Grease Trap & Tank Cleaning | |
| 10 | Service Call - Pumping - Grey Water | **Y** | Service Call | Pumping | Grey Water | |
| 11 | Service Call - Pumping - Lift Station & Tank Cleaning | **Y** | Service Call | Pumping | Lift Station & Tank Cleaning | |
| 12 | Service Call - Cleaning - Main Line Cleaning | N | Service Call | Cleaning | Main Line Cleaning | |
| 13 | Service Call - Cleaning - Auxiliary Line Cleaning | N | Service Call | Cleaning | Auxiliary Line Cleaning | |
| 14 | Service Call - Cleaning - Tank Cleaning | N | Service Call | Cleaning | Tank Cleaning | |
| 15 | Service Call - Unclogging - Residential - Manual | N | Service Call | Unclogging | Residential | Manual |
| 16 | Service Call - Unclogging - Residential - Hydrojet | N | Service Call | Unclogging | Residential | Hydrojet |
| 17 | Service Call - Unclogging - Commercial - Manual | N | Service Call | Unclogging | Commercial | Manual |
| 18 | Service Call - Unclogging - Commercial - Hydrojet | N | Service Call | Unclogging | Commercial | Hydrojet |
| 19 | Service Call - Camera Inspection | N | Service Call | Camera Inspection | | |
| 20 | Service Call - Dye Test | N | Service Call | Dye Test | | |
| 21 | Service Call - Assessment | N | Service Call | Assessment | | |
| 22 | Service Call - Labor | N | Service Call | Labor | | |
| 23 | Service Call - Parts | N | Service Call | Parts | | |
| 24 | Service Call - Labor BUS | N | Service Call | Labor BUS | | |
| 25 | Credit card fee (3.53%) | N | fee | | | |
| 26 | ACH Fee (1%) | N | fee | | | |
| 27 | GDO Online Reporting | N | GDO Online Reporting | | | |

**DERM rule:** `derm_required = (col A == "Y")`, which is exactly the **7 Pumping items** (01–04, 09–11). All non-pumping = N.
**Visit-title candidates** are the *service* rows **01–24**; 25–26 are billing fees (not visits), 27 is a reporting add-on.

---

## 2. How Jobber models Jobs / Visits / Line Items

- **Job** = the container ("a scheduled event where work takes place"). Belongs to a **client + property**, is `RECURRING` or one-off,
  carries **line items** (billing) and one or more **visits**. Status: `active` / `late` / `archived` / `action_required` / `completed`.
- **Visit** = one occurrence on a job ("each time a provider goes to the property"). Has `title`, a `schedule` (date/time/timezone),
  assigned team members, and can carry its **own** line items.
- **Multi-job clients** (126 of 274) split jobs **by service** — e.g. `001-17` has a "Grease Trap Pumping & Warranty" job *and* a
  "Hydrojet Cleaning" job; sometimes an **archived** duplicate sits beside the active one (`007-CC`). Distribution: 1 job→148 clients, 2→71, 3→33, 4→17, 5→4, 6→1.
- **We already mirror all of this** in Prod:
  - `public.jobs` (594 rows: id, client_id, property_id, job_number, title, job_status, start_at, end_at, total, quote_id, notes)
  - `public.visits.job_id` → `public.jobs.id`
  - `entity_source_links`: `job→jobber` (594), `line_item→jobber` (565), `property→jobber` (554), `client→jobber` (387), `visit→jobber` (622)
  - → **the Jobber job GID for any of our jobs is resolvable from our own DB** (no Jobber round-trip needed to find the target job).
- **Real sample** (client Cheeseteak, job 10000359, RECURRING): line item `"01 - Service Agreement - Pumping - Grease Trap"`,
  one visit titled `"Cheeseteak - Grease Trap Pumping & Hydrojet Cleaning"`, `startAt: 2026-06-01T21:00:00Z` (Jobber returns UTC `Z`).

---

## 3. Write API — verified mutation contracts (live introspection 2026-06-01)

**Conventions:** IDs are opaque **`EncodedId`** (base64 GIDs — pass back exactly what Jobber returns, never construct).
Every mutation returns **`userErrors { message path }`** with HTTP 200 — **validation failures live there**, you MUST check it
(not just GraphQL `errors`). Rate limits: 2,500 req / 300 s (→429) + a points/leaky-bucket cost throttle (`extensions.cost.throttleStatus`; →`THROTTLED`). Keep mutations lean.

### 3a. `visitCreate` — add visit(s) to an EXISTING job ← the Option-B path
```
visitCreate(jobId: EncodedId!, input: VisitCreateInput!) : VisitCreatePayload

VisitCreateInput      { visits: [VisitCreateAttributes!]! }      # batch — N visits per call
VisitCreateAttributes { title: String, instructions: String, overrideOrder: Int, schedule: ScheduledItemAttributes }
ScheduledItemAttributes {
  startAt: LocalDateTimeAttributes,  endAt: LocalDateTimeAttributes,
  notifyTeam: Boolean,               # <-- set FALSE to avoid spamming the crew on every push
  teamReminderOffset: Minutes,
  teamMemberIdsToAssign: [EncodedId!]
}
LocalDateTimeAttributes { date: ISO8601Date!,  time: ISO8601Time,  timezone: Timezone! }   # split fields, TZ REQUIRED
VisitCreatePayload    { createdVisits: [Visit!]!, job: Job!, userErrors: [MutationErrors!]! }
```
Example:
```graphql
mutation CreateVisit($jobId: EncodedId!, $input: VisitCreateInput!) {
  visitCreate(jobId: $jobId, input: $input) {
    createdVisits { id title startAt endAt }
    job { id jobNumber }
    userErrors { message path }
  }
}
```
```json
{ "jobId": "Z2lkOi8vSm9iYmVyL0pvYi8xNDY0MTcwNTM=",
  "input": { "visits": [{
    "title": "09 - Service Call - Pumping - Grease Trap & Tank Cleaning",
    "instructions": "optional crew note",
    "schedule": {
      "startAt": { "date": "2026-06-10", "time": "09:00:00", "timezone": "America/New_York" },
      "endAt":   { "date": "2026-06-10", "time": "11:00:00", "timezone": "America/New_York" },
      "notifyTeam": false,
      "teamMemberIdsToAssign": []
    } }] } }
```
> Times are **split date+time+timezone** (not an ISO datetime). Always `America/New_York` (ET) per house rule. Jobber stores/returns UTC `Z`.
>
> ✅ **Smoke-tested end-to-end on 112-YA (2026-06-01):** `visitCreate` → read-back → `visitDelete` all succeeded; `09:00 America/New_York` correctly stored as `13:00Z` (EDT); query cost ~2–4 pts; `notifyTeam:false` = no crew ping. **Cleanup mutation is `visitDelete(visitIds: [EncodedId!]!)` — PLURAL array arg, not `visitId`.** Runner: `scripts/probes/jobber_write_smoketest.js`.

### 3b. `jobCreate` — one-off job (only the no-match fallback)
```
jobCreate(input: JobCreateAttributes!) : JobCreatePayload  { job: Job, userErrors: [MutationErrors!]! }

JobCreateAttributes {
  propertyId: EncodedId!,                 # REQUIRED
  invoicing: JobInvoicingAttributes!,     # REQUIRED { invoicingType: BillingStrategy!, invoicingSchedule: BillingFrequencyEnum!, recurrence: ICalendarRule }
  title: String, instructions: String, jobNumber: Int, lineItems: [JobCreateLineItemAttributes!],
  scheduling: JobSchedulingAttributes,    # { createVisits!, notifyTeam!, assignedTo, startTime, endTime, recurrence: ICalendarRule, ... }
  timeframe: TimeframeAttributes, quoteId, requestId, jobFormIds, salespersonId, customFields, ...
}
```
> One-off jobs need a `propertyId` + an `invoicing` block (enum values `BillingStrategy`/`BillingFrequencyEnum` — introspect when building this path). `scheduling.recurrence: ICalendarRule` is how recurring series are created (RRULE) — exists if ever needed.

### 3c. `visitCreateLineItems` — give a visit its own billing line(s) (optional)
```
visitCreateLineItems(visitId: EncodedId!, input: VisitCreateLineItemInput!)
VisitCreateLineItemInput { lineItems: [VisitCreateLineItemAttributes!]! }
VisitCreateLineItemAttributes { name: String!, quantity: Float!, unitPrice: Float!,   # unitPrice is DOLLARS (Float), not cents
  description, category: ProductsAndServicesCategory, totalPrice, taxable, saveToProductsAndServices: Boolean! }
```

### Other useful mutations present in schema
`visitEdit`, `visitEditSchedule`, `visitEditAssignedUsers`, `visitDelete`, `visitComplete`, `updateFutureVisits` (bulk-edit a recurring job's future visits), `jobEdit`, `jobCreateLineItems`, `jobEditLineItems`, `jobClose/jobReopen`.

---

## 4. DERM logic (for the DERM app)
On each visit, resolve its **title → line-item row → column A**:
`derm_required = (lineItem.requires_derm == "Y")` → the 7 Pumping services. Surface as **"DERM required"** vs **"Not DERM required"**
in the DERM Tracker. (We already have `visits.derm_required boolean` to hold this.)

---

## 5. Calendar → Jobber sync design (Option B)
**Goal:** a visit you create in the Calendar appears in Jobber, attached to the client's existing job.

1. **Find** Calendar-origin visits to push: `source != 'jobber'` AND no `visit→jobber` link yet (future, `deleted_at IS NULL`).
2. **Resolve the target Jobber job** from our DB:
   - if `visits.job_id` is set → use that job's `job→jobber` GID;
   - else pick the client's **active** job whose **line item matches the visit's title** (the col-B service); prefer non-archived.
3. **Create** the visit via `visitCreate(jobId, {visits:[{title: <col B>, schedule:{startAt,endAt,notifyTeam:false}}]})`.
4. **Link back**: store the returned `createdVisits[].id` as `entity_source_links(visit, jobber, GID)` + set `visits.job_id` →
   the read-sync (`cron_jobber_upcoming_visits.js`) then recognizes it and never duplicates (no loop).

**Open decisions (lock before building):**
- **Scope:** push only ad-hoc `Service Call` visits (Jobber keeps generating `Service Agreement` recurring) — recommended — vs all.
- **No-match fallback:** multi-job client with no job for that service → create a one-off job (`jobCreate`) vs skip + flag.
- **Source value:** confirm what `source` the Calendar app stamps on manually-created visits (today only `jobber` + `supabase_cron` exist).

**Creds/runtime:** read+refresh `webhook_tokens` source_system=`jobber_write` (grant_type=refresh_token). Token lives ~1h; refresh on demand.
**Safe testing:** 112-YA test client, Jobber gid `Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ=` — create + `visitDelete` to clean up.
