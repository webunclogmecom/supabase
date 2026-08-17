# Call-Before-Scheduling Clients Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Diego a reliable reminder to call approval-required clients, without the scheduling engine creating dated visits nobody agreed to.

**Architecture:** A small `ops.client_call_policy` table holds a per-client call cadence. A daily pg_cron function files a **dateless** `ops.visit_requests` row into the Calendar's existing TO BE SCHEDULED queue. A Slack digest points at that queue but never holds a task of its own. Approving uses the existing schedule flow; "not now" snoozes the policy to a client-given date.

**Tech Stack:** Postgres (Supabase Prod `wbasvhvvismukaqdnouk`), pg_cron + pg_net, Supabase Edge Functions (Deno/TypeScript), Slack `chat.postMessage`, Lovable/React for the Visit Calendar.

**Spec:** [`../specs/2026-08-17-call-before-scheduling-clients-design.md`](../specs/2026-08-17-call-before-scheduling-clients-design.md)

---

## Before you start

**Read these first.** This repo has rules that will fail your work if you skip them:

- `Supabase/CLAUDE.md` — rule #8 (audit opt-in/opt-out **must** be stated in every migration header), the `CREATE OR REPLACE` copy-never-retype rule, and the grants asymmetry (`CREATE TABLE` hands out privileges **before** your GRANT statements run — check `relacl` after the fact).
- `Building Apps/Visit Calendar/CLAUDE.md` — the Calendar's rules, including that visit **requests** are dateless and reach Jobber only once scheduled.
- Root `CLAUDE.md` §5 — claim your work in `WORKING-NOW.md` before touching shared resources.

**How this repo tests DB work.** There is no pytest. The idiom is a **rolled-back probe**: a `.sql` file wrapped in `begin; … rollback;` that asserts with `raise exception`, run through the Management API:

```bash
node scripts/q.js path/to/probe.sql /tmp/out.json
```

`scripts/q.js` reads `Supabase/.env` itself. A probe that passes prints a single result row; a probe that fails returns an `ERROR:` message in the JSON.

🛑 **Every probe must carry a positive control** — an assertion that FAILS if the thing you are testing is absent. A probe returning "0 problems" against a broken instrument is the single most common failure mode in this codebase. If your probe cannot fail, it is not a test.

**Claim the work before Task 1:**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude"
printf '\n## %s · call-before-scheduling build · ops.client_call_policy + ops.visit_requests\n' "$(date +%F)" >> WORKING-NOW.md
git add WORKING-NOW.md && git commit -m "Claim the call-before-scheduling build" && git push
```

---

## File structure

| file | responsibility |
|---|---|
| `Supabase/docs/migrations/2026-08-17_1600_client_call_policy.sql` | **Create:** the policy table, its audit trigger, its grants |
| `Supabase/docs/migrations/2026-08-17_1610_visit_requests_call_required.sql` | **Create:** `call_required` column + expose it in `ops.v_visit_requests` |
| `Supabase/docs/migrations/2026-08-17_1620_file_due_call_requests.sql` | **Create:** the daily filer function + pg_cron schedule |
| `Supabase/docs/migrations/2026-08-17_1630_call_policy_lifecycle.sql` | **Create:** snooze RPC + advance-on-schedule trigger |
| `Supabase/docs/migrations/2026-08-17_1640_v_client_call_policy.sql` | **Create:** policy + GDO ceiling view for the UI warning |
| `Supabase/supabase/functions/call-due-digest/index.ts` | **Create:** reads the queue, posts one Slack digest. Best-effort. |
| `Supabase/docs/migrations/2026-08-17_1650_call_digest_invoker.sql` | **Create:** `fn_request_call_digest()` + its pg_cron schedule |
| `Supabase/scripts/probes/call_policy_*.sql` | **Create:** the rolled-back probes for each task |
| `Building Apps/Visit Calendar/docs/08-changelog.md` | **Modify:** app-facing write-up (root `CLAUDE.md` §4b) |

**Phase 1 (Tasks 1-5) ships standalone and is already useful**: Diego sees due clients in TO BE SCHEDULED. Phases 2 and 3 add the Slack nudge and the UI polish.

---

## Task 1: The policy table

**Files:**
- Create: `Supabase/docs/migrations/2026-08-17_1600_client_call_policy.sql`
- Test: `Supabase/scripts/probes/call_policy_table.sql`

- [ ] **Step 1: Write the failing probe**

Create `Supabase/scripts/probes/call_policy_table.sql`:

```sql
begin;
do $probe$
declare n int;
begin
  -- the table exists with the columns the filer will rely on
  select count(*) into n from information_schema.columns
   where table_schema='ops' and table_name='client_call_policy'
     and column_name in ('client_id','job_id','service_line_item_ids','cadence_days','next_call_at','paused','notes');
  if n <> 7 then raise exception 'expected 7 known columns, found %', n; end if;

  -- audit rule #8: this table holds human-edited policy, so it MUST be audited
  select count(*) into n from pg_trigger t
    join pg_class c on c.oid=t.tgrelid join pg_namespace ns on ns.oid=c.relnamespace
    join pg_proc p on p.oid=t.tgfoid join pg_namespace pn on pn.oid=p.pronamespace
   where ns.nspname='ops' and c.relname='client_call_policy'
     and pn.nspname='audit' and p.proname='log_change' and not t.tgisinternal;
  if n <> 1 then raise exception 'audit trigger missing on ops.client_call_policy (found %)', n; end if;

  -- grants: authenticated may READ, never write directly
  if has_table_privilege('authenticated','ops.client_call_policy','SELECT') is not true then
    raise exception 'authenticated should hold SELECT';
  end if;
  if has_table_privilege('authenticated','ops.client_call_policy','INSERT') then
    raise exception 'authenticated must NOT hold INSERT (CREATE TABLE hands this out by default - revoke it)';
  end if;

  -- POSITIVE CONTROL: this assertion must fail if the probe is pointed at nothing.
  perform 1 from information_schema.tables where table_schema='ops' and table_name='visit_requests';
  if not found then raise exception 'CONTROL FAILED: ops.visit_requests missing, probe environment is wrong'; end if;

  raise notice 'ALL PASS';
end $probe$;
select 'PASS' as result;
rollback;
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
node scripts/q.js scripts/probes/call_policy_table.sql /tmp/p1.json && cat /tmp/p1.json
```

Expected: an error mentioning `expected 7 known columns, found 0`.

- [ ] **Step 3: Write the migration**

Create `Supabase/docs/migrations/2026-08-17_1600_client_call_policy.sql`:

```sql
-- 2026-08-17_1600_client_call_policy.sql
--
-- WHY: a few clients will not accept a visit we schedule unilaterally; we must call for approval
-- first. Diego was encoding that with a Service Agreement, which generates dated visits, pushes them
-- to Jobber, puts them on a truck and marks them Late. See
-- docs/superpowers/specs/2026-08-17-call-before-scheduling-clients-design.md.
--
-- This table holds ONLY the policy. It creates nothing schedulable.
--
-- AUDIT (rule #8): OPT-IN. Human-edited business policy, so it carries audit.log_change.
--
-- GRANTS: authenticated gets SELECT only. Writes happen through SECDEF RPCs or by hand as postgres.
-- CREATE TABLE hands out privileges BEFORE the GRANT lines run, so the REVOKE below is the control,
-- not the GRANT (Supabase CLAUDE.md, 2026-08-07 job_frequency_changes incident).

begin;

create table if not exists ops.client_call_policy (
  client_id             bigint      primary key references public.clients(id),
  job_id                bigint      not null references public.jobs(id),
  service_line_item_ids bigint[]    not null,
  cadence_days          int         not null check (cadence_days between 1 and 400),
  next_call_at          date        not null,
  paused                boolean     not null default false,
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

comment on table ops.client_call_policy is
  'Clients that require a phone approval before we schedule. Drives ops.fn_file_due_call_requests, '
  'which files a DATELESS visit request. Nothing here ever creates a visit or reaches Jobber.';
comment on column ops.client_call_policy.service_line_item_ids is
  'Services the filed request carries. ops.create_visit_request rejects anything that is not an '
  'active schedulable Service Call (or code 27), so keep these Service Call codes.';
comment on column ops.client_call_policy.next_call_at is
  'The only mutable state. Advanced to visit_date + cadence_days when a filed request is scheduled, '
  'or set directly by the snooze RPC when the client names a date.';

drop trigger if exists audit_client_call_policy on ops.client_call_policy;
create trigger audit_client_call_policy
  after insert or update or delete on ops.client_call_policy
  for each row execute function audit.log_change();

drop trigger if exists trg_client_call_policy_updated_at on ops.client_call_policy;
create trigger trg_client_call_policy_updated_at
  before update on ops.client_call_policy
  for each row execute function public.set_updated_at();

revoke all on ops.client_call_policy from anon, authenticated;
grant select on ops.client_call_policy to authenticated, service_role;

commit;
```

⚠ If `public.set_updated_at()` does not exist under that name, find the real one first:

```bash
node scripts/q.js /dev/stdin /tmp/fn.json <<'SQL'
select n.nspname||'.'||p.proname as fn from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where p.proname ilike '%updated_at%' and p.prokind='f';
SQL
```

Use whatever that returns; do not invent a name.

- [ ] **Step 4: Apply and re-run the probe**

```bash
node scripts/q.js docs/migrations/2026-08-17_1600_client_call_policy.sql /tmp/apply1.json && cat /tmp/apply1.json
node scripts/q.js scripts/probes/call_policy_table.sql /tmp/p1.json && cat /tmp/p1.json
```

Expected: `[{"result":"PASS"}]`.

- [ ] **Step 5: Commit**

```bash
git add docs/migrations/2026-08-17_1600_client_call_policy.sql scripts/probes/call_policy_table.sql
git commit -m "Add ops.client_call_policy for approval-required clients"
git push origin main
```

---

## Task 2: Mark the request as needing a call

**Files:**
- Create: `Supabase/docs/migrations/2026-08-17_1610_visit_requests_call_required.sql`
- Test: `Supabase/scripts/probes/call_required_column.sql`

- [ ] **Step 1: Write the failing probe**

Create `Supabase/scripts/probes/call_required_column.sql`:

```sql
begin;
do $probe$
declare n int;
begin
  select count(*) into n from information_schema.columns
   where table_schema='ops' and table_name='visit_requests' and column_name='call_required';
  if n <> 1 then raise exception 'ops.visit_requests.call_required missing'; end if;

  -- it must default false so every existing and future ordinary request is unaffected
  select count(*) into n from ops.visit_requests where call_required is null;
  if n <> 0 then raise exception '% rows have NULL call_required; column must be NOT NULL DEFAULT false', n; end if;

  -- the Calendar reads the view, not the table, so the flag has to reach the view
  select count(*) into n from information_schema.columns
   where table_schema='ops' and table_name='v_visit_requests' and column_name='call_required';
  if n <> 1 then raise exception 'call_required not exposed on ops.v_visit_requests'; end if;

  -- POSITIVE CONTROL: a column that does not exist must be reported missing by the same query shape
  select count(*) into n from information_schema.columns
   where table_schema='ops' and table_name='v_visit_requests' and column_name='definitely_not_a_column';
  if n <> 0 then raise exception 'CONTROL FAILED: probe reports phantom columns as present'; end if;

  raise notice 'ALL PASS';
end $probe$;
select 'PASS' as result;
rollback;
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
node scripts/q.js scripts/probes/call_required_column.sql /tmp/p2.json && cat /tmp/p2.json
```

Expected: `ops.visit_requests.call_required missing`.

- [ ] **Step 3: Capture the current view body BEFORE editing it**

🛑 Do not retype the view. Copy it.

```bash
node scripts/q.js /dev/stdin /tmp/vd.json <<'SQL'
select pg_get_viewdef('ops.v_visit_requests'::regclass, true) as def;
SQL
```

Take `def` from that JSON, add `r.call_required,` to the select list next to `r.vehicle_id`, and paste the whole thing into the migration below. Every other byte stays identical.

- [ ] **Step 4: Write the migration**

Create `Supabase/docs/migrations/2026-08-17_1610_visit_requests_call_required.sql`:

```sql
-- 2026-08-17_1610_visit_requests_call_required.sql
--
-- WHY: a filed call reminder is an ordinary dateless visit request, but Diego needs to see at a
-- glance that this one must be phoned through before it is scheduled.
--
-- AUDIT (rule #8): ops.visit_requests is ALREADY audited (verified: 1 audit.log_change trigger).
-- Adding a column to an audited table is captured automatically. No trigger work needed.
--
-- The view body below is pg_get_viewdef output with ONE line added (r.call_required). Copied, not
-- retyped, per Supabase CLAUDE.md.

begin;

alter table ops.visit_requests
  add column if not exists call_required boolean not null default false;

comment on column ops.visit_requests.call_required is
  'TRUE when this request was filed by ops.fn_file_due_call_requests and the client must be phoned '
  'for approval before it is scheduled. Purely informational: it changes nothing about scheduling.';

-- >>> PASTE the pg_get_viewdef output here, with r.call_required added to the select list <<<
create or replace view ops.v_visit_requests as
  -- ... copied body ...
;

commit;
```

- [ ] **Step 5: Apply and re-run the probe**

```bash
node scripts/q.js docs/migrations/2026-08-17_1610_visit_requests_call_required.sql /tmp/apply2.json && cat /tmp/apply2.json
node scripts/q.js scripts/probes/call_required_column.sql /tmp/p2.json && cat /tmp/p2.json
```

Expected: `[{"result":"PASS"}]`.

- [ ] **Step 6: Commit**

```bash
git add docs/migrations/2026-08-17_1610_visit_requests_call_required.sql scripts/probes/call_required_column.sql
git commit -m "Flag visit requests that need a call before scheduling"
git push origin main
```

---

## Task 3: The daily filer

**Files:**
- Create: `Supabase/docs/migrations/2026-08-17_1620_file_due_call_requests.sql`
- Test: `Supabase/scripts/probes/file_due_call_requests.sql`

- [ ] **Step 1: Write the failing probe**

Create `Supabase/scripts/probes/file_due_call_requests.sql`. This is the most important probe in the plan: it asserts the **inertness** property the Service Agreement violated.

```sql
begin;
do $probe$
declare
  v_client bigint; v_job bigint; v_filed int; v_req bigint;
  v_visits_before int; v_visits_after int; v_links int;
begin
  select count(*) into v_visits_before from public.visits;

  -- a due client and a NOT-due client, so the filer has to discriminate
  select id into v_client from public.clients where client_code = '226-JER';
  select id into v_job from public.jobs where id = 1623;

  insert into ops.client_call_policy (client_id, job_id, service_line_item_ids, cadence_days, next_call_at)
  values (v_client, v_job, array[9]::bigint[], 60, current_date);

  v_filed := ops.fn_file_due_call_requests();
  if v_filed <> 1 then raise exception 'expected to file 1 request, filed %', v_filed; end if;

  select id into v_req from ops.visit_requests
   where client_id = v_client and status='open' and call_required order by id desc limit 1;
  if v_req is null then raise exception 'no call_required request was filed'; end if;

  -- THE POINT OF THE WHOLE FEATURE: it must create nothing schedulable.
  select count(*) into v_visits_after from public.visits;
  if v_visits_after <> v_visits_before then
    raise exception 'filer created % public.visits rows; it must create ZERO', v_visits_after - v_visits_before;
  end if;
  select count(*) into v_links from public.entity_source_links
   where entity_type='visit' and synced_at > now() - interval '1 minute';
  if v_links <> 0 then raise exception 'filer produced % Jobber links; it must produce ZERO', v_links; end if;

  -- idempotent: a second run must not duplicate while one is open
  v_filed := ops.fn_file_due_call_requests();
  if v_filed <> 0 then raise exception 're-run filed % duplicates; expected 0', v_filed; end if;

  -- POSITIVE CONTROL: a policy that is not due yet must file nothing.
  update ops.client_call_policy set next_call_at = current_date + 365 where client_id = v_client;
  update ops.visit_requests set status='cancelled' where id = v_req;
  v_filed := ops.fn_file_due_call_requests();
  if v_filed <> 0 then
    raise exception 'CONTROL FAILED: filer filed % for a policy due in a year - it is not reading next_call_at', v_filed;
  end if;

  -- paused policies are skipped
  update ops.client_call_policy set next_call_at = current_date, paused = true where client_id = v_client;
  v_filed := ops.fn_file_due_call_requests();
  if v_filed <> 0 then raise exception 'paused policy still filed %', v_filed; end if;

  raise notice 'ALL PASS';
end $probe$;
select 'PASS' as result;
rollback;
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
node scripts/q.js scripts/probes/file_due_call_requests.sql /tmp/p3.json && cat /tmp/p3.json
```

Expected: an error about `ops.fn_file_due_call_requests` not existing.

- [ ] **Step 3: Write the migration**

Create `Supabase/docs/migrations/2026-08-17_1620_file_due_call_requests.sql`:

```sql
-- 2026-08-17_1620_file_due_call_requests.sql
--
-- WHY: turn a due call cadence into a DATELESS queue item, which is the whole point of the feature.
-- It files through ops.create_visit_request so it inherits that RPC's validation (active non-archived
-- job for the client, services must be schedulable Service Calls).
--
-- AUDIT (rule #8): no new table. ops.visit_requests is already audited; rows filed here are captured.
--
-- LEAD TIME is a constant here on purpose (spec: do not add a per-client column until one is needed).

begin;

create or replace function ops.fn_file_due_call_requests()
returns int
language plpgsql
security definer
set search_path to 'public', 'ops'
as $function$
declare
  c_lead_days constant int := 3;   -- file this many days BEFORE the call is due
  r           record;
  v_filed     int := 0;
  v_req       bigint;
begin
  for r in
    select p.*, cl.client_code, cl.name as client_name
      from ops.client_call_policy p
      join public.clients cl on cl.id = p.client_id
     where not p.paused
       and p.next_call_at - c_lead_days <= current_date
       -- idempotency: never a second open call request for the same client
       and not exists (
         select 1 from ops.visit_requests vr
          where vr.client_id = p.client_id
            and vr.call_required
            and vr.status = 'open'
            and vr.deleted_at is null)
  loop
    v_req := ops.create_visit_request(
      p_client_id             => r.client_id,
      p_job_id                => r.job_id,
      p_service_line_item_ids => r.service_line_item_ids,
      p_title                 => 'Call for approval',
      p_notes                 => coalesce(r.notes || ' | ', '')
                                 || 'Client must approve before scheduling. Call due '
                                 || to_char(r.next_call_at, 'YYYY-MM-DD') || '.'
    );

    update ops.visit_requests set call_required = true where id = v_req;
    v_filed := v_filed + 1;
  end loop;

  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('call-due-filer', now(), now(), 0,
          case when v_filed > 0 then 'attention' else 'ok' end,
          jsonb_build_object('filed', v_filed, 'lead_days', c_lead_days));

  return v_filed;
end;
$function$;

revoke all on function ops.fn_file_due_call_requests() from public, anon, authenticated;

select cron.schedule(
  'call-due-filer',
  '10 11 * * *',        -- 07:10 ET, before the working day, after the overnight crons settle
  $$select ops.fn_file_due_call_requests();$$
);

commit;
```

- [ ] **Step 4: Apply and re-run the probe**

```bash
node scripts/q.js docs/migrations/2026-08-17_1620_file_due_call_requests.sql /tmp/apply3.json && cat /tmp/apply3.json
node scripts/q.js scripts/probes/file_due_call_requests.sql /tmp/p3.json && cat /tmp/p3.json
```

Expected: `[{"result":"PASS"}]`.

- [ ] **Step 5: Verify the cron actually registered**

```bash
node scripts/q.js /dev/stdin /tmp/cron.json <<'SQL'
select jobname, schedule, active from cron.job where jobname = 'call-due-filer';
SQL
```

Expected: one row, `active: true`. A silently unscheduled job is the failure mode that looks exactly like success.

- [ ] **Step 6: Commit**

```bash
git add docs/migrations/2026-08-17_1620_file_due_call_requests.sql scripts/probes/file_due_call_requests.sql
git commit -m "File a dateless queue item when a client call comes due"
git push origin main
```

---

## Task 4: Snooze and advance-on-schedule

**Files:**
- Create: `Supabase/docs/migrations/2026-08-17_1630_call_policy_lifecycle.sql`
- Test: `Supabase/scripts/probes/call_policy_lifecycle.sql`

- [ ] **Step 1: Write the failing probe**

Create `Supabase/scripts/probes/call_policy_lifecycle.sql`:

```sql
begin;
do $probe$
declare
  v_client bigint; v_job bigint; v_req bigint; v_next date; v_visit bigint;
begin
  select id into v_client from public.clients where client_code='226-JER';
  select id into v_job from public.jobs where id=1623;

  insert into ops.client_call_policy (client_id, job_id, service_line_item_ids, cadence_days, next_call_at)
  values (v_client, v_job, array[9]::bigint[], 60, current_date);
  perform ops.fn_file_due_call_requests();
  select id into v_req from ops.visit_requests where client_id=v_client and call_required and status='open';

  -- SNOOZE: the client says "call me on this date"
  perform ops.snooze_call_request(v_req, current_date + 21);
  select next_call_at into v_next from ops.client_call_policy where client_id=v_client;
  if v_next <> current_date + 21 then raise exception 'snooze did not move next_call_at (got %)', v_next; end if;
  perform 1 from ops.visit_requests where id=v_req and status='open';
  if found then raise exception 'snoozed request is still open; it must leave the queue'; end if;

  -- and it must not be re-filed before the snoozed date
  if ops.fn_file_due_call_requests() <> 0 then raise exception 'snoozed client was re-filed immediately'; end if;

  -- ADVANCE ON SCHEDULE: approving must push next_call_at to visit_date + cadence_days
  update ops.client_call_policy set next_call_at = current_date where client_id=v_client;
  perform ops.fn_file_due_call_requests();
  select id into v_req from ops.visit_requests where client_id=v_client and call_required and status='open';
  v_visit := ops.schedule_visit_request(v_req, current_date + 5);
  select next_call_at into v_next from ops.client_call_policy where client_id=v_client;
  if v_next <> (current_date + 5 + 60) then
    raise exception 'expected next_call_at = visit_date + cadence (%), got %', current_date + 5 + 60, v_next;
  end if;

  -- POSITIVE CONTROL: scheduling an ORDINARY request must not touch any policy.
  update ops.client_call_policy set next_call_at = date '2030-01-01' where client_id=v_client;
  v_req := ops.create_visit_request(v_client, v_job, array[9]::bigint[]);   -- call_required stays false
  perform ops.schedule_visit_request(v_req, current_date + 6);
  select next_call_at into v_next from ops.client_call_policy where client_id=v_client;
  if v_next <> date '2030-01-01' then
    raise exception 'CONTROL FAILED: an ordinary request moved next_call_at to % - the trigger is too broad', v_next;
  end if;

  raise notice 'ALL PASS';
end $probe$;
select 'PASS' as result;
rollback;
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
node scripts/q.js scripts/probes/call_policy_lifecycle.sql /tmp/p4.json && cat /tmp/p4.json
```

Expected: an error about `ops.snooze_call_request` not existing.

- [ ] **Step 3: Write the migration**

Create `Supabase/docs/migrations/2026-08-17_1630_call_policy_lifecycle.sql`:

```sql
-- 2026-08-17_1630_call_policy_lifecycle.sql
--
-- WHY: two outcomes of the phone call.
--   "not now, call me on the 5th" -> snooze: close the queue item, move next_call_at to that date.
--   "yes, come" -> the existing schedule flow runs; we then advance next_call_at from the VISIT date.
--
-- Advancing from the visit date rather than the call date is deliberate: a call made three weeks
-- early must not drag the whole cadence forward.
--
-- AUDIT (rule #8): no new table. Both objects write to already-audited tables.
--
-- The advance is an AFTER UPDATE trigger on ops.visit_requests rather than an edit to
-- ops.schedule_visit_request, because that RPC is shared by every ordinary request and this feature
-- has no business changing its body. The trigger is gated on call_required so ordinary requests are
-- untouched - the probe asserts exactly that.

begin;

create or replace function ops.snooze_call_request(p_request_id bigint, p_next_call_at date)
returns void
language plpgsql
security definer
set search_path to 'public', 'ops'
as $function$
declare v_client bigint;
begin
  if p_next_call_at is null or p_next_call_at <= current_date then
    raise exception 'snooze_call_request: next call date must be in the future';
  end if;

  select client_id into v_client from ops.visit_requests
   where id = p_request_id and call_required and status = 'open' and deleted_at is null;
  if v_client is null then
    raise exception 'snooze_call_request: request % is not an open call request', p_request_id;
  end if;

  update ops.client_call_policy
     set next_call_at = p_next_call_at
   where client_id = v_client;

  perform ops.cancel_visit_request(p_request_id, 'snoozed to ' || to_char(p_next_call_at,'YYYY-MM-DD'));
end;
$function$;

revoke all on function ops.snooze_call_request(bigint, date) from public, anon;
grant execute on function ops.snooze_call_request(bigint, date) to authenticated, service_role;

create or replace function ops.fn_advance_call_policy_on_schedule()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'ops'
as $function$
declare v_visit_date date;
begin
  -- only a call-required request that has just been converted into a visit
  if not new.call_required then return new; end if;
  if new.converted_visit_id is null or old.converted_visit_id is not null then return new; end if;

  select visit_date into v_visit_date from public.visits where id = new.converted_visit_id;
  if v_visit_date is null then return new; end if;

  update ops.client_call_policy p
     set next_call_at = v_visit_date + p.cadence_days
   where p.client_id = new.client_id;

  return new;
end;
$function$;

drop trigger if exists trg_zz_advance_call_policy on ops.visit_requests;
create trigger trg_zz_advance_call_policy
  after update on ops.visit_requests
  for each row execute function ops.fn_advance_call_policy_on_schedule();

commit;
```

- [ ] **Step 4: Apply and re-run the probe**

```bash
node scripts/q.js docs/migrations/2026-08-17_1630_call_policy_lifecycle.sql /tmp/apply4.json && cat /tmp/apply4.json
node scripts/q.js scripts/probes/call_policy_lifecycle.sql /tmp/p4.json && cat /tmp/p4.json
```

Expected: `[{"result":"PASS"}]`.

⚠ If the probe fails on `ops.schedule_visit_request` returning something other than a bigint, read its real signature first and adjust the probe, not the trigger:

```bash
node scripts/q.js /dev/stdin /tmp/sig.json <<'SQL'
select pg_get_function_result(p.oid) as ret, pg_get_function_arguments(p.oid) as args
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='ops' and p.proname='schedule_visit_request';
SQL
```

- [ ] **Step 5: Commit**

```bash
git add docs/migrations/2026-08-17_1630_call_policy_lifecycle.sql scripts/probes/call_policy_lifecycle.sql
git commit -m "Add snooze and advance-on-schedule for call policies"
git push origin main
```

---

## Task 5: Seed Jerusalem Pizza (Phase 1 ships here)

**Files:**
- Create: `Supabase/docs/migrations/2026-08-17_1645_seed_226_call_policy.sql`

🛑 **This adds the policy row ONLY.** Fred's instruction is to leave Diego's SA `99900892` and its four visits alone until this flow is live. Do not cancel anything in this task.

- [ ] **Step 1: Write the seed**

Create `Supabase/docs/migrations/2026-08-17_1645_seed_226_call_policy.sql`:

```sql
-- 2026-08-17_1645_seed_226_call_policy.sql
--
-- WHY: 226-JER Jerusalem Pizza is the client that prompted this work. Last completed service is
-- visit 7797 on 2026-08-17 (a correctly-created Service Call), and GDO-03256 caps the interval at
-- 60 days, so the next call is due 2026-10-16.
--
-- Services: id 9 = "09 - Service Call - Pumping - Grease Trap & Tank Cleaning", which is what they
-- actually receive. Job 1623 = "Service Call" 99900891, active.
--
-- 🛑 Diego's SA 99900892 and its 4 generated visits are deliberately NOT touched here (Fred,
-- 2026-08-17: leave it until the flow exists so he does not lose his only reminder).
--
-- AUDIT (rule #8): insert into an audited table; captured automatically.

begin;

insert into ops.client_call_policy (client_id, job_id, service_line_item_ids, cadence_days, next_call_at, notes)
select c.id, 1623, array[9]::bigint[], 60, date '2026-10-16',
       'Owner must approve each visit by phone before we schedule.'
  from public.clients c
 where c.client_code = '226-JER'
on conflict (client_id) do nothing;

commit;
```

- [ ] **Step 2: Apply and verify**

```bash
node scripts/q.js docs/migrations/2026-08-17_1645_seed_226_call_policy.sql /tmp/apply5.json && cat /tmp/apply5.json
node scripts/q.js /dev/stdin /tmp/seed.json <<'SQL'
select p.*, (select client_code from public.clients c where c.id=p.client_id) as code
from ops.client_call_policy p;
SQL
```

Expected: one row for `226-JER`, `next_call_at = 2026-10-16`, `paused = false`.

- [ ] **Step 3: Confirm nothing schedulable appeared**

```bash
node scripts/q.js /dev/stdin /tmp/inert.json <<'SQL'
select (select count(*) from ops.visit_requests where call_required and status='open') as open_call_requests,
       (select count(*) from public.v_visits_live v join public.clients c on c.id=v.client_id
         where c.client_code='226-JER' and v.created_at > now() - interval '10 minutes') as new_visits;
SQL
```

Expected: `new_visits: 0`. The filer will not fire until 2026-10-13 (3-day lead).

- [ ] **Step 4: Commit**

```bash
git add docs/migrations/2026-08-17_1645_seed_226_call_policy.sql
git commit -m "Seed the call policy for 226-JER"
git push origin main
```

---

## Task 6: The GDO ceiling view (warning only)

**Files:**
- Create: `Supabase/docs/migrations/2026-08-17_1640_v_client_call_policy.sql`
- Test: `Supabase/scripts/probes/v_client_call_policy.sql`

- [ ] **Step 1: Write the failing probe**

Create `Supabase/scripts/probes/v_client_call_policy.sql`:

```sql
begin;
do $probe$
declare v_exceeds boolean; v_ceiling int;
begin
  update ops.client_call_policy set cadence_days = 90 where client_id = (select id from public.clients where client_code='226-JER');
  select cadence_exceeds_permit, permit_max_frequency_days into v_exceeds, v_ceiling
    from ops.v_client_call_policy where client_code = '226-JER';
  if v_ceiling <> 60 then raise exception 'expected GDO ceiling 60, got %', v_ceiling; end if;
  if v_exceeds is not true then raise exception '90-day cadence over a 60-day permit must flag as exceeding'; end if;

  -- POSITIVE CONTROL: a legal cadence must NOT flag, or the warning is just always-on decoration
  update ops.client_call_policy set cadence_days = 60 where client_id = (select id from public.clients where client_code='226-JER');
  select cadence_exceeds_permit into v_exceeds from ops.v_client_call_policy where client_code='226-JER';
  if v_exceeds is not false then
    raise exception 'CONTROL FAILED: a 60-day cadence on a 60-day permit flagged as exceeding';
  end if;

  raise notice 'ALL PASS';
end $probe$;
select 'PASS' as result;
rollback;
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
node scripts/q.js scripts/probes/v_client_call_policy.sql /tmp/p6.json && cat /tmp/p6.json
```

Expected: an error about `ops.v_client_call_policy` not existing.

- [ ] **Step 3: Write the migration**

Create `Supabase/docs/migrations/2026-08-17_1640_v_client_call_policy.sql`:

```sql
-- 2026-08-17_1640_v_client_call_policy.sql
--
-- WHY: Fred chose a manual cadence over deriving due-ness from the GDO clock, and that decision
-- stands. But 226's gap still reached 77 days against a 60-day permit, so the permit ceiling is
-- surfaced here as a WARNING the UI can show next to the cadence.
--
-- 🛑 This view is display-only. It drives NO scheduling, and it is NOT a revival of
-- ops.v_service_due (retired from the Calendar by Fred, 2026-07-30).
--
-- AUDIT (rule #8): a view. Nothing to opt in or out of.

begin;

create or replace view ops.v_client_call_policy as
select
  p.client_id,
  c.client_code,
  c.name                    as client_name,
  p.job_id,
  p.service_line_item_ids,
  p.cadence_days,
  p.next_call_at,
  p.paused,
  p.notes,
  g.max_frequency_days      as permit_max_frequency_days,
  g.gdo_number,
  (g.max_frequency_days is not null and p.cadence_days > g.max_frequency_days)
                            as cadence_exceeds_permit,
  (select max(v.visit_date) from public.v_visits_live v
    where v.client_id = p.client_id and v.visit_status = 'completed')
                            as last_completed_visit
from ops.client_call_policy p
join public.clients c on c.id = p.client_id
left join lateral (
  select g2.gdo_number, g2.max_frequency_days
    from public.gdos g2
   where g2.client_id = p.client_id and g2.status = 'ACTIVE' and g2.max_frequency_days is not null
   order by g2.max_frequency_days asc
   limit 1
) g on true;

revoke all on ops.v_client_call_policy from anon;
grant select on ops.v_client_call_policy to authenticated, service_role;

commit;
```

- [ ] **Step 4: Apply and re-run the probe**

```bash
node scripts/q.js docs/migrations/2026-08-17_1640_v_client_call_policy.sql /tmp/apply6.json && cat /tmp/apply6.json
node scripts/q.js scripts/probes/v_client_call_policy.sql /tmp/p6.json && cat /tmp/p6.json
```

Expected: `[{"result":"PASS"}]`.

- [ ] **Step 5: Commit**

```bash
git add docs/migrations/2026-08-17_1640_v_client_call_policy.sql scripts/probes/v_client_call_policy.sql
git commit -m "Surface the GDO ceiling next to the call cadence as a warning"
git push origin main
```

---

## Task 7: Slack digest edge function

**Files:**
- Create: `Supabase/supabase/functions/call-due-digest/index.ts`
- Create: `Supabase/docs/migrations/2026-08-17_1650_call_digest_invoker.sql`

🛑 **Ask Fred for the Slack channel id before this task.** Posts go out as him. The spec's default is the channel Yannick raised the thread in. Do not guess and do not tag anyone without his say-so.

- [ ] **Step 1: Read the existing Slack helper and copy its shape**

```bash
sed -n '480,540p' supabase/functions/dump-visit-create/index.ts
```

Reuse that `slackPost` structure: `SLACK_BOT_TOKEN` + a channel id env var, `chat.postMessage`, and **best-effort** semantics.

- [ ] **Step 2: Write the function**

Create `Supabase/supabase/functions/call-due-digest/index.ts`:

```ts
// call-due-digest — one Slack message naming clients due for an approval call.
//
// 🛑 THIS IS A POINTER, NOT A TASK LIST. The queue (ops.visit_requests where call_required) is the
// only source of truth. If this message and the queue could ever disagree we would have rebuilt the
// original bug in a second place, so this function announces only what it reads, and only once.
//
// Best-effort, exactly like dump-visit-create: a Slack failure must never fail anything upstream.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "ops" } },
);

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

async function slackPost(text: string): Promise<boolean> {
  const token = Deno.env.get("SLACK_BOT_TOKEN");
  const channel = Deno.env.get("SLACK_CALL_DIGEST_CHANNEL_ID");
  if (!token || !channel) { console.log("[digest] slack env unset, no-op"); return false; }
  const r = await fetch("https://slack.com/api/chat.postMessage", {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ channel, text, mrkdwn: true }),
  });
  const j = await r.json().catch(() => ({}));
  if (!j?.ok) console.error("[digest] slack error", j?.error);
  return Boolean(j?.ok);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });

  // Announce NEW arrivals only. announced_at is what stops this becoming daily wallpaper.
  const { data: due, error } = await db
    .from("visit_requests")
    .select("id, client_id, announced_at")
    .eq("call_required", true).eq("status", "open").is("announced_at", null).is("deleted_at", null);
  if (error) return json({ ok: false, error: error.message }, 500);
  if (!due?.length) return json({ ok: true, announced: 0 });

  const { data: names } = await db.from("v_visit_requests")
    .select("id, client_code, client_name").in("id", due.map((d) => d.id));

  const lines = (names ?? []).map((n) => `• *${n.client_code}* ${n.client_name}`).join("\n");
  const text =
    `${due.length} client${due.length === 1 ? "" : "s"} due for an approval call:\n${lines}\n` +
    `They are in *To Be Scheduled* in the Calendar: https://calendar.unclogme.app/`;

  const posted = await slackPost(text);

  // Mark announced even if Slack failed, so a broken webhook cannot spam once it recovers.
  await db.from("visit_requests").update({ announced_at: new Date().toISOString() })
    .in("id", due.map((d) => d.id));

  return json({ ok: true, announced: due.length, slack_ok: posted });
});
```

- [ ] **Step 3: Add the `announced_at` column and the invoker**

Create `Supabase/docs/migrations/2026-08-17_1650_call_digest_invoker.sql`:

```sql
-- 2026-08-17_1650_call_digest_invoker.sql
--
-- WHY: announce new call-due arrivals once. announced_at is the de-duplication key that keeps the
-- Slack message from becoming daily wallpaper people learn to ignore.
--
-- AUDIT (rule #8): column added to ops.visit_requests, which is already audited. Captured.

begin;

alter table ops.visit_requests
  add column if not exists announced_at timestamptz;

comment on column ops.visit_requests.announced_at is
  'When call-due-digest announced this request in Slack. NULL means not yet announced. Set even when '
  'the Slack post fails, so a recovering webhook cannot replay a backlog.';

create or replace function public.fn_request_call_digest()
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_bearer text;
begin
  select decrypted_secret into v_bearer from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_bearer is null then
    raise exception 'fn_request_call_digest: edge_invoke_service_key missing from vault';
  end if;

  perform net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/call-due-digest',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_bearer),
    body    := '{}'::jsonb
  );
end;
$function$;

revoke all on function public.fn_request_call_digest() from public, anon, authenticated;

select cron.schedule('call-due-digest', '30 11 * * *', $$select public.fn_request_call_digest();$$);

commit;
```

- [ ] **Step 4: Deploy and schedule**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
SUPABASE_ACCESS_TOKEN=$(grep '^SUPABASE_PAT=' .env | cut -d= -f2) \
  supabase functions deploy call-due-digest --project-ref wbasvhvvismukaqdnouk
node scripts/q.js docs/migrations/2026-08-17_1650_call_digest_invoker.sql /tmp/apply7.json && cat /tmp/apply7.json
```

⚠ Check `supabase/config.toml` for this function's `verify_jwt` setting and respect it. Never pass `--no-verify-jwt` unless it is already set that way.

- [ ] **Step 5: Verify it announces once and only once**

```bash
node scripts/q.js /dev/stdin /tmp/announce.json <<'SQL'
select id, call_required, status, announced_at from ops.visit_requests where call_required order by id desc limit 5;
SQL
```

Invoke the function twice and confirm the second call returns `announced: 0`. That is the anti-wallpaper property; if it re-announces, stop and fix before scheduling.

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/call-due-digest/index.ts docs/migrations/2026-08-17_1650_call_digest_invoker.sql
git commit -m "Announce call-due clients in Slack once, pointing at the queue"
git push origin main
```

---

## Task 8: Calendar UI — badge and snooze

**Files:**
- Modify: Visit Calendar Lovable project `6533c3ee-94f5-499c-96d1-c8847a729a8f`
- Modify: `Building Apps/Visit Calendar/docs/08-changelog.md`

🛑 **Claim the Lovable project first** (Building Apps rule #13: a Publish ships every session's pending changes). 🛑 **Keep the prompt on ONE line** — Enter submits, and a newline splits it into separate queue items that get silently dropped.

- [ ] **Step 1: Send the Lovable prompt**

One line:

> In the Visit Calendar's TO BE SCHEDULED panel, the visit request rows now have a boolean `call_required` from `ops.v_visit_requests`; when it is true show a small amber "Call first" chip on the row and a "Snooze" action next to the existing "Schedule" link, where Snooze opens a date picker and calls the RPC `ops.snooze_call_request({ p_request_id, p_next_call_at })` then refreshes the queue; do not change anything about the existing Schedule flow, do not add a date to these rows, and do not call any Jobber function from the app. Acceptance: a request with `call_required` true shows the chip and the Snooze action, snoozing removes it from the panel, and a request with `call_required` false looks exactly as it does today.

- [ ] **Step 2: Verify against the LIVE bundle, not the chat card**

After publishing, walk the deployed chunks with recursive discovery and grep for `call_required` and `snooze_call_request`. Lovable's "Done" is a claim; the bundle is the evidence.

- [ ] **Step 3: Visual check**

Open `https://calendar.unclogme.app/`, confirm the chip renders on a `call_required` row and that an ordinary request is unchanged. Screenshot both.

- [ ] **Step 4: Document and commit**

Add a dated entry to `Building Apps/Visit Calendar/docs/08-changelog.md` covering what changed, why (quote Yannick's Slack ask), the DB objects the app now reads, and the rule that must not be regressed: **these rows are dateless and must never reach Jobber before scheduling.**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Building Apps"
git add "Visit Calendar/docs/08-changelog.md"
git commit -m "Show call-first chip and snooze in To Be Scheduled"
git push origin main
```

---

## Task 9: Retire Diego's SA (do NOT run without Fred's explicit go)

🛑 **Destructive and outward-facing.** It removes visits from a crew's live Jobber schedule. Fred's standing instruction is that this happens only once the flow above is live and he says go.

- [ ] **Step 1: Confirm the replacement is working**

The 226 policy row exists, the filer has produced at least one queue item on a real due date, and Diego has used it once.

- [ ] **Step 2: Back up before deleting**

```bash
node scripts/q.js /dev/stdin ../backups/226_sa_cleanup_$(date +%F).json <<'SQL'
select json_agg(row_to_json(t)) from (
  select v.* from public.visits v where v.job_id = 1622
) t;
SQL
```

- [ ] **Step 3: Cancel the four generated visits**

Visits 6537, 6538, 6539, 6953. ⚠ 6537 and 6538 are live on Jobber and must leave both sides; 6539 and 6953 are DB-only. Use the sanctioned RPC, pinned to ids **and** re-asserting what made them removable:

```sql
select public.delete_calendar_visit(v.id)
from public.visits v
where v.id in (6537,6538,6539,6953)
  and v.job_id = 1622
  and v.visit_status = 'scheduled'
  and v.deleted_at is null;
```

- [ ] **Step 4: Verify both sides**

Confirm all four are soft-deleted, that 6537 and 6538 are gone from the Jobber schedule, and — the control — that **other visits on those days still render**. An empty page looks identical to a successful delete.

- [ ] **Step 5: Close the SA job**

Close job 1622 (`99900892`) in Jobber. Then confirm `job_status='late'` no longer matches any Service Agreement, restoring that indicator.

⚠ **Do not touch job 1623 (`99900891`) or visit 7797.** That is the correct flow working — a real Service Call, completed 2026-08-17.

- [ ] **Step 6: Release the claim**

Append the outcome to `WORKING-NOW.md` and commit.

---

## Self-review notes

- **Spec coverage:** policy table → Task 1; `call_required` → Task 2; daily filer + queue → Task 3; snooze and advance → Task 4; seed → Task 5; GDO warning → Task 6; Slack pointer → Task 7; UI → Task 8; deferred cleanup → Task 9. Every spec section maps to a task.
- **Naming consistency:** `ops.fn_file_due_call_requests`, `ops.snooze_call_request`, `ops.fn_advance_call_policy_on_schedule`, `ops.v_client_call_policy`, `public.fn_request_call_digest`, cron jobs `call-due-filer` and `call-due-digest`. These exact names are used identically in every task and probe.
- **Open items carried from the spec:** the Slack channel id (Task 7, blocked on Fred) and who maintains the policy rows (by hand at this size — no CRUD screen is in this plan, on purpose).
- **Lead time** is the constant `c_lead_days := 3` inside the filer, per the spec's instruction not to add a per-client column until one is needed.
