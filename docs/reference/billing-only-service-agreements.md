# Billing-only Service Agreements (Warranty of Drainage / code 08)

*Added 2026-07-02 (Fred + Yan). The model + how to fix/recreate — for any future client.*

## What a billing-only SA is
Some Service Agreements are **billing-only**: a recurring **charge** with **NO physical service
visit**. The canonical case is **"Warranty of Drainage"** (line-item **code 08**) — the customer pays
a periodic warranty fee, but no truck rolls out. In Jobber these are set up as a **recurring invoice**
via the job's **"Billing frequency"** (e.g. *"Monthly on the last day of the month"*, or every N days),
**not** a recurring visit schedule.

> **Jobber limitation (the whole reason this is painful):** the **Billing frequency is set only at job
> CREATION and cannot be edited afterward.** To turn an existing visit-based SA into a billing-only one,
> you must **recreate the job** (archive the old, create a new one with the billing frequency).

**Done-right example — 012-DKC** "Service Agreement - Warranty of Drainage" (Jobber job **1202**):
Recurring job · **Billing frequency = "Monthly on the last day of the month"** · Automatic payments Yes ·
Fixed price · **no visits**. That's the target shape for a warranty/billing-only SA.

## The bug this surfaced (2026-07-02)
`service_line_items` code **08 "Warranty of Drainage"** carries **`service_type='WD'`**. Our SA
visit-generator (`scripts/sync/generate_service_agreement_visits.js`) generates visits for **any** SA
job with a serviceable-typed line item + `frequency_days>0` — so it wrongly created **service visits**
for the billing-only warranty jobs. **~30 TCE clients** (061–081, 092, 169-TCE) each carry a *second* SA
job with line items **`[08+26]`** (Warranty of Drainage + ACH fee), freq 60, which was generating ~2–3
**phantom visits** each (**~69 total**). A warranty needs no visit → these pollute the Calendar.

Each of those TCE clients correctly *also* has a **`[01+26]`** job (01 = Grease Trap Pumping) — that one
**is** a real service and **keeps its visits**. Only the **`08`-only** job is billing-only.

## How to identify a billing-only SA
An SA job whose **only serviceable line item is `08` (WD)** — i.e. it has **no `01`–`04`** (grease-trap /
lift-station pumping). Fees (25 credit-card, 26 ACH) don't count as service. Such a job is billing-only.

## The fix (two phases)
**Phase 1 — our side (stop + remove the phantom visits):**
1. Exclude WD-only jobs from `generate_service_agreement_visits.js` (a job whose only serviceable line
   item is `08`/WD is billing-only → never generate visits). Consider dropping `service_type` on code 08
   (WD) so the taxonomy itself marks it non-serviceable.
2. Soft-delete the phantom scheduled visits on the `[08]`-only jobs, and un-push any that reached Jobber.

**Phase 2 — Jobber (bill it correctly): DONE 2026-07-02 for the 23 TCE warranties (via `jobCreate` API).**
Recreate each `[08+26]`/`[08+25]` warranty SA in Jobber as **billing-only** (recurring invoice, no visits),
then archive the old visit-based one. The Jobber API CAN do it (verified + UI-double-checked on 065-TCE).

**The exact `jobCreate` recipe** (matches the 012-DKC done-right reference — copy for any future warranty):
```js
jobCreate(input: {                                  // input type = JobCreateAttributes
  propertyId: <client's Jobber property GID>,
  title: 'Service Agreement - Warranty of Drainage',
  timeframe: { startAt: '<YYYY-MM-01>', durationUnits: 'YEARS', durationValue: 3 },  // 3-yr term (012-DKC = 3yr)
  invoicing: {
    invoicingType: 'FIXED_PRICE',
    invoicingSchedule: 'PERIODIC',
    recurrence: 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=-1'   // every 2 months on the LAST day (freq 60).
  },                                                            // monthly => drop INTERVAL=2. BYMONTHDAY=-1 = last day.
  scheduling: { createVisits: false, notifyTeam: false },      // NO truck rolls.
  lineItems: [ { name, unitPrice, quantity, totalPrice, saveToProductsAndServices: false }, ... ]  // 08 warranty + 25/26 fee
})
```
Gotchas (all enforced by the API): `recurrence` needs the `RRULE:` prefix; `notifyTeam` and each line item's
`saveToProductsAndServices` cannot be null; `timeframe.startAt` is REQUIRED when a recurrence is set (else it
defaults the job to a 6-month term). Verify the result shows `jobType=RECURRING`, `billingType=FIXED_PRICE`,
`invoiceSchedule.scheduleSummary="Every 2 months on the last day of the month"`, and `visits.totalCount=0`.
Retire the old visit-based job with `jobClose(jobId, input:{ modifyIncompleteVisitsBy: DESTROY_ALL })`
(→ status `archived`; DESTROY_ALL is safe here since Phase 1 already left 0 visits).

**Done 2026-07-02:** 23 TCE warranties (061–081, 092, 169-TCE; all freq 60 = every-2-months) recreated as
billing-only jobs `#99900984`–`#99901006` (3-yr term, first invoice Jul 31 2026), old jobs `#99900659…`
closed→archived. New jobs poll-sync into `public.jobs`; the generator excludes them (08-only, Phase 1).

## For any future client
If an SA is a warranty / billing-only service (no physical work — Warranty of Drainage, a pure retainer,
etc.): in Jobber create it with a **Billing frequency** (recurring invoice), **not** a visit schedule; and
make sure our visit-generator does **not** create visits for it (it must be WD-only / non-serviceable).

## 2026-07-03 CORRECTION — the Phase-2 recreations were WRONG; fixed by reopening the originals
Fred caught that the Phase-2 billing-only jobs (`#99900984`–`#99901006`) had **two errors** vs the real
originals: they billed **every 2 months on the LAST day** (should be **the 22nd**) and had **Automatic
payments = No** (should be **Yes**).

- **Autopay CANNOT be set via the Jobber API.** `Job.willClientBeAutomaticallyCharged` is READ-ONLY; there's
  no autopay field in `jobCreate`/`jobEdit`, and 0 of ~109 mutations touch it. It's a UI-only, per-job setting
  fixed at CREATION. Jobber AI also confirmed a **true 0-visit recurring job isn't creatable in the UI**
  ("recurring jobs are built around a visit schedule"). So neither path alone gives 22nd + autopay + 0 visits:
  the API makes 0-visit jobs but no autopay; the UI sets autopay but forces visits.
- **The originals (`#100000xx`) already had all three** (22nd + autopay=Yes + 0 visits) — they predate this and
  were just archived. **Fix (all via API):** `jobReopen` the original (restores everything incl. billing
  history; reopen creates **NO** new invoice — verified) → `jobEdit` title = "Service Agreement - Warranty of
  Drainage" → `jobEditLineItems`/`jobCreateLineItems` to match `08 - …Warranty of Drainage $225` + `26-ACH (1%)
  $2.25` (or `25-CC (3.53%) $7.94`) → `jobClose` the wrong Phase-2 dupe. Next invoice = **Jul 22 2026** (odd-month
  …May 22 → Jul 22 cadence). 22/23 done; DB re-synced via webhook-jobber replay.
- **2 exceptions:** **081-TCE**'s original never had autopay (auto=false — likely no card on file); reopened on
  the 22nd but autopay stays off (office must enable in UI). **169-TCE** has **no original** to reopen (only the
  Phase-2 dupe ever existed) — left as-is pending an office UI setup.
- **Rule for future warranties:** if a correct original exists, **REOPEN it** — don't recreate (reopen preserves
  autopay, which the API can't set). A brand-new warranty needing autopay must be created in the Jobber UI.
