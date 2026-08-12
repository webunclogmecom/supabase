# 2026-08-12 — the "duplicate Service Call jobs", reviewed and mostly refuted

Fred, in order:

1. *"make sure all active and recurrent clients have their SC job correctly set and opened and to
   not be 2 of them each client only needs one SC without any line item, remember the SC only have
   line items on their visits not on the settings."*
2. *"fix the 3 job statuses and remove the duplicate SC jobs"*
3. (after the DB-side removal was refused, because Jobber held them all open)
   *"close the duplicate SC jobs in jobber"*

**Outcome: one job closed in Jobber. Six kept. Four of the six are open questions for Fred, not
data defects.** No DB row was deleted at any point.

---

## What was actually closed

| | |
|---|---|
| Jobber job | **#99901049** (`ourjob` 1807), 112-YA Yan's Restaurant |
| was | `action_required`, property *1745 Cleveland Road*, **0 visits**, 0 line items |
| now | `archived` |
| control | #99900535 re-read after the mutation: still `upcoming`, still 7 visits |

It is the only one of the seven that pointed at a property **already served by another open SC**
(#99900535, same client, same property, same title). `DESTROY_ALL` was provably inert: Jobber
reported 0 visits in the pre-flight read taken seconds before the mutation, and our side holds 0
visits, 0 invoices, 0 line items and 0 `ops.visit_requests` against job 1807. `jobReopen` exists,
so it is reversible.

🛑 **DO NOT REPORT THIS AS "THE DUPLICATE SC PROBLEM IS FIXED".** 112-YA is Fred's **test client**,
and this job carries `notes = 'testing this feature'`, was INSERTed by `app_source='client-app'`
on 2026-07-31 17:27 and last edited 2026-08-06. It is test cleanup on the test account. **Zero
paying clients were remediated by this action.**

---

## 🛑 The other six are NOT duplicates, and the reason is the property

This is the **fourth** "duplicate" finding reversed in a single day by the same check. Pulled live
from the Jobber API, the seven open SC jobs sit at **six different service addresses**:

| client | job | Jobber # | property | visits | verdict |
|---|---|---|---|---|---|
| 112-YA | 766 | 99900535 | 1745 Cleveland Rd | 7 (1 **upcoming 08-16**) | keep |
| 112-YA | 1807 | 99901049 | 1745 Cleveland Rd ← **same** | 0 | **closed** |
| 128-MF | 1683 | 99900936 | 301 Arthur Godfrey Rd | 0 | keep |
| 128-MF | 1791 | 99901035 | 1747 Alton Rd | 1 completed | ask Fred |
| 275-MLP | 1280 | 10001049 | 47 NW 49th St | 1 completed | ask Fred |
| 275-MLP | 1790 | 99901034 | **341** NW 43rd Ave | 0 | keep |
| 275-MLP | 1836 | 99901055 | 160 NW 45th St | 1 completed | ask Fred |

275-MLP (Milas LP) is a **property manager with three sites**; 128-MF has two. A call at a second
site needs its own job, and **295 of the 297 jobs where the property is visible serve exactly one
property.** Job 1790 is the clincher: it is titled `"Service call - 341"` and its property is
literally *named* **`341`**. A human named that job after its site.

⚠ **The apparent counterexamples are not counterexamples.** 242-WYN (7 properties) and BHRE
Property Management (4) hold one SC each — but 4 of those 5 multi-site clients have never had a
single visit on that SC, so they have never faced a second-site call at all. Absence of a second
job is absence of a second call, not evidence of a one-per-client rule.

**⇒ The rule, for the fourth time today: before deleting anything as a duplicate, ask Jobber. If
Jobber has it, we are mirroring correctly and the fix belongs in Jobber, not here.**

### Left for Fred

Three of the six (1791, 1280, 1836) have their work **completed and already invoiced**, 0
incomplete visits. Closing them would destroy nothing and is normal Jobber lifecycle — 378 SC jobs
are already closed. But they are **finished jobs, not duplicates**, so closing them executes Fred's
words against a premise he now knows is false. That is a one-question business call, not a data fix.

1683 and 1790 are kept under **both** readings of the instruction: each is its client's only *empty*
SC, so it is the natural survivor if Fred wants one per client, and the site container if he wants
one per site.

---

## 🛑 Two measured gaps that silently disable checks this work depended on

### 1. Jobber holds an upcoming visit our mirror does not have

Job 766 has an **UPCOMING visit dated 2026-08-16** in Jobber. `public.visits` holds **zero rows
dated 2026-08-16** for 112-YA. Control in the same query: 748 alive fleet visits from 2026-08-08
onward, so the instrument works.

⚠ **This is NOT the documented test-client exclusion.** Both exclusion sets
(`webhook-jobber` `EXCLUDED_JOBBER_CLIENT_GIDS`, `sync-jobber-upcoming-visits`
`EXCLUDED_CLIENT_GIDS`) are `new Set<string>([])` — **empty**. 112-YA was un-excluded 2026-06-24 per
Fred. The surrounding comments still *name* 112-YA, which reads like a live exclusion and is not one.

⇒ **A pre-flight "does this job have visits?" check written against our own database returns a
false clean bill of health for exactly the job that must not be closed.** Every `jobClose` must
re-read visits **from Jobber** immediately before the mutation. That is what the script here did.

*(A reviewer reported this as "zero 112-YA visits on/after 2026-08-08, alive or soft-deleted". That
detail is wrong — there are 5, all soft-deleted `TEST-RLS do not service` rows dated 2026-09-15. The
substance stands: nothing on 08-16.)*

### 2. `public.line_items` cannot audit Fred's SC line-item rule at all

```
open Service Call jobs .................. 271
job-scoped line_items on them ..........   0
CONTROL job-scoped on open SA jobs .....  323   <- instrument works
total line_items rows .................. 6264
```

Jobber holds **49** job-scoped line items on job 766 alone, and 1 each on 1791/1280/1790/1836. We
mirror **none** of them, including for job 766 which is `upcoming` and therefore inside
`sync-jobber-job-drift`'s candidate predicate.

⇒ **Fred's rule — *"the SC only have line items on their visits not on the settings"* — CANNOT be
checked from our database.** A query answering "do any SC jobs carry job-scoped line items?" returns
0 for every client, forever, and that 0 is the mirror gap, not compliance. Every line-item fact in
this document came from the Jobber API for that reason.

*(766's 49 lines are all quantity 0. Per [`docs/audits/2026-07-18_qty0_line_item_residue_audit.md`](2026-07-18_qty0_line_item_residue_audit.md)
that is stranded per-visit-override residue from its 27 soft-deleted visits — **not** junk to delete.)*

### 3. 🛑 The root cause of the false "duplicate" reading: 50 open jobs had no `property_id`

This is the important one, because **it is what made real jobs look like duplicates.** Read from
our own database, 275-MLP's three open SC jobs all showed property = *(none)* — the exact signature
of a duplicate. Read from Jobber they sit at three different addresses.

```
open jobs missing property_id ....  50 / 451  (11%)
  open Service Call .............  41 / 271  (15%)
  open Service Agreement ........   6 / 176  (3%)   <- control
by month created:  Apr 0/25 (0%)  Jun 20/382 (5%)  Jul 27/38 (71%)  Aug 3/5 (60%)
```

⚠ **My first diagnosis was wrong and the data refuted it.** I attributed this to the property sweep
bug (no property to point at). Measured: all 50 carry a property in Jobber and **49 already had it
linked on our side.** The mechanism is *ordering* — `webhook-jobber:1105` reads
`if (propertyId) jobRow.property_id = propertyId`, so a job populated **before** its property exists
is **silently skipped** rather than erroring, and nothing re-populates it. The sweep bug widened the
window; the silent skip is the defect.

**Fixed the data** in [`2026-08-12_1550_backfill_job_property_id.sql`](../migrations/2026-08-12_1550_backfill_job_property_id.sql):
49 jobs linked, 0 cross-client, 0 billing rows, 1 remaining (job 1838, created 15:45 ET, self-heals
when the sweep links its property). A targeted one-column UPDATE, deliberately **not** a
`needs_populate` replay, which would have rewritten every field from stale raw and could have
reverted the three job statuses corrected at 14:20 today.

**⇒ NOT FIXED: the silent skip itself.** A job populated ahead of its property will still come out
NULL. That belongs in `handleJob`.

### 4. 166 clients have a NULL `client_code`

Noted, not investigated. It also broke a query in this very audit: grouping open SC jobs by
`client_code` collapsed every null-code client into one row reading *"6 open SC jobs"* for a client
that does not exist. **Group by `client_id`.**

---

## Procedure notes for the next person

- **`jobClose` takes `modifyIncompleteVisitsBy: DESTROY_ALL`** (required, no default). It destroys
  Jobber's incomplete visits. Completed visits survive. There is no `jobDelete`.
- The close ran as a **direct GraphQL mutation**, not through `save-client-job`, because that
  function authenticates with `auth.getUser()` on a real staff session token. Consequence: our poll
  records the change as `app_source='jobber'` with a NULL actor, so **this file is the only record of
  who did it and why.** `audit.logs.changed_by` has never been populated (see repo `CLAUDE.md`).
- The script asserted five guards before sending anything: GID resolved from `entity_source_links`
  rather than hand-copied, `jobNumber` equals the expected value, the number is **not** the live
  sibling's, the client name matches, and Jobber reports 0 visits. **One guard fired on the first
  run** (`jobNumber` returns as a *number*, not a string, so `!==` against a string literal refused a
  correct job). It failed toward safety, which is the right direction, and was fixed by coercion —
  worth remembering, because a guard that fails safe is one nobody re-checks.
- If a close needs undoing, **do it within 14 days**: `sync-jobber-job-drift`'s recovery arm is
  capped at `updated_at >= now() - 14 days`, after which a Jobber-side reopen never reaches
  `public.jobs`. Three jobs needed a hand-written repair for exactly that gap earlier today
  ([`2026-08-12_1420`](../migrations/2026-08-12_1420_resync_three_job_statuses_from_jobber.sql)).

## Recurrence

**4 of the last 40 SC jobs landed on a client that already had an open one** (275-MLP twice). This
cleanup is a one-shot against a live producer; the same shape returns in roughly two weeks unless
the booking habit changes. That is a process question for Fred, not a schema one.
