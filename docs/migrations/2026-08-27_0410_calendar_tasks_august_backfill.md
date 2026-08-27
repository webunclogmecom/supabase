# 2026-08-27_0410 — Calendar Tasks: August 2026 backfill (35 tasks)

**WHAT:** 35 rows into `ops.calendar_tasks` (ids **180–214**), 41 into `ops.calendar_task_assignees`,
35 into `public.entity_source_links` (`entity_type='calendar_task'`). Executed **2026-08-27 04:07–04:14 ET**.

**WHY:** the Calendar Tasks build (Task 6, grid chips) needs something to render, and "counts must
stay numerically identical" needs a real N>=1 to test against. This is the **first production write
of the entire Calendar Tasks build** — everything before it was read-only or rolled back.

**Not a `.sql` file on purpose.** The backfill is 35 `ops.fn_record_calendar_task` calls, not DDL.
It lives here because this is where anyone asking "what changed Prod on 2026-08-27" looks.

App-facing contract and the app-visible consequences:
`Building Apps/Visit Calendar/docs/08-changelog.md`, entry **2026-08-27**. Not duplicated here.

---

## The door used, and the one deliberately not used

Written through **`ops.fn_record_calendar_task(p jsonb, p_actor_email text)` directly**, as the table
owner over the Management API.

🛑 **NOT through the `save-calendar-task` edge function.** That function mutates Jobber *first*
(`taskCreate` on create) and only then calls the RPC. Running it over 35 tasks that already exist in
Jobber would have **created 35 duplicate Jobber tasks**. Jobber was READ ONLY throughout: the only
Jobber traffic was the task walk and the `completedAt` count queries, and
`poll-calendar-tasks/index.ts` contains zero GraphQL `mutation` bodies.

**Actor:** `calendar-task-backfill@machine.unclogme.local` — deliberately not a person, so
`audit.logs` does not attribute 35 rows to a human who did not create them. All 76 audit rows
(35 task + 41 assignee) carry it; **zero** carry a human address.

---

## Scope, re-derived live rather than reused

The candidate list was **re-walked against live Jobber**, not read from the earlier probe's cache:
the brief measured at 19:10 ET and two of the tasks fall on today's ET date, so a completion could
have landed in between. Walk: `first:25`, 17 pages, **collected === totalCount === distinct === 401**,
zero errors.

> ⚠ `first:100` with `assignedUsers(first:25)` returns `Throttled` and collects **zero**. A naive run
> keeps that empty result and reports it as a finding. Use `first:25`.

**Positive control on the ET conversion** (a single-bucket histogram would mean the timezone maths
was broken and the August number an artefact): 2026-06 → 30, 2026-07 → 26, **2026-08 → 35**,
2026-12 → 2, plus 3 permanently undated. Healthy neighbours.

```
35 total | 10 open / 25 completed | 0 all-day / 35 timed | 0 recurring
0 with no assignee | 3 with multiple assignees | 6 distinct assignees
10 distinct clients (all map) | 10 distinct properties (all map)
=> 35 task rows, 41 assignee rows, 35 entity_source_links rows
task_date range 2026-08-03 .. 2026-08-27
```

Identical to the brief's figures on every line.

---

## 🛑 `Task.duration` IS IN MINUTES, NOT SECONDS — and getting it wrong is silent

The single most dangerous thing found in this run. A `duration / 60` conversion (the natural
assumption, and what an earlier draft of the backfill script did) yields:

```
30 / 60 = 0.5 -> round -> 1        45 / 60 = 0.75 -> round -> 1        60 / 60 = 1
```

**`duration_minutes = 1` on all 35 rows.** That passes `CHECK (duration_minutes BETWEEN 1 AND 1440)`,
passes every other constraint, and commits clean. Nothing would have flagged it.

Measured from the raw signal rather than assumed:

```
(endAt - startAt) / 60000 === duration   -> TRUE on 35/35
(endAt - startAt) / 1000  === duration   -> FALSE
distinct duration values in August: [30, 45, 60]
```

⇒ **`duration_minutes = duration`, no conversion.** The backfill now asserts the unit and refuses to
run if it ever stops holding. Anyone touching Jobber `Task.duration` again should assert it too — a
units bug here is invisible to the schema.

---

## `completed_at` for the 25 completed rows

`Task.completedAt` is **not a readable field** (Task exposes no `completedAt`, no `updatedAt`, no
`createdAt`). It exists only as a range filter. Recovered with the **shipped** `findCompletedAt` from
`supabase/functions/poll-calendar-tasks/index.ts` (`countAfter` L195, `findCompletedAt` L207), ported
line for line and deliberately **not** reimplemented differently: bracket and assert **both** bounds,
bisect to 1 second, `probes < 60` cap, return `lo + 1000ms` so the stored value is never *earlier*
than the real event, null when it cannot converge.

```
25/25 recovered exactly     32 probes each, 800 total     0 fallbacks, 0 estimates
```

Two independent cross-checks, both run before writing anything:

- **Set identity.** The tasks Jobber returns for `completedAt after 2026-08-01` are **exactly** the
  25 we hold as completed. `totalCount=25`, collected 25, set difference **0 in either direction**.
- **All 25 recovered instants land in August ET.** Any that did not would be a search bug, not a datum.

`completed_source = 'jobber'` on all 25, as required by `calendar_tasks_completed_source_check`.

**What is NOT closed, and cannot be from here:** nothing cross-checks that Jobber's `completedAt` is
the true completion instant rather than a derived value. It is accurate to the second *relative to
what Jobber stores*, which is the best available and strictly better than notice-time. The poll's own
header already flags this.

⚠ **And it is the only chance to get it right.** The poll runs `findCompletedAt` only when *adopting*
a completion (`jobberComplete && !oursComplete`). A wrong `completed_at` on an already-complete row
is never repaired and never noticed.

---

## Order of execution, and the free end-to-end proof taken in the middle

1. **Dry run**, two tasks, inside a real `begin; … rollback;` — the simple canary *and* the most
   complex row (completed, 3 assignees incl. the inactive one, client + property), so every CHECK,
   both FKs, the completion triple and the multi-row assignee insert were exercised. 🛑 A real
   transaction block, **not** a bare `DO` block, which commits. Verified afterwards in a **separate
   submission** that all three counts were still 0.
2. **Canary: one task committed** (id 180, `Reminder install GT for Marcel`, open, one assignee, no
   client, no property). 13/13 checks.
3. **Waited one poll tick and read `public.sync_log`** before writing anything else. This was the
   first real end-to-end exercise of the adoption path and it was free.
4. **The remaining 34**, sequential, reversal map rewritten to disk after every single call.
5. **Verified**, then waited another tick for the full 35.

### The adoption path, proven for the first time

`public.sync_log` where `sync_source='calendar-task-poll'` (columns `started_at` / `finished_at` /
`status` / `details` — there is **no `created_at`**).

**The discriminating control was already in hand:** every run before the canary logged
`watching.open = 0, checked = 0` against an empty table, so a state change here is real and not a
field that always reads the same.

| run | watching | checked | adopted | missing | conflicts | estimated |
|---|---|---|---|---|---|---|
| before canary (36429) | open 0 | 0 | 0 | [] | [] | [] |
| after canary (36431) | **open 1** | **1** | 0 | [] | [] | [] |
| after all 35 (36435) | **open 10 + recently_completed 25** | **35** | 0 | [] | [] | [] |

`walk_complete: true`, `collected === total_count` on both.

⇒ **The poll independently re-read all 35 from Jobber and agreed with our copy on every one.** It
adopted nothing, conflicted on nothing, and rewrote nothing (0 rows have `updated_at > created_at + 2s`).
That is the strongest available check on the backfill's *content*, not just its shape — though note it
still cannot check `completed_at` itself, for the reason given above.

---

## Jeffry (employee 25) is INACTIVE and his 3 rows were stored deliberately

He is an assignee on tasks 194, 195, 196. `calendar_task_assignees.employee_id` FKs to
`public.employees(id)` with no status predicate, so the rows insert fine.

`ops.v_calendar_driver` filters `status='ACTIVE'` and therefore does not contain him — the predicate
would match him, the UI offers no way to ask. **This is identical to the existing visit-side gap** and
is not new. **No task becomes unreachable:** all three also carry Aaron (26) and Grecia (1), both
ACTIVE and both in the view.

🛑 **Do not "fix" this by adding inactive employees to `ops.v_calendar_driver`** — that view also
feeds the visit-side Team filter and the change would land there too. It is a note, not code. Open
question 6 for Fred.

---

## Reversal — and step 2a's answer

**`ops.fn_delete_calendar_task` DOES clear the `entity_source_links` row.** The brief flagged this
UNVERIFIED and it was the reversal path, so it was read before the canary rather than after. Body,
read live off `pg_get_functiondef`:

```sql
DELETE FROM public.entity_source_links l
 WHERE l.entity_type = 'calendar_task' AND l.entity_id = p_task_id;
DELETE FROM ops.calendar_tasks t WHERE t.id = p_task_id;
```

Link first, task second, assignees by `ON DELETE CASCADE`. **So the reversal is one RPC call per task
id and needs no separate ESL cleanup**, and the brief's "blunt fallback" is not required.

```sql
select ops.fn_delete_calendar_task(<task_id>, 'calendar-task-backfill@machine.unclogme.local');
```

**id-to-GID map:** `backups/2026-08-27_calendar_tasks_august_backfill_reversal.json` (35 entries,
gitignored by the root allowlist). It was rewritten after **every single call**, so a crash mid-run
would still have left an accurate undo path for exactly what had landed.

⚠ **The ESL delete leaves no trace whatsoever** — `public.entity_source_links` carries zero triggers.
The `ops.calendar_tasks` audit row, with `old_row` and the actor email, is the only record that any
of it happened.

⚠ **Standing guardrail is soft-delete only.** A backfill of rows that never existed before is the one
case where a hard delete is a true undo rather than data loss — but that still needs **Fred's explicit
OK**, not a unilateral call.

**Nothing to reverse on the Jobber side.** The operation is entirely DB-local.

---

## Findings worth carrying

**1. A stale absolute control is worse than no control.** The brief's `entity_source_links` total of
**27,913** was derived from 27,878 measured at 19:10 ET. By 03:54 ET the live total was already
**27,896** — other writers had moved it by 18. Asserting the absolute would have failed for a reason
having nothing to do with this backfill. The assertion actually used is
`entity_type='calendar_task' = 35`, which no other writer touches. (The total did land at 27,931,
i.e. 27,896 + 35, so nothing else wrote during the window — but that was luck, not a guarantee.)
⇒ **Assert on the slice you own, not on a shared counter.**

**2. The recorder btrims titles, and 4 of the 35 Jobber titles carry a trailing space.** The first
verification run reported 4 "title differs" mismatches. Compared at the byte level rather than
guessed: each differed by exactly one trailing `0x20`. `v_title := btrim(…, c_ws)` where
`c_ws = ' ' || chr(9) || chr(10) || chr(13) || chr(160)`. **The data was right and my assertion was
wrong.** Corrected to mirror `c_ws` exactly rather than paraphrase it with JS `.trim()`, which strips
a *different* class (it also takes VT and FF), and then **mutation-tested** so the relaxed assertion
still catches a changed title and an internal whitespace change.

**3. `audit.logs` has `operation`, not `action`.** Cost one failed verification query after the
canary had already committed correctly. The write was fine; the instrument was not.

**4. An `authenticated` JWT can be minted with zero side effects.** The Management API's
`GET /v1/projects/{ref}/postgrest` returns `jwt_secret`, and the project still signs HS256. So a role
test through *real* PostgREST needs **no password, no account, no session and no `auth.users` row** —
which every other option here would have required. **The instrument was control-tested before being
trusted:** the secret re-signs the known-good anon key's own `header.payload` to a byte-identical
signature. Without that control a minted token that PostgREST rejects is indistinguishable from a
genuine permission failure.

**5. Step 1's gate is closed, both halves.** See the app changelog for what it means for the app.
Controls that fired: positive (`ops.v_calendar_visit` returns rows on the same token), negative (same
query as `anon` → 401/42501), embed (`zzz_no_such_rel` → 400/PGRST200), absent (→ 404/PGRST205).
Re-run after the canary with a real row present, the embed returns a populated array.

---

## Consequence for whoever builds the app next

All 35 rows are inside the poll's working set (10 open, plus 25 completed within the 30-day window —
the earliest August completion is Aug 3). The cron reads them from Jobber every 5 minutes. That is
desirable and now proven, with one rider: **if the backfill had written a wrong `is_complete` the
poll would silently correct it; a wrong `completed_at` it would not.**
