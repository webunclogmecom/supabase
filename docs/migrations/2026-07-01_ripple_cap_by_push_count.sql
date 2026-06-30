-- 2026-07-01_ripple_cap_by_push_count.sql
-- ============================================================================
-- FIX: ripple_reschedule_visit aborted ("ripple set N exceeds cap 24") when moving a
-- HIGH-FREQUENCY SA visit. The cap was on the full DB forward-chain size, but a weekly SA
-- (freq=7) has a ~26-visit 6-month chain while only ~9 of them fall inside the 60-day Jobber
-- push horizon — and ONLY in-horizon visits actually push to Jobber (out-of-horizon ones are
-- cheap DB-only re-anchors). 214-MYK (job 1635, the lone weekly SA) was the only job tripping it.
--
-- Now: cap on the IN-HORIZON PUSH count (the real burst), not the DB chain. If even that exceeds
-- the cap (e.g. a hypothetical daily SA), fall back to moving ONLY the target — the office's move
-- always succeeds, never errors. Keeps the DST-safe ET round-trip shift from 2026-07-01_ripple_dst_safe_shift.
-- Supersedes that migration's function body; ops.ripple_reschedule_visit wrapper unchanged.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.ripple_reschedule_visit(p_visit_id bigint, p_new_date date, p_new_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_new_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_dry_run boolean DEFAULT false)
 RETURNS TABLE(visit_id bigint, old_date date, new_date date)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_max_ripple CONSTANT int := 24;  -- cap on the Jobber-PUSH burst (in-horizon), not the DB chain
  m            RECORD;
  v_freq       int;
  v_lower      date;
  v_set        bigint[];
  v_n          int;
  v_n_push     int;
BEGIN
  SELECT id, job_id, client_id, visit_date, visit_status, source, deleted_at, start_at
    INTO m FROM public.visits WHERE id = p_visit_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'visit % not found', p_visit_id; END IF;
  IF m.deleted_at IS NOT NULL OR m.visit_status IN ('completed','cancelled') THEN
    RAISE EXCEPTION 'visit % is %/deleted; not reschedulable', p_visit_id, m.visit_status;
  END IF;
  -- A Jobber-mastered visit edited in the Calendar is ADOPTED as Calendar-mastered (promote in the
  -- target UPDATE below, non-dry-run only), so the move pushes back to Jobber instead of no-op'ing.

  SELECT j.frequency_days INTO v_freq FROM public.jobs j WHERE j.id = m.job_id;
  v_lower := LEAST(m.visit_date, p_new_date);

  -- gather + lock the forward ripple set (job-scoped, calendar/cron, live, future).
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

  -- Cap on the JOBBER-PUSH burst, NOT the DB chain size. Only re-anchored visits whose NEW date
  -- lands inside the 60-day push horizon actually push to Jobber; out-of-horizon ones are cheap
  -- DB-only updates. If even the in-horizon push set exceeds the cap (e.g. a daily SA), fall back
  -- to moving ONLY the target so the move still SUCCEEDS (graceful) instead of erroring.
  IF v_n > 0 THEN
    SELECT count(*) INTO v_n_push
    FROM unnest(v_set) WITH ORDINALITY AS i(vid, ord)
    WHERE (p_new_date + (i.ord * v_freq)::int) <= ((now() AT TIME ZONE 'America/New_York')::date + 60);
    IF v_n_push > v_max_ripple THEN
      RAISE WARNING 'ripple: % in-horizon downstream visits exceed cap % for job % — moving target only',
        v_n_push, v_max_ripple, m.job_id;
      v_set := '{}'; v_n := 0;  -- chain too large to push safely -> move target only
    END IF;
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

  -- move the target; preserve ET wall-clock by shifting the day count IN the local
  -- ('America/New_York') zone so US DST boundaries don't drift the hour.
  UPDATE public.visits
     SET visit_date = p_new_date,
         source     = CASE WHEN source IN ('visit-calendar','supabase_cron') THEN source ELSE 'visit-calendar' END,
         start_at   = COALESCE(
                        p_new_start_at,
                        ((start_at AT TIME ZONE 'America/New_York'
                          + make_interval(days => (p_new_date - visit_date)))
                         AT TIME ZONE 'America/New_York')
                      ),
         end_at     = COALESCE(
                        p_new_end_at,
                        ((end_at AT TIME ZONE 'America/New_York'
                          + make_interval(days => (p_new_date - visit_date)))
                         AT TIME ZONE 'America/New_York')
                      )
   WHERE id = m.id;
  RETURN QUERY SELECT m.id, m.visit_date, p_new_date;

  -- re-anchor the forward chain at +freq; shift start/end by the same day delta IN the
  -- local zone (DST-safe); skip no-ops.
  IF v_n > 0 THEN
    RETURN QUERY
    WITH tgt AS (
      SELECT i.vid, (p_new_date + (i.ord * v_freq)::int)::date AS nd
      FROM unnest(v_set) WITH ORDINALITY AS i(vid, ord)
    ), upd AS (
      UPDATE public.visits v
         SET visit_date = t.nd,
             start_at   = ((v.start_at AT TIME ZONE 'America/New_York'
                            + make_interval(days => (t.nd - v.visit_date)))
                           AT TIME ZONE 'America/New_York'),
             end_at     = ((v.end_at   AT TIME ZONE 'America/New_York'
                            + make_interval(days => (t.nd - v.visit_date)))
                           AT TIME ZONE 'America/New_York')
      FROM tgt t WHERE v.id = t.vid AND v.visit_date IS DISTINCT FROM t.nd
      RETURNING v.id, t.nd
    )
    SELECT u.id, v0.visit_date, u.nd
    FROM upd u JOIN public.visits v0 ON v0.id = u.id;
  END IF;
END;
$function$;
