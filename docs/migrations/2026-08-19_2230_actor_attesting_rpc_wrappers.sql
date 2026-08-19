-- 2026-08-19_2230_actor_attesting_rpc_wrappers.sql
--
-- WHAT: two thin `_as` wrappers that attest the acting human into request.jwt.claims and then
--       delegate to the existing RPC unchanged, so audit.logs names the PERSON rather than the app
--       for writes made through an edge function.
--
-- WHY:  Fred asked to extend the job-attribution fix (2026-08-19_2130) to the other edge functions.
--       An audit first (below) changed the shape of that request, so read the scope notes before
--       assuming this covers everything.
--
-- ============================ WHAT THE AUDIT ACTUALLY FOUND ============================
-- 1. ATTRIBUTION IS NOT BROADLY BROKEN. Browser-direct writes already carry the claim, because
--    PostgREST sets request.jwt.claims itself. Measured over 60 days:
--        admin-review  -> photo_classifications   406 rows, 406 with an email
--        visit-calendar-> visits                 4396 rows, 4107 with an email
--        visit-calendar-> visit_locations         566 rows,  545 with an email
--    The gap exists ONLY where an edge function writes as service_role.
--
-- 2. ONLY ONE SURFACE CAN SHOW AN ACTOR. `client.job_activity` is the only view in the estate built
--    on audit.logs. Everywhere else attribution is FORENSIC, not visible. That is why this is
--    scoped to real writers and not applied blindly.
--
-- 3. TWO CANDIDATES WERE DROPPED BECAUSE THEY WRITE NOTHING AUDITABLE.
--        fn_request_jobber_push  -> no direct table write
--        fn_request_jobber_sync  -> no direct table write
--    Wrapping them would add surface for no record. push-visit-to-jobber is therefore NOT changed.
--    ⚠ The first regex that measured this returned "no table writes" for ALL FOUR candidates,
--      including fn_record_client_identity which plainly writes `clients`. That was the SQL regex
--      mangled in transport, not the truth. Re-measured by fetching the bodies and matching in
--      Node, with a control asserting each body actually contains "begin".
--
-- 4. THREE MORE WERE ALREADY ATTRIBUTED and need nothing:
--        fn_record_manual_gdo_report  already takes p_filed_by_email
--        create-client                already records requested_by on client_create_attempts
--        save-calendar-visit          ALREADY SOLVED IT BY A DIFFERENT MECHANISM, and this is the
--            one worth knowing about: it sends an `x-actor-name` header which audit.log_change
--            captures into request_context.actor_name. So the estate has TWO attribution channels,
--            not one, and a check that only looks at jwt_claims->>'email' will under-report.
--            Measured on public.visits over 30 days: visit-calendar wrote 2,748 rows, of which
--            2,470 carry jwt_claims->>'email', 263 carry request_context->>'actor_name', and only
--            15 carry neither. It needs nothing.
--            ⚠ I built and applied wrappers for edit_calendar_visit and edit_calendar_visit_verified
--              before measuring this, then DROPPED them again in the same session rather than leave
--              two functions no code calls. Dead surface is what makes the next audit harder.
--
-- ============================ WHY WRAPPERS AND NOT NEW PARAMETERS ============================
-- 🛑 ADDING A DEFAULTED PARAMETER BREAKS EVERY EXISTING CALLER. Tested, not assumed, in a
--    rolled-back probe: with f(int) and f(int, text DEFAULT NULL) both present, a one-argument call
--    fails `42725: function ... is not unique`. So `p_actor_email text DEFAULT NULL` on the existing
--    signatures would have taken down the Visit Calendar's own edit path.
-- 🛑 AND REPLACING THE BODIES WAS THE OTHER BAD OPTION. public.edit_calendar_visit is 9,183 bytes.
--    CREATE OR REPLACE takes the WHOLE body, so a two-line insertion means restating all of it, and
--    anything not reproduced is silently deleted (see the 2026-08-06 resolver incident). A wrapper
--    touches none of it.
-- ⇒ Each wrapper is additive: no DROP, no signature change, no grant loss, and every existing
--   caller keeps calling the original untouched.
--
-- TRUST: SECURITY DEFINER, EXECUTE granted to service_role ONLY (never authenticated), so the only
--    callers are our own edge functions, each of which has already verified the bearer token with
--    auth.getUser(). The email is attested, not asserted by a browser. Same model as
--    send-derm-email's sent_by_email and fn_record_client_job's actor_email.
--
-- MECHANISM: audit.log_change stores NULLIF(current_setting('request.jwt.claims', true), '')::jsonb.
--    The GUC is TRANSACTION-scoped, so it must be set inside the same transaction as the write,
--    which is why the wrapper sets it and then delegates rather than the edge function setting it.
--
-- AUDIT (rule 8): no table changed, no trigger changed. Two new functions only.

begin;

-- ---- 2. save-client-fields: client name / code --------------------------------------------------
create or replace function public.fn_record_client_identity_as(
  p_actor_email text, p_client_id bigint, p_name text, p_client_code text, p_clear_code boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if nullif(btrim(coalesce(p_actor_email, '')), '') is not null then
    perform set_config('request.jwt.claims',
                       json_build_object('email', btrim(p_actor_email))::text, true);
  end if;
  return public.fn_record_client_identity(p_client_id, p_name, p_client_code, p_clear_code);
end $$;

-- ---- 3. adopt-visit-from-jobber: "Sync from Jobber" ---------------------------------------------
create or replace function public.adopt_visit_schedule_from_jobber_as(
  p_actor_email text, p_visit_id bigint, p_visit_date date,
  p_start_at timestamptz, p_end_at timestamptz,
  p_expected_visit_date date, p_expected_start_at timestamptz, p_enforce_expected boolean)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if nullif(btrim(coalesce(p_actor_email, '')), '') is not null then
    perform set_config('request.jwt.claims',
                       json_build_object('email', btrim(p_actor_email))::text, true);
  end if;
  return public.adopt_visit_schedule_from_jobber(
    p_visit_id, p_visit_date, p_start_at, p_end_at,
    p_expected_visit_date, p_expected_start_at, p_enforce_expected);
end $$;

-- ---- grants: service_role ONLY -----------------------------------------------------------------
-- Supabase's ALTER DEFAULT PRIVILEGES hands new public functions to authenticated, so the revoke is
-- load-bearing, not decorative: without it a signed-in browser could call these and attest ANY
-- email it liked.
revoke all on function public.fn_record_client_identity_as(text, bigint, text, text, boolean) from public, anon, authenticated;
revoke all on function public.adopt_visit_schedule_from_jobber_as(text, bigint, date, timestamptz, timestamptz, date, timestamptz, boolean) from public, anon, authenticated;

grant execute on function public.fn_record_client_identity_as(text, bigint, text, text, boolean) to service_role;
grant execute on function public.adopt_visit_schedule_from_jobber_as(text, bigint, date, timestamptz, timestamptz, date, timestamptz, boolean) to service_role;

-- ---- VERIFY ------------------------------------------------------------------------------------
do $verify$
declare v_bad text; v_n int;
begin
  -- both exist
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('fn_record_client_identity_as','adopt_visit_schedule_from_jobber_as');
  if v_n <> 2 then raise exception 'VERIFY: expected 2 wrappers, found %', v_n; end if;

  -- 🛑 authenticated must NOT be able to call any of them, or a browser could attest any identity
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('fn_record_client_identity_as','adopt_visit_schedule_from_jobber_as')
     and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  if v_bad is not null then raise exception 'VERIFY: authenticated can execute %', v_bad; end if;

  -- and service_role MUST be able to, or the edge functions break
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('fn_record_client_identity_as','adopt_visit_schedule_from_jobber_as')
     and not has_function_privilege('service_role', p.oid, 'EXECUTE');
  if v_bad is not null then raise exception 'VERIFY: service_role CANNOT execute %', v_bad; end if;

  -- the originals must still be callable by everyone who could call them before
  if not has_function_privilege('authenticated', 'public.fn_record_client_identity(bigint, text, text, boolean)', 'EXECUTE') then
    raise exception 'VERIFY: authenticated lost EXECUTE on the ORIGINAL fn_record_client_identity';
  end if;

  raise notice 'VERIFY ok: 2 wrappers, service_role only, original fn_record_client_identity untouched and still callable';
end $verify$;

commit;
