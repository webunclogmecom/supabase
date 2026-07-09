# SA Pump-Frequency Audit — 2026-07-09

**Trigger (Fred):** On the Field Portal, 152-DAV's visit page (`/152-dav/visit/bBSpATqruQ`) showed
**"GDO Permits & Frequency → No permits on file"** with no frequency. Its Jobber SA job
([148743894](https://secure.getjobber.com/jobs/148743894)) has **Frequency = 60 days**. Fred asked
for a full audit of the frequency issue across all SA clients — "check they have been solved, and
document it."

## Method

Reconciled every **active (non-archived) Service-Agreement job** in `public.jobs` against Jobber's
live **"Frequency"** custom field (a `CustomFieldNumeric`, in days), pulled per job via the Jobber
GraphQL API (`job(id).customFields … on CustomFieldNumeric { label valueNumeric }`, version
`2026-04-16`). SA jobs identified by `title ILIKE '%Service Agreement%' AND job_status <> 'archived'`,
joined to their Jobber GID via `entity_source_links`. Script:
`scratchpad/freq_audit.js` (176 jobs, concurrency 5).

## Findings — the DATA is correct (nothing to backfill)

| Bucket | Count |
|---|---|
| **Match** (`jobs.frequency_days` == Jobber Frequency) | **153** |
| DB missing, Jobber has a value | 0 |
| DB has a value, Jobber missing | 0 |
| Mismatch (both present, differ) | 0 |
| Both missing | 23 |
| Errors | 0 |
| **Total active SA jobs** | **176** |

- **153/153 SA jobs that carry a Jobber frequency match our `jobs.frequency_days` exactly — 0
  mismatches, 0 one-sided gaps.** 152-DAV = 60 in both.
- The **23 "both-missing"** are all old `action_required` **legacy jobs** (pre-`99900xxx`
  numbering, e.g. `10000069`) where **neither Jobber nor our DB** has a frequency. Every one of those
  clients has a **separate current** SA job (`99900xxx`) that *does* carry the right frequency (e.g.
  061-TCE: legacy job 10000069 = null/null, current job 99900658 = 21/21 ✓). They are stale duplicate
  jobs, not real gaps — safe to ignore for frequency (they may need invoicing attention separately).

**Conclusion: `jobs.frequency_days` faithfully mirrors Jobber's Frequency custom field for every
active SA. The frequency data is solved.** (⚠ watch item: the JOBS poll doesn't fetch `customFields`
— see `reference/… jobs sync gaps`; the value is currently consistent but a future Jobber edit to the
Frequency custom field could drift until re-synced. Re-run this audit script to check.)

## Root cause of the reported symptom — a DISPLAY gap, not a data gap

The Field Portal renders the pump frequency **only inside a GDO-permit row** (`customer.permits`,
one row per GDO permit). So an SA client with a correct frequency but **no GDO permit on file** shows
**"No permits on file"** and the frequency is invisible.

Quantified: of **146 active SA clients** with a frequency,
- **114 have a GDO permit** → frequency shows ✓
- **32 have NO GDO permit → frequency hidden** (the 152-DAV class).

The 32 (all have a correct DB frequency): 007-CC (60), 010-CS (60), 019-G7 (30), 020-G7 (60),
022/023/024-GRO (60), 028-HUM (30), 037-LB (60), 044-MP (60), 051-PV (60), 064-TCE (60), 067-TCE (30),
076-TCE (60), 081-TCE (60), 090-OAK (30), 093-KC (90), 103-BWC (30), 106-ALC (30), 109-RAB (90),
152-DAV (60), … (full set = the 32 `no_gdo_permit` clients).

## Fix (applied 2026-07-09, Building Apps session)

1. **`customer.clients.service_frequency_days`** — new field = `max(frequency_days)` of the client's
   non-archived SA jobs with `frequency_days > 0` (migration
   `2026-07-09_clients_service_frequency_days.sql`). Verified 152-DAV = 60, 244-URI = 30.
2. **Field Portal** — the "GDO Permits & Frequency" section (visit page + Location Info tab) now shows
   **"PUMP FREQUENCY — Every N days"** from `service_frequency_days` when the client has **no GDO
   permit**; the "No permits on file" copy remains only when there is also no frequency. Clients with
   GDO permits are unchanged (still per-permit frequency).

**Net:** all 32 hidden SA clients (incl. 152-DAV) now show their frequency; the underlying data was
already correct.
