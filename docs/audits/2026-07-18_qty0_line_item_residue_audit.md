# Audit — the "qty-0 duplicate line items" on SA jobs are NOT what they looked like

**Date:** 2026-07-18 (evening ET) · **Trigger:** Fred spotted job 99900631 (043-MIL Mila) showing the
`02 - …` line item twice in Jobber and asked (a) why, (b) whether visit creation causes it, (c) whether
other SA jobs have it. Full-fleet audit ordered: DB, our code + docs, Jobber's official docs (online),
and a read-only probe of Jobber's live state. 8 investigation/design/judge agents; raw payloads in the
session scratchpad (`jobber_<jobnum>.json`).

---

## 1. Headline: the earlier "dead duplicates, safe to delete" read was WRONG

The 2026-07-18g migration header and the session discussion before this audit called the qty-0 lines
"dead duplicates … clearing them is a DELETE in Jobber". **The live id-level probe disproves that:**

> Of the 14 qty-0 job-scope lines across the 8 affected jobs, **12 are LINKED — they ARE the per-visit
> override line items of pushed visits.** Jobber renders a visit-scoped line at **quantity 0 in the
> job-scope connection** while the owning visit reads the SAME id at quantity 1. One of them backs an
> **already-issued invoice** (045-NU #2658 = $481.41 = exactly its "qty-0" pair).
> **Only 2 of 14 are true orphans** (045-NU ids `215806562` $465 + `215806563` $9.99 — linked to no
> visit and no invoice; a superseded price revision).

Deleting "the qty-0 lines" wholesale would have stripped line items off live visits, including an
invoiced one. Migration 18g's header has been amended with a correction note.

## 2. The Jobber line-item model (schema-verified, live-confirmed)

- **There is no `VisitLineItem` type.** `Visit.lineItems` returns `JobLineItemConnection` — visit lines
  and job lines are the **same shared `JobLineItem` objects**; `job.lineItems` = the union of template
  lines + every per-visit override line. (Schema introspection @ `2026-04-16`; confirmed empirically —
  zero visit-only ids across 13 probed jobs.)
- **`quantity` is context-dependent.** The same id reads `0` in `job.lineItems` and `1` in the owning
  visit's `lineItems`. qty-0 at job scope = "contributes 0 at template level", a **first-class modeled
  state** (`VisitLineItemQuantityFilter.ALL` = "including those with zero quantity"). The Jobber UI's
  *"Quantity varies on Jul 13"* annotation is this exact mechanism.
- **`visitCreate` auto-inherits the job's template lines** onto every new visit (Help Center, and no
  suppression flag exists — `VisitCreateAttributes` has only title/instructions/overrideOrder/schedule).
- **`visitDeleteLineItems` unlinks; `jobDeleteLineItems` destroys** (only the latter returns
  `deletedLineItems`). The unlinked object survives on the job — the "residue" operator.
- **`jobEditLineItems` exists** (edit in place, partial updates) — no delete+recreate needed to fix a
  quantity/name.
- **Invoices are denormalized**: `InvoiceLineItem` keeps its own name/qty/price with a NULLABLE
  `jobLineItem` back-link — historical invoice AMOUNTS cannot change no matter what happens to job
  lines. (Whether `jobDeleteLineItems` refuses or null-links on an invoiced line is undocumented —
  settled by the gated canary, §6 Gate B.)
- **VISIT_BASED invoices read the completed VISITS' lines**; job lines reach invoices only through
  visits. FIXED_PRICE inverts it (why the 031-KRU strip exists and why VISIT_BASED was financially
  unharmed).

## 3. Why Mila shows the 02 line twice (Fred's question, answered)

1. Our cron creates the SA visit in our DB → trigger → `jobber-push-visit` → `visitCreate`. Jobber
   auto-links the job's priced template lines to the new visit. **Pure cron visits stop here — clean**
   (`syncVisitLineItems` early-returns when our DB has no visit-scoped rows; all 5 healthy control jobs
   confirm: every visit references the same template ids, no extra objects, ever).
2. But when a visit **has visit-scoped rows in our DB** — Calendar-created visits (the create RPC picks
   services at **$0**: `quantity 1, unit_price 0`), drawer service edits, or B2 freeze-on-completion —
   the push runs `visitCreateLineItems` (mints NEW shared objects, at OUR price = usually $0) then
   `visitDeleteLineItems` (unlinks the inherited priced copies).
3. Result on the job screen: the priced template (qty 1) **plus** the visit's $0 override line rendered
   at qty 0 → "the same line twice". Mila's second `02` = the 07-13 visit's override line (id
   `218163348`, $0, linked, qty 1 on that visit). The "Drainnage" spelling on the duplicates is the
   Calendar picker's old catalog title — our own pushed rows, fingerprint-confirmed.
4. Repeat pushes strand more: the `*/3` stale re-driver and the drift HEAL have **always included the
   `lineitems` group since 2026-07-09** (`fn_request_jobber_push_safe_groups`), so re-drives re-run the
   create-then-unlink cycle with no human edit. 99900797 shows one extra line per pushed visit.

**Affected: 8 jobs** (99900583, 99900631, 99900635, 99900667, 99900670, 99900785, 99900797, 99900837)
— all VISIT_BASED RECURRING SA jobs with ≥1 pushed lined visit. ~70 jobs have lined visits eligible to
join them on the next `lineitems` push. Also 20 legacy qty-0 rows in our DB on 14 archived jobs
(2026-04-29 baseline import; DB-only, inert).

## 4. Real risks found (ranked) — the cosmetic duplicate is the LEAST of them

1. **$0-billing risk (live).** A pushed visit's lines REPLACE the inherited priced template with our
   $0 rows. 99900670's ONLY remaining Jobber visit rides a $0 line while the priced templates ($300+$3)
   are linked to NO visit — a VISIT_BASED invoice built from that visit bills **$0**. Root cause:
   `create_calendar_visit` hardcodes `unit_price=0`; `edit_calendar_visit` defaults to 0.
2. **Mirror lies.** Our DB coerces Jobber's qty 0 → 1 (`Number(n.quantity)||1`, `reconcile_jobs.js` L65
   + `sync_job_line_items.js` L37), so 045-NU shows $956.40 of phantom template value and no DB query
   can see the real state.
3. **Residue feedback loops.** `ops.client_service_options` (Calendar picker), `ops.v_calendar_visit`
   fallbacks, B2 freeze, and `fn_visit_requires_derm` all aggregate job-scope lines **without a qty>0
   filter** → duplicate picker options (045-NU offers `01` twice: $465 and $0), residue re-frozen onto
   newly completed visits, and a latent DERM monotonic-flag contamination class.
4. **100-line-item cap.** Every override push adds a permanent object to the job's collection (cap:
   100/job, documented). HEAL-storm churn marches toward the cap, where `visitCreateLineItems` starts
   failing — a push outage, per client.
5. **Unprobed cancel/skip class.** Nothing handles a deleted visit's linked lines (`visitDelete` path).
   If Jobber orphans rather than cascades them, every cancel/skip of a lined visit strands a batch.
   Read-only probe settles it (§6 Step 2).
6. **Cosmetic duplicates** on the 8 job screens — what was actually noticed.

## 5. What "clean" can mean (expectation to set)

Jobber ALWAYS renders a per-visit override line at qty-0 on the job screen ("visits that vary") — that
is the billing mechanism, not residue. Achievable end state: **zero orphans, zero $0-duplicate
overrides, zero accumulation** — i.e. un-edited visits ride the priced template refs (like the 5
healthy controls) and only genuinely-different visits carry an override. Literally-zero qty-0 rows is
impossible while per-visit overrides exist.

## 6. The judged plan (3 designs adversarially attacked → composite)

Full proposals + attacks in the workflow output. Composite recommendation:

**Ships without approval (no Jobber deletes, no visible change):**
- **Step 1 — mirror truth + consumer hardening (DB-only):** drop the `||1` coercion (both writers, +
  select `id`), and add `qty>0` filters to `ops.client_service_options`, `ops.v_calendar_visit`
  fallback legs, B2 freeze's template copy, `fn_visit_requires_derm` job leg. Kills risks #2/#3 and the
  picker's $0 duplicates.
- **Step 2 — read-only probe of skipped/cancelled lined visits:** settles the cancel/skip class (risk
  #5) with zero mutations.
- **Step 3 — gate the HEAL channel (SQL-only):** re-drives for already-confirmed visits send
  `['schedule','title']` only; full groups stay for never-confirmed INSERT retries. Removes the
  automatic strand-birth channel (9 of 11 known birth events).
- **Step 4 — birth-side sweep in LOG MODE:** `sweepStrandedJobLines` in `jobber-push-visit` — after
  each line sync, candidates = ids it JUST unlinked that are qty-0 AND linked to no visit AND have no
  invoice back-ref; log-only until gated. `stripInheritedLineItemsFixedPrice` stays byte-identical.
- **Step 6 — cleanup script, dry-run + weekly tripwire:** expected output exactly 2 deletable ids
  (`215806562`/`215806563`); any deviation = new finding, stop.

**Fred gates:**
- **Gate A:** flip the sweep to delete mode (after 48h clean logs on a 112-YA test visit).
- **Gate B:** one-time cleanup — canary `215806563` ($9.99 orphan) first; it doubles as the live test
  of `jobDeleteLineItems`' undocumented invoice constraints. Then `215806562`. That's ALL that is
  deletable today.
- **Gate C (each separately):** (a) **catalog prices in `create_calendar_visit`** — the forward fix for
  the $0-billing class and the only way picks become template-equivalent (visible product change);
  (b) repair of existing linked $0 overrides on PENDING visits (completed ones are untouchable);
  (c) cosmetic cleanup of the 14 archived legacy jobs; (d) dump-schedule go-live line strategy vs the
  100-cap; (e) `jobEditLineItems`-based edit-in-place reconciler — only if the tripwire shows the
  narrow sweep insufficient.

## 7. Corrections this audit makes to earlier statements

- "The typo'd lines are dead duplicates; the right move is removing them" (session, pre-audit) —
  **wrong**: 12/14 are live visit lines; only 2 are deletable. 18g's header is amended.
- "reconcile skips nothing" — it skips archived jobs (065-TCE's mirror frozen at 07-14).
- The '20 qty-0 DB rows = the 8 jobs' residue' conflation — the DB-20 are legacy archived-job imports;
  the 8 jobs' Jobber residue was invisible in our DB because of the `||1` coercion.

**Standing rule going forward: NEVER delete a qty-0 job-scope line by quantity alone.** The predicate
is qty-0 **AND linked to no visit (quantityFilter:ALL, paginated to exhaustion) AND no invoice
back-ref** — and in automated paths, only ids the same execution just unlinked.

---

## 8. Addendum (same night) — provenance of the 9 birth visits (Fred: "was it from smoke tests?")

Checked against `audit.logs` (visits is audited; actor = JWT email; `record_pk` is jsonb — filter on
`new_row->>'id'`, not `record_pk`):

| Visit | Client | Created | By | How |
|---|---|---|---|---|
| 7050 | 142-57 | 07-03 14:29Z | `contact@unclogme.com` | Calendar Create Visit |
| 7064 | 064-TCE | 07-08 14:40Z | `contact@unclogme.com` | Calendar Create Visit |
| 7083 | 152-DAV | 07-09 20:43Z | `contact@unclogme.com` | Calendar Create Visit |
| 7086–7089 | 043-MIL, 186-PV, 014-JOY, 065-TCE | 07-10 20:31–20:48Z | `contact@unclogme.com` | **batch of 4 in 17 min**, all scheduled for Mon 07-13 |
| 7103 | 152-DAV | 07-14 18:21Z | `contact@unclogme.com` | Calendar Create Visit |
| 6054 | 045-NU | 06-24 (cron) | — | services edited later, see below |

**NOT smoke tests — 8 of 9 are real office usage**: the office account creating extra/replacement SA
visits through the Calendar (visibly a human batching the following Monday's route on Thursday evening).
Their $0 line rows were written at the exact second of visit creation = the Create-Visit RPC's picks.

**The exception, where Fred's hypothesis IS right: 045-NU.** Its two `line_items_rev` bumps on the cron
visit 6054 were (1) `fred@ayache.com` via visit-calendar 06-25 22:38Z — the day the drawer services
editor shipped — and (2) an `app_source='sql'` write 2 min later (a Claude session). That is the
test-era trace, and it's why 045-NU alone has PRICED residue (edit RPC falls back to catalog prices)
and the fleet's only 2 true orphans (a superseded price revision from that editing).

**Consequence for Gate C, sharpened by Fred's stated intent** (*"the idea is to have always the same
Line Items on the visits of the SA"* — VISIT_BASED: the visit's lines ARE the bill): in every one of
the 8 office cases the picks equalled the job's own services. The cleanest forward fix is therefore
**template-equivalence, not just catalog prices**: a Calendar-created SA visit whose picks match the
job's services should write NO visit-scoped override rows at all — Jobber then auto-inherits the priced
template and the visit is indistinguishable from a cron visit (the healthy-control state). Overrides
remain only for deliberate service differences, at real prices, never $0.
