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

- `fn_line_item_requires_derm(name)` — taxonomy code → authoritative flag **for service codes only**
  (see the 2026-08-06 amendment: fee/admin codes 25/26/27 abstain and return NULL); else a free-text
  classifier (PUMP regex evaluated **before** NONPUMP, so a pumping line is never downgraded by a
  co-occurring fee/cleaning token); else NULL.
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

## Amendment 2026-08-06: a fee line ABSTAINS; the taxonomy branch is not authoritative for 25/26/27

Migration `2026-08-06_1448_fee_lines_are_derm_neutral.sql` (commit `0af47f1`). The Decision above said
"taxonomy code → authoritative flag" with no exception. That is now false for three codes, and the
exception is a **compliance** change, not a tidy-up.

Codes **25 (Credit card fee), 26 (ACH Fee), 27 (GDO Online Reporting)** carry
`service_line_items.reason IN ('fee','other')`. `fn_line_item_requires_derm` returns **NULL** for them
regardless of the catalogue column. Rationale: on code 05 (Main Line Cleaning) a FALSE is a genuine
statement about the work; on a credit card fee it is not a statement at all. `service_line_items.
requires_derm` is **NOT NULL** and so cannot express "this line does not say", which is why the
distinction lives in the function (the semantic layer) rather than in the column.

**What it protects.** `fn_visit_requires_derm` folds with `bool_or` and `customer.work_orders` ends
`COALESCE(v.derm_required, true) = true`. A Service Call visit reaches no job-scoped line today and
therefore derives NULL, which every consumer reads as "still needs a manifest". The moment a fee line is
mirrored onto that job, the visit reaches exactly one line; a FALSE there would derive FALSE, the
nightly `derm-required-rederive` would write that NULL to FALSE fill, and the monotonic guard would not
block it (it only protects a known TRUE). **33 live visits across 22 non-SA jobs are in that shape**,
and Fred ruled on 2026-08-05 that `customer.work_orders` is the client's DERM compliance surface by
design, so eviction from it is a real loss.

**Measured impact was zero, with the control printed beside it** (826 visits reach a fee line today, the
positive control; 1741 reach any line; **0** derives changed) because a real service line already
decides those visits. A guard installed ahead of the hazard, so "it changed nothing" is not grounds to
remove it.

**Scope is deliberately narrow:** only the authoritative taxonomy branch changed. The free-text branch
still answers FALSE for a fee-ish string, because that same regex also covers cleaning/camera/labour
where FALSE genuinely is evidence. Splitting that branch is a separate change with its own blast radius.

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
