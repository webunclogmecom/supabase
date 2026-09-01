# Pulling a pre-convention visit into the Admin Review queue

*Design, 2026-09-01. Fred: "There is a thing with the 117-BH client that have a visit on march with a
job that is not compliant to the SC or SA, do a brainstorm about how is the best practice to make it
show in the Admin Review."*

## The case

**V-1542, 117-BH, 2026-03-25.** Completed, **9 photos**, **`derm_required = true`**, manifest work.
It is absent from the Admin Review queue because its job (**83, "Grease Trap Pumping & Hydrojet
Cleaning", archived**) predates the Service Agreement / Service Call naming convention, and the queue
was scoped to that convention earlier the same day (`2026-09-01_1700`, `job_is_sa_sc`).

The client's other visit, V-6311 on job 1514 ("Service Agreement - Grease Trap Pumping..."), is in
the queue. So one visit of one client is reviewable and the other is not, for a reason that has
nothing to do with the work.

## What the exclusion is, settled with Fred

**"The line is a historic change of before/after naming convention."** It marks an era, not quality.
That matters because the excluded population is not junk:

| completed visits excluded by the SA/SC rule | 660 |
|---|---|
| with photos | 563 |
| `derm_required = true` | 431 |
| **both DERM-required and photographed** | **413** |
| with a filed manifest link | 479 |
| carrying the `[OLD]` marker | 89 |

Spread over **276 jobs**, of which **145** carry a DERM-required photographed visit.

Three options were put to Fred: replace the rule with a signal of real work; hold the line and treat
each case individually; or hold the line and add a deliberate escape hatch. **He chose the escape
hatch**, operated **by him from inside Admin Review**, with **checkbox multi-select and one reason
per batch**.

🛑 **Renaming the job in Jobber is NOT the answer here, and that is a real distinction from the two
renames done earlier today.** Jobs 1771 ("Service") and 1839 ("Emergency call") were *vague*, so
retitling them "Service Call" made the record more accurate. Job 83 is titled "Grease Trap Pumping &
Hydrojet Cleaning", which is *true*. Jobber is customer-facing, so relabelling it would make the
record worse to satisfy a query, and it would not scale to 145 jobs.

## Data

**`public.review_scope_inclusions`**

| column | notes |
|---|---|
| `visit_id bigint PRIMARY KEY` | FK to `public.visits(id)`. The PK is what makes re-inclusion idempotent instead of duplicating. |
| `reason text NOT NULL` | CHECK that it is non-empty after stripping the whole whitespace class, not just ASCII space. `btrim()` alone strips SPACE only, so a TAB or NBSP reason defeats the guard: the same hole `fn_requeue_derm_portal` had to close. |
| `included_at timestamptz NOT NULL DEFAULT now()` | |
| `included_by text` | The human, from the JWT. |

⚠ **Read `request.jwt.claims`, PLURAL.** The singular `request.jwt.claim.email` is never set by
PostgREST, and this estate has already shipped that bug twice (`audit.logs.changed_by`, which has
been NULL on all 54,756 rows, and `derm.band_set_by`, which held no email at all). Reuse the
`derm._actor()` pattern rather than writing a third copy.

**Rule 8: this table OPTS IN to `audit.logs` triggers.** `derm_portal_requeue` is the obvious
precedent for opting out, on the grounds that such a table *is* its own audit trail. That reasoning
holds only because it is append-only. This table has human-editable fields, so the default for
human-editable tables applies.

**The undo is deliberately NOT built.** It was speculative. A wrong inclusion costs nothing worse
than a reviewer looking at a real visit, and re-adding a `removed_at` column later is cheap. Cutting
it now is YAGNI, not an oversight.

## View

`public.visits_with_review` gains two appended columns. Appending keeps this a `CREATE OR REPLACE`
rather than a drop and recreate, which would discard grants.

- **`in_review_scope boolean`** = `job_is_sa_sc OR EXISTS(an inclusion row)`. **This is what the queue
  filters on**, replacing `job_is_sa_sc`.
- **`scope_source text`** = `convention` or `manual`. **`convention` wins when both are true.** That
  is not hypothetical: the RPC refuses to include a visit already in scope, so the only way to reach
  the overlap is for a job to become compliant AFTER a manual inclusion, which is exactly what
  happens if someone renames it in Jobber the way jobs 1771 and 1839 were renamed today. Once the job
  qualifies on its own, the inclusion is no longer what is carrying it, and the badge should stop
  claiming otherwise. The inclusion row is left in place as the record that the decision was made.

🛑 **`job_is_sa_sc` stays and keeps its current meaning.** It is a FACT about the job (does its title
follow the convention). `in_review_scope` is a POLICY (should the queue show this). Collapsing them
would mean a future policy change silently rewrites the historical fact, and the modal could no
longer explain *why* a visit is out of scope. Same separation as `our_frequency_days` versus
`frequency_source` shipped this morning.

Both are `COALESCE`d so they are never NULL: an unknown job is not in scope.

## Picker view

**`public.v_review_scope_picker`**, one row per completed visit, carrying exactly what the modal
renders: `client_id`, `client_code`, `client_name`, `visit_id`, `visit_date`, `job_id`, `job_title`,
`job_status`, `photo_count`, `derm_required`, `in_review_scope`, `scope_source`.

It exists so the modal does not have to join `jobs` and count `photo_links` from the browser, and so
the "why is this out of scope" answer comes from one place. `authenticated` gets SELECT; nothing else.

## RPC

**`public.include_visits_in_review(p_visit_ids bigint[], p_reason text)`**, SECURITY DEFINER with a
pinned `search_path`, EXECUTE to `authenticated`.

Per-visit guards, each of which refuses rather than silently skipping:

- the visit exists and `deleted_at IS NULL`
- `visit_status = 'completed'` (the queue shows only completed; including anything else is inert and
  would look like a broken feature)
- **it is not already in scope** 🛑 An inclusion that changes nothing while reporting success is the
  "operator believes they acted" failure `fn_requeue_derm_portal` exists to prevent.
- the reason is present after the whitespace-class strip

**It is partial, not all-or-nothing, and it returns the post-condition rather than "ok".** One
already-in-scope visit in a batch of ten must not abort the other nine. The return is one entry per
requested visit: `{visit_id, included, skipped_because, in_scope_now}`. The caller renders that, so a
partially applied batch is visible instead of assumed.

## The modal

Triggered from a control beside the queue filters.

1. **Search** by client code or name.
2. **Result: that client's completed visits, GROUPED BY JOB.** Each group headed by job title, job
   status, and whether that job follows the convention. Each visit shows date, photo count and
   `derm_required`.
3. **Show every visit, not only the excluded ones.** This is what makes the grouping earn its place.
   For 117-BH the operator sees job 83 (pre-convention, V-1542 out of scope, includable) directly
   above job 1514 (in scope, V-6311 already queued), so the reason one is missing is legible rather
   than mysterious.
4. **Checkbox multi-select across groups, one reason for the batch**, then Include. The queue
   refetches.

Sizing, measured so the modal does not need paging it will never use: **248 clients with completed
visits, median 3 visits each, p90 of 9, worst case 31 across at most 9 jobs.** 198 clients hold at
least one out-of-scope visit; the largest single-client backlog is 15.

**Queue badge.** An included visit renders an "Included manually" chip. A pre-convention visit that
blends silently into current work is the most likely thing to confuse whoever picks it up.

## Verification

- **The RPC refuses an already-in-scope visit.** This is the control proving refusal works at all; a
  batch that reports 10 successes tells you nothing if nothing can ever fail.
- Include, then confirm `in_review_scope` and `scope_source='manual'` flip for exactly that visit and
  the queue count moves by exactly the number included.
- A partial batch (one valid, one already in scope, one non-completed) returns three distinct
  outcomes rather than one verdict.
- **`SET LOCAL ROLE authenticated`** and read the view and picker, and execute the RPC. The
  view/function privilege asymmetry has broken five things in this estate; reasoning about it is not
  evidence.
- **Read `relacl` on the new table AFTER creation** and compare against a sibling. `CREATE TABLE`
  hands out grants before any GRANT statement runs, which is how `public.job_frequency_changes`
  shipped with `authenticated` holding TRUNCATE.
- App side: verify against the **live published bundle**, not the Lovable panel.

## Out of scope

No Jobber writes. No change to the SA/SC rule itself. No automatic admission of DERM-required
photographed visits (Fred chose deliberate over automatic). No bulk "include everything for this
client" button beyond ticking the boxes. No undo.

## Open question for later

413 excluded visits are DERM-required with photos, and this escape hatch is a per-case answer to a
population-sized fact. If the hatch gets used dozens of times, that is evidence the line is in the
wrong place and the question should be reopened as a rule change rather than more clicking. Worth
revisiting after a month of use, not now.
