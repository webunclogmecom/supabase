-- 2026-08-19_2130_record_client_job_actor.sql
--
-- WHAT: fn_record_client_job accepts an optional actor_email and attests it into
--       request.jwt.claims for the duration of its transaction, so the audit trail names the
--       PERSON who did the work instead of the app that carried it.
--
-- WHY:  Fred, 2026-08-19, on client 309-KEB: "this should also show in the activity history who
--       created that job." Measured on that job before this change: the Activity trail shows
--       INSERT ... app_source 'client-app', actor 'client-app'. The human is nowhere, even though
--       save-client-job knew exactly who it was: it verifies the bearer token with auth.getUser()
--       before doing anything.
--
-- THE MECHANISM, measured not assumed: audit.log_change stores
--       NULLIF(current_setting('request.jwt.claims', true), '')::jsonb. A service_role write over
--       PostgREST carries no claims, so that column is NULL and client.job_activity falls back to
--       the app name. Proven in a rolled-back probe: setting the GUC transaction-locally before a
--       real UPDATE produced an audit row with jwt_claims->>'email' = 'fred@ayache.com'.
--       ⚠ The first version of that probe used `set title = title`, which audit.log_change SKIPS as
--         a no-op, so it captured nothing and I read a PREVIOUS row. A no-op write is not a test.
--
-- 🛑 IT MUST BE SET INSIDE THIS FUNCTION. The GUC is transaction-scoped and each PostgREST call is
--    its own transaction, so a claim set by the edge function beforehand is invisible to the
--    trigger that fires in here.
--
-- 🛑 NO VIEW CHANGE IS NEEDED. client.job_activity already reads
--    coalesce(jwt_claims->>'email', ...) for its actor, so populating the claim is sufficient and
--    the Activity modal starts naming people with no app deploy.
--
-- TRUST: SECURITY DEFINER, EXECUTE granted to service_role only (verified: acl is
--    postgres=X | service_role=X). The only callers are our own edge functions, each of which has
--    already verified the JWT. The email is attested, not asserted by a browser. Same shape as
--    send-derm-email's sent_by_email.
--
-- NON-BREAKING: actor_email is optional. A caller that omits it behaves exactly as before, which
--    the VERIFY block below asserts explicitly rather than assuming.
--
-- BODY: copied from the LIVE pg_get_functiondef output and edited in place; a programmatic diff
--    confirmed the only change is the inserted block. It was NOT retyped.
--
-- AUDIT (rule 8): no table changed. public.jobs remains audited; this makes its rows more truthful.

begin;

CREATE OR REPLACE FUNCTION public.fn_record_client_job(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gid     text := nullif(btrim(coalesce(p->>'gid','')), '');
  v_job_id  bigint;
  v_created boolean := false;
  v_li      jsonb := p->'line_items';
  v_r       record;
begin

  -- ---- ATTEST THE HUMAN, so the audit trail names a person and not an app ---------------------
  -- 🛑 WHY THIS IS HERE AND NOT IN THE EDGE FUNCTION. audit.log_change reads
  --    current_setting('request.jwt.claims'), and that GUC is TRANSACTION-scoped. save-client-job
  --    writes as service_role over PostgREST, where each call is its own transaction, so a claim
  --    set outside this function would not be visible to the trigger that fires inside it. It has
  --    to be set in the same transaction as the write, which means here.
  -- ⚠ TRUST MODEL: this function is SECURITY DEFINER and only service_role may execute it, so the
  --    only callers are our own edge functions, each of which has already verified the bearer token
  --    with auth.getUser() before calling. The email is therefore attested, not asserted by a
  --    browser. Same shape as send-derm-email's sent_by_email (2026-07-21h).
  -- ⚠ OPTIONAL BY DESIGN: a caller that sends no actor_email behaves exactly as before, so this is
  --    a non-breaking change for every existing caller.
  if nullif(btrim(coalesce(p->>'actor_email','')), '') is not null then
    perform set_config('request.jwt.claims',
                       json_build_object('email', btrim(p->>'actor_email'))::text,
                       true);
  end if;

  if v_gid is null then
    raise exception 'fn_record_client_job: gid is required' using errcode = '22023';
  end if;

  select l.entity_id into v_job_id
    from public.entity_source_links l
   where l.entity_type = 'job' and l.source_system = 'jobber' and l.source_id = v_gid;

  if v_job_id is null then
    insert into public.jobs (client_id, property_id, job_number, title, job_status,
                             start_at, end_at, total, notes, frequency_days,
                             billing_type, invoice_frequency, invoice_rrule)
    values ((p->>'client_id')::bigint,
            (p->>'property_id')::bigint,
            p->>'job_number',
            p->>'title',
            lower(p->>'job_status'),
            nullif(p->>'start_at','')::timestamptz,
            nullif(p->>'end_at','')::timestamptz,
            nullif(p->>'total','')::numeric,
            p->>'notes',
            nullif(p->>'frequency_days','')::integer,
            nullif(p->>'billing_type',''),
            nullif(p->>'invoice_frequency',''),
            nullif(p->>'invoice_rrule',''))
    returning id into v_job_id;
    v_created := true;

    insert into public.entity_source_links
      (entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence)
    values ('job', v_job_id, 'jobber', v_gid, p->>'title', 'client-app', 1.0)
    on conflict (entity_type, entity_id, source_system)
    do update set source_id = excluded.source_id, source_name = excluded.source_name;
  else
    update public.jobs j
       set title          = coalesce(p->>'title', j.title),
           job_status     = coalesce(lower(p->>'job_status'), j.job_status),
           start_at       = case when p ? 'start_at' then nullif(p->>'start_at','')::timestamptz else j.start_at end,
           end_at         = case when p ? 'end_at'   then nullif(p->>'end_at','')::timestamptz   else j.end_at   end,
           total          = case when p ? 'total'    then nullif(p->>'total','')::numeric        else j.total    end,
           notes          = case when p ? 'notes'    then p->>'notes'                            else j.notes    end,
           frequency_days = case when p ? 'frequency_days'
                                 then nullif(p->>'frequency_days','')::integer
                                 else j.frequency_days end,
           billing_type      = case when p ? 'billing_type'
                                    then nullif(p->>'billing_type','')      else j.billing_type      end,
           invoice_frequency = case when p ? 'invoice_frequency'
                                    then nullif(p->>'invoice_frequency','') else j.invoice_frequency end,
           invoice_rrule     = case when p ? 'invoice_rrule'
                                    then nullif(p->>'invoice_rrule','')     else j.invoice_rrule     end
     where j.id = v_job_id;
  end if;

  if v_li is not null and jsonb_typeof(v_li) = 'array' then
    delete from public.line_items
     where job_id = v_job_id and visit_id is null and invoice_id is null;
    for v_r in select * from jsonb_array_elements(v_li) as e(x) loop
      insert into public.line_items (job_id, name, quantity, unit_price, total_price)
      values (v_job_id,
              v_r.x->>'name',
              coalesce(nullif(v_r.x->>'quantity','')::numeric, 1),
              nullif(v_r.x->>'unit_price','')::numeric,
              nullif(v_r.x->>'total_price','')::numeric);
    end loop;
  end if;

  return jsonb_build_object('job_id', v_job_id, 'created', v_created);
end
$function$;

-- ---- VERIFY: EXERCISE the new body, do not just create it ---------------------------------------
-- PL/pgSQL is not parsed at creation time, so "the migration applied" says nothing about whether the
-- function runs. Both arms below call it for real against an existing job and roll back.
do $verify$
declare
  v_gid   text := 'Z2lkOi8vSm9iYmVyL0pvYi8xNTQ1MDc4NzY=';  -- 309-KEB's Service Call, job 1845
  v_email text;
  v_rows  int;
begin
  -- ARM 1: WITH actor_email -> the audit row must name the human
  perform public.fn_record_client_job(jsonb_build_object(
    'gid', v_gid, 'title', 'VERIFY MARKER A', 'actor_email', 'verify.person@ayache.com'));
  select jwt_claims->>'email' into v_email
    from audit.logs
   where table_name = 'jobs' and new_row->>'title' = 'VERIFY MARKER A'
   order by changed_at desc limit 1;
  if v_email is distinct from 'verify.person@ayache.com' then
    raise exception 'VERIFY arm 1: expected the attested email, got %', coalesce(v_email, 'NULL');
  end if;

  -- ARM 2 (the control): WITHOUT actor_email -> still works, and still records no person.
  -- This is what proves arm 1's result came from the attestation and not from something ambient.
  perform set_config('request.jwt.claims', '', true);
  perform public.fn_record_client_job(jsonb_build_object(
    'gid', v_gid, 'title', 'VERIFY MARKER B'));
  select count(*) into v_rows
    from audit.logs where table_name = 'jobs' and new_row->>'title' = 'VERIFY MARKER B';
  if v_rows < 1 then
    raise exception 'VERIFY arm 2: the no-actor call wrote nothing, so it is NOT non-breaking';
  end if;
  select jwt_claims->>'email' into v_email
    from audit.logs
   where table_name = 'jobs' and new_row->>'title' = 'VERIFY MARKER B'
   order by changed_at desc limit 1;
  if v_email is not null then
    raise exception 'VERIFY arm 2: expected no attested email without actor_email, got %', v_email;
  end if;

  raise notice 'VERIFY ok: with actor_email the trail names the person; without it the call still succeeds and names nobody';
  raise exception 'VERIFY_ROLLBACK';  -- deliberate: undo both marker writes
exception
  when others then
    if sqlerrm = 'VERIFY_ROLLBACK' then
      raise notice 'VERIFY complete, probe writes discarded';
    else
      raise;
    end if;
end $verify$;

commit;
