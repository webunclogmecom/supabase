# Admin Review queue scope + manual inclusions — as-built reference

*Shipped 2026-09-01, **policy rewritten 2026-09-09** (`2026-09-09_1600_admin_review_scope_open_jobs.sql`).
The durable DB-side contract for WHICH completed visits appear in the Admin
Review queue, and the deliberate escape hatch for pulling a pre-convention visit in (and taking it
back out). App-facing rules: `Building Apps/Admin Review/CLAUDE.md` ("THE QUEUE SCOPE"). Design:
[`../superpowers/specs/2026-09-01-admin-review-scope-inclusions-design.md`](../superpowers/specs/2026-09-01-admin-review-scope-inclusions-design.md).*

---

## 1. What the queue shows

The Admin Review queue is **all of history** (no date lower bound), filtered to **completed, in-scope**
visits:

```
.eq("visit_status","completed").eq("in_review_scope",true).lte("visit_date", today).limit(2000)
```

🛑 **The filter is `in_review_scope`, and that column is the ONLY place the rule exists.** Never
`job_is_sa_sc`, never a raw job-status test, never a title test - not in the view's consumers and not
in an app.

🛑 **THE POLICY WAS REWRITTEN ON 2026-09-09 AND THIS SECTION USED TO SAY THE OPPOSITE.** It read:
*"Fred's rule is about job era/type, not quality or open/closed: a closed or archived SA/SC job's
visits MUST stay reviewable so their photos can be classified and a Service Report can exist."* That
was Fred's rule on 2026-09-01 and he replaced it on 2026-09-09:

> *"I remember asking you to show only the visits at the admin review app that are a SC or SA job on
> their title. So what i want is actually a filter that only shows the visits from open jobs, and the
> `Include a past visit` button, let's you bypass that filter of any visit you select there."*

**`in_review_scope` is now three arms, ORed: the job is OPEN, OR work has already been done on the
visit, OR an active `review_scope_inclusions` row.** The kept sentence from the old rule is the
reason the second and third arms exist at all - a closed job's photos still need classifying, so the
work-started arm holds anything in progress and the include modal is the way back for the rest.

⚠ **The original symptom was NOT a job-status filter.** `visits_with_review` (`v_visits_live LEFT JOIN
visit_reviews`) has no job filter at all; what hid old visits was the queue's own **28-day window**.
Removing a "job-status filter" would have been a no-op (migration `2026-09-01_1700` header records
this). The real scoping is `job_is_sa_sc` (the era gate) widened by manual inclusions.

## 2. The columns on `public.visits_with_review`

| column | meaning |
|---|---|
| `job_is_sa_sc` | **FACT** about the job title: does it follow the modern convention (SA = `Service Agreement%`, SC = `Service Call`), else false; **never NULL**. Added `2026-09-01_1700`. **No longer the policy** - kept as the historical record of the naming era, and it is what lets the app explain why a visit is out of scope. |
| `job_is_open` | **FACT**, added `2026-09-09_1600`: `job_status NOT IN (archived, closed, destroyed)`. Column 39 of `visits_with_review`, column 14 of `v_review_scope_picker`. **An app must read this rather than testing `job_status` itself.** |
| `in_review_scope` | **POLICY** the queue filters on: `job_is_open` **OR** `review_work_started` **OR** an active `review_scope_inclusions` row (`removed_at IS NULL`). |
| `scope_source` | which arm carried it: `open_job`, `manual` or `work_started`, in that precedence. NULL for any out-of-scope visit. **`'convention'` no longer exists.** A deliberate act outranks a side effect, so `manual` beats `work_started`: otherwise the "Included manually" chip vanishes off a visit somebody has worked on. |
| `review_work_started` | true once real work exists for the visit — a `photo_classifications` row OR a `visit_reviews` decision (bonus/invoice/quality/`reviewed_at`). Drives the remove-friction (below). |

🛑 **Keep FACTS (`job_is_sa_sc`, `job_is_open`) and POLICY (`in_review_scope`) apart, and never
re-implement the rule in the app** (no title tests, no job-status tests). The separation is why the app
can explain WHY a visit is out of scope instead of listing orphans, and **it is what let the policy be
rewritten on 2026-09-09 without touching a single historical fact** - the migration asserts
`job_is_sa_sc` is byte-identical on every row.

⚠ **`in_review_scope` now depends on a MUTABLE, JOBBER-MASTERED column.** Under the old rule the
automatic arm was a job TITLE, which moves only on a rename. It is now `job_status`, which the `*/5`
poll rewrites: **closing or reopening a job in Jobber moves its visits out of and into this queue on
its own.** That is the intended behaviour, but it means queue membership is no longer stable, and a
manually included visit whose job reopens will read `open_job` (losing its chip and its Remove
control) until the job closes again.

## 3. `public.review_scope_inclusions` — the manual escape hatch

The deliberate, recorded way to pull a **pre-convention** visit into the queue without touching Jobber.
Fred's principle: the SA/SC naming line marks an **ERA, not quality**, so an exception is a recorded act,
not a rule change. (Renaming the job in Jobber is **deliberately rejected** when the title is already
true — job 83's title is accurate; relabelling it to satisfy a query would degrade Jobber and does not
scale: 276 jobs are excluded, 145 carrying a DERM-required photographed visit.)

| column | note |
|---|---|
| `visit_id` bigint | **PRIMARY KEY** (one inclusion row per visit) |
| `reason` text | **NOT NULL** — the RPC strips the whole whitespace class, not just ASCII space |
| `included_at` / `included_by` | when / who (GoTrue email) |
| `removed_at` / `removed_by` / `removed_reason` | **soft-removal** — a removed inclusion keeps its row; `in_review_scope` requires `removed_at IS NULL` |

- **Audited** (`audit_review_scope_inclusions` trigger) — it is cross-user state (an inclusion changes
  what other reviewers see), so it is opted into `audit.logs` per ADR 010.
- `authenticated` holds **SELECT only** — the app never writes this table directly; the two RPCs do.

## 4. The RPCs

- **`public.include_visits_in_review(p_visit_ids bigint[], p_reason text)`** — the ONLY writer of an
  inclusion. Reason required. **Partial by design**: each visit gets its own verdict, so the caller
  renders `results[]` rather than assuming success. Refuses a visit **already in scope** rather than
  reporting a no-op success.
  - 🛑 **Re-including a previously REMOVED visit is supported** (`2026-09-01_2000`): the RPC was a bare
    INSERT against a `visit_id` PK, so a soft-removed visit read out-of-scope, hit the INSERT, and
    raised `23505` — and because a raise is not caught per visit, one removed visit killed the whole
    batch. Fixed to revive the removed row. Removal is therefore **reversible**, which is the "we made a
    mistake" case the feature exists for.
- **`public.remove_visits_from_review(p_visit_ids bigint[], p_reason text)`** (`2026-09-01_1900`) —
  soft-removes an inclusion. **Friction by design:** one click while `review_work_started` is false; a
  **reason required** once work exists against the visit.
  - 🛑 **THE REASON-REQUIRED FRICTION IS RETIRED (`2026-09-09_1600`). A worked-on visit can no longer
    be removed at all**, because work now keeps it in scope on its own: removing the inclusion cannot
    take it out of the queue, so a reason would buy a change that does not happen. The RPC refuses with
    *"work has already been done on this visit, so it stays in the queue whatever happens to the
    inclusion"*, and the app hides the control on `review_work_started`. **V-1542 is in that state
    today.** The paragraph below is the record of what the rule was, not what it does.
  - ⚠ The obvious "already reviewed" predicate (`review_status <> 'pending'`) is **dead** — all 1,145
    completed visits read `pending` and `reviewed_at` is set on 0 rows, so it is a guard at the cap that
    can never trip. The real signal is the **work product** (`photo_classifications` OR a real
    `visit_reviews` decision) = `review_work_started`; 165 of 1,145 qualify.
- **Refusal text must name the real state** (`2026-09-01_2100`): a removed inclusion has a NULL
  `scope_source` (like a bad id), so the "no such visit, or it was never included" arm was firing on a
  visit that exists and carries a reason/`included_by`/`removed_by`. The chain now distinguishes
  absent-visit from removed-inclusion. The app keeps the dialog open on `ok:false` and renders the
  server's `skipped_because`; a two-tab race (tab B removes while tab A's dialog is open) is handled.

## 5. Migrations

`2026-09-01_1700` (`job_is_sa_sc`), `_1800` (`review_scope_inclusions` table + `include_visits_in_review`),
`_1900` (soft-removal + `remove_visits_from_review`), `_2000` (include revives a removed inclusion),
`_2100` (refusal messages tell the truth), **`2026-09-09_1600` (the policy becomes open-job +
work-started + manual, `job_is_open` added, `scope_source` renamed, the worked-on removal refused,
and the include RPC stops naming the retired pre-convention rule)**. Headers are the primary record of each defect + its measured
control.

⚠ **Design-spec note:** the spec (`2026-09-01-...-inclusions-design.md`) says the undo was "deliberately
NOT built / No undo" — that was cut as speculative and then shipped hours later (`_1900`/`_2000`/`_2100`).
The migration headers + Admin Review CLAUDE.md carry the reversal; treat the spec's "no undo" lines as
superseded.

## 6. Cross-references
- **App-facing:** `Building Apps/Admin Review/CLAUDE.md` ("THE QUEUE SCOPE" + the fact/policy rule);
  `Building Apps/Admin Review/docs/08-changelog.md`.
- **Design:** `docs/superpowers/specs/2026-09-01-admin-review-scope-inclusions-design.md`.
