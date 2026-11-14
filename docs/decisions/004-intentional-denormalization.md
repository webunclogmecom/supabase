# ADR 004 — Keep `visits.truck` and `visits.completed_by` as text denorms

- **Status:** Accepted (2026-04)

## Context

The `visits` table has proper FKs: `vehicle_id → vehicles.id`, and `visit_assignments(visit_id, employee_id)` for M:N attribution. In a clean design, the `visits.truck` (TEXT) and `visits.completed_by` (TEXT) columns would be dropped — they duplicate information available via joins.

The complication: **~1,400 historical visits predate both the `vehicles` table and the `visit_assignments` table.** Those visits come from Airtable, where the truck name was stored as a free-text field ("David", "the big one", "Moise", "Big One") and the completer was attributed by string ("Andres", "Pablo", etc.). No IDs.

`scripts/populate/populate.js` does fuzzy resolution and manages to map 1505 of 2208 legacy visits to a `vehicle_id`. The remaining 703 fall through — text mismatches, trucks that no longer exist, historical drivers we can't disambiguate. Dropping the `truck` and `completed_by` text columns destroys the **only** attribution data for that 703-row cohort.

## Decision

Keep both columns. Document them as intentional denormalization.

- `visits.truck` — free-text historical truck name. Populated from Airtable. Preserved forever.
- `visits.completed_by` — free-text historical technician attribution. Same.

For all *new* visits (post-webhook), populate the proper FKs (`vehicle_id`, `visit_assignments`) and let the text columns be `NULL`.

## Consequences

**Positive:**
- Zero data loss during the v1→v2 migration.
- Old queries that relied on `v.truck = 'David'` keep working.
- Analytics queries can union "modern" and "historical" cohorts with `COALESCE(v.name, visits.truck)`.

**Negative / accepted trade-offs:**
- Two sources of truth for truck and employee attribution on the same table. Noted in `docs/operations.md` under "Live vs historical cohorts".
- Enforced by convention: new inserts must fill the FKs and leave text columns NULL. There is no DB constraint preventing a writer from filling both.

**Never do this again for new columns.** This is a one-time concession to legacy data. Any future denorm must either have a stronger justification or be replaced by a resolvable FK.

## Addendum 2026-11-14: the card fee on a payment AND on its payout line

`public.payments.fee_amount` and `public.payout_lines.fee_amount` (the payments copy, `docs/reference/payments-copy.md`)
can hold the same number for a Jobber Payments payment. Kept on purpose, with this justification: they are two facts
Jobber states separately, neither computed from the other here. The payment's fee is what Jobber kept on that payment
(set when it is taken, also on payments not yet in any payout); the line's fee is what the bank payout deducted (the
bank statement, including refund-fee lines that belong to no payment). Measured 2026-11-13: payment fees $15,731.51,
payout line fees $15,602.64, the difference being the payments not paid out yet. Deriving one from the other would make
the bank reconciliation lie for exactly those payments. Neither is written by hand; both are replaced from Jobber.
