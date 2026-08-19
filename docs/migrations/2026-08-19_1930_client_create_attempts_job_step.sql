-- 2026-08-19_1930_client_create_attempts_job_step.sql
--
-- WHAT: record the Service Call job step on the create-client ledger, and give
--       public.v_client_create_attention a branch for a job-step orphan.
--
-- WHY:  create-client is gaining a third step (client, property, JOB). The attention view keys
--       entirely on the client-level `status`, so without a branch here a client that landed
--       perfectly while Jobber kept a job we never recorded is INVISIBLE to the only human-facing
--       reconciliation surface we have.
--
-- 🛑 `status` KEEPS ITS CURRENT MEANING: the CLIENT landed. It is deliberately NOT widened to mean
--    client+property+job, because 'created' RELEASES the code reservation (2026-08-12_2045) and
--    holding the reservation across the job step would turn this ledger into a permanent second
--    registry of client codes. The job step reports through `job_step`, never through `status`.
--
-- 🛑 `failed` AND `skipped` ARE DELIBERATELY DIFFERENT VALUES. `skipped` means the flow correctly
--    did not try (property_mode=none, so there was no property to hang a job on). `failed` means it
--    tried and did not succeed. Collapsing them would hide every real failure inside a legitimate
--    state, which is the exact shape of false all-clear this repo keeps paying for.
--
-- AUDIT (rule 8): public.client_create_attempts is NOT audited and stays NOT audited. Measured
--    immediately before applying this: zero audit.log_change triggers on the table. It is an
--    operational ledger written only by the create-client edge function as service_role, it has no
--    human-editable fields, and it IS itself the audit record for the flow. Opting it in would
--    duplicate its own contents into audit.logs on every attempt.
--
-- ⚠ THE VIEW IS `CREATE OR REPLACE`, AND THAT IS LOAD-BEARING FOR TWO REASONS.
--    (a) OR REPLACE may only APPEND columns, never insert them, so `job_step` and `jobber_job_gid`
--        are added AFTER the existing trailing `what_to_do`. Reordering them to read more naturally
--        would force DROP + CREATE.
--    (b) DROP VIEW DISCARDS GRANTS, and the pre-apply audit found this view carries a
--        **yannick_readonly SELECT** grant alongside postgres and service_role. A DROP + CREATE
--        would have silently revoked Yannick's access with nothing to announce it. The probe
--        `scripts/probes/job_step_ledger.js` asserts that grant survives.
--
-- PRE-APPLY AUDIT (measured, not assumed): 12 columns, 0 of the 3 new ones; constraints were
--    client_create_attempts_pkey + client_create_attempts_status_check; 7 attempt rows
--    (created=6, failed=1); 0 rows in v_client_create_attention; view had no job_step; 0 audit
--    triggers; grants postgres + service_role + yannick_readonly:SELECT.

begin;

alter table public.client_create_attempts
  add column if not exists jobber_job_gid text,
  add column if not exists job_id         bigint,
  add column if not exists job_step       text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'client_create_attempts_job_step_chk') then
    alter table public.client_create_attempts
      add constraint client_create_attempts_job_step_chk
      check (job_step is null or job_step in ('skipped','created','existing','failed','orphaned'));
  end if;
end $$;

comment on column public.client_create_attempts.job_step is
  'Service Call job step outcome: skipped (property_mode=none, there was no property to hang a job on), created, existing (idempotent hit), failed (we tried and it did not happen, nothing was left behind), orphaned (Jobber may hold a job we never recorded). NULL for attempts made before 2026-08-19. WARNING: failed and skipped are deliberately DIFFERENT - skipped means the flow correctly did not try, failed means it tried and did not succeed.';

comment on column public.client_create_attempts.job_id is
  'public.jobs.id of the Service Call job this attempt created or found. NULL when job_step is skipped, failed or orphaned.';

comment on column public.client_create_attempts.jobber_job_gid is
  'Jobber Job GID, when we managed to record one. NULL is expected on job_step=orphaned, which is precisely the state where Jobber may hold a job we never wrote down.';

create or replace view public.v_client_create_attention as
  select
    idempotency_key,
    requested_by,
    client_code,
    status,
    failure_reason,
    jobber_client_gid,
    created_at,
    now() - created_at as age,
    case
      when status = 'orphaned'   then 'Jobber holds this client and we never imported it. Check Jobber, then import or delete it there.'
      when status = 'unknown'    then 'We do not know whether Jobber created this. Check Jobber BEFORE anyone retries.'
      when status = 'started'    then 'Stuck mid-flight. It holds its code reserved. Confirm against Jobber before releasing.'
      when job_step = 'orphaned' then 'The client landed, but Jobber may hold a Service Call job we never recorded. Check Jobber before retrying. There is no jobDelete: the only teardown is jobClose.'
      else null
    end as what_to_do,
    job_step,
    jobber_job_gid
  from client_create_attempts a
  where status in ('orphaned','unknown')
     or (status = 'started' and created_at < now() - interval '5 minutes')
     or job_step = 'orphaned';

-- ---- VERIFY ------------------------------------------------------------------------------------
do $$
declare v_cols int; v_def text; v_seen int; v_yannick boolean;
begin
  select count(*) into v_cols from information_schema.columns
   where table_schema='public' and table_name='client_create_attempts'
     and column_name in ('jobber_job_gid','job_id','job_step');
  if v_cols <> 3 then raise exception 'VERIFY: expected 3 new columns, got %', v_cols; end if;

  select pg_get_viewdef('public.v_client_create_attention'::regclass, true) into v_def;
  if position('job_step' in v_def) = 0 then raise exception 'VERIFY: view has no job_step branch'; end if;
  if position('what_to_do' in v_def) = 0 then raise exception 'VERIFY: view lost what_to_do'; end if;

  -- the grant the CREATE OR REPLACE exists to protect
  select has_table_privilege('yannick_readonly','public.v_client_create_attention','SELECT') into v_yannick;
  if not v_yannick then raise exception 'VERIFY: yannick_readonly lost SELECT on the view'; end if;

  -- the CHECK must actually reject a bad value (a constraint that cannot fire is not a constraint)
  begin
    insert into public.client_create_attempts (idempotency_key, requested_by, payload, status, job_step)
    values (gen_random_uuid(), 'verify@probe', '{}'::jsonb, 'failed', 'not_a_valid_value');
    raise exception 'VERIFY: the job_step CHECK did not reject an invalid value';
  exception when check_violation then
    null; -- correct
  end;

  -- and it must ACCEPT every value we intend to write
  begin
    insert into public.client_create_attempts (idempotency_key, requested_by, payload, status, job_step)
    values ('00000000-0000-0000-0000-00000000feed', 'verify@probe', '{}'::jsonb, 'failed', 'failed');
    delete from public.client_create_attempts where idempotency_key = '00000000-0000-0000-0000-00000000feed';
  exception when others then
    raise exception 'VERIFY: the job_step CHECK rejected a value we intend to write: %', sqlerrm;
  end;

  select count(*) into v_seen from public.v_client_create_attention;
  raise notice 'VERIFY ok: 3 columns, view branch present, yannick_readonly intact, CHECK rejects bad and accepts good, % rows currently need attention', v_seen;
end $$;

commit;
