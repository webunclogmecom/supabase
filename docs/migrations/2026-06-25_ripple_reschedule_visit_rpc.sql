-- ============================================================================
-- Migration: 2026-06-25_ripple_reschedule_visit_rpc.sql
-- ADR: 010 (audit; writes to already-audited public.visits, no new audit trigger)
-- Purpose: Calendar "ripple reschedule" — moving an SA/Calendar visit's date
--          re-anchors the job's FORWARD chain at jobs.frequency_days from the
--          moved date; each shifted row pushes ONCE via the existing unchanged
--          trg_push_visit_update -> jobber-push-visit path (no push fork).
-- Safety: the cascade lives in THIS function's loop, not a trigger reacting to
--         its own writes, so it cannot re-enter (fn_push_visit_to_jobber has no
--         depth guard — verified). Date-only UPDATEs do NOT fire
--         trg_gdo_compliance_check (scoped UPDATE OF service_type). The ripple set
--         is locked FOR UPDATE to serialize concurrent ripples. A hard fan-out cap
--         RAISEs rather than firing an unbounded push burst.
-- Rollout: ships with p_dry_run; dry-run real chains (job 1635=24, freq 7) BEFORE
--          any live enable. The RPC is INERT until the Calendar is wired to call it
--          (a plain PATCH moves+pushes ONE visit but does NOT ripple).
-- Idempotent: CREATE OR REPLACE; re-calling with the same date is a no-op
--             (every target equals current, skipped by IS DISTINCT FROM).
-- Notes vs the original design draft (fixed here):
--   * array_agg(...) FOR UPDATE is illegal — lock+order in a subquery, aggregate outside.
--   * timed visits: shift start_at/end_at by the SAME day delta as visit_date
--     (make_interval) so a moved visit keeps its wall-clock time; NULL start_at stays NULL.
-- ============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.ripple_reschedule_visit(
  p_visit_id     bigint,
  p_new_date     date,
  p_new_start_at timestamptz DEFAULT NULL,
  p_new_end_at   timestamptz DEFAULT NULL,
  p_dry_run      boolean     DEFAULT false
) RETURNS TABLE(visit_id bigint, old_date date, new_date date)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
  IF m.source NOT IN ('visit-calendar','supabase_cron') THEN
    RAISE EXCEPTION 'visit % source=% is Jobber-mastered; ripple not allowed', p_visit_id, m.source;
  END IF;

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
$$;

GRANT EXECUTE ON FUNCTION public.ripple_reschedule_visit(bigint, date, timestamptz, timestamptz, boolean)
  TO anon, authenticated, service_role;

COMMIT;
