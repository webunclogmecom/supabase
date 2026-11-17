-- 2026-11-17_0558_calendar_drawer_save_one_step.sql
-- Trello #198 bZ17bUSj (Visit Calendar and the Ops Portal's /calendar): the visit drawer's Save made up to three server
-- calls (set_visit_status, ripple_reschedule_visit, then save-calendar-visit or edit_calendar_visit). When the last one
-- failed, the status and the date move were already saved while the drawer said "Nothing was written on our side".
-- Fred, 2026-11-17: "One server step only", then "Jobber first" (plan: Building Apps/Ops Portal/docs/specs/
-- 2026-11-17-drawer-save-one-step-plan.md).
--
-- What changes:
--   1. NEW public.fn_apply_visit_status(visit, status, reason): the status rules of set_visit_status, lifted VERBATIM.
--      EXECUTE: owner only.
--   2. public.set_visit_status: same staff checks, then RETURN public.fn_apply_visit_status(...). One anchored edit of
--      the live body (md5 guarded below); behaviour identical.
--   3. NEW public.save_calendar_visit_drawer(visit, patch, status, own_fields_verified): the whole Save in one
--      transaction. service_role only (save-calendar-visit, after Jobber confirmed this visit's own fields).
--   4. NEW ops.save_calendar_visit_drawer(visit, patch, status): the same for signed-in staff (the saves the Jobber-first
--      path cannot check: services, a date move on an all-day visit); never switches a push off.
-- Jobber: nothing new is pushed and nothing stops being pushed. The date move's later visits and a status change go out
-- by their triggers as before; only this visit's own already-confirmed fields skip their echo push (as before, via
-- app.suppress_jobber_push for one statement).
-- Audit (rule 8): no table changes; public.visits stays audited and every write is the existing functions' own.
-- Rollback: 2026-11-17_0558_calendar_drawer_save_one_step_rollback.sql.

begin;
set local lock_timeout = '3s';

do $guard$
begin
  if md5(pg_get_functiondef('public.set_visit_status(bigint,text,text)'::regprocedure)) <> 'c69367b74ebdb18820560cdb2ebc5bbe' then
    raise exception 'public.set_visit_status changed since this migration was written; rebuild it from the live body';
  end if;
end $guard$;

CREATE FUNCTION public.fn_apply_visit_status(p_visit_id bigint, p_status text, p_reason text DEFAULT NULL::text)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The status rules of public.set_visit_status, lifted out VERBATIM (2026-11-17, Trello #198) so the drawer's one-step
-- save can apply a status in the same transaction. No caller check here: set_visit_status keeps its staff checks and
-- calls this; public.save_calendar_visit_drawer is reached only by service_role or through ops.save_calendar_visit_drawer,
-- which makes the same checks. EXECUTE belongs to the owner only.
DECLARE v_row public.visits;
BEGIN
  IF p_status NOT IN ('completed','scheduled','skipped','cancelled') THEN
    RAISE EXCEPTION 'set_visit_status: unsupported status %', p_status USING ERRCODE='check_violation';
  END IF;

  SELECT * INTO v_row FROM public.visits WHERE id = p_visit_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'visit % not found', p_visit_id; END IF;
  IF v_row.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'visit % is deleted', p_visit_id; END IF;

  IF p_status = 'completed' THEN
    IF v_row.visit_status <> 'scheduled' THEN
      RAISE EXCEPTION 'only a scheduled visit can be completed (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    UPDATE public.visits SET visit_status='completed', completed_at=now()
      WHERE id=p_visit_id RETURNING * INTO v_row;

  ELSIF p_status = 'scheduled' THEN  -- uncomplete ONLY (un-skip lives in unskip_visit)
    IF v_row.visit_status = 'skipped' THEN
      RAISE EXCEPTION 'visit % is skipped; use unskip_visit to restore it', p_visit_id USING ERRCODE='check_violation';
    ELSIF v_row.visit_status <> 'completed' THEN
      RAISE EXCEPTION 'only a completed visit can be un-completed (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    UPDATE public.visits SET visit_status='scheduled', completed_at=NULL
      WHERE id=p_visit_id RETURNING * INTO v_row;

  ELSIF p_status = 'skipped' THEN
    IF v_row.visit_status <> 'scheduled' THEN
      RAISE EXCEPTION 'only a scheduled visit can be skipped (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    UPDATE public.visits
       SET visit_status='skipped',
           skip_reason=NULLIF(btrim(coalesce(p_reason,'')),''),
           source=CASE WHEN source IN ('visit-calendar','supabase_cron') THEN source ELSE 'visit-calendar' END
     WHERE id=p_visit_id RETURNING * INTO v_row;
    PERFORM public.fn_promote_next_sa_occurrence(v_row.job_id);

  ELSE  -- 'cancelled'
    IF v_row.visit_status <> 'scheduled' THEN
      RAISE EXCEPTION 'only a scheduled visit can be cancelled (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    -- cancel == skip in Jobber: the AFTER push trigger deletes THIS occurrence (visit_status IN
    -- (cancelled,skipped) -> op='delete'); normalizing source makes that delete fire + bypass the
    -- origin gate, exactly as skip does. Reason not stored (no cancel_reason column in Phase 1).
    UPDATE public.visits
       SET visit_status='cancelled',
           source=CASE WHEN source IN ('visit-calendar','supabase_cron') THEN source ELSE 'visit-calendar' END
     WHERE id=p_visit_id RETURNING * INTO v_row;
    PERFORM public.fn_promote_next_sa_occurrence(v_row.job_id);
  END IF;

  RETURN v_row;
END; $function$;

CREATE OR REPLACE FUNCTION public.set_visit_status(p_visit_id bigint, p_status text, p_reason text DEFAULT NULL::text)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_row public.visits; v_email text;
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'change a visit status');   -- 2026-10-21_0900 access phase 5
  -- AUTH: logged-in staff only (@ayache.com / @unclogme.com). Defense-in-depth over the
  -- authenticated-only EXECUTE grant so even a mis-grant can't let the public anon key through.
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'set_visit_status requires a logged-in staff user' USING ERRCODE='insufficient_privilege';
  END IF;
  v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  IF NOT public.fn_is_staff_email(v_email) THEN
    RAISE EXCEPTION 'set_visit_status: % is not a staff account', v_email USING ERRCODE='insufficient_privilege';
  END IF;

  RETURN public.fn_apply_visit_status(p_visit_id, p_status, p_reason);
END; $function$;

CREATE FUNCTION public.save_calendar_visit_drawer(p_visit_id bigint, p_patch jsonb, p_status text DEFAULT NULL::text, p_own_fields_verified boolean DEFAULT false)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- The visit drawer's whole Save in ONE transaction (2026-11-17, Trello #198, Fred: "One server step only", then "Jobber
-- first"). Before this the drawer made up to three calls (status, date move, the rest); a failure in the last left the
-- first two saved while the drawer said nothing was saved. Now any failure rolls back all of it.
-- Order: an un-complete first (the date move refuses a completed visit), then the date move with the later visits of the
-- agreement (public.ripple_reschedule_visit, pushed to Jobber by their triggers exactly as before), then the rest of the
-- edit (public.edit_calendar_visit), then any other status (public.fn_apply_visit_status, pushed by its trigger).
-- p_own_fields_verified = true ONLY from save-calendar-visit after Jobber confirmed this visit's own fields: the push of
-- the rest of the edit is switched off for that one statement (as edit_calendar_visit_verified does) and the visit is
-- marked confirmed; the date move and the status are never switched off, so the later visits and Jobber's own
-- complete/uncomplete still go out. EXECUTE: service_role only. Signed-in staff use ops.save_calendar_visit_drawer.
DECLARE
  v public.visits;
  v_rest jsonb := COALESCE(p_patch, '{}'::jsonb);
  v_status text := NULLIF(btrim(COALESCE(p_status, '')), '');
  v_date date;
  v_status_first boolean;
BEGIN
  SELECT * INTO v FROM public.visits WHERE id = p_visit_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'save_calendar_visit_drawer: visit % not found or deleted', p_visit_id;
  END IF;
  IF v_status IS NOT DISTINCT FROM v.visit_status THEN v_status := NULL; END IF;
  v_status_first := v_status = 'scheduled';

  IF v_status_first THEN
    PERFORM public.fn_apply_visit_status(p_visit_id, v_status, NULL);
  END IF;

  IF v_rest ? 'visit_date' THEN
    v_date := (v_rest ->> 'visit_date')::date;
    IF v_date IS DISTINCT FROM v.visit_date THEN
      PERFORM public.ripple_reschedule_visit(
        p_visit_id, v_date,
        CASE WHEN v_rest ? 'start_at' THEN (v_rest ->> 'start_at')::timestamptz END,
        CASE WHEN v_rest ? 'end_at' THEN (v_rest ->> 'end_at')::timestamptz END,
        false);
      v_rest := v_rest - 'visit_date' - 'start_at' - 'end_at';
    ELSE
      v_rest := v_rest - 'visit_date';
    END IF;
  END IF;

  IF v_rest <> '{}'::jsonb THEN
    IF p_own_fields_verified THEN
      PERFORM set_config('app.suppress_jobber_push', 'on', true);
    END IF;
    PERFORM public.edit_calendar_visit(p_visit_id, v_rest);
    IF p_own_fields_verified THEN
      PERFORM set_config('app.suppress_jobber_push', 'off', true);
      UPDATE public.visits SET sync_state = 'confirmed' WHERE id = p_visit_id AND sync_state = 'pending';
    END IF;
  END IF;

  IF v_status IS NOT NULL AND NOT v_status_first THEN
    PERFORM public.fn_apply_visit_status(p_visit_id, v_status, NULL);
  END IF;

  SELECT * INTO v FROM public.visits WHERE id = p_visit_id;
  RETURN v;
END;
$function$;

CREATE FUNCTION ops.save_calendar_visit_drawer(p_visit_id bigint, p_patch jsonb, p_status text DEFAULT NULL::text)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- The drawer's one-step save for signed-in staff, for the saves the Jobber-first path cannot check (a change of
-- services, or a date move on an all-day visit). Same checks as public.set_visit_status; pushes to Jobber by triggers.
DECLARE v_email text;
BEGIN
  PERFORM hr.fn_check_app('visit_calendar', 'edit', 'save a visit');
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'save_calendar_visit_drawer requires a logged-in staff user' USING ERRCODE = 'insufficient_privilege';
  END IF;
  v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  IF NOT public.fn_is_staff_email(v_email) THEN
    RAISE EXCEPTION 'save_calendar_visit_drawer: % is not a staff account', v_email USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN public.save_calendar_visit_drawer(p_visit_id, p_patch, p_status, false);
END;
$function$;

revoke all on function public.fn_apply_visit_status(bigint, text, text) from public, anon, authenticated, service_role;
revoke all on function public.save_calendar_visit_drawer(bigint, jsonb, text, boolean) from public, anon, authenticated;
grant execute on function public.save_calendar_visit_drawer(bigint, jsonb, text, boolean) to service_role;
revoke all on function ops.save_calendar_visit_drawer(bigint, jsonb, text) from public, anon;
grant execute on function ops.save_calendar_visit_drawer(bigint, jsonb, text) to authenticated, service_role;

do $verify$
begin
  if has_function_privilege('authenticated', 'public.fn_apply_visit_status(bigint,text,text)', 'EXECUTE')
     or has_function_privilege('service_role', 'public.fn_apply_visit_status(bigint,text,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.fn_apply_visit_status(bigint,text,text)', 'EXECUTE') then
    raise exception 'VERIFY: fn_apply_visit_status is callable from outside';
  end if;
  if has_function_privilege('authenticated', 'public.save_calendar_visit_drawer(bigint,jsonb,text,boolean)', 'EXECUTE')
     or has_function_privilege('anon', 'public.save_calendar_visit_drawer(bigint,jsonb,text,boolean)', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.save_calendar_visit_drawer(bigint,jsonb,text,boolean)', 'EXECUTE') then
    raise exception 'VERIFY: wrong rights on public.save_calendar_visit_drawer';
  end if;
  if has_function_privilege('anon', 'ops.save_calendar_visit_drawer(bigint,jsonb,text)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'ops.save_calendar_visit_drawer(bigint,jsonb,text)', 'EXECUTE') then
    raise exception 'VERIFY: wrong rights on ops.save_calendar_visit_drawer';
  end if;
  if pg_get_functiondef('public.set_visit_status(bigint,text,text)'::regprocedure) !~ 'RETURN public\.fn_apply_visit_status\(p_visit_id, p_status, p_reason\)'
     or pg_get_functiondef('public.set_visit_status(bigint,text,text)'::regprocedure) ~ 'UPDATE public\.visits' then
    raise exception 'VERIFY: set_visit_status body is not the expected one';
  end if;
  if pg_get_functiondef('public.fn_apply_visit_status(bigint,text,text)'::regprocedure) !~ 'fn_promote_next_sa_occurrence' then
    raise exception 'VERIFY: fn_apply_visit_status lost its rules';
  end if;
  perform set_config('verify.summary', 'rights and bodies as intended', true);
end $verify$;

commit;
