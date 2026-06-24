# 018 — DERM-required derived from a visit's line items

**Status:** Accepted — 2026-06-24
**Supersedes:** the 2026-06-02 stopgap (`migrations/2026-06-02_manifest_pickable_all_service_types.sql`,
which offered all non-GT visits and flagged `derm_required IS NOT false` as missing docs).

## Context

A visit needs a Miami-Dade DERM disposal manifest **iff it includes a "Pumping" line item** (Fred's
Google Sheet, "Requires DERM reporting"). The system had been keying "needs DERM" off
`visits.service_type = 'GT'`, which is wrong both ways:

- `webhook-jobber.handleVisit` **defaults** `service_type` to GT when it can't infer one, so cleaning
  visits looked like GT (481 GT visits had `derm_required` NULL; 41 GT visits were actually cleaning).
- Grey-water pumping is coded **CL** but **does** require DERM (18 such visits hidden).

`service_line_items.requires_derm` (codes 01–04, 09–11 = Pumping) was already correct, but nothing
derived a per-visit signal from the visit's actual line items.

## Decision

Populate `visits.derm_required` from each visit's line items via two SQL functions:

- `fn_line_item_requires_derm(name)` — taxonomy code → authoritative flag; else a free-text classifier
  (PUMP regex evaluated **before** NONPUMP, so a pumping line is never downgraded by a co-occurring
  fee/cleaning token); else NULL.
- `fn_visit_requires_derm(visit_id)` — classifies the **UNION** of the visit's line items across the
  visit/invoice/job scopes: any pumping → true; all-classified-none-pumping → false; else NULL.

`NULL` means "unknown" and is the **safe default** — every consumer treats `derm_required IS NULL OR
= true` as still-needs-a-manifest. (Compliance: a false negative — hiding a real DERM visit — is worse
than the noise of an over-surfaced ambiguous one.)

Three writers keep it fresh: the Calendar `create_calendar_visit` RPC (from chosen services),
`handleVisit` (`set_visit_derm_required` after the poll stores line items), and a nightly pg_cron
(`rederive_visits_derm_required`) for line items that arrive later. The two automated writers are
**monotonic**: they never demote a stored TRUE and never write NULL (only promote NULL→{true,false} and
false→true) — so a later non-pump invoice can't hide a pumping visit, and a human NULL→true
reclassification is never reverted overnight. The one-time backfill is authoritative (writes the
function's verdict, protecting only existing trues).

Consumers (`manifest_pickable_visits`, `derm.visits.needs_manifest`, `customer.work_orders`) already
keyed off `derm_required` NULL-safe and auto-corrected on populate; `ops.v_derm_compliance` was switched
from `service_type='GT'` to `derm_required` (it stays GT-config-roster-scoped — grey-water/LS-only
clients are covered by `derm.visits`).

## Alternatives considered

- **Pure priority resolution** (visit→invoice→job, first non-empty) instead of UNION — rejected: an
  adversarial review showed it can hide pumping carried on the job when the invoice shows only cleaning.
- **`line_items.service_line_item_id` FK + a Jobber/DB taxonomy reformat** — the right long-term shape,
  but owned by Fred and not yet done; the free-text classifier is the bridge until then.
- **Coerce ambiguous to `false`** — rejected on compliance grounds (would hide possible pumping SAs).
- **Trigger on `line_items`** for sub-second freshness — deferred (fan-out/audit cost); nightly cron +
  per-poll `handleVisit` give acceptable latency (NULL is safe in the meantime).

## Consequences

- 2026-06-24 backfill of 706 completed visits: 436 true / 176 false / 94 null (41 GT→false, 18 CL→true
  corrected). `manifest_pickable_visits` dropped from the noisy stopgap to genuinely-missing visits.
- `visits` is audited; the `IS DISTINCT FROM` + monotonic guards mean steady-state nightly runs write 0
  rows (no audit/`updated_at` churn).
- The 94 NULL visits remain surfaced for review and resolve as Jobber line items get reformatted to the
  01–27 taxonomy. Free-text classification is best-effort and lives in the function (auditable, re-runnable).
- Rollback: `derm_required_backfill_snapshot_2026_06_24`; `cron.unschedule('derm-required-rederive')`.
