-- ============================================================================
-- 2026-09-08_0100_preview_status_change_accurate_sa_warning.sql
--
-- Fix the RECURRING -> ACTIVE confirmation dialog, which today tells the operator
-- something that is false, and stays silent about the thing that actually bites.
--
-- Fred, 2026-09-08, on flipping 213-TRUE from RECURRING to ACTIVE and being shown
-- "This client keeps its Service Agreement job, so the nightly job will schedule new
-- visits again unless you also close that job":  *"Does it makes senses?"*
-- It does not. Two independent reasons.
--
-- (1) THE CONDITION NEVER LOOKED AT THE CLIENT.
--     `'reschedules_unless_job_closed', (v_will and p_status = 'ACTIVE')` is the entire
--     test. It never checks whether a qualifying Service Agreement job exists, whether it
--     is archived, or whether it has a frequency. It fires on EVERY RECURRING -> ACTIVE
--     change. 213-TRUE's only SA job (915) is ARCHIVED, frequency NULL, zero line items:
--     there was no job to close.
--
-- (2) THE PREMISE IS STALE.
--     The wording traces to the KNOWN LIMIT in
--     2026-07-31_1430_client_status_sa_visit_cleanup.sql, which describes
--     `generate_service_agreement_visits.js` keying on `status IN ('ACTIVE','RECURRING')`.
--     That JS path's schedule has been PAUSED since 2026-06-02
--     (.github/workflows/generate-recurring-visits.yml is workflow_dispatch only).
--     The live generator is public.fn_generate_sa_visits, whose job selection requires
--     `c.status = 'RECURRING'`, and client.generate_visits_for_client is a thin wrapper
--     over it -- so BOTH the nightly pg_cron path ('sa-visit-generation', 10:00) and the
--     app's on-demand button require RECURRING.
--     => An ACTIVE client is excluded by definition. NOTHING regenerates. The operator was
--     being told to go close a job to prevent an event that cannot happen.
--
-- 🛑 THE REAL RISK IS THE EXACT OPPOSITE, AND IT IS CURRENTLY UNWARNED.
--    Moving a client that holds a LIVE, gate-passing Service Agreement to ACTIVE does not
--    cause visits to come back -- it STOPS them being generated at all. Measured today,
--    two clients are already stranded that way, both ACTIVE, both holding a real SA that
--    passes client.fn_is_current_sa_job, both past their own cycle with nothing booked:
--      084-ULT Ultra Padel Club   job 1467  every 30 days  last visit 2026-08-06  0 upcoming
--      201-ALA Aladdin Med. food  job 1575  every 70 days  last visit 2026-07-04  0 upcoming
--    So the dialog should warn about LOSING the schedule, not about it returning.
--
-- WHAT THIS MIGRATION DOES
--   1. Adds client.fn_client_live_sa_jobs(bigint) -- the live, gate-passing SA jobs for a
--      client, as a bigint[]. Extracted as its own STABLE function ON PURPOSE: the preview
--      RPC raises without auth.uid(), so it cannot be called from a migration running as
--      postgres, which would leave this change with no executable VERIFY. The helper is
--      testable directly. It is NOT granted to anon/authenticated; the SECURITY DEFINER
--      preview function reaches it as the owner.
--   2. Replaces client.preview_client_status_change so that:
--        - `reschedules_unless_job_closed` is now FALSE (accurate under the current
--          generator). The key is KEPT rather than dropped so the deployed Client App does
--          not break on a missing field; it simply stops rendering the false warning.
--        - NEW `has_live_sa_job` (boolean) and `live_sa_job_ids` (jsonb array).
--        - NEW `stops_sa_generation` (boolean) -- the honest warning the app should render.
--      Counts (`sa_visits_to_remove`, `service_call_visits_kept`) are UNCHANGED; they were
--      correct, and 213-TRUE's 0/0 was right.
--
-- ⚠ APP-SIDE FOLLOW-UP, NOT DONE HERE. The Client App still renders its banner from
--    `reschedules_unless_job_closed`. After this migration that flag is false, so the FALSE
--    warning disappears immediately -- which is the fix Fred asked for. Surfacing the new
--    `stops_sa_generation` warning is a Client App change and is written up in
--    Building Apps/Client App/docs/. Nothing regresses in the meantime: the app just shows
--    no SA banner, which is correct for every client that has no live SA job.
--
-- ⚠ NOT CHANGED, DELIBERATELY: fn_generate_sa_visits still requires RECURRING. Whether an
--    ACTIVE client with a real SA should be generated for is the business call the
--    2026-07-31 header put to Fred and it is still his. This migration only stops the app
--    lying about it.
--
-- Grants: CREATE OR REPLACE preserves them; asserted in VERIFY anyway.
-- Audit: N/A (two functions, no DML).
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. the testable helper
-- ---------------------------------------------------------------------------
create or replace function client.fn_client_live_sa_jobs(p_client_id bigint)
returns bigint[]
language sql
stable
set search_path to ''
as $fn$
  select coalesce(array_agg(j.id order by j.id), '{}'::bigint[])
    from public.jobs j
   where j.client_id = p_client_id
     and coalesce(j.job_status, '') <> 'archived'
     and client.fn_is_current_sa_job(j.id);
$fn$;

comment on function client.fn_client_live_sa_jobs(bigint) is
  'Live (non-archived) jobs for a client that pass the current-format Service Agreement '
  'gate client.fn_is_current_sa_job. Used by client.preview_client_status_change so the '
  'status-change dialog can tell the truth about whether a real SA is at stake. Extracted '
  'so it is testable from a migration: the preview RPC raises without auth.uid().';

revoke all on function client.fn_client_live_sa_jobs(bigint) from public;
revoke all on function client.fn_client_live_sa_jobs(bigint) from anon;
revoke all on function client.fn_client_live_sa_jobs(bigint) from authenticated;

-- ---------------------------------------------------------------------------
-- 2. the corrected preview
-- ---------------------------------------------------------------------------
create or replace function client.preview_client_status_change(p_client_id bigint, p_status text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_old  text;
  v_will boolean;
  v_n    int := 0;
  v_sc   int := 0;
  v_sa   bigint[];
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;

  select c.status into v_old from public.clients c where c.id = p_client_id;
  if v_old is null then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;

  v_will := (v_old = 'RECURRING' and p_status <> 'RECURRING')
         or (p_status in ('INACTIVE','PAUSED') and v_old not in ('INACTIVE','PAUSED'));

  if v_will then
    select count(*) into v_n
      from public.visits v
     where v.client_id = p_client_id and v.deleted_at is null
       and v.visit_status = 'scheduled' and v.visit_date >= current_date
       and exists (select 1 from public.jobs j
                    where j.id = v.job_id and j.title ilike 'Service Agreement%');
    select count(*) into v_sc
      from public.visits v
     where v.client_id = p_client_id and v.deleted_at is null
       and v.visit_status = 'scheduled' and v.visit_date >= current_date
       and not exists (select 1 from public.jobs j
                    where j.id = v.job_id and j.title ilike 'Service Agreement%');
  end if;

  v_sa := client.fn_client_live_sa_jobs(p_client_id);

  return jsonb_build_object(
    'current_status', v_old,
    'new_status', p_status,
    'will_clean_up', v_will,
    'sa_visits_to_remove', v_n,
    'service_call_visits_kept', v_sc,

    -- Does this client actually hold a live, current-format Service Agreement?
    'has_live_sa_job',  (cardinality(v_sa) > 0),
    'live_sa_job_ids',  to_jsonb(v_sa),

    -- CORRECTED 2026-09-08. Was `(v_will and p_status = 'ACTIVE')`, which never looked at
    -- the client and whose premise (the JS generator keying on ACTIVE OR RECURRING) has
    -- been dead since 2026-06-02. The live generator public.fn_generate_sa_visits requires
    -- c.status = 'RECURRING', so an ACTIVE client is never regenerated, by any path.
    -- Kept as a key so the deployed app does not break on a missing field.
    'reschedules_unless_job_closed', false,

    -- The honest warning: leaving RECURRING with a real SA in hand STOPS generation.
    -- This is what stranded 084-ULT and 201-ALA.
    'stops_sa_generation',
      (v_will and p_status <> 'RECURRING' and cardinality(v_sa) > 0)
  );
end;
$function$;

revoke execute on function client.preview_client_status_change(bigint, text) from public;
revoke execute on function client.preview_client_status_change(bigint, text) from anon;
grant  execute on function client.preview_client_status_change(bigint, text) to authenticated;

commit;

-- ---------------------------------------------------------------------------
-- VERIFY. Every assertion carries a control that must move the other way, so a
-- silently-broken instrument cannot pass this block.
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_213   bigint;  v_084 bigint;  v_201 bigint;  v_241 bigint;
  v_jobs  bigint[];
  v_pass  int;     v_total int;   v_exec int;
begin
  select id into v_213 from public.clients where client_code = '213-TRUE';
  select id into v_084 from public.clients where client_code = '084-ULT';
  select id into v_201 from public.clients where client_code = '201-ALA';
  select id into v_241 from public.clients where client_code = '241-WYN';

  if v_213 is null or v_084 is null or v_201 is null or v_241 is null then
    raise exception 'VERIFY 0 FAILED: a fixture client is missing (213-TRUE/084-ULT/201-ALA/241-WYN)';
  end if;

  -- 1. NEGATIVE: 213-TRUE holds no live gate-passing SA. Its only SA job (915) is archived.
  v_jobs := client.fn_client_live_sa_jobs(v_213);
  if cardinality(v_jobs) <> 0 then
    raise exception 'VERIFY 1 FAILED: 213-TRUE should have 0 live SA jobs, got %', v_jobs;
  end if;

  -- 2. POSITIVE CONTROL for the same call on the same instrument. Without this, VERIFY 1
  --    passes just as well if the helper always returns empty.
  v_jobs := client.fn_client_live_sa_jobs(v_241);
  if cardinality(v_jobs) = 0 then
    raise exception 'VERIFY 2 FAILED (control): 241-WYN must hold >=1 live SA job; helper returns empty for everyone';
  end if;

  -- 3. The two stranded clients must each show their real SA job, by id.
  v_jobs := client.fn_client_live_sa_jobs(v_084);
  if not (1467 = any(v_jobs)) then
    raise exception 'VERIFY 3a FAILED: 084-ULT should include job 1467, got %', v_jobs;
  end if;
  v_jobs := client.fn_client_live_sa_jobs(v_201);
  if not (1575 = any(v_jobs)) then
    raise exception 'VERIFY 3b FAILED: 201-ALA should include job 1575, got %', v_jobs;
  end if;

  -- 4. The helper must agree with the gate it wraps, across the whole estate.
  select count(*) filter (where client.fn_is_current_sa_job(j.id)), count(*)
    into v_pass, v_total
    from public.jobs j
   where coalesce(j.job_status,'') <> 'archived';
  if v_pass = 0 or v_pass = v_total then
    raise exception 'VERIFY 4 FAILED: gate is degenerate (% of % live jobs pass) - instrument suspect', v_pass, v_total;
  end if;

  -- 5. Grants survived CREATE OR REPLACE.
  select count(*) into v_exec
    from information_schema.routine_privileges
   where specific_schema = 'client'
     and routine_name = 'preview_client_status_change'
     and grantee = 'authenticated'
     and privilege_type = 'EXECUTE';
  if v_exec <> 1 then
    raise exception 'VERIFY 5 FAILED: authenticated lost EXECUTE on preview_client_status_change';
  end if;

  -- 6. The helper must NOT be reachable by the client roles.
  if has_function_privilege('authenticated', 'client.fn_client_live_sa_jobs(bigint)', 'EXECUTE')
     or has_function_privilege('anon', 'client.fn_client_live_sa_jobs(bigint)', 'EXECUTE') then
    raise exception 'VERIFY 6 FAILED: fn_client_live_sa_jobs is executable by anon/authenticated';
  end if;

  -- 7. The old, false expression must be gone from the preview body, and the new one present.
  if pg_get_functiondef('client.preview_client_status_change(bigint,text)'::regprocedure)
       ~ 'reschedules_unless_job_closed''[[:space:]]*,[[:space:]]*\(v_will' then
    raise exception 'VERIFY 7a FAILED: the old (v_will and p_status = ACTIVE) expression is still in place';
  end if;
  if pg_get_functiondef('client.preview_client_status_change(bigint,text)'::regprocedure)
       !~ 'stops_sa_generation' then
    raise exception 'VERIFY 7b FAILED: stops_sa_generation missing from the new body';
  end if;

  raise notice 'VERIFY ok: 213-TRUE 0 live SA jobs; control 241-WYN non-empty; 084-ULT has 1467; 201-ALA has 1575; gate passes % of % live jobs; grants intact', v_pass, v_total;
end
$verify$;
