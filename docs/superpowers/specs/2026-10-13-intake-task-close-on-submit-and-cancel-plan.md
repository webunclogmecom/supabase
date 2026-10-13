# Close the intake task when the form is submitted or cancelled (plan)

*2026-10-13 · Trello `QzHJYuNZ`*

> ✅ **SHIPPED 2026-10-13 ~12:38 ET.** Fred's answers: D1 delete, D2 yes, D4 yes; D3 (expiry) still open, so expired
> forms are not handled. Migration `docs/migrations/2026-10-13_1235_intake_task_close.sql` (rollback beside it), edge fn
> `intake-task-sync` v1. Two changes from the plan: the closure marker is its own table
> (`public.intake_task_closures`) instead of a column on `property_intakes`, and the health check is one line in
> `log_jobber_sync_health`'s watched list with a 25-minute window (the sweeper runs every 5 minutes and logs every run),
> instead of a new item kind. Verified: tasks 292 and 326 ticked in Jobber and in the Calendar on the first run; the
> delete path on a [TEST] form and task on 112-YA (Jobber task gone, our row gone, ledger and audit say so); the health
> watch reports nothing while it runs and "stalled" when its runs are hidden (rolled back).

## The ask

Fred, quoting the two version 1 gaps of the Schedule intake task (intake flow doc 8.4b, "Not in v1"):

> Submitting the form doesn't complete the task. Someone ticks it by hand.
> Cancelling a form doesn't remove its task.

"Design a plan for this."

## What is true today (measured 2026-10-13)

- Scheduling an intake creates a Jobber + Calendar task (`save-calendar-task`, `app: "client-app"`, `intake_id`) and
  stores it on `public.property_intakes.calendar_task_id`. Verified in Jobber: tasks 299 and 325 carry the right
  title, client, property, assignee and the form link in the instructions.
- **Submit** happens in `intake-submit`, called by the collector with a link code and no login. It never touches the
  task.
- **Cancel** is `client.cancel_intake` (staff only), called from the Picture Planner "Cancel form" and from the
  Client App when task creation is refused (no task exists in that case). It never touches the task.
- `save-calendar-task` already has both writes we need, each verified by reading Jobber back:
  - `complete`: `appointmentEditCompleteness`, read back `isComplete`, then `ops.fn_record_calendar_task`.
  - `delete`: `taskDelete` + read back until proven absent (`deleteAndVerify`), then `ops.fn_delete_calendar_task`.
  But it only accepts a signed-in staff person ("Never service_role-by-default"), so `intake-submit` cannot call it.
- `ops.fn_delete_calendar_task` HARD-deletes the task row (the `ops.calendar_tasks` audit row keeps `old_row` and the
  actor), and `property_intakes.calendar_task_id` is `ON DELETE SET NULL`.
- `ops.calendar_tasks.completed_source` CHECK allows only `calendar` and `jobber`. No view reads that column.
- Backlog right now:
  - submitted, task still open: intake **1042 -> task 292** (submitted 2026-09-30) and **1067 -> task 326**
    (submitted today);
  - cancelled with a task still present: **none**;
  - open forms with open tasks (correct, untouched by this plan): 1062-1066 -> tasks 299-302, 325.
- The pattern for a server-side Jobber job already exists: pg_cron calls a SQL wrapper
  (`public.fn_request_calendar_task_poll()`), the wrapper does `net.http_post` with a service_role bearer, the edge fn
  has `verify_jwt = true` AND asserts `role = service_role`, and machine writes pass `p_actor_email: null`.
  `calendar-task-poll` runs every 5 minutes this way.

## Design: one small sweeper, no app change

A new edge fn **`intake-task-sync`**, run by pg_cron every 5 minutes, does exactly two things:

| Form state | Task state | Action |
|---|---|---|
| submitted (`submitted_at` set), not yet handled | open | complete it in Jobber, read back, record locally with `completed_source = 'intake'` |
| cancelled (`cancelled_at` set) | still present | delete it in Jobber, verify gone, remove our copy (the existing delete path) |

Everything else is left alone.

**Why a sweeper and not inline in submit / cancel:**
1. A submit must never fail or wait because Jobber is slow or down. The collector is on a phone at a restaurant.
2. Cancel would otherwise need two calls from the Picture Planner (cancel, then delete the task), which is a Lovable
   change and a half-done state when the second call fails. The sweeper needs **no app change at all**.
3. Retries come for free: a Jobber failure is retried on the next run instead of being lost.
4. Cost: up to 5 minutes of lag. Optional later: `intake-submit` can nudge the sweeper right after a submit
   (`EdgeRuntime.waitUntil`, already used by four functions) to make it near-instant.

**Do it once, never fight a person.** If the office unticks a task the sweeper closed, the sweeper must not tick it
again 5 minutes later. So the "submitted" branch is keyed on a new marker, `property_intakes.task_closed_at`, set
when the sweeper has acted (or decided there was nothing to do). The "cancelled" branch needs no marker: after a
delete, `calendar_task_id` is NULL and the form drops out by itself.

## Steps

1. **Migration** (`YYYY-MM-DD_HHMM_intake_task_close`, staged, rehearsed with rollback first):
   - widen `calendar_tasks_completed_source_check` to `('calendar','jobber','intake')`;
   - add `public.property_intakes.task_closed_at timestamptz` and `task_close_error text` (last failure, for the
     health line);
   - `public.fn_request_intake_task_sync()` wrapper, a copy of `fn_request_calendar_task_poll()`;
   - `cron.schedule('intake-task-sync', '3-59/5 * * * *', ...)`, offset from the 5 minute jobs already on 1-4;
   - the run writes one `sync_log` row (source `intake_task_sync`, status `success` / `partial` / `error`, the
     clean word is `success`) and is added as a watched source in `log_jobber_sync_health`, the way
     `railway_samsara_readings` was. That check already sits in both `ops.v_health_items` and
     `ops.v_health_status`, so nothing new needs registering there. The run's items carry
     `intake_task_out_of_step`: a submitted form whose task is still open 30 minutes later, or a cancelled form
     whose task still exists 30 minutes later, with the intake ids;
   - revoke the wrapper and any new function BY NAME from `public, anon, authenticated` and assert it with
     `has_function_privilege` in the migration (Supabase default privileges grant EXECUTE to staff on every new
     `public` function; the health chain rule);
   - check before widening: grep the apps for `completed_source` (the Visit Calendar may print it). No DB view reads
     it today.
2. **Shared helper** `supabase/functions/_shared/jobber-task.ts`: move `completeAndVerify` (from the `complete`
   branch) and `deleteAndVerify` out of `save-calendar-task` unchanged, and import them back there. The behaviour of
   `save-calendar-task` must not change; its existing checks must still pass. (One implementation of "verified
   complete" and "verified gone", not two.)
3. **Edge fn `intake-task-sync`** (`verify_jwt = true` in `config.toml` + `role = service_role` asserted in code):
   - select at most 20 forms per run, oldest first;
   - submitted branch: task already complete -> just set `task_closed_at`; open -> complete + read back +
     `fn_record_calendar_task({ jobber_gid, is_complete: true, completed_source: 'intake', completed_at })`, then set
     `task_closed_at`; task gone in Jobber -> set `task_closed_at`, log it;
   - cancelled branch: `deleteAndVerify`, then `fn_delete_calendar_task`. Already gone in Jobber counts as success
     (the existing idempotent rule);
   - any failure: write `task_close_error`, leave the row for the next run, never a false success;
   - machine actor (`p_actor_email: null`), never `x-actor-name`;
   - returns a summary `{completed, deleted, skipped, failed}` for the cron log.
4. **Deploy and turn on.** The first run will close the two backlog tasks (292 and 326), which is the intended
   outcome for submitted forms. See decision D4.
5. **Test on 112-YA (the sanctioned test client), live Jobber writes on the test client only:**
   - schedule a `[TEST]` intake from the Client App, assigned to Fred -> task appears in Jobber;
   - submit it with the existing test tool (`scripts/intake-collector/tests/`) -> within one run the task is complete
     in Jobber AND in the Calendar, `completed_source = 'intake'`, `task_closed_at` set;
   - untick that task in the Calendar -> wait two runs -> still unticked (the "never fight a person" control);
   - schedule a second `[TEST]` intake, "Cancel form" in the Picture Planner -> within one run the task is gone from
     Jobber and the Calendar, the audit row shows the delete;
   - negative control: an open, unsubmitted form's task is untouched across runs;
   - visual check in the Visit Calendar after each Prod write.
6. **Docs, same cycle:** `Building Apps/docs/client-intake-flow.md` (8.4b "Not in v1" line, 13.1, change log),
   Client App CLAUDE.md rule 2s, Picture Planner CLAUDE.md (Cancel form now removes the task within 5 minutes),
   Visit Calendar docs (a task can be completed by `intake`), Supabase CLAUDE.md cron list, both changelogs.

Size: one migration, one shared module moved, one ~150 line edge fn, one cron line. No Lovable work.

## Rules that must not regress

- Submit never depends on Jobber. The sweeper runs after, never inside, the submit.
- Only verified writes: nothing local changes until Jobber read-back confirms it (the `save-calendar-task` standard).
- One action per form. A task a person reopened stays reopened.
- Only forms with a `calendar_task_id` are touched; forms scheduled before 2026-09-29 evening have none.
- Never touch a task whose form is still open.

## Decisions for Fred

- **D1. On cancel, delete the task or tick it done?** Recommended: **delete**. It is what "remove its task" means,
  it takes the dead link off the worker's schedule, and it reuses the Calendar's own delete path. The trail stays in
  the `ops.calendar_tasks` audit row. Alternative: tick it done and rename it "Cancelled: ...", which keeps the row
  but shows a finished task that was never done.
- **D2. Complete the task on any submit, even when the form came back Incomplete?** Recommended: **yes**. The task
  is "fill in the form" and that happened; missing answers mean a new link, which makes a new task.
- **D3. Treat an expired form like a cancelled one?** Forms last 60 days; the first real one expires 2026-11-28.
  Recommended: **yes**, it is one more condition in the same query. Or leave it for later.
- **D4. Let the first run close tasks 292 and 326** (both forms already submitted)? Recommended: **yes**.
