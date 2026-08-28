# Past due: the canonical definition

*Established 2026-08-28 by Fred. Written down because it is a BUSINESS rule that looks like a
technical detail, and because the wrong reading is three times larger than the right one.*

## The rule

> **Past due is whatever JOBBER says is past due.** We read `invoices.invoice_status = 'past_due'`.
> We do NOT compute it ourselves from due dates.

Fred, 2026-08-28: *"follow with the rules of Jobber on that part, and keep it that way."*

This follows the standing principle that **billing truth is Jobber invoices**. Jobber is where the
office works, where payments are recorded and where terms live. Anything we derive ourselves will
eventually disagree with the screen the office is looking at, and then we are the ones who are wrong.

```sql
-- the definition, in full
select *
from public.invoices
where invoice_status = 'past_due'
  and outstanding_amount > 0;   -- see "the one exception" below
```

## 🛑 The rejected alternative, and why the gap matters

The obvious re-derivation is "unpaid and past its due date". It was measured and rejected:

| | clients | invoices | amount |
|---|---|---|---|
| **A. `invoice_status = 'past_due'`** (SHIPPED) | **37** | **40** | **$34,795** |
| B. `outstanding_amount > 0 AND due_date < current_date` | 107 | 147 | $101,155 |

**B is roughly three times larger.** Most of the difference is `awaiting_payment` invoices that are
past their date but which Jobber has not escalated, for reasons that live in Jobber (terms,
arrangements, disputes) and are not visible to us.

⚠ **Both numbers are legitimate answers to different questions.** If anyone asks *"how much are we
owed late?"*, the honest answer is closer to **B**. If they ask *"who is past due?"*, it is **A**,
because that is what Jobber and the office call past due. Do not silently swap one for the other.

## The one exception, and it is deliberate

The shipped definition adds `outstanding_amount > 0`. That is **not** part of Jobber's rule and it
excludes exactly one invoice today:

| client | invoice | total | outstanding | due |
|---|---|---|---|---|
| 168-AVA | 2167 | -$34.22 | **-$34.22** | 2026-05-09 |

It is a **credit note** that Jobber has labelled `past_due`. 168-AVA has no other past-due invoice,
so without the guard that client would carry a badge reading **"Past due: -$34.22 · 1 invoice"**,
which asserts a debt where there is a credit.

**So the honest statement of what we ship is:** Jobber's `past_due` status, minus invoices with a
non-positive balance. That is 40 of Jobber's 41, and 37 of its 38 clients.

⚠ **`outstanding_amount > 0` is NOT redundant beside the status in general.** Status and balance
disagree in BOTH directions across the table:
- one `past_due` invoice has a negative balance (above),
- **nine `paid` invoices have a non-zero balance**, six positive and three negative, netting $781.99.

So neither field can be trusted alone, and a change to one predicate is not cosmetic.

## Where this is implemented

| | |
|---|---|
| View | `ops.v_client_past_due` (one row per affected client, 37 today) |
| Migrations | `2026-08-28_0857_client_past_due_view.sql`, `2026-08-28_0915_client_past_due_jobber_id.sql` |
| Consumer | Visit Calendar: red client code on the card, hover-card badge, drawer line |
| App rule | `Building Apps/Visit Calendar/CLAUDE.md` rule 12 |

`jobber_client_id` is decoded **in the view** from the base64 GID in `entity_source_links`, so the
app can never construct a Jobber URL from a displayed number.
⚠ Filter `source_system = 'jobber'` **before** decoding: `entity_type='client'` also holds airtable
and samsara ids that are not base64 and raise `22023 invalid base64 end sequence`.

## 🛑 Do not do these

1. **Do not replace the status test with a date comparison.** That is definition B. It is a product
   change and needs Fred, not a refactor. The tell that someone has done it: the client count jumps
   from about 37 to about 107.
2. **Do not `SUM(outstanding_amount)` across all invoices** to answer "what are we owed". That folds
   in unsent drafts ($9,286) and nets off credits. Scope it:
   `where invoice_status in ('awaiting_payment','past_due')` gives **$116,765**, against a naive
   whole-table sum of $126,833.
3. **Do not drop `outstanding_amount > 0`** without deciding what a negative past-due badge should
   say. It is currently load-bearing for exactly one client.
4. **Do not key past-due joins on `client_code`.** Six of the 37 clients have a NULL code. They have
   no calendar visits so nothing renders today, but a code-keyed join silently drops them.

## Verifying it after a change

```sql
-- what Jobber says
select count(*) invoices, count(distinct client_id) clients,
       round(sum(outstanding_amount)::numeric,2) outstanding
from public.invoices where invoice_status = 'past_due';

-- what we show
select count(*) clients, sum(past_due_invoice_count) invoices,
       round(sum(past_due_amount)::numeric,2) amount
from ops.v_client_past_due;

-- the delta must be ONLY non-positive-balance invoices
select client_id, invoice_number, total, outstanding_amount
from public.invoices
where invoice_status = 'past_due' and not (outstanding_amount > 0);
```

⚠ **Include a control when checking.** "The view returns 37 clients" is satisfied by both the right
definition and several wrong ones. The migration's verify block asserts that definition B yields a
*different* count, so the check can actually tell them apart.

## Named fixtures

| client | expect |
|---|---|
| 293-ALC (A La Carte Bay Harbour) | 3 invoices, $5,508.00, jobber client 145753373 |
| 151-OAS (Oasis Hallandale) | 1 invoice, $3,019.98 |
| 154-PV (Pura Vida Fisher Island) | **nothing**. Three invoices, all paid, zero outstanding. Fred's original mockup showed "$734 - 2 invoices" on this client; that was illustrative, not real. Use it as the negative control. |
