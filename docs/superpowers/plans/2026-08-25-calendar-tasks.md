# Calendar Tasks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let office staff create a task in the Visit Calendar that appears on the Jobber schedule, stays consistent with Jobber at all times, and can be completed from either side.

**Architecture:** `ops.calendar_tasks` is master. Nobody holds a write grant on it. All writes go through a synchronous edge-function saga that pushes to Jobber, reads the Task back to verify, and only then calls a SECURITY DEFINER RPC to persist. A separate `*/5` cron polls Jobber by Task GID and adopts `isComplete` in both directions.

**Tech Stack:** Postgres (Supabase Prod `wbasvhvvismukaqdnouk`), Deno edge functions, pg_cron + pg_net, Jobber GraphQL `2026-04-16`, Lovable/React for the app.

**Spec:** [`Building Apps/Visit Calendar/docs/specs/2026-08-25-calendar-tasks-design.md`](../../../../Building%20Apps/Visit%20Calendar/docs/specs/2026-08-25-calendar-tasks-design.md)
**Evidence:** [`Building Apps/Visit Calendar/docs/specs/2026-08-25-calendar-tasks-jobber-findings.md`](../../../../Building%20Apps/Visit%20Calendar/docs/specs/2026-08-25-calendar-tasks-jobber-findings.md)

---

## 🛑 Read before Task 1

**1. This repo has no unit-test runner for DB work.** The idiom is a **rolled-back SQL probe** through the Management API, and a `scripts/probes/*.mjs` node script. "Write the failing test" here means "write the probe and watch it fail against the current schema". That is a real red/green loop, just not pytest.

**2. Phase C is NOT file edits.** The Visit Calendar is a **Lovable** app (project `6533c3ee-94f5-499c-96d1-c8847a729a8f`). There is no local React source to edit. Those tasks are **prompts sent to the Lovable editor**, verified against the live published bundle and DOM. Read `Building Apps/CLAUDE.md` "Lovable workflow" rules 1 to 20 before starting Phase C, especially rule 9 (one line per prompt, Enter submits) and rule 17 ("Up to date" can lie).

**3. Commit conventions differ by repo.** `Supabase/` commits carry the footer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. `Building Apps/` commits are **one line, no footer**. Always `git commit -- <pathspec>`, never a bare `git commit`, because two sessions share this checkout.

**4. Claim the work first.** Append to `WORKING-NOW.md` at the workspace root and commit in the same breath. Include: `ops.calendar_tasks`, `entity_source_links`, edge fns `save-calendar-task` / `poll-calendar-tasks`, and the Visit Calendar Lovable project.

**5b. 🛑 NEVER ASSERT A FROZEN ROW COUNT ON A CONTINUOUSLY-WRITTEN TABLE.** Measured during Task 1: `public.entity_source_links` went **27,868 → 27,870 → 27,871** within the hour from live Jobber sync writes (5 invoice, 4 job, 1 note, 1 photo in three hours), with **zero** rows attributable to the probe. A "count must be identical" check there manufactures a false alarm for whoever runs it next. This is the `CLAUDE.md` §5.2b case: a live object changed between your two reads, and with a machine writing it that is the likely explanation, not your change.
- To prove **no existing row was invalidated** by a new CHECK: rely on `ADD CONSTRAINT` *without* `NOT VALID`, which validates every row at apply time and fails loudly. That success IS the proof.
- To prove **a rolled-back probe leaked nothing**: query for the probe's own sentinels (`source_id like 'PROBE%'`, `entity_id = -999`, the new `entity_type`) and require 0. That is the check that discriminates.
- ⚠ This does NOT apply to `ops.calendar_tasks` in Tasks 4 and 8: nothing else writes it, so "unchanged" IS a valid assertion there.

**5. Get today's date from the DB, never from memory.** `select to_char(now() at time zone 'America/New_York','YYYY-MM-DD HH24:MI');` Migration filenames are the apply ORDER. The newest applied is `2026-08-26_1710` (the other session), so this plan uses `2026-08-26_1800` onward. The numeric part is an ORDERING LABEL in this repo, not a wall clock: what matters is that it sorts after everything already applied.

---

## Phase A — Database

### Task 1: Widen the `entity_source_links` CHECK

**Why first:** on 2026-08-06 the missing value made `jobber-push-task` return `ok:true` having created a real Jobber Task with no link row, and the next push would have minted a second one on the crew's schedule. Nothing can push until this exists.

**Files:**
- Create: `Supabase/docs/migrations/2026-08-26_1800_esl_allow_calendar_task.sql`
- Create: `Supabase/scripts/probes/calendar_task_esl.mjs`

- [ ] **Step 1: Write the failing probe**

Create `Supabase/scripts/probes/calendar_task_esl.mjs`:

```js
import { readFileSync } from 'fs'
import { pathToFileURL } from 'url'
const env = Object.fromEntries(readFileSync('.env','utf8').split(/\r?\n/)
  .filter(l => l.includes('=')).map(l => { const i = l.indexOf('='); return [l.slice(0,i).trim(), l.slice(i+1).trim()] }))

export async function sql(query) {
  const r = await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + env.SUPABASE_PAT },
    body: JSON.stringify({ query }) })
  const j = await r.json()
  if (!Array.isArray(j)) throw new Error('query failed: ' + JSON.stringify(j).slice(0, 300))
  return j
}

// 🛑 THE MAIN-MODULE GUARD MUST USE pathToFileURL. On Windows import.meta.url is
// `file:///C:/...` (three slashes) while `file://` + a backslash-replaced argv[1] gives
// `file://C:/...` (two), so a hand-built comparison NEVER matches, the whole block is
// skipped, and the script exits 0 printing NOTHING. A probe that prints nothing is not a
// passing probe, it is a broken instrument. This plan shipped with the broken form and the
// Task 1 implementer caught it on the first run. Verified on this machine 2026-08-26.
// ⚠ AND `process.argv[1] &&` IS REQUIRED, NOT DEFENSIVE. pathToFileURL(undefined) THROWS, and
// argv[1] is undefined under `node -e`. Without it the throw kills the IMPORT for every later
// probe that reuses this module -- the same failure class, arriving by a different route.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // POSITIVE CONTROL: an already-allowed value must insert cleanly.
  const control = await sql(`
    begin;
    insert into public.entity_source_links (entity_type, entity_id, source_system, source_id)
    values ('visit', -999, 'jobber', 'PROBE-CONTROL');
    select 'control-inserted' as r;
    rollback;`)
  // TARGET: the new value.
  let targetOk = true, targetErr = ''
  try {
    await sql(`
      begin;
      insert into public.entity_source_links (entity_type, entity_id, source_system, source_id)
      values ('calendar_task', -999, 'jobber', 'PROBE-TARGET');
      rollback;`)
  } catch (e) { targetOk = false; targetErr = e.message.slice(0, 120) }

  console.log('control (must pass): ' + JSON.stringify(control).slice(0, 60))
  console.log('target  calendar_task allowed: ' + targetOk + (targetOk ? '' : '  <- ' + targetErr))
  console.log('--- audit complete --- ' + JSON.stringify({ probe: 'calendar_task_esl', target_ok: targetOk }))
}
```

- [ ] **Step 2: Run it and confirm the target FAILS**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/calendar_task_esl.mjs
```

Expected: control passes, `target calendar_task allowed: false` with a `23514` check-violation message. **If the target already passes, stop** — someone has applied this and the rest of the task is a no-op.

- [ ] **Step 3: Write the migration**

Create `Supabase/docs/migrations/2026-08-26_1800_esl_allow_calendar_task.sql`:

```sql
-- 2026-08-26_1800_esl_allow_calendar_task.sql
--
-- WHAT: allow entity_type = 'calendar_task' on public.entity_source_links.
--
-- WHY: Calendar Tasks (spec 2026-08-25) link an ops.calendar_tasks row to its Jobber Task GID.
--      The link row is THE ONLY THING deciding create-versus-edit on the push.
--
-- 🛑 THIS MUST LAND BEFORE THE FIRST PUSH. On 2026-08-06 the same omission for
--    'calendar_day_marker' produced a real Jobber Task, a rejected link insert (23514) that was
--    swallowed, and ok:true returned to the caller. The next push would have created a SECOND
--    Task on the crew's schedule.
--
-- AUDIT (ADR 010): no new table, no trigger work. entity_source_links keeps its existing triggers.

BEGIN;

ALTER TABLE public.entity_source_links
  DROP CONSTRAINT entity_source_links_entity_type_chk;

ALTER TABLE public.entity_source_links
  ADD CONSTRAINT entity_source_links_entity_type_chk
  CHECK (entity_type IN ('client','derm_manifest','employee','inspection','invoice','job',
                         'line_item','note','photo','property','quote','vehicle','visit',
                         'calendar_day_marker','calendar_task'));

COMMIT;
```

⚠ **Before running this, dump the live constraint and confirm the existing value list matches the one above exactly.** A hand-copied list that drops a value silently breaks a different integration:

```sql
select pg_get_constraintdef(oid) from pg_constraint where conname = 'entity_source_links_entity_type_chk';
```

If it differs, use the live list plus `calendar_task`, not the list written here.

- [ ] **Step 4: Apply it, then re-run the probe**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/calendar_task_esl.mjs
```

Expected: control passes, `target calendar_task allowed: true`.

- [ ] **Step 5: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && git add docs/migrations/2026-08-26_1800_esl_allow_calendar_task.sql scripts/probes/calendar_task_esl.mjs && git commit -- docs/migrations/2026-08-26_1800_esl_allow_calendar_task.sql scripts/probes/calendar_task_esl.mjs -m "Allow calendar_task on entity_source_links

Calendar Tasks link an ops.calendar_tasks row to its Jobber Task GID. Without
this the push creates a real Task and cannot record the link, which is how a
duplicate lands on the crew's schedule.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" && git push origin main
```

---

### Task 2: The tables

**Files:**
- Create: `Supabase/docs/migrations/2026-08-26_1810_calendar_tasks_tables.sql`
- Create: `Supabase/scripts/probes/calendar_task_grants.mjs`

- [ ] **Step 1: Write the failing grant probe**

Create `Supabase/scripts/probes/calendar_task_grants.mjs`:

```js
import { sql } from './calendar_task_esl.mjs'

const rows = await sql(`
  select c.relname,
         c.relrowsecurity as rls_on,
         c.relacl::text   as acl,
         has_table_privilege('authenticated','ops.'||c.relname,'SELECT') as authn_select,
         has_table_privilege('authenticated','ops.'||c.relname,'INSERT') as authn_insert,
         has_table_privilege('authenticated','ops.'||c.relname,'UPDATE') as authn_update,
         has_table_privilege('authenticated','ops.'||c.relname,'DELETE') as authn_delete,
         has_table_privilege('service_role','ops.'||c.relname,'INSERT')  as svc_insert
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'ops' and c.relname in ('calendar_tasks','calendar_task_assignees','visit_requests')
   order by c.relname`)

// CONTROL: visit_requests is the shape we are copying. It must show authn SELECT-only.
const control = rows.find(r => r.relname === 'visit_requests')
if (!control) throw new Error('CONTROL MISSING: ops.visit_requests not found, probe is untrustworthy')
const controlOk = control.authn_select && !control.authn_insert && !control.svc_insert
console.log('CONTROL ops.visit_requests SELECT-only: ' + controlOk + '  (must be true)')

for (const r of rows.filter(r => r.relname !== 'visit_requests')) {
  const good = r.rls_on && r.authn_select &&
    !r.authn_insert && !r.authn_update && !r.authn_delete && !r.svc_insert
  console.log(`  ops.${r.relname}: rls=${r.rls_on} authn(s/i/u/d)=${r.authn_select}/${r.authn_insert}/${r.authn_update}/${r.authn_delete} svc_insert=${r.svc_insert}  => ${good ? 'OK' : 'WRONG'}`)
}
// 🛑 DO NOT WRITE `if (rows.length < 3) console.log('(tables not created yet)')` AND FALL THROUGH
// TO exit(0). That is what this plan originally said and it is a CONFIDENT ZERO: with both target
// tables absent the loop iterates an empty array, `fails` stays 0, and the probe reports success.
// Mutation-tested against two non-existent relation names: {"found":1,"failures":0}, exit 0. It
// would greenlight a dropped or renamed table.
//
// Absence must FAIL by default, but it is the CORRECT state on the pre-migration run, so make it
// a mode matching `--expect-blocked` in calendar_task_esl.mjs:
//   default          -> both tables MUST be found, else fail naming which is missing
//   --expect-absent  -> both MUST be missing, else fail   (this is the Step 2 run)
// Assert on the specific table NAMES, never on rows.length, so a future third row cannot mask a
// missing one. The visit_requests control must pass in BOTH modes.
console.log('--- audit complete --- ' + JSON.stringify({ probe: 'calendar_task_grants', found: rows.length, failures: fails }))
process.exit(fails ? 1 : 0)
```

- [ ] **Step 2: Run it and confirm the tables are missing**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/calendar_task_grants.mjs
```

Expected: `CONTROL ... true`, then `(tables not created yet)`.

- [ ] **Step 3: Write the migration**

Create `Supabase/docs/migrations/2026-08-26_1810_calendar_tasks_tables.sql`:

```sql
-- 2026-08-26_1810_calendar_tasks_tables.sql
--
-- WHAT: ops.calendar_tasks + ops.calendar_task_assignees.
--
-- 🛑 NOBODY GETS A WRITE GRANT, NOT EVEN service_role. All writes go through
--    ops.fn_record_calendar_task (SECDEF, next migration), called by the save-calendar-task edge
--    function only AFTER Jobber has confirmed the change. That is what makes "no discrepancies"
--    structural rather than a convention: there is no PostgREST write path to bypass it.
--    Grant shape copied from ops.visit_requests (authenticated=r, service_role=r), NOT from
--    ops.calendar_day_markers, which grants authenticated 'arwd' under a FOR ALL USING(true)
--    policy and lets any signed-in browser delete any row.
--
-- AUDIT (ADR 010): OPT IN, both tables. A task assigned to someone else is cross-user state on
--    day one. Precedent: client.saved_views opted out and was reversed within 24 hours.

BEGIN;

CREATE TABLE ops.calendar_tasks (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title            text        NOT NULL CHECK (btrim(title) <> ''),
  instructions     text,
  task_date        date        NOT NULL,
  minutes          smallint    CHECK (minutes BETWEEN 0 AND 1439),
  duration_minutes smallint    NOT NULL DEFAULT 30 CHECK (duration_minutes BETWEEN 1 AND 1440),
  all_day          boolean     NOT NULL DEFAULT false,
  client_id        bigint      REFERENCES public.clients(id),
  property_id      bigint      REFERENCES public.properties(id),
  visit_id         bigint      REFERENCES public.visits(id),
  is_complete      boolean     NOT NULL DEFAULT false,
  completed_at     timestamptz,
  completed_source text        CHECK (completed_source IN ('calendar','jobber')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  -- all_day is true EXACTLY when there is no clock time
  CONSTRAINT calendar_tasks_allday_chk CHECK (all_day = (minutes IS NULL)),
  -- completion metadata travels together
  CONSTRAINT calendar_tasks_completion_chk
    CHECK ((is_complete AND completed_at IS NOT NULL AND completed_source IS NOT NULL)
        OR (NOT is_complete AND completed_at IS NULL AND completed_source IS NULL))
);

CREATE INDEX calendar_tasks_task_date_idx ON ops.calendar_tasks (task_date);
CREATE INDEX calendar_tasks_visit_id_idx  ON ops.calendar_tasks (visit_id) WHERE visit_id IS NOT NULL;
-- the poll's working set: open tasks only
CREATE INDEX calendar_tasks_open_idx      ON ops.calendar_tasks (id) WHERE NOT is_complete;

CREATE TABLE ops.calendar_task_assignees (
  task_id     bigint NOT NULL REFERENCES ops.calendar_tasks(id) ON DELETE CASCADE,
  employee_id bigint NOT NULL REFERENCES public.employees(id),
  PRIMARY KEY (task_id, employee_id)
);

-- updated_at: a REAL trigger. ops.calendar_day_markers has DEFAULT now() and NO trigger, so its
-- updated_at freezes at insert. Do not copy that.
CREATE TRIGGER trg_calendar_tasks_updated_at
  BEFORE UPDATE ON ops.calendar_tasks
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Audit opt-in (ADR 010)
CREATE TRIGGER audit_calendar_tasks
  AFTER INSERT OR UPDATE OR DELETE ON ops.calendar_tasks
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();
CREATE TRIGGER audit_calendar_task_assignees
  AFTER INSERT OR UPDATE OR DELETE ON ops.calendar_task_assignees
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- Grants: READ ONLY for everyone. Supabase ALTER DEFAULT PRIVILEGES hands out grants nobody
-- wrote, so revoke explicitly first rather than assuming a new table starts empty.
REVOKE ALL ON ops.calendar_tasks           FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON ops.calendar_task_assignees  FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT ON ops.calendar_tasks          TO authenticated, service_role, yannick_readonly;
GRANT SELECT ON ops.calendar_task_assignees TO authenticated, service_role, yannick_readonly;

ALTER TABLE ops.calendar_tasks          ENABLE ROW LEVEL SECURITY;
ALTER TABLE ops.calendar_task_assignees ENABLE ROW LEVEL SECURITY;

CREATE POLICY calendar_tasks_read ON ops.calendar_tasks
  FOR SELECT TO authenticated, service_role USING (true);
CREATE POLICY calendar_task_assignees_read ON ops.calendar_task_assignees
  FOR SELECT TO authenticated, service_role USING (true);

COMMENT ON TABLE ops.calendar_tasks IS
  'Office tasks created in the Visit Calendar and mirrored to Jobber as Jobber Tasks. MASTER copy. '
  'No role holds a write grant: all writes go through ops.fn_record_calendar_task after Jobber has '
  'confirmed the change. See Building Apps/Visit Calendar/docs/specs/2026-08-25-calendar-tasks-design.md';

COMMIT;
```

⚠ **Verify `public.set_updated_at()` is the real function name before applying:**

```sql
select n.nspname||'.'||p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where p.proname ilike '%updated_at%' order by 1;
```

Use whatever that returns. If the estate's helper has a different name, use the real one.

- [ ] **Step 4: Apply, then re-run the probe**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/calendar_task_grants.mjs
```

Expected: control true, and both new tables report `OK`.

- [ ] **Step 5: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && git add docs/migrations/2026-08-26_1810_calendar_tasks_tables.sql scripts/probes/calendar_task_grants.mjs && git commit -- docs/migrations/2026-08-26_1810_calendar_tasks_tables.sql scripts/probes/calendar_task_grants.mjs -m "Add ops.calendar_tasks with no write grant for any role

Writes go through a SECDEF recorder called only after Jobber confirms, so the
no-discrepancy guarantee is structural rather than a convention.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" && git push origin main
```

---

### Task 3: `ops.fn_record_calendar_task`

The single writer. Persists the task, its assignees and the link row in one transaction.

**Files:**
- Create: `Supabase/docs/migrations/2026-08-26_1820_fn_record_calendar_task.sql`
- Create: `Supabase/scripts/probes/calendar_task_recorder.mjs`

- [ ] **Step 1: Write the failing probe**

Create `Supabase/scripts/probes/calendar_task_recorder.mjs`:

```js
import { sql } from './calendar_task_esl.mjs'

// Rolled back. Exercises upsert-by-jobber-gid, assignee replacement, and the link row.
const out = await sql(`
  begin;
  select ops.fn_record_calendar_task(jsonb_build_object(
    'jobber_gid',   'PROBE-GID-1',
    'title',        'Probe task',
    'task_date',    current_date,
    'minutes',      540,
    'all_day',      false,
    'duration_minutes', 30,
    'assignee_ids', '[]'::jsonb
  )) as first_call;
  select ops.fn_record_calendar_task(jsonb_build_object(
    'jobber_gid',   'PROBE-GID-1',
    'title',        'Probe task RENAMED',
    'task_date',    current_date,
    'minutes',      540,
    'all_day',      false,
    'duration_minutes', 30,
    'assignee_ids', '[]'::jsonb
  )) as second_call;
  select count(*) as task_rows from ops.calendar_tasks where title like 'Probe task%';
  select count(*) as link_rows from public.entity_source_links
   where entity_type='calendar_task' and source_id='PROBE-GID-1';
  rollback;`)

console.log(JSON.stringify(out, null, 1))
console.log('EXPECT: second_call returns the SAME id as first_call, task_rows=1, link_rows=1')
console.log('--- audit complete --- ' + JSON.stringify({ probe: 'calendar_task_recorder' }))
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/calendar_task_recorder.mjs
```

Expected: throws with `function ops.fn_record_calendar_task(jsonb) does not exist`.

- [ ] **Step 3: Write the migration**

Create `Supabase/docs/migrations/2026-08-26_1820_fn_record_calendar_task.sql`:

```sql
-- 2026-08-26_1820_fn_record_calendar_task.sql
--
-- WHAT: the ONLY writer for ops.calendar_tasks. SECDEF, EXECUTE to service_role only.
--
-- WHY: no role holds a write grant on the table (2026-08-25_1610). The save-calendar-task edge
--      function calls this AFTER Jobber has confirmed the change, so our row can never describe
--      a state Jobber does not have. Precedent: public.fn_record_client_job, same shape.
--
-- ⚠ IDEMPOTENT ON jobber_gid. The edge function may retry after a network failure that actually
--   succeeded upstream; a second call with the same GID must update, never insert a duplicate.
--
-- ⚠ ASSIGNEES REPLACE ON PRESENCE. Omit the key to leave them alone; pass [] to clear. This
--   mirrors ops.update_visit_request's jsonb key-presence style.
--
-- AUDIT (ADR 010): writes audited tables; the function itself needs no trigger.

BEGIN;

CREATE OR REPLACE FUNCTION ops.fn_record_calendar_task(p jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ops, public, pg_temp
AS $function$
DECLARE
  v_gid  text := p->>'jobber_gid';
  v_id   bigint;
BEGIN
  IF v_gid IS NULL OR btrim(v_gid) = '' THEN
    RAISE EXCEPTION 'jobber_gid is required' USING ERRCODE = '22023';
  END IF;

  SELECT entity_id INTO v_id
    FROM public.entity_source_links
   WHERE entity_type = 'calendar_task' AND source_system = 'jobber' AND source_id = v_gid;

  IF v_id IS NULL THEN
    INSERT INTO ops.calendar_tasks
      (title, instructions, task_date, minutes, duration_minutes, all_day,
       client_id, property_id, visit_id, is_complete, completed_at, completed_source)
    VALUES
      (p->>'title', p->>'instructions', (p->>'task_date')::date,
       (p->>'minutes')::smallint, coalesce((p->>'duration_minutes')::smallint, 30),
       coalesce((p->>'all_day')::boolean, false),
       (p->>'client_id')::bigint, (p->>'property_id')::bigint, (p->>'visit_id')::bigint,
       coalesce((p->>'is_complete')::boolean, false),
       (p->>'completed_at')::timestamptz, p->>'completed_source')
    RETURNING id INTO v_id;

    INSERT INTO public.entity_source_links (entity_type, entity_id, source_system, source_id)
    VALUES ('calendar_task', v_id, 'jobber', v_gid);
  ELSE
    UPDATE ops.calendar_tasks SET
      title            = coalesce(p->>'title', title),
      instructions     = CASE WHEN p ? 'instructions' THEN p->>'instructions' ELSE instructions END,
      task_date        = coalesce((p->>'task_date')::date, task_date),
      minutes          = CASE WHEN p ? 'minutes' THEN (p->>'minutes')::smallint ELSE minutes END,
      duration_minutes = coalesce((p->>'duration_minutes')::smallint, duration_minutes),
      all_day          = coalesce((p->>'all_day')::boolean, all_day),
      client_id        = CASE WHEN p ? 'client_id'   THEN (p->>'client_id')::bigint   ELSE client_id   END,
      property_id      = CASE WHEN p ? 'property_id' THEN (p->>'property_id')::bigint ELSE property_id END,
      visit_id         = CASE WHEN p ? 'visit_id'    THEN (p->>'visit_id')::bigint    ELSE visit_id    END,
      is_complete      = coalesce((p->>'is_complete')::boolean, is_complete),
      completed_at     = CASE WHEN p ? 'is_complete'
                              THEN (p->>'completed_at')::timestamptz ELSE completed_at END,
      completed_source = CASE WHEN p ? 'is_complete'
                              THEN p->>'completed_source' ELSE completed_source END
    WHERE id = v_id;
  END IF;

  -- assignees REPLACE on presence only
  IF p ? 'assignee_ids' THEN
    DELETE FROM ops.calendar_task_assignees WHERE task_id = v_id;
    INSERT INTO ops.calendar_task_assignees (task_id, employee_id)
    SELECT v_id, (e)::bigint
      FROM jsonb_array_elements_text(p->'assignee_ids') AS e
     WHERE btrim(e) <> ''
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION ops.fn_record_calendar_task(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ops.fn_record_calendar_task(jsonb) TO service_role;

-- The deleter, same access model.
CREATE OR REPLACE FUNCTION ops.fn_delete_calendar_task(p_task_id bigint)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ops, public, pg_temp
AS $function$
BEGIN
  DELETE FROM public.entity_source_links
   WHERE entity_type = 'calendar_task' AND entity_id = p_task_id;
  DELETE FROM ops.calendar_tasks WHERE id = p_task_id;
  RETURN FOUND;
END;
$function$;

REVOKE ALL ON FUNCTION ops.fn_delete_calendar_task(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ops.fn_delete_calendar_task(bigint) TO service_role;

COMMIT;
```

⚠ **A hard delete is correct here and is NOT a rule-6 violation.** Rule 6 protects business records like clients and visits. A calendar task deleted by the person who created it, whose Jobber twin has already been deleted and verified gone, has no history to preserve, and `audit.logs` retains the `old_row` because Task 2 opted both tables in.

- [ ] **Step 4: Apply, then re-run the probe**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/calendar_task_recorder.mjs
```

Expected: `first_call` and `second_call` return the **same** id, `task_rows` 1, `link_rows` 1.

- [ ] **Step 5: Verify `authenticated` still cannot write**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/calendar_task_grants.mjs
```

Expected: unchanged, both tables `OK`. Adding a SECDEF function must not have widened anything.

- [ ] **Step 6: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && git add docs/migrations/2026-08-26_1820_fn_record_calendar_task.sql scripts/probes/calendar_task_recorder.mjs && git commit -- docs/migrations/2026-08-26_1820_fn_record_calendar_task.sql scripts/probes/calendar_task_recorder.mjs -m "Add the single SECDEF writer for calendar tasks

Idempotent on the Jobber GID so a retry after a network failure that actually
succeeded upstream updates rather than duplicating.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" && git push origin main
```

---

## Phase B — Edge functions

### Task 4: `save-calendar-task` (the saga)

**Files:**
- Create: `Supabase/supabase/functions/save-calendar-task/index.ts`
- Modify: `Supabase/supabase/config.toml` (add the function block)

- [ ] **Step 1: Copy the helpers verbatim, do not retype them**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && mkdir -p supabase/functions/save-calendar-task && sed -n '36,150p' supabase/functions/jobber-push-task/index.ts > /tmp/helpers.ts && wc -l /tmp/helpers.ts
```

Take `getJobberToken`, `gql` (**including the content-type waiting-room check**), `errsOf` and `json` from that extract. **Do not reimplement them.** Retyping a body is how `2026-08-06_1316` silently dropped six clauses from a live function.

Drop `bearerRole`: this function is browser-called and uses in-handler `auth.getUser()` instead (Step 3).

- [ ] **Step 2: Write the function**

Create `Supabase/supabase/functions/save-calendar-task/index.ts`. Structure, with the helper bodies pasted in from Step 1:

```ts
// ============================================================================
// save-calendar-task — the Visit Calendar's VERIFIED task saga.
//
// PUSH to Jobber -> READ THE TASK BACK -> only then record locally.
// On ANY failure: write NOTHING and return a typed error the app displays.
//
// 🛑 WHY NOT A TRIGGER + pg_net (which is what ops.calendar_day_markers does):
//    pg_net is fire-and-forget. The transaction commits without waiting, so it CANNOT fail
//    closed and CANNOT return an error to the app. Fred, 2026-08-25: "if jobber gets an issue
//    while completing it on our app, then our app also shows that error so it can't be
//    completed. I don't want discrepancies."
//
// 🛑 AUTH: verify_jwt=false in config.toml, in-handler auth.getUser() + staff-domain gate.
//    NOT the fail-open idiom. This project signs session tokens with ES256 and the gateway
//    rejects them on newer functions (401 UNAUTHORIZED_ASYMMETRIC_JWT). Same as
//    adopt-visit-from-jobber and save-client-job. auth.getUser() round-trips to GoTrue and is
//    STRONGER than the gateway check, which the public anon key also passes.
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GQL_VERSION  = "2026-04-16";
const ENTITY_TYPE  = "calendar_task";

const db  = createClient(SUPABASE_URL, SERVICE_KEY);
const ops = createClient(SUPABASE_URL, SERVICE_KEY, { db: { schema: "ops" } });

// --- paste getJobberToken, gql, errsOf, json from /tmp/helpers.ts here ---

const TASK_READ = `query($id:EncodedId!){ task(id:$id){
  id title isComplete allDay startAt endAt instructions
  client{id} property{id} assignedUsers(first:20){nodes{id}} } }`;

function fail(kind: string, message: string, status = 400) {
  return json({ ok: false, kind, message }, status);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return fail("method", "POST only", 405);

  // AUTH
  const m = (req.headers.get("authorization") ?? "").match(/^Bearer (.+)$/);
  if (!m) return fail("forbidden", "Staff account required.", 403);
  const { data: u, error: uErr } = await db.auth.getUser(m[1]);
  const email = String(u?.user?.email ?? "").toLowerCase();
  if (uErr || !u?.user?.id ||
      (!email.endsWith("@ayache.com") && !email.endsWith("@unclogme.com"))) {
    return fail("forbidden", "Staff account required.", 403);
  }

  let body: any;
  try { body = await req.json(); } catch { return fail("bad_request", "Invalid JSON body."); }

  const op = String(body.op ?? "");
  if (!["create", "edit", "complete", "delete"].includes(op)) {
    return fail("bad_request", `Unknown op '${op}'.`);
  }

  let token: string;
  try { token = await getJobberToken(); }
  catch (e) { return fail("jobber_unavailable", String(e), 503); }

  // ---- resolve the existing GID for anything that is not a create ----
  let gid: string | null = null;
  if (op !== "create") {
    const { data: link } = await db.from("entity_source_links")
      .select("source_id")
      .eq("entity_type", ENTITY_TYPE).eq("source_system", "jobber")
      .eq("entity_id", body.task_id).maybeSingle();
    if (!link?.source_id) return fail("not_linked", "That task has no Jobber link.", 409);
    gid = link.source_id;
  }

  // ---- 1. PUSH ----
  let res: any, field: string;
  if (op === "create") {
    field = "taskCreate";
    res = await gql(token, `mutation($cid:EncodedId,$pid:EncodedId,$in:TaskCreateInput!){
      taskCreate(clientId:$cid, propertyId:$pid, input:$in){ task{id} userErrors{message path} } }`,
      { cid: body.client_gid ?? null, pid: body.property_gid ?? null, in: body.input });
  } else if (op === "edit") {
    field = "taskEdit";
    res = await gql(token, `mutation($id:EncodedId!,$in:TaskEditInput!){
      taskEdit(taskId:$id, input:$in){ task{id} userErrors{message path} } }`,
      { id: gid, in: body.input });
  } else if (op === "complete") {
    field = "appointmentEditCompleteness";
    res = await gql(token, `mutation($id:EncodedId!,$c:Boolean!){
      appointmentEditCompleteness(appointmentId:$id, input:{completed:$c}){ userErrors{message path} } }`,
      { id: gid, c: !!body.completed });
  } else {
    field = "taskDelete";
    res = await gql(token, `mutation($ids:[EncodedId!]!){
      taskDelete(taskIds:$ids){ userErrors{message path} } }`, { ids: [gid] });
  }

  const errs = errsOf(res, field);
  if (errs.length) return fail("jobber_rejected", errs.join("; "), 502);

  if (op === "create") {
    gid = res?.data?.taskCreate?.task?.id ?? null;
    if (!gid) return fail("jobber_no_id", "Jobber accepted the create but returned no task id.", 502);
  }

  // ---- 2. READ BACK. Never trust the mutation's own response. ----
  const back = await gql(token, TASK_READ, { id: gid });
  const task = back?.data?.task ?? null;

  if (op === "delete") {
    // POSITIVE PROOF REQUIRED. A reply with no `data` key is NOT evidence the task is gone.
    if (!("data" in (back ?? {}))) {
      return fail("jobber_unverified", "Jobber did not answer; the task may still exist.", 502);
    }
    if (task) return fail("jobber_not_deleted", "Jobber still returns that task.", 502);
    const { error } = await ops.rpc("fn_delete_calendar_task", { p_task_id: body.task_id });
    if (error) return fail("db_error", error.message, 500);
    return json({ ok: true, op, verified_gone: true });
  }

  if (!task) return fail("jobber_unverified", "Could not read the task back from Jobber.", 502);
  if (op === "complete" && task.isComplete !== !!body.completed) {
    return fail("jobber_unverified",
      `Jobber still reports isComplete=${task.isComplete}.`, 502);
  }

  // ---- 3. ONLY NOW record locally ----
  const payload: Record<string, unknown> = {
    jobber_gid: gid,
    title: task.title,
    instructions: task.instructions,
    task_date: body.task_date,
    minutes: body.minutes ?? null,
    all_day: !!task.allDay,
    duration_minutes: body.duration_minutes ?? 30,
    client_id: body.client_id ?? null,
    property_id: body.property_id ?? null,
    visit_id: body.visit_id ?? null,
  };
  if (body.assignee_ids !== undefined) payload.assignee_ids = body.assignee_ids;
  if (op === "complete") {
    payload.is_complete = !!body.completed;
    payload.completed_at = body.completed ? new Date().toISOString() : null;
    payload.completed_source = body.completed ? "calendar" : null;
  }

  const { data: id, error } = await ops.rpc("fn_record_calendar_task", { p: payload });
  if (error) {
    // The Jobber object exists and we could not record it. On CREATE that is an orphan, so
    // compensate exactly as jobber-push-task does.
    if (op === "create") {
      const del = await gql(token, `mutation($ids:[EncodedId!]!){
        taskDelete(taskIds:$ids){ userErrors{message} } }`, { ids: [gid] });
      const rolledBack = errsOf(del, "taskDelete").length === 0;
      return fail("db_error", `${error.message} (jobber task ${rolledBack ? "rolled back" : "ORPHANED " + gid})`, 500);
    }
    return fail("db_error", error.message, 500);
  }

  return json({ ok: true, op, task_id: id, jobber_gid: gid });
});
```

- [ ] **Step 3: Add the config block**

Append to `Supabase/supabase/config.toml`:

```toml
# save-calendar-task: the Visit Calendar's verified task saga (create/edit/complete/delete).
# Browser-called with the real user JWT.
# ⚠ verify_jwt = false is DELIBERATE and is NOT fail-open: this project signs session tokens with
# ES256 and the gateway rejects them on newer functions (401 UNAUTHORIZED_ASYMMETRIC_JWT). The
# handler does auth.getUser() + an @ayache.com/@unclogme.com gate, which is STRONGER than the
# gateway check that the public anon key also passes. Same pattern as save-client-job and
# adopt-visit-from-jobber. Do NOT "harmonise" this to true.
[functions.save-calendar-task]
verify_jwt = false
```

- [ ] **Step 4: Deploy**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && SUPABASE_ACCESS_TOKEN=$(grep '^SUPABASE_PAT=' .env | cut -d= -f2-) supabase functions deploy save-calendar-task --project-ref wbasvhvvismukaqdnouk
```

- [ ] **Step 5: Test the FAILURE leg first**

This is the requirement; the happy path is the easy half. Send an `edit` for a task id that has no link row:

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && curl -s -X POST "https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/save-calendar-task" -H "Content-Type: application/json" -H "Authorization: Bearer $(grep '^SUPABASE_SERVICE_ROLE_KEY=' .env | cut -d= -f2-)" -d '{"op":"edit","task_id":-999,"input":{"title":"x"}}'
```

Expected: `403 forbidden` (a service key is not a staff user). That proves the auth gate. Then repeat with a real staff JWT from the browser and expect `{"ok":false,"kind":"not_linked"}` and **zero rows written**:

```sql
select count(*) from ops.calendar_tasks;   -- must be unchanged
```

- [ ] **Step 6: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && git add supabase/functions/save-calendar-task/index.ts supabase/config.toml && git commit -- supabase/functions/save-calendar-task/index.ts supabase/config.toml -m "Add the verified calendar-task saga

Pushes to Jobber, reads the task back, and only then records locally, so a
Jobber failure can never leave our copy claiming something Jobber does not have.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" && git push origin main
```

---

### Task 5: `poll-calendar-tasks` and its cron

**Files:**
- Create: `Supabase/supabase/functions/poll-calendar-tasks/index.ts`
- Create: `Supabase/docs/migrations/2026-08-26_1840_calendar_task_poll_cron.sql`
- Modify: `Supabase/supabase/config.toml`

- [ ] **Step 1: Write the function**

Create `Supabase/supabase/functions/poll-calendar-tasks/index.ts`. Same helper copy rule as Task 4. Core:

```ts
// Poll Jobber for OUR open tasks only, by GID. No date window and no updatedAt needed:
// TaskFilterAttributes.ids does the whole job, so cost scales with our open-task count.
//
// 🛑 Adopts isComplete in BOTH directions and needs no conflict rule. Every completion we store
//    was already verified in Jobber by save-calendar-task, so for this one field Jobber is the
//    authority by construction. See spec 3.2.
// 🛑 A task Jobber no longer has is REPORTED, never deleted. Rule 6: we do not destroy business
//    data on an inference, and the poll cannot tell "deleted upstream" from a malformed reply.

const { data: open } = await ops.from("calendar_tasks").select("id").eq("is_complete", false);
const ids = (open ?? []).map((r: any) => r.id);
if (!ids.length) return json({ ok: true, checked: 0, adopted: 0 });

const { data: links } = await db.from("entity_source_links")
  .select("entity_id, source_id")
  .eq("entity_type", "calendar_task").eq("source_system", "jobber").in("entity_id", ids);

const byGid = new Map((links ?? []).map((l: any) => [l.source_id, l.entity_id]));
const gids = [...byGid.keys()];

const res = await gql(token, `query($ids:[EncodedId!]){
  tasks(first:100, filter:{ids:$ids}){ nodes{ id isComplete } } }`, { ids: gids });
if (!("data" in (res ?? {}))) return json({ ok: false, kind: "jobber_unavailable" }, 502);

const seen = new Set<string>();
let adopted = 0;
for (const n of res.data.tasks.nodes ?? []) {
  seen.add(n.id);
  if (!n.isComplete) continue;                       // still open, nothing to do
  await ops.rpc("fn_record_calendar_task", { p: {
    jobber_gid: n.id, is_complete: true,
    completed_at: new Date().toISOString(), completed_source: "jobber" } });
  adopted++;
}

const missing = gids.filter((g) => !seen.has(g));    // reported, never deleted
return json({ ok: true, checked: gids.length, adopted, missing });
```

⚠ **`tasks(first:100)` caps the page.** If our open-task count can exceed 100, paginate with `after`. Assert this rather than assuming: `select count(*) from ops.calendar_tasks where not is_complete;`

- [ ] **Step 2: Deploy and invoke once by hand**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && SUPABASE_ACCESS_TOKEN=$(grep '^SUPABASE_PAT=' .env | cut -d= -f2-) supabase functions deploy poll-calendar-tasks --project-ref wbasvhvvismukaqdnouk
```

Expected on an empty table: `{"ok":true,"checked":0,"adopted":0}`.

- [ ] **Step 3: Write the cron migration**

Create `Supabase/docs/migrations/2026-08-26_1840_calendar_task_poll_cron.sql`, following the existing `fn_request_jobber_sync` wrapper pattern (read it first: `select prosrc from pg_proc where proname='fn_request_jobber_sync';`) so the cron command calls a SQL wrapper rather than embedding the URL:

```sql
-- 2026-08-26_1840_calendar_task_poll_cron.sql
--
-- WHAT: */5 cron that polls Jobber for completion on our open calendar tasks.
--
-- 🛑 DELIBERATELY ITS OWN CRON, NOT FOLDED INTO sync-jobber-poll. That function is the busiest
--    thing we run and is delicate (raising its replay cap once left it working while silently
--    not writing its sync_log row). This poll is the safety net for discrepancies, so it must not
--    share a failure domain with the sync it is checking. Fred agreed 2026-08-25.
--
-- AUDIT (ADR 010): no table changes.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_request_calendar_task_poll()
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $function$
  SELECT net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/poll-calendar-tasks',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'Authorization','Bearer '||public.edge_invoke_service_key()),
    body    := '{}'::jsonb) ;
$function$;

SELECT cron.schedule('calendar-task-poll', '*/5 * * * *',
                     'SELECT public.fn_request_calendar_task_poll()');

COMMIT;
```

⚠ **Confirm `public.edge_invoke_service_key()` is the real helper name** before applying: `select proname from pg_proc where proname ilike '%edge_invoke%';` Use whatever exists.

- [ ] **Step 4: Verify the cron actually fired**

Wait six minutes, then:

```sql
select jobname, status, return_message, start_time
  from cron.job_run_details d join cron.job j using (jobid)
 where j.jobname = 'calendar-task-poll' order by start_time desc limit 3;
```

⚠ **A `succeeded` here means the SQL ran, NOT that the edge function did anything.** `pg_net` is fire-and-forget. Confirm the real outcome in `net._http_response` (retained about 6 hours).

- [ ] **Step 5: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && git add supabase/functions/poll-calendar-tasks/index.ts supabase/config.toml docs/migrations/2026-08-26_1840_calendar_task_poll_cron.sql && git commit -- supabase/functions/poll-calendar-tasks/index.ts supabase/config.toml docs/migrations/2026-08-26_1840_calendar_task_poll_cron.sql -m "Poll Jobber for calendar-task completion on its own cron

Queries by Task GID via TaskFilterAttributes.ids, so it needs no date window and
no updatedAt. Kept out of sync-jobber-poll so the safety net cannot take down the
sync it checks.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" && git push origin main
```

---

## Phase C — The Visit Calendar app (Lovable prompts, not file edits)

🛑 **There is no local React source. Every task here is a prompt to the Lovable editor at `https://lovable.dev/projects/6533c3ee-94f5-499c-96d1-c8847a729a8f`, then a Publish, then verification against the live bundle.**

Before starting, re-read `Building Apps/CLAUDE.md` Lovable rules. The ones that will bite:
- **Rule 9:** Enter submits. Keep every prompt on ONE line, using "ITEM 1: ... ITEM 2: ..." separators.
- **Rule 8:** click into the `.ProseMirror` composer; a JS `focus()` reports success and swallows the text.
- **Rule 13:** one owner per Lovable project. Check `WORKING-NOW.md` before driving the editor.
- **Rule 17:** the publish panel can say "Up to date" while the live site lacks the change. Verify against the live bundle with recursive chunk discovery, never the entry chunk alone.

### Task 6: Read-only task chips on the grid

- [ ] **Step 1: Send the prompt** (one line)

> ITEM 1: Add a read-only task layer to the calendar. Read `ops.calendar_tasks` (schema `ops`, existing authenticated client) selecting id, title, task_date, minutes, duration_minutes, all_day, is_complete, client_id, visit_id, and render each as a chip on the Month, Week and Day grids positioned by task_date and minutes exactly like a visit, with all_day tasks in the ANYTIME row. ITEM 2: The task chip must use a NEUTRAL fill with NO zone tint, NO coloured left border, and NO SA service-group colour, because those three encode zone, lateness and service group for visits and must not be reused; give it a leading clipboard icon and a check icon that is filled when is_complete is true. ITEM 3: Tasks must be excluded from every visit count, the dollar, gallon, drive-time and on-site statistics, and from the truck and zone filters, so a day containing a task shows an unchanged visit count. ITEM 4: Task chips are NOT draggable in this change.

- [ ] **Step 2: Publish, then verify against the LIVE bundle**

```bash
cd "C:/Users/FRED/AppData/Local/Temp/claude/C--Users-FRED-Desktop-Virtrify-Yannick-Claude/7c2a3b02-2bd0-4e90-925a-a417d2e23728/scratchpad" && node -e "
(async () => {
  const html = await (await fetch('https://calendar.unclogme.app/')).text();
  const seeds = [...html.matchAll(/\/assets\/[A-Za-z0-9._-]+\.js/g)].map(m => m[0]);
  const seen = new Set(); let src = '';
  const walk = async (p) => { if (seen.has(p)) return; seen.add(p);
    const t = await (await fetch('https://calendar.unclogme.app' + p)).text(); src += t;
    for (const m of t.matchAll(/[\"'\`](\/assets\/[A-Za-z0-9._-]+\.js)[\"'\`]/g)) await walk(m[1]); };
  for (const s of seeds) await walk(s);
  console.log('chunks: ' + seen.size + '  bytes: ' + src.length);
  console.log('calendar_tasks present: ' + src.includes('calendar_tasks'));
  console.log('CONTROL v_calendar_visit present: ' + src.includes('v_calendar_visit'));
})()"
```

Expected: `calendar_tasks present: true` **and** the control true. A control that fails means the scan is broken, not that the feature is missing.

- [ ] **Step 3: Verify the counts did not move**

In the live app with a day that has a task, read the day-header visit count before and after inserting a test task row. It must be **identical**. Assert both directions: at least one task chip must render (a one-sided check passes when the feature is missing entirely).

- [ ] **Step 4: Commit the app-side doc**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Building Apps" && git add "Visit Calendar/docs/08-changelog.md" && git commit -- "Visit Calendar/docs/08-changelog.md" -m "Document the read-only task chip layer on the calendar grid" && git push origin main
```

### Task 7: Create, edit, complete and delete from the app

- [ ] **Step 1: Send the prompt** (one line)

> ITEM 1: Add a task drawer and a New Task action. All writes go to the edge function `save-calendar-task` via supabase.functions.invoke with the user's session, never to the table directly, because the table is SELECT-only by design. ITEM 2: The drawer has title, instructions, a date picker, a time picker with an All day toggle, duration, optional client, optional property, and optional assignees from the active employees list; sending no assignees must OMIT the assignee_ids key entirely rather than sending an empty array. ITEM 3: Add a Complete/Reopen control that calls the same function with op complete, and a Delete control behind a confirmation that calls op delete. ITEM 4: If the function returns ok false, show the returned message in the drawer and leave the task in its previous state; never optimistically mark a task complete before the response arrives. ITEM 5: Times display 12-hour with AM/PM at the render site, but the time input value must stay 24-hour HH:mm or the browser rejects it.

- [ ] **Step 2: Publish and verify the failure path in the real UI**

With Jobber reachable, complete a task and confirm it flips. Then set an invalid GID on a test row so the push fails, click Complete, and confirm the drawer shows the error **and the chip does not change state**. That is the requirement.

- [ ] **Step 3: Commit the app-side doc**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Building Apps" && git add "Visit Calendar/docs/08-changelog.md" "Visit Calendar/CLAUDE.md" && git commit -- "Visit Calendar/docs/08-changelog.md" "Visit Calendar/CLAUDE.md" -m "Document calendar task create, edit, complete and delete" && git push origin main
```

---

## Phase D — End-to-end

### Task 8: The live round trip

⚠ **This writes a real Task to production Jobber, which the crew can see. Get Fred's go-ahead at this point rather than folding it into the build.** Model it on the 2026-08-25 contract test: future-dated so no same-day push fires, assigned to Fred so no colleague is notified, `emailAssignments` unset, and deleted with the deletion verified by read-back.

- [ ] **Step 1: Create a task in the app**, clearly titled, on test client 112-YA.
- [ ] **Step 2: Confirm it appears on the Jobber schedule.** ⚠ Assert the Jobber page actually LOADED and other tasks still render; an empty schedule looks identical to a successful delete.
- [ ] **Step 3: Complete it in Jobber**, wait one poll cycle (5 minutes), and confirm the Calendar shows it complete with `completed_source = 'jobber'`.
- [ ] **Step 4: Reopen it in the Calendar**, confirm Jobber shows it open.
- [ ] **Step 5: Delete it in the Calendar**, confirm it is gone from Jobber by read-back, and confirm `ops.calendar_tasks` and `entity_source_links` both have no residue.
- [ ] **Step 6: Re-run every probe** from Phase A and confirm all still pass.
- [ ] **Step 7: Release the claim** in `WORKING-NOW.md` and commit.

---

## Spec coverage check

| spec section | covered by |
|---|---|
| 3.1 saga, fail closed, auth model | Task 4 |
| 3.1 no write grant, SECDEF recorder | Tasks 2, 3 |
| 3.2 poll by ids, both directions, missing reported not deleted | Task 5 |
| 3.3 tables, CHECKs, audit opt-in, real updated_at trigger | Task 2 |
| 3.3 entity_source_links widening | Task 1 |
| 3.4 Jobber operation mapping | Task 4 |
| 4 grid chips, fifth visual language, not counted as visits | Task 6 |
| 4a not draggable | Task 6 Step 1 ITEM 4 |
| 4 drawer, ET, 12-hour display | Task 7 |
| 6 verification: failure leg first, grants after the fact, delete unanswered case, two-sided assertions | Tasks 3.5, 4.5, 6.3, 8 |
| 8 any staff user, delete mirrors, assignee optional | Tasks 3, 4, 7 |

**Not covered, and deliberately:** drag (spec 4a), recurrence, `emailAssignments` (spec 5). The Jobber mobile visibility **permission** (spec 8) is an account setting for Fred, not a task.

---

## ⚠ Found during execution, deliberately out of scope, do not lose

**`sync.source_field_shadow_entity_type_chk` now DIVERGES from `entity_source_links_entity_type_chk`.**
Found by the Task 1 spec reviewer, 2026-08-26.

`docs/migrations/2026-08-17_1636_jobber_custom_field_shadow.sql:215-219` carries a **deliberately
parallel copy** of the same vocabulary, with a comment saying so: *"Same vocabulary as
public.entity_source_links_entity_type_chk"*. Task 1 widened one and not the other, so the two lists
no longer match.

**Inert today**, and that is measured rather than assumed: `sync.source_field_shadow` exists for the
Jobber custom-field shadow (grease trap size), calendar tasks never write shadow rows, and widening
it would have needed a second migration that Task 1's spec explicitly excluded. Leaving it was the
correct call.

🛑 **But it is now a trap of exactly the shape this repo keeps paying for**: two copies of one
vocabulary, one updated, and a comment still asserting they are the same. Whoever next adds an
`entity_type` anywhere should widen both or delete the comment. Do not "tidy" it as part of this
plan.
