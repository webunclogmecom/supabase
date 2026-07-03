-- Migration: 2026-07-03c_skip_visit_status.sql
-- Author: Claude (Supabase session)
-- Ticket/Reason: Yannick (Slack) — "I need to skip a visit for 202, the restaurant is not open yet."
--   Today ops can only REMOVE a visit (loses the record) or RESCHEDULE it to a fake future date.
--   Fred: "let me see how to implement so it can work around jobber." This adds a real 4th
--   visit_status = 'skipped': the visit stays in our DB (deleted_at IS NULL, keeps its date + a
--   reason) but is REMOVED from Jobber's schedule (Jobber has no skip concept) so the crew doesn't
--   show up. Reversible via unskip. Design: per-visit skip, single-occurrence cadence hole.
--
-- Blast-radius audit (5-agent workflow) + independent live-DB verification found:
--   * 21 visit_status consumers: only public.visits_with_status LEAKS (labels a past-dated skipped
--     visit 'late'); every other view uses a POSITIVE `visit_status='completed'`/`='scheduled'`
--     whitelist and naturally excludes 'skipped'. GUARDRAIL: never rewrite those to
--     `visit_status <> 'cancelled'` — that would leak a skipped visit in as revenue/utilization/a
--     missing-manifest gap.
--   * The SA generator (generate_service_agreement_visits.js) needs NO change: a skipped visit keeps
--     deleted_at IS NULL, so it appears in the job's existing-visits set and its date suppresses
--     regeneration via the status-agnostic ±7-day idempotency filter — i.e. it OCCUPIES the slot.
--   * LOAD-BEARING: fn_push_visit_to_jobber must emit op='delete' for 'skipped' (else a pure
--     status flip produces changed=[] + op='upsert' and the edge fn NO-OPS — the crew stays booked).
--   * RIPPLE TRAP: ripple_reschedule_visit's guards IN/NOT IN ('completed','cancelled') must include
--     'skipped', else a skipped visit gets pulled into a ripple chain and silently re-dated/un-skipped.
--
-- Jobber push firing: rather than DROP/CREATE the hot-zone trigger trg_push_visit_update, skip_visit
--   ADOPTS the visit as calendar-mastered (source -> 'visit-calendar' if jobber/sql-born) — the same
--   adoption pattern ripple_reschedule_visit uses — so the existing arm-1 WHEN (source in
--   calendar/cron AND visit_status changed) fires the push for ANY-source skip. No trigger edit.
--
-- Separate deploy (NOT in this SQL): edge fn jobber-push-visit index.ts delete guard += 'skipped'.
--
-- Rollback: see 2026-07-03c section in docs; DROP the two RPCs + skip_reason column, restore the
--   fn/view/ripple bodies from git history, and re-widen the CHECK back to 3 values (after
--   un-skipping any 'skipped' rows).

BEGIN;

-- 1) widen the status domain (additive; existing rows unaffected) --------------
ALTER TABLE public.visits DROP CONSTRAINT visits_visit_status_chk;
ALTER TABLE public.visits ADD CONSTRAINT visits_visit_status_chk
  CHECK (visit_status = ANY (ARRAY['scheduled'::text,'completed'::text,'cancelled'::text,'skipped'::text]));

-- 2) dedicated reason column (NOT `notes` — notes is round-tripped to Jobber as the visit
--    instruction, so a reason there would leak to Jobber and be clobbered) ------
ALTER TABLE public.visits ADD COLUMN IF NOT EXISTS skip_reason text;
COMMENT ON COLUMN public.visits.skip_reason IS
  'Why a visit was skipped (visit_status=''skipped''). Set by skip_visit(), cleared by unskip_visit(). '
  'NOT pushed to Jobber (the visit is removed from Jobber on skip).';
ALTER TABLE public.visits ADD CONSTRAINT visits_skip_reason_chk
  CHECK (visit_status = 'skipped'::text OR skip_reason IS NULL);

-- 3) LOAD-BEARING: a skip must push a Jobber REMOVAL (op='delete') --------------
CREATE OR REPLACE FUNCTION public.fn_push_visit_to_jobber()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op      text;
  v_key     text;
  v_origin  text;
  v_changed jsonb := '[]'::jsonb;
BEGIN
  IF current_setting('app.suppress_jobber_push', true) = 'on' THEN
    RETURN NEW;
  END IF;

  v_op := CASE WHEN NEW.deleted_at IS NOT NULL OR NEW.visit_status IN ('cancelled','skipped')
               THEN 'delete' ELSE 'upsert' END;

  IF v_op = 'delete'
     AND NEW.source IS DISTINCT FROM 'visit-calendar'
     AND NEW.source IS DISTINCT FROM 'supabase_cron' THEN
    BEGIN
      v_origin := NULLIF(current_setting('request.headers', true), '')::jsonb ->> 'origin';
    EXCEPTION WHEN OTHERS THEN
      v_origin := NULL;
    END;
    IF v_origin IS NULL OR v_origin NOT LIKE 'http%' THEN
      RETURN NEW;
    END IF;
  END IF;

  -- "On-purpose" diff. title and notes are now SEPARATE groups so a title-only edit never
  -- touches the Jobber instruction (and vice-versa).
  IF TG_OP = 'UPDATE' THEN
    IF NEW.visit_date IS DISTINCT FROM OLD.visit_date
       OR NEW.start_at IS DISTINCT FROM OLD.start_at
       OR NEW.end_at   IS DISTINCT FROM OLD.end_at THEN
      v_changed := v_changed || to_jsonb('schedule'::text);
    END IF;
    IF NEW.title IS DISTINCT FROM OLD.title THEN
      v_changed := v_changed || to_jsonb('title'::text);
    END IF;
    IF NEW.notes IS DISTINCT FROM OLD.notes THEN
      v_changed := v_changed || to_jsonb('notes'::text);
    END IF;
    IF NEW.team_rev IS DISTINCT FROM OLD.team_rev THEN
      v_changed := v_changed || to_jsonb('crew'::text);
    END IF;
    IF NEW.line_items_rev IS DISTINCT FROM OLD.line_items_rev
       OR NEW.service_line_item_id IS DISTINCT FROM OLD.service_line_item_id THEN
      v_changed := v_changed || to_jsonb('lineitems'::text);
    END IF;
  ELSE
    v_changed := '["schedule","title","notes","crew","lineitems"]'::jsonb;  -- INSERT: full initial push
  END IF;

  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'jobber_push_service_key';
  IF v_key IS NULL THEN
    RAISE WARNING 'jobber_push_service_key vault secret missing; skipping push for visit %', NEW.id;
    RETURN NEW;
  END IF;
  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/jobber-push-visit',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body    := jsonb_build_object('op', v_op, 'visit_id', NEW.id, 'changed', v_changed)
  );
  RETURN NEW;
END;
$function$;

-- 4) RIPPLE TRAP: treat 'skipped' like 'cancelled' in BOTH predicates ----------
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
  IF m.deleted_at IS NOT NULL OR m.visit_status IN ('completed','cancelled','skipped') THEN
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
      AND v.visit_status NOT IN ('completed','cancelled','skipped')
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

-- 5) the ONE real view leak: don't label a skipped visit 'late' ---------------
CREATE OR REPLACE VIEW public.visits_with_status AS
 SELECT v.id,
    v.client_id,
    v.property_id,
    v.job_id,
    v.vehicle_id,
    v.visit_date,
    v.start_at,
    v.end_at,
    v.completed_at,
    v.duration_minutes,
    v.title,
    v.service_type,
    v.visit_status,
    v.visit_status = 'completed'::text AS is_complete,
    v.actual_arrival_at,
    v.actual_departure_at,
    v.is_gps_confirmed,
    v.created_at,
    v.updated_at,
    v.invoice_id,
    v.completed_by,
    c.name AS client_name,
    p.zone,
    veh.name AS vehicle_name,
    sc.frequency_days,
        CASE
            WHEN v.visit_status = 'skipped'::text THEN 'skipped'::text
            WHEN v.visit_status = 'completed'::text THEN 'completed'::text
            WHEN v.visit_date < CURRENT_DATE AND v.visit_status <> 'completed'::text THEN 'late'::text
            WHEN v.visit_date = CURRENT_DATE THEN 'today'::text
            ELSE 'upcoming'::text
        END AS computed_late_status
   FROM visits v
     LEFT JOIN clients c ON c.id = v.client_id
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
     LEFT JOIN service_configs sc ON sc.client_id = v.client_id AND sc.service_type = v.service_type
  WHERE v.deleted_at IS NULL;

-- 6) skip / unskip RPCs (+ ops wrappers the Lovable apps call) -----------------
-- skip_visit: mark a SCHEDULED visit skipped, record the reason, and ADOPT it as calendar-mastered
--   (source -> visit-calendar if jobber/sql-born) so the existing push trigger fires a Jobber removal.
--   The Jobber saga (sync_state pending -> confirmed/failed via the edge fn) runs exactly as for cancel.
CREATE OR REPLACE FUNCTION public.skip_visit(p_visit_id bigint, p_reason text DEFAULT NULL)
 RETURNS public.visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_row public.visits;
BEGIN
  SELECT * INTO v_row FROM public.visits WHERE id = p_visit_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'visit % not found', p_visit_id; END IF;
  IF v_row.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'visit % is deleted', p_visit_id; END IF;
  IF v_row.visit_status <> 'scheduled' THEN
    RAISE EXCEPTION 'only a scheduled visit can be skipped (visit % is %)', p_visit_id, v_row.visit_status;
  END IF;
  UPDATE public.visits
     SET visit_status = 'skipped',
         skip_reason  = NULLIF(btrim(coalesce(p_reason,'')), ''),
         source       = CASE WHEN source IN ('visit-calendar','supabase_cron') THEN source ELSE 'visit-calendar' END
   WHERE id = p_visit_id
   RETURNING * INTO v_row;
  RETURN v_row;
END;
$function$;

-- unskip_visit: restore a skipped visit to scheduled (re-creates it in Jobber via the push trigger's
--   upsert/create path, subject to the 60-day Jobber horizon; far-future re-adds are deferred to the
--   daily generator PROMOTE step).
CREATE OR REPLACE FUNCTION public.unskip_visit(p_visit_id bigint)
 RETURNS public.visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_row public.visits;
BEGIN
  SELECT * INTO v_row FROM public.visits WHERE id = p_visit_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'visit % not found', p_visit_id; END IF;
  IF v_row.visit_status <> 'skipped' THEN
    RAISE EXCEPTION 'visit % is not skipped (is %)', p_visit_id, v_row.visit_status;
  END IF;
  UPDATE public.visits
     SET visit_status = 'scheduled',
         skip_reason  = NULL
   WHERE id = p_visit_id
   RETURNING * INTO v_row;
  RETURN v_row;
END;
$function$;

-- ops-schema wrappers (the app boundary; apps call ops.*, never public.* directly)
CREATE OR REPLACE FUNCTION ops.skip_visit(p_visit_id bigint, p_reason text DEFAULT NULL)
 RETURNS public.visits LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$ SELECT public.skip_visit(p_visit_id, p_reason); $function$;

CREATE OR REPLACE FUNCTION ops.unskip_visit(p_visit_id bigint)
 RETURNS public.visits LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$ SELECT public.unskip_visit(p_visit_id); $function$;

GRANT EXECUTE ON FUNCTION ops.skip_visit(bigint, text)   TO anon, authenticated;
GRANT EXECUTE ON FUNCTION ops.unskip_visit(bigint)       TO anon, authenticated;

COMMIT;
