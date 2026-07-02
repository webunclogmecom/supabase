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

**Phase 2 — Jobber (bill it correctly):**
Recreate each `[08+26]` warranty SA in Jobber as **billing-only**: create a new job with the **Billing
frequency** (e.g. "Monthly on the last day" or every N days) and **no visit schedule**, then archive the
old visit-based one. **Verify first whether the Jobber `jobCreate` API exposes the billing/invoice
schedule** — if it doesn't, this must be done in the **Jobber UI** (creation-time only). High-stakes
(billing config for ~30 clients) → do deliberately, ideally after confirming one client end-to-end.

## For any future client
If an SA is a warranty / billing-only service (no physical work — Warranty of Drainage, a pure retainer,
etc.): in Jobber create it with a **Billing frequency** (recurring invoice), **not** a visit schedule; and
make sure our visit-generator does **not** create visits for it (it must be WD-only / non-serviceable).
