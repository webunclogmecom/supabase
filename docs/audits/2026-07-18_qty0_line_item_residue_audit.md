# Audit — the "qty-0 duplicate line items" on SA jobs are NOT what they looked like

> **⚠ READ §10 (CORRECTIONS) BEFORE ACTING ON ANYTHING BELOW.** This document evolved across five
> addenda in one night; an adversarial fact-check (2026-07-19) verified 65 claims OK but found the
> one-line survival rule WRONG as written, several tallies miscounted, and terminology drift in the
> later sections that could lead a reader back to the dangerous pre-audit "delete the qty-0 lines"
> conclusion. §10 states the corrected rules and supersedes conflicting text everywhere else.

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

## 9. Addendum 2 — LIVE REPRODUCTION on 112-YA (Fred: "do tests before doing changes")

Full protocol executed 2026-07-19 03:15–03:30 ET on the designated test client's SA job `11100534`
(Jobber `146650142`; DB said archived — STALE, Jobber said `action_required`; mirror corrected).
Baseline: 3 priced template lines ($1/$2/$30), 0 visits, 0 invoices. Evidence JSONs:
`phase0_baseline` → `phase8_final_state` in the session scratchpad. Every mutation on the test
client only; everything reverted; **production code untouched**.

| Phase | Action (real flow) | Result |
|---|---|---|
| 2 | `create_calendar_visit` pick=01 → push | **REPRODUCED — and WORSE than predicted:** our $0 line created + linked; the 3 priced templates were **DESTROYED, not stranded** (unlinked with no other referencing visit → Jobber removes the object). Job screen lost its agreed services. |
| 3 | services edit [01]→[01,05] → push | Batch replaced; the previous $0 line **destroyed** (same rule). Identical-set edit = no-op (no rev bump — good). |
| 4 | **Fix simulation**: visit with NO override rows (INSERT, `source='visit-calendar'`) → push | **CLEAN: pure inherit, zero new objects, zero destruction.** Also learned: `jobCreateLineItems` auto-links new job lines onto existing future visits, and `visitCreate` inherits the **entire current collection — including other visits' $0 override objects** (cross-contamination channel). |
| 5A | HEAL simulation, **gated shape** `['schedule','title']` (direct edge-fn POST) | `did:["schedule","title"]`, **zero line mutations**. The Step-3 gate is verified safe. |
| 5B | HEAL simulation, **current shape** `[...,'lineitems']` | Job 5→7 objects: new $0 pair rendered **qty-0 at job scope / qty-1 on the visit** — the EXACT fingerprint of the 8 affected jobs (043-MIL match). Accumulation per re-push proven. |
| 6a | `ops.delete_calendar_visit` on the lined visit | **CANCEL CLASS IS REAL: `visitDelete` STRANDS** — the visit's pair survived as true qty-0 orphans. |
| 6b | delete the fix-sim visit | All 7 objects survive; template-quantity lines keep qty 1 (visitDelete does NOT zero templates). |
| 7 | **`jobDeleteLineItems` canary** (1 orphan, then 3) | Clean: `userErrors` empty, `deletedLineItems` returned, templates untouched. Gate B's mechanics de-risked. |
| 8 | Restore + verify | Final state == baseline (3 lines $1/$2/$30, 0 visits, 0 invoices, `action_required`; template **ids differ** — originals destroyed in Phase 2, re-created via `jobCreateLineItems`). DB: both test visits soft-deleted, ESLs removed, sync confirmed, mirror truthful. |

### Round 2 — same protocol on REAL clients (Fred: "Do the test again with other clients now")

Run 2026-07-19 ~04:00 ET on TWO real jobs, chosen to complete the generalization matrix, each gated by
the precondition *every qty>0 line referenced by ≥1 other visit* (no template-destruction risk) and an
abort-on-any-unexpected-state script (`r2_run.js`; evidence `r2_baseline_*` / `r2_*_after_*` /
`r2_*_final.json`):

| | HEALTHY — 110-CLA `99900746` | AFFECTED — 064-TCE `99900667` |
|---|---|---|
| Baseline | 1 template ($1,180, refs=4 visits), 1 invoice | 2 templates + the existing dupe `217635383` (protected id), 2 invoices |
| Create+push (office flow) | **Dupe born:** `219427848` qty-0/$0 beside the template | **Dupe born:** `219427892` — the job briefly showed the `01` line **three times** (1 priced + 2 qty-0), the exact Mila-style multiplication |
| Template survival | **INTACT (LOST: none)** — survival-via-other-refs CONFIRMED on a real job | INTACT; existing dupe untouched throughout |
| Delete visit (real flow) | Born line **STRANDED** as true orphan | Same |
| Cleanup (`jobDeleteLineItems` on our id only) | OK | OK |
| Final vs baseline | **BYTE-IDENTICAL** (same ids; 1 line, 4 visits, 1 invoice) | **BYTE-IDENTICAL** (3 lines, 3 visits, 2 invoices) |
| DB | visit 7132 soft-deleted, ESL 0 | visit 7133 soft-deleted, ESL 0 |

Score across all three arenas (112-YA + healthy + affected): **cause reproduced 3/3 · cancel-class
strand 3/3 · `jobDeleteLineItems` clean 5/5 deletes · template survival = exactly predicted by the
reference rule (survives iff another visit references it).** The causal claim and every fix-relevant
semantic are now verified on the test client, a healthy production job, and an affected production job.

### Round 3 — two more clients (Fred: "test again with 2 new more clients")

Run 2026-07-19 ~04:30 ET, same gated protocol (`r3_run.js`), adding the **multi-pick** case:

| | HEALTHY multi-service — 191-TEN `99900846` | AFFECTED — 014-JOY `99900583` |
|---|---|---|
| Baseline | 3 templates (fee $13.77 / 08 $120 / 01 $270), each refs=5 visits, 1 invoice | template 01 $375 (refs=3) + existing dupe `218166346` (protected), 0 invoices |
| Create+push | **Picks [01, 08] → EXACTLY 2 born objects** (`219446643/44`, one $0 line per pick — matches the wild 2-orphan cases 142-57/186-PV 1:1) | 1 born object `219446681` — job briefly showed `01` ×3 (Mila multiplication again) |
| Templates / protected | All intact; invoice untouched | Intact; existing dupe untouched |
| Cancel class | Both born lines stranded as true orphans | Stranded |
| Cleanup | `jobDeleteLineItems` OK (2) | OK (1) |
| Final vs baseline | **BYTE-IDENTICAL** (3 lines, 5 visits, 1 invoice) | **BYTE-IDENTICAL** (2 lines, 4 visits, 0 invoices) |
| DB | visit 7134 soft-deleted, ESL 0 | visit 7135 soft-deleted, ESL 0 |

**Cumulative across all five arenas** (112-YA, 110-CLA, 064-TCE, 191-TEN, 014-JOY):
cause reproduced **5/5** · born objects scale 1:1 with picks · cancel-class strand **5/5** ·
`jobDeleteLineItems` **8/8** clean deletes (incl. next to real invoices) · templates survive
**4/4** where another visit references them, destroyed only where nothing does (112-YA).

**Model updates this forces (supersedes §2 where different):**
- `visitDeleteLineItems` on a line with **no remaining visit refs → the object is REMOVED from the job**
  — including original priced templates. Destruction, not qty-0 stranding.
- `visitDelete` (cancel/skip/soft-delete) → the visit's exclusive lines **strand** as qty-0 orphans.
- Both end states (vanish vs strand) are now reproduced; which one you get depends on the operator.
- **NEW TOP RISK — template destruction:** a Calendar-created (lined) visit pushed onto an SA job whose
  priced template is referenced by **no other in-window visit** (brand-new jobs, or jobs whose visits are
  all Calendar-created) wipes the job's agreed services; the next poll then wipes our mirror, and the
  job-line-driven visit-generation predicate goes blind for that client. The 8 affected jobs escaped this
  only because cron visits referenced their templates.
- Fingerprint match confirmed on the affected client's data (043-MIL): its dupe = linked-to-its-visit,
  qty-0-at-job, $0, catalog-title — byte-for-byte the Phase-5B signature.

**Consequence for Gate C, sharpened by Fred's stated intent** (*"the idea is to have always the same
Line Items on the visits of the SA"* — VISIT_BASED: the visit's lines ARE the bill): in every one of
the 8 office cases the picks equalled the job's own services. The cleanest forward fix is therefore
**template-equivalence, not just catalog prices**: a Calendar-created SA visit whose picks match the
job's services should write NO visit-scoped override rows at all — Jobber then auto-inherits the priced
template and the visit is indistinguishable from a cron visit (the healthy-control state). Overrides
remain only for deliberate service differences, at real prices, never $0.

---

## 10. CORRECTIONS (2026-07-19 adversarial fact-check — supersedes conflicting text above)

A dedicated fact-check agent re-read every claim in §1–§9 against the archived evidence JSONs:
**65 claims verified OK**; the following are corrected. A final-state verification also confirmed all
5 test arenas RESTORED-CLEAN in Jobber id-by-id, zero DB test leftovers, the */3 re-push predicate
returning 0 rows table-wide, and the fleet qty-0 census byte-identical to the pre-test baseline.

### 10.1 THE SURVIVAL RULE — corrected (the single most important fix)

The Round-2 one-liner *"a line survives iff another visit references it"* is **wrong as written**
(the "only if" half is falsified by every strand observation and by 99900670's ref-less-but-alive
templates). The correct, operator- and time-scoped rules:

1. **`visitDeleteLineItems` (unlink):** the object is **destroyed iff no other visit references it AT
   THAT MOMENT** — confirmed July 2026, 5 arenas.
2. **`visitDelete` (cancel/skip/delete the visit):** the visit's exclusive lines **strand as qty-0
   orphans REGARDLESS of references** — 5/5.
3. **Lines can outlive losing all references** (99900670's templates; every test strand).

**Known counterexample we cannot reproduce:** 045-NU's orphans `215806562/63` survived a June-25
unlink from a still-existing visit with no known co-reference — rule 1 is confirmed **for July-2026
behavior only**. Consequence: the birth-side sweep may legitimately find candidates the July tests
say cannot exist. **Treat any future sweep hit OR zero-hit as informative, never anomalous.**

### 10.2 Factual corrections

- **§4.3 picker example:** 045-NU's picker shows code 01 **three times, all at $465** (1 real + 2
  priced mirrors) — not "twice: $465 and $0". The $0-variant example is **186-PV**.
- **`jobDeleteLineItems` tallies:** evidence supports **4** deletes on 112-YA (phase 7: 1+3), **2** in
  round 2, **3** in round 3 = **9/9 clean**, not "5/5"/"8/8" as stated in the round scorelines.
- **"Byte-identical" restores** were **content-identical** (line ids/qty/prices + visit and invoice
  counts all match; the final JSONs simply omit two metadata keys the baselines carried).
- **142-57 / 186-PV are LINKED live overrides, not "orphan cases"** — §3.4's "strand more" phrasing
  and the Round-3 comparison drift back into pre-§1 terminology. Fleet-wide, exactly **2** true
  orphans exist (045-NU). §4's "permanent accumulation" is superseded: accumulation is
  operator-scoped; unlink can destroy.
- **"9 of 11 birth events via HEAL" is approximate** — the underlying evidence file's own counts
  disagree (10 vs 11) and per-event proof was not archived.
- **"a superseded price revision" (045-NU orphans)** is a hypothesis, not established fact.
- **Single-observation semantics** (observed once, on 112-YA only, plausible but not multi-arena
  confirmed): identical-set edit no-ops; `jobCreateLineItems` auto-links onto existing future visits;
  `visitCreate` inherits the whole current collection; `visitDelete` keeps template quantities.
- **Legacy DB rows:** 19 from the 2026-04-29 baseline + 1 from 2026-05-21 (223-CHA), not 20 from one date.

### 10.3 Untested outcomes (honest register — none of these were exercised)

Ranked by risk: **FIXED_PRICE lined-visit sequence** (code order suggests the sync could wipe a
one-visit FP job's base lines BEFORE the strip runs — the 031-KRU class; test only on a throwaway
job); **completion + B2-freeze + `lineitems` re-push** (the only channel minting PRICED residue on
completed visits — the 045-NU flavor; freeze has no qty>0 filter); **the 60-day PROMOTE path** (the
one automatic birth channel the HEAL gate does NOT close — L460 syncs unconditionally on CREATE);
**pagination past `first:50`** (failure mode flips to additive double-billing on the largest jobs —
census needed); **$0 invoice generation** (inferred from invoice #2658's denormalization; safely
closable only by a human draft-and-discard in the Jobber UI); **NULL-job_id lined visits**;
**racing pushes**; and — **deliberately reserved** — `jobDeleteLineItems` on an invoiced line: the
$9.99 canary (`215806563`) IS that test, gated behind Fred's Gate B. Full test protocols for each
are in the 2026-07-19 final-audit workflow output (P1–P12).
