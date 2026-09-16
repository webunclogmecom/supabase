# Reference: Calendar Tasks (`ops.calendar_tasks`, the saga, the poll)

*Written 2026-09-16 by @Building Apps, after the "create from the Calendar, dateless tray, two-way with
Jobber" pass shipped and was smoke-tested end to end on real data.*

**Why this file exists.** The DB side of Calendar Tasks lived in seven migration headers, two edge
function headers and a plan doc, and the 2026-09-16 pass changed the recorder body, the poll and the
column contract in one afternoon. A Supabase reader who opens the folder needs one page that says what
the objects are today and which invariants must not regress. The **app-facing** contract stays in
`Building Apps/Visit Calendar/` (root `CLAUDE.md` section 4b); link it, do not duplicate it.

| where | what it covers |
|---|---|
| [`Building Apps/Visit Calendar/CLAUDE.md`](../../../Building%20Apps/Visit%20Calendar/CLAUDE.md) rule 11 (11a to 11d) | the app rules: tasks never enter the visits array, every write goes through the saga, NULL date = tray, today at open, no drag yet |
| [`.../docs/08-changelog.md`](../../../Building%20Apps/Visit%20Calendar/docs/08-changelog.md) 2026-08-27 and 2026-09-16 (h) | the feature history and the measured smoke results |
| [`.../docs/specs/2026-08-25-calendar-tasks-design.md`](../../../Building%20Apps/Visit%20Calendar/docs/specs/2026-08-25-calendar-tasks-design.md) | the approved v2 design (saga, poll, rule 6) |
| [`.../docs/specs/2026-09-16-calendar-tasks-create-two-way-design.md`](../../../Building%20Apps/Visit%20Calendar/docs/specs/2026-09-16-calendar-tasks-create-two-way-design.md) | the delta: unscheduled state, poll widened plus discovery, tray colours, date at open |
| migrations `2026-08-26_1800` to `_1901` and `2026-09-16_1300_calendar_tasks_unscheduled` | the objects, with their PRE checks and rolled-back probes |
| `supabase/functions/save-calendar-task/index.ts`, `supabase/functions/poll-calendar-tasks/index.ts` | the two functions; their headers are the detailed reasoning |
| migration `2026-09-16_1700_get_record_history_calendar_tasks` | the Activity tab: `get_record_history` widened to tasks, the render types, the header-based actor labels |
| `scripts/probes/calendar_task_unscheduled_contract.js`, `calendar_task_poll_run.js`, `calendar_task_jobber_edit.js` | live Jobber probes, safe to re-run (each cleans up after itself) |

---

## The objects

- **`ops.calendar_tasks`** is master. Columns that carry a contract: `title`, `instructions`,
  `task_date date NULL`, `minutes int NULL` (minutes past ET midnight), `all_day bool`,
  `duration_minutes int` (1 to 1440), `client_id`, `property_id`, `visit_id`, `is_complete`, `completed_at`,
  `completed_source` (`calendar` or `jobber`; the completion CHECK ties the three together).
  `task_date` has been **nullable since 2026-09-16_1300**: **NULL = unscheduled** = the Calendar's To
  be scheduled tray = Jobber `startAt: null`. The CHECK `calendar_tasks_allday_chk` is
  `(task_date IS NULL AND minutes IS NULL AND NOT all_day) OR (task_date IS NOT NULL AND all_day = (minutes IS NULL))`:
  a dateless task has no time and is not all-day (it keeps a normal duration, default 30); a dated
  task without a time is all-day with duration 1440. Partial index `calendar_tasks_unscheduled_idx ON
  (id) WHERE task_date IS NULL` serves the tray query.
- **`ops.calendar_task_assignees`** (task_id, employee_id) and **`public.entity_source_links`** with
  `entity_type = 'calendar_task'` (the Jobber Task GID, `source_system = 'jobber'`).
- **Grants:** `authenticated` and `service_role` hold **SELECT only** on both tables (plus
  `yannick_readonly`). **Nobody writes them directly.** The only writers are the two SECURITY DEFINER
  recorders `ops.fn_record_calendar_task(p jsonb, p_actor_email text)` (insert or update by
  `jobber_gid`, assignee set, link row) and `ops.fn_delete_calendar_task`. The table is opted IN to
  `audit.logs`; `trg_calendar_tasks_updated_at` maintains `updated_at`.
- **`public.sync_cursors` entity `calendar_tasks`**: the poll's discovery cursor (the `createdAt`
  instant of its last complete walk). Delete the row to re-walk 30 days; the recorder is idempotent by
  GID so a re-walk imports nothing twice.

## The two functions

**`save-calendar-task`** (the door). Browser-called by the Calendar with the user's session token;
`verify_jwt = false` in `config.toml` **on purpose**, because the handler does its own
`auth.getUser` and a staff-domain gate and must be able to answer a bad token with its own plain
sentence. Ops `create | edit | complete | delete`. Every op is push to Jobber, read the Task back,
compare, and only then the RPC; a mismatch on create compensates with `taskDelete` and saves
nothing. Failures are non-200 `{ ok: false, code, message }` written for a dispatcher. Since
2026-09-16: `create` without `task_date` and `edit` with `task_date: null` produce an unscheduled
Task (`taskCreate` without `startAt`; `taskEdit` with `startAt: null, endAt: null, allDay: false`);
the read-back requires no window in that case; a time without a date is refused (`22023` from the
recorder, surfaced as a sentence). An empty assignee list on an edit **omits** `assignedTo` rather
than stripping Jobber's assignment.

**`poll-calendar-tasks`** (the safety net, cron `calendar-task-poll`, every 5 minutes, service_role).
Walks every GID we hold (open tasks, plus completed ones for 30 days) with pagination and a
`collected === totalCount` assertion (Jobber truncates silently at 100 and omits unknown ids without
an error). Since 2026-09-16 it is **two-way for every field**: title, instructions, the schedule
(including NULL for unscheduled), client and property through their link rows, the assignee set
through employee links, and `is_complete`. Jobber wins on any difference, by construction: every value
we hold was verified in Jobber before it was written, so a difference can only have been made on the
Jobber side. Before each RPC it re-reads the task and compares the whole adoptable fingerprint; a task
that moved under it is skipped and retried next cycle; the RPC's `expected_is_complete` guard
(`ZZ002`) is the second lock. It **discovers tasks created in Jobber** (`createdAt` after the cursor,
first run 30 days back, plus the scheduled horizon [today - 30d, today + 60d], at most 50 new per
cycle; the cursor advances to the run's start only when the `createdAt` walk completed and nothing was
deferred by the cap, so a leftover is seen next time) and records them through the same recorder;
**GIDs linked to a `calendar_day_marker` are never imported** (those are the Calendar's route markers,
owned by `jobber-push-task`). It never deletes ours: a task Jobber no longer has is surfaced under
`missing` (the long-known task 214, `gid://Jobber/Task/2304786340`, is the one such today). A client,
property or assignee it cannot map to one of our rows is logged under `unmapped_*` and the field is
left alone.

## The Activity tab (since the evening of 2026-09-16)

The task drawer shows the same history list a visit has, read through `public.get_record_history(p_table =>
'calendar_tasks', p_record_id => <id>, p_hide_system => false)` (migration
`2026-09-16_1700_get_record_history_calendar_tasks`, applied 19:2x ET after a full dry run with ROLLBACK):
- the allow-list admits `calendar_tasks` (and only that: `calendar_task_assignees` as `p_table` is still
  refused); the assignee child rows fold in by `task_id` exactly as `visit_team` does for a visit, with the
  same delete-then-reinsert churn filter;
- `audit.entity_render_config` holds ten rows for the task columns (Title, Notes, Date, Start time, Duration,
  Client, Property, Visit, Completed, Assigned to), and `audit.render_value` learned two additive types:
  `minutes` ('450' becomes '7:30 AM ET') and `duration` ('90' becomes '1 hr 30 min', 1440 becomes 'All day');
- the actor label comes from the request headers, never from a guess: `save-calendar-task` (v15) sends
  `x-app-source: visit-calendar` and `x-actor-name: <email>` on its three RPC writes, so a row reads
  "Edited in Visit Calendar by <employees.full_name>"; `poll-calendar-tasks` (v11) sends `x-app-source:
  jobber` on its two, so a discovery reads "Created in Jobber", an adoption "Changed in Jobber" and a
  completion flip "Completed in Jobber" / "Reopened in Jobber". Both keep their plain, header-less client for
  everything else (the audited `webhook_tokens` refresh keeps its label).
- Rows written before those headers (every task row up to 2026-09-16 19:21 ET, 167 of them) carry
  `app_source = 'sql'` and read "System" for good. Do not add a path or email heuristic to relabel them;
  the trail is a record of what was observed.
- Both function bodies were spliced from the live definitions with their md5 pinned before and after; the
  previous bodies are in `backups/2026-09-16_get_record_history_and_render_value_before_calendar_tasks.sql`.

## Jobber facts these depend on (measured 2026-09-16 against the live API)

- `TaskCreateInput.startAt` is optional; a Task created without it reads back `startAt: null,
  allDay: false`. `taskEdit` with `startAt`/`endAt` schedules it; with both `null` it unschedules it.
- `TaskFilterAttributes` has `createdAt`, `startAt`, `endAt`, `assignedTo`, `completedAt`, `ids`. There
  is **no `updatedAt`** on a Task, which is why adoption is by value, not by recency.
- Jobber AI, asked in Fred's tab: an undated Task appears on no dated view; an assigned team member
  sees and completes Tasks in the mobile app when their Schedule permission is "View and complete
  their schedule".

## What must not regress

1. **No direct write path.** If a grant on `ops.calendar_tasks` or `calendar_task_assignees` ever
   grows beyond SELECT, or an app bundle gains an `.insert/.update/.delete` on them, the
   no-discrepancy guarantee is gone. The Calendar bundle was checked for 0 such calls on 2026-09-16
   (`index-Dg2up5vh`); repeat the check at every publish that touches tasks.
2. **The recorder is spliced from its LIVE body, never rewritten from memory.** `2026-09-16_1300` PRE
   1 pins the md5 of the body it was written against and refuses otherwise. Do the same for the next
   change (`scratchpad mkmig3.js` is the pattern: `pg_get_functiondef`, anchor, splice, control).
3. **The poll never deletes and never invents.** Missing in Jobber is reported, not acted on (rule 6
   of the v2 design). Unmappable references are logged, not guessed.
4. **The CHECK encodes the state machine.** Dateless implies no time and not all-day. A migration that
   relaxes it must also change `save-calendar-task`'s read-back and the Calendar's tray predicate
   (`task_date IS NULL OR task_date BETWEEN range`).
5. **Route-marker Tasks are not Calendar Tasks.** The discovery exclusion by `calendar_day_marker`
   link is what keeps a Start/End/Dump marker from being imported as a second task every cycle.
