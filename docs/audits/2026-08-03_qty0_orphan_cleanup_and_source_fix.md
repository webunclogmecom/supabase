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

## Post-cleanup convergence, and a decision that must not be re-litigated

`jobber_job_drift` ran at 20:15 UTC after the deletions (`line_syncs: 3`) and converged all three
**live** jobs I cleaned (99900885, 99900562, 99900635 — each now byte-matches Jobber).

The other four (10000171, 10000188, 2505, 10000196) are **archived**, and the reconciler excludes
them by design: `.not("job_status", "in", "(archived,closed,destroyed)")`. **They will never
converge and that is correct.** Measured: those four appear **0 times** in
`ops.client_service_options`, which filters `job_status <> 'archived'`, so no app surface reads them.

🛑 **Fred, 2026-08-03: "leave it, don't extend the reconciler to archived jobs."** Do NOT add archived
jobs to the drift sweep. It would add a Jobber API cost to every 30-minute run, forever, for records
no app queries. The stale rows are inert.

⚠ Also inert, and NOT introduced by this work: archived job 10000196 has 4 job-scope rows on our side
and 5 in Jobber, i.e. drift in the *opposite* direction. Pre-existing, left alone under the same
decision.

⚠ **The 15 duplicate groups still reported on live jobs are NOT orphans.** They are faithful mirrors
of Jobber's live per-visit overrides. Verified: 99900635 holds 4 rows / 2 at qty-0 in our DB and
4 rows / 2 at qty-0 in Jobber. Anyone re-running the naive duplicate query will see a non-zero count
and must not "clean" it — check the qty-0 line's visit references first.

---

## 2026-08-19 — the source fix was NARROWED, and why it does not undo any of the above

**Fred:** *"But with that fix does it clash with the duplicate of putting multiple line items on
the job? specially that was a problem for the SA jobs."* Fair question. Measured answer: **no.**

The guard shipped above skips an all-$0 set so Jobber keeps its **own priced templates**. That
premise is false on a job with no templates, where the skip left the visit showing **no services**
(131 visits), or worse, **silently inheriting an older visit's service** — Excelsior Condo 300-EC,
job 99901029: the Aug 6 visit was dispatched as "22 - Labor" and displayed "18 - Unclogging
Hydrojet", the line minted by the Jul 30 visit before this guard existed.

So `syncVisitLineItems` now skips only when the job carries line items **other than this visit's
own** (Jobber has no VisitLineItem type, so a visit's lines are job lines linked to it and would
otherwise count themselves as inheritable). If Jobber cannot be read, the old skip stands.

### Why the SA duplicate problem cannot come back

| job kind | templates? | behaviour after the change | visits |
|---|---|---|---|
| **SA job** | yes | **STILL SKIPS — unchanged** | **16 of 16** |
| Service Call / other | yes | still skips | 20 |
| Service Call / other | **no** | now pushes | 163 |

**Every SA visit in the affected set sits on a job with templates, so the new branch never fires on
an SA job.** Verified live as well: a control push of visit 7454 (templated job) left its Jobber
line item ids byte-identical.

### The three symptoms from this audit, re-measured after the change and after re-pushing 56 visits

| check | result |
|---|---|
| duplicate entries in the New Visit picker (`ops.client_service_options`, 176 jobs) | **0** — the `2026-08-03d` view guard (excludes `visit_id IS NOT NULL` and `quantity = 0`) still holds |
| orphaned qty-0 job lines on the two jobs exercised today | **0** — every job-scope line is referenced by a live visit |
| a visit created AND deleted today (smoke test 7818 on job 99901061) | left **no** stranded line |

⚠ **Honest limit:** that last row is one delete, not proof the stranding mechanism is gone — 9 real
orphans existed historically. The exposure is unchanged in kind and now applies to Service Call jobs
with no templates: if such a visit is later deleted, skipped or cancelled, its line can strand. The
distinction that made the 2026-08-03 cleanup safe still governs any future cleanup: **a qty-0 job
line is only an orphan when ZERO visits reference it.** 33 live overrides were left untouched then,
and the same rule protects the 56 lines pushed on 2026-08-19, all of which are attached to live
visits.
