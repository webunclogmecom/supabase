# Admin Review queue scope + manual inclusions — as-built reference

*Shipped 2026-09-01. The durable DB-side contract for WHICH completed visits appear in the Admin
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

🛑 **The filter is `in_review_scope`, NOT `job_is_sa_sc`, NOT job status.** Fred's rule is about job
**era/type**, not quality or open/closed: a closed or archived SA/SC job's visits MUST stay reviewable
so their photos can be classified and a Service Report can exist.

⚠ **The original symptom was NOT a job-status filter.** `visits_with_review` (`v_visits_live LEFT JOIN
visit_reviews`) has no job filter at all; what hid old visits was the queue's own **28-day window**.
Removing a "job-status filter" would have been a no-op (migration `2026-09-01_1700` header records
this). The real scoping is `job_is_sa_sc` (the era gate) widened by manual inclusions.

## 2. The columns on `public.visits_with_review`

| column | meaning |
|---|---|
| `job_is_sa_sc` | **FACT** about the job: does its title follow the modern convention (SA = `Service Agreement%`, SC = `Service Call`), else false; **never NULL**. Added `2026-09-01_1700`. |
| `in_review_scope` | **POLICY** the queue filters on: `job_is_sa_sc` **OR** an active `review_scope_inclusions` row (`removed_at IS NULL`). |
| `scope_source` | which carried it: `convention` or `manual`. **`convention` wins when both are true** (reachable once a job is renamed to comply after an inclusion). NULL for any out-of-scope visit. |
| `review_work_started` | true once real work exists for the visit — a `photo_classifications` row OR a `visit_reviews` decision (bonus/invoice/quality/`reviewed_at`). Drives the remove-friction (below). |

🛑 **Keep FACT (`job_is_sa_sc`) and POLICY (`in_review_scope`) apart, and never re-implement the rule in
the app** (no title tests, no job-status tests). The separation is why the app can explain WHY a visit
is out of scope instead of listing orphans, and why a future policy change cannot rewrite history.

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
`_2100` (refusal messages tell the truth). Headers are the primary record of each defect + its measured
control.

⚠ **Design-spec note:** the spec (`2026-09-01-...-inclusions-design.md`) says the undo was "deliberately
NOT built / No undo" — that was cut as speculative and then shipped hours later (`_1900`/`_2000`/`_2100`).
The migration headers + Admin Review CLAUDE.md carry the reversal; treat the spec's "no undo" lines as
superseded.

## 6. Cross-references
- **App-facing:** `Building Apps/Admin Review/CLAUDE.md` ("THE QUEUE SCOPE" + the fact/policy rule);
  `Building Apps/Admin Review/docs/08-changelog.md`.
- **Design:** `docs/superpowers/specs/2026-09-01-admin-review-scope-inclusions-design.md`.
