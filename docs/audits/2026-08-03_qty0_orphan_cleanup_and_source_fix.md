# 2026-08-03 — Duplicate line items: source fixed, orphans cleaned

**Fred:** *"check the duplicate of the line items, it's happening to a lot of clients ... find the
reason a fix"* then *"stop the bleeding at the source, then clean the orphans"*.

## Root cause (MEASURED) — our code authored them, in Jobber

`public.create_calendar_visit` writes one visit-scoped `line_items` row per picked service at
`COALESCE(p_line_item_prices…, s.unit_price, 0)`. **All 28 catalogue rows have `unit_price` NULL**, so
with no user override every row lands **$0, no description**. The INSERT trigger pushes `lineitems`,
and `jobber-push-visit → syncVisitLineItems` called `visitCreateLineItems`, which **mints brand-new
shared `JobLineItem` objects on the JOB** and unlinks the inherited priced templates.

Jobber has no `VisitLineItem` type: `job.lineItems` is the union of templates plus every per-visit
override, and an override renders **quantity 0 at job scope**. Deleting/skipping/cancelling that
visit **strands** its lines permanently. `sync-jobber-job-drift` (`15,45 * * * *`) mirrors them into
`public.line_items`, and `ops.client_service_options` aggregated job-scope lines with no quantity
predicate — so the New Visit modal listed the service twice.

Previously reproduced on **137/137** eligible SA jobs in
`2026-07-18_qty0_line_item_residue_audit.md`; its cleanup gate never ran.

⚠ **It fired again during this session and the session caused it:** visit 7648 created 18:21:53Z from
`calendar.unclogme.app` → Jobber objects `221733691`/`221733692` born 18:21:55Z → visit deleted
18:23:32Z → drift 18:45:00Z → DB rows 18:46:06Z.

## What shipped

**1. Source fix — `jobber-push-visit`, deployed 2026-08-03.** A per-VISIT no-op guard: if every
visit-scoped row is `$0` with no description, skip `visitCreateLineItems` entirely and let Jobber
keep its own priced templates.
- Per-visit (`items.some`), never per-row: **525 of 1519** visit-scoped rows are all-zero, but the
  other **994 carry a real price** from `p_line_item_prices` and must still push. A visit mixing a
  priced line with a $0 line still pushes in full.
- ⚠ Trade-off, accepted: a deliberately comped $0 line with no description no longer pushes. Give it
  a description to force the override through.
- `verify_jwt=true` preserved (this function is the documented exception that requires it).

**2. Symptom fix — `ops.client_service_options`** (migration `2026-08-03d`): exclude `visit_id IS NOT
NULL` and `quantity = 0`. Duplicate picker entries fleet-wide **19 groups → 0**; jobs offering ≥1
schedulable service **175 → 175, 0 regressed to empty**.

**3. Residue cleaned — 9 orphans deleted via `jobDeleteLineItems`.**

## ⚠ The distinction that made the cleanup safe

A qty-0 job-scope line is **only** an orphan if it is referenced by **zero visits**. Measured across
the 27 jobs carrying qty-0 lines:

| | count | action |
|---|---|---|
| true orphans (zero visit refs) | **9** | deleted |
| live per-visit overrides (attached to a real, often completed, visit) | **33** | **left untouched** |

🛑 **A naive "delete all qty-0 lines" would have destroyed 33 real override lines**, including
pricing on completed visits.

## Verification

- Source fix proven with the exact failing scenario: probe visit 7673 created on job 1629 then
  deleted. Jobber line items **5 before → 5 after**, no new objects minted. Pre-fix, the same cycle
  minted 2 within 2 seconds.
- After cleanup, re-walked all affected jobs: **0 remaining true orphans**, **33 live overrides still
  intact**. Positive control: job 99900885 went 5 → 3 (its three real priced lines).
- ⚠ An earlier sweep returned "no data" for all 27 jobs because the Jobber token was not exported to
  the child process. That is a broken instrument, not a clean result — the re-run carries an explicit
  positive control that must return 5 line items before any conclusion is drawn.

## Notes for whoever touches this next

- `public.line_items` has **no unique constraint** on any natural key and no writer uses `ON
  CONFLICT`; idempotency comes from delete-then-insert. That is defensible (jobs legitimately carry
  repeated names at different prices, split pricing) but it means **`created_at` dates the last
  resync, not the row's birth**.
- `public.line_items` has **no audit trigger**, so `audit.logs` is structurally blind to its writers.
  The writer here was identified by column fingerprint (`description` NULL vs `''`) plus cron timing.
- `entity_source_links` does **not** track Jobber line item ids — the `line_item` set is frozen at
  2026-04-29 with 89 orphaned links. It cannot answer sync questions about line items.
- Do **not** dedupe `public.line_items` directly: the drift reconciler multiset-diffs against Jobber
  and re-inserts within 30 minutes.
