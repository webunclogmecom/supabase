-- Rollback of 2026-11-17_0558_calendar_drawer_save_one_step.sql: set_visit_status back to its own body (md5 c69367b7...), the three new functions dropped.
begin;
set local lock_timeout = '3s';
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
END; $function$
;

drop function ops.save_calendar_visit_drawer(bigint, jsonb, text);
drop function public.save_calendar_visit_drawer(bigint, jsonb, text, boolean);
drop function public.fn_apply_visit_status(bigint, text, text);
do $v$ begin
  if md5(pg_get_functiondef('public.set_visit_status(bigint,text,text)'::regprocedure)) <> 'c69367b74ebdb18820560cdb2ebc5bbe' then
    raise exception 'ROLLBACK VERIFY: set_visit_status body differs';
  end if;
end $v$;
commit;
