-- Migration: 2026-06-29f_ripple_promote_jobber_source
-- Author: Claude (Opus 4.8) for Fred
-- Audit: writes to already-audited public.visits via the RPC. No DDL beyond the function.
--
-- WHY: ripple_reschedule_visit REJECTED Jobber-mastered visits (source not in
-- visit-calendar/supabase_cron). But the Calendar lets the office drag-n-drop ANY visit;
-- moving a jobber-source visit (e.g. 051-PV 5857) updated the DB but the push trigger +
-- jobber-push-visit edge fn both skip jobber-source -> silent desync (DB moved, Jobber stale).
-- Now: editing a Jobber-mastered visit ADOPTS it as Calendar-mastered (source -> visit-calendar)
-- in the target UPDATE (non-dry-run only), so the move pushes back. handleVisit loop-guard then
-- preserves source=visit-calendar on inbound, so it will not revert. Forward-chain cron/calendar
-- visits still cascade; jobber-source chain visits are left untouched (excluded from the set).
-- Part 1 of the Calendar<->Jobber ACID work (Fred 2026-06-29). Drag-n-drop will be routed
-- through this RPC (Calendar app) so timed moves shift start_at + cascade + push correctly.

CREATE OR REPLACE FUNCTION public.ripple_reschedule_visit(p_visit_id bigint, p_new_date date, p_new_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_new_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_dry_run boolean DEFAULT false)
 RETURNS TABLE(visit_id bigint, old_date date, new_date date)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_max_ripple CONSTANT int := 24;  -- mirror generator MAX_PER_JOB; abort rather than burst
  m            RECORD;
  v_freq       int;
  v_lower      date;
  v_set        bigint[];
  v_n          int;
BEGIN
  SELECT id, job_id, client_id, visit_date, visit_status, source, deleted_at, start_at
    INTO m FROM public.visits WHERE id = p_visit_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'visit % not found', p_visit_id; END IF;
  IF m.deleted_at IS NOT NULL OR m.visit_status IN ('completed','cancelled') THEN
    RAISE EXCEPTION 'visit % is %/deleted; not reschedulable', p_visit_id, m.visit_status;
  END IF;
  -- A Jobber-mastered visit edited in the Calendar is ADOPTED as Calendar-mastered (the
  -- promote happens in the target UPDATE below, non-dry-run only), so the move pushes back to
  -- Jobber instead of silently no-op'ing. handleVisit's loop-guard then preserves
  -- source='visit-calendar' on inbound, so it won't revert. (Was: rejected jobber-source.)

  SELECT j.frequency_days INTO v_freq FROM public.jobs j WHERE j.id = m.job_id;
  v_lower := LEAST(m.visit_date, p_new_date);

  -- gather + lock the forward ripple set (job-scoped, calendar/cron, live, future).
  -- FOR UPDATE cannot combine with array_agg, so lock+order in the subquery.
  SELECT array_agg(s.id ORDER BY s.visit_date, s.id) INTO v_set
  FROM (
    SELECT v.id, v.visit_date
    FROM public.visits v
    WHERE v.job_id = m.job_id AND v.id <> m.id
      AND v.source IN ('visit-calendar','supabase_cron')
      AND v.visit_status NOT IN ('completed','cancelled')
      AND v.deleted_at IS NULL
      AND v.visit_date > v_lower
    ORDER BY v.visit_date, v.id
    FOR UPDATE
  ) s;
  v_n := COALESCE(array_length(v_set,1),0);

  IF v_freq IS NULL OR v_freq <= 0 THEN v_set := '{}'; v_n := 0; END IF;  -- move-only, no chain
  IF v_n > v_max_ripple THEN
    RAISE EXCEPTION 'ripple set % exceeds cap % for job % — aborting rather than firing an unbounded push burst',
      v_n, v_max_ripple, m.job_id;
  END IF;

  IF p_dry_run THEN
    RETURN QUERY SELECT m.id, m.visit_date, p_new_date;
    IF v_n > 0 THEN
      RETURN QUERY
      SELECT v.id, v.visit_date, (p_new_date + (i.ord * v_freq)::int)::date
      FROM unnest(v_set) WITH ORDINALITY AS i(vid, ord)
      JOIN public.visits v ON v.id = i.vid;
    END IF;
    RETURN;
  END IF;

  -- move the target; preserve wall-clock by shifting timestamps by the same day
  -- delta unless an explicit start/end was passed.
  UPDATE public.visits
     SET visit_date = p_new_date,
         source     = CASE WHEN source IN ('visit-calendar','supabase_cron') THEN source ELSE 'visit-calendar' END,
         start_at   = COALESCE(p_new_start_at, start_at + make_interval(days => (p_new_date - visit_date))),
         end_at     = COALESCE(p_new_end_at,   end_at   + make_interval(days => (p_new_date - visit_date)))
   WHERE id = m.id;
  RETURN QUERY SELECT m.id, m.visit_date, p_new_date;

  -- re-anchor the forward chain at +freq; shift start/end by the same delta; skip no-ops.
  IF v_n > 0 THEN
    RETURN QUERY
    WITH tgt AS (
      SELECT i.vid, (p_new_date + (i.ord * v_freq)::int)::date AS nd
      FROM unnest(v_set) WITH ORDINALITY AS i(vid, ord)
    ), upd AS (
      UPDATE public.visits v
         SET visit_date = t.nd,
             start_at   = v.start_at + make_interval(days => (t.nd - v.visit_date)),
             end_at     = v.end_at   + make_interval(days => (t.nd - v.visit_date))
      FROM tgt t WHERE v.id = t.vid AND v.visit_date IS DISTINCT FROM t.nd
      RETURNING v.id, t.nd
    )
    SELECT u.id, v0.visit_date, u.nd
    FROM upd u JOIN public.visits v0 ON v0.id = u.id;
  END IF;
END;
$function$

