-- 2026-08-17_1500_sync_from_jobber_stale_warning.sql
--
-- WHY -----------------------------------------------------------------------------------------
-- Fred, 2026-08-17: "every time i click on the button `Sync from jobber` the warning stays even
-- though we should've adopted the data from jobber, and if i click again the button i get
-- [This visit changed while you were looking at it. Reopen it and try again]. Fix that."
--
-- Repro: visit 7742 (288-PER Aromas del Peru West Miami). THE ADOPT WORKED. The reconciler's
-- snapshot recorded our_start_at 2026-08-11T11:00Z vs jobber_start_at 2026-08-17T13:15Z; after the
-- click the row reads exactly 2026-08-17T13:15Z. Two independent defects made a correct sync look
-- broken, and this migration fixes both. Neither needs an app change or an edge-fn redeploy.
--
-- DEFECT 1 - THE BANNER IS A STALE SNAPSHOT, NOT A LIVE COMPARISON --------------------------------
-- ops.v_calendar_push_health's 'drift_surfaced' arm reads the newest sync_log row for
-- 'jobber_visit_drift' and trusts its surfaced_visits list verbatim. pg_cron runs that reconciler
-- every 30 minutes, so a successful adopt leaves an alarming, self-contradicting warning on screen
-- for up to half an hour - it literally said "Jobber has this visit on a different day (2026-08-17)
-- than we do" while our visit_date WAS 2026-08-17.
--
-- FIX: re-validate each snapshot entry against live data, per reason. FAIL-OPEN by design - any
-- reason we cannot re-check (audit_read_fail, future reasons) keeps surfacing, because hiding a
-- real drift is far worse than showing a stale one.
--   jobber_date_differs        -> resolved when v.visit_date::text = entry.jobber_date
--                                 (TEXT compare on purpose: no ::date cast, so a malformed value
--                                  can never raise inside a view the Calendar depends on)
--   jobber_all_day_vs_our_time -> resolved when v.start_at IS NULL (we now have no time either)
--   jobber_time_differs        -> resolved when v.start_at = entry.jobber_start_at, and the cast is
--                                 gated behind an escape-free POSIX-class regex
--
-- DEFECT 2 - A NO-OP ADOPT IS REPORTED AS A CONFLICT ----------------------------------------------
-- public.adopt_visit_schedule_from_jobber ended its UPDATE with
--     AND (visit_date IS DISTINCT FROM p_visit_date OR start_at IS ... OR end_at IS ...)
-- i.e. "skip if already equal". So clicking Sync a second time matched 0 rows, returned false, and
-- adopt-visit-from-jobber maps false to "This visit changed while you were looking at it. Reopen it
-- and try again." Nothing had changed - the visit was ALREADY in sync. One return value was carrying
-- two very different meanings: "somebody moved the row under you" and "there was nothing to do".
--
-- FIX: split them. Already-equal is now an idempotent SUCCESS (returns true, still confirms
-- sync_state). A genuine expectation mismatch, and an ineligible row (completed / deleted /
-- Jobber-mastered), still return false, so the existing 409 copy stays accurate for the case it was
-- written for. The signature is unchanged, so the edge function needs no redeploy.
--
-- BODIES WERE COPIED, NOT RETYPED (Supabase CLAUDE.md) --------------------------------------------
-- The view is pg_get_viewdef output with a single WHERE appended at a uniqueness-asserted anchor
-- ("onset ON true", verified to occur exactly once). The function is pg_get_functiondef output with
-- the trailing is-distinct predicate lifted out into an explicit early return.
--
-- AUDIT (rule #8): no table changed. ops.v_calendar_push_health is a view; visits keeps its
-- existing audit trigger, and the sync_state confirm this function performs is captured as before.

begin;

-- PART 1 ------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW ops.v_calendar_push_health AS
SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.source,
    'push_failed'::text AS issue,
    f.reason,
    f.detail,
    f.created_at AS since
   FROM visit_sync_flags f
     JOIN visits v ON v.id = f.visit_id
     JOIN clients c ON c.id = v.client_id
  WHERE f.resolved_at IS NULL AND v.deleted_at IS NULL
UNION ALL
 SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.source,
    'not_in_jobber'::text AS issue,
    NULL::text AS reason,
    NULL::text AS detail,
    v.created_at AS since
   FROM visits v
     JOIN clients c ON c.id = v.client_id
  WHERE (v.source = ANY (ARRAY['visit-calendar'::text, 'supabase_cron'::text])) AND v.visit_status = 'scheduled'::text AND v.deleted_at IS NULL AND v.created_at < (now() - '00:15:00'::interval) AND fn_visit_in_jobber_scope(v.id) AND NOT (EXISTS ( SELECT 1
           FROM entity_source_links e
          WHERE e.entity_type = 'visit'::text AND e.source_system = 'jobber'::text AND e.entity_id = v.id))
UNION ALL
 SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.source,
    'skip_removal_failed'::text AS issue,
    'skipped visit still linked to Jobber (removal did not complete)'::text AS reason,
    v.sync_state AS detail,
    v.updated_at AS since
   FROM visits v
     JOIN clients c ON c.id = v.client_id
  WHERE v.visit_status = 'skipped'::text AND v.deleted_at IS NULL AND (EXISTS ( SELECT 1
           FROM entity_source_links e
          WHERE e.entity_type = 'visit'::text AND e.source_system = 'jobber'::text AND e.entity_id = v.id))
UNION ALL
 SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.source,
    'drift_surfaced'::text AS issue,
    sv.sv ->> 'reason'::text AS reason,
        CASE sv.sv ->> 'reason'::text
            WHEN 'jobber_date_differs'::text THEN ('Jobber has this visit on a different day ('::text || COALESCE(sv.sv ->> 'jobber_date'::text, '?'::text)) || ') than we do. Decide which is right - syncing from Jobber will move the visit.'::text
            WHEN 'jobber_all_day_vs_our_time'::text THEN 'Same day in both, but Jobber has no set time (all-day) while we have one. Syncing from Jobber will clear the time.'::text
            WHEN 'jobber_time_differs'::text THEN 'Same day in both, but the times differ. Syncing from Jobber will use Jobber''s time.'::text
            WHEN 'audit_read_fail'::text THEN 'We could not read this visit''s edit history, so the difference was not classified. It is re-checked every run.'::text
            ELSE 'Our schedule and Jobber''s disagree and the reconciler could not resolve it safely.'::text
        END AS detail,
    onset.first_seen AS since
   FROM ( SELECT sync_log.started_at,
            sync_log.details
           FROM sync_log
          WHERE sync_log.sync_source = 'jobber_visit_drift'::text AND sync_log.details ? 'surfaced_visits'::text
          ORDER BY sync_log.started_at DESC
         LIMIT 1) sl
     CROSS JOIN LATERAL jsonb_array_elements(sl.details -> 'surfaced_visits'::text) sv(sv)
     JOIN visits v ON v.id = ((sv.sv ->> 'id'::text)::bigint) AND v.deleted_at IS NULL AND v.visit_status = 'scheduled'::text
     JOIN clients c ON c.id = v.client_id
     LEFT JOIN LATERAL ( SELECT min(r.started_at) AS first_seen
           FROM sync_log r
          WHERE r.sync_source = 'jobber_visit_drift'::text AND r.details ? 'surfaced_visits'::text AND (EXISTS ( SELECT 1
                   FROM jsonb_array_elements(r.details -> 'surfaced_visits'::text) e(value)
                  WHERE ((e.value ->> 'id'::text)::bigint) = v.id)) AND r.started_at > COALESCE(( SELECT max(r2.started_at) AS max
                   FROM sync_log r2
                  WHERE r2.sync_source = 'jobber_visit_drift'::text AND r2.details ? 'surfaced_visits'::text AND NOT (EXISTS ( SELECT 1
                           FROM jsonb_array_elements(r2.details -> 'surfaced_visits'::text) e2(value)
                          WHERE ((e2.value ->> 'id'::text)::bigint) = v.id))), '-infinity'::timestamp with time zone)) onset ON true
  WHERE
    -- Re-validate the reconciler's snapshot against LIVE data. The snapshot is a point-in-time
    -- list; without this a visit stays 'drifting' until the next */30 run even after a successful
    -- 'Sync from Jobber'. Fail-OPEN: anything we cannot re-check keeps surfacing.
    CASE sv.sv ->> 'reason'::text
      WHEN 'jobber_date_differs'::text THEN
        v.visit_date::text IS DISTINCT FROM (sv.sv ->> 'jobber_date'::text)
      WHEN 'jobber_all_day_vs_our_time'::text THEN
        v.start_at IS NOT NULL
      WHEN 'jobber_time_differs'::text THEN
        CASE
          WHEN (sv.sv ->> 'jobber_start_at'::text) ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'::text
            THEN v.start_at IS DISTINCT FROM ((sv.sv ->> 'jobber_start_at'::text)::timestamptz)
          ELSE true
        END
      ELSE true
    END;

-- PART 2 ------------------------------------------------------------------------------------
-- Copied from pg_get_functiondef. The ONLY behavioural change: the "skip if already equal"
-- predicate is lifted out of the UPDATE into an explicit early return, so already-in-sync is a
-- success rather than a conflict. Signature, grants, guards and the sync_state confirm are byte-
-- identical in intent to the previous body.
CREATE OR REPLACE FUNCTION public.adopt_visit_schedule_from_jobber(p_visit_id bigint, p_visit_date date, p_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_expected_visit_date date DEFAULT NULL::date, p_expected_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_enforce_expected boolean DEFAULT false)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_hit      int;
  v_eligible boolean := false;
  v_already  boolean := false;
BEGIN
  -- suppress the direct echo push for THIS transaction only
  PERFORM set_config('app.suppress_jobber_push', 'on', true);

  -- Is this row adoptable at all, and does it ALREADY hold Jobber's schedule?
  -- Same eligibility predicate the UPDATE uses, asked first so we can tell "nothing to do" apart
  -- from "someone moved it under you" - the two used to share one false return.
  SELECT true,
         (visit_date IS NOT DISTINCT FROM p_visit_date
          AND start_at IS NOT DISTINCT FROM p_start_at
          AND end_at   IS NOT DISTINCT FROM p_end_at)
    INTO v_eligible, v_already
    FROM public.visits
   WHERE id = p_visit_id
     AND source IN ('visit-calendar', 'supabase_cron')   -- only DB-mastered visits
     AND visit_status = 'scheduled'
     AND deleted_at IS NULL;

  IF NOT v_eligible THEN
    RETURN false;   -- completed, skipped, soft-deleted or Jobber-mastered: not ours to adopt
  END IF;

  IF v_already THEN
    -- IDEMPOTENT SUCCESS. The visit already equals Jobber, so a re-click is a no-op, not a
    -- conflict. Still confirm sync_state for the same reason the write path does.
    UPDATE public.visits SET sync_state = 'confirmed'
     WHERE id = p_visit_id AND sync_state = 'pending';
    RETURN true;
  END IF;

  UPDATE public.visits
     SET visit_date = p_visit_date,
         start_at   = p_start_at,
         end_at     = p_end_at
   WHERE id = p_visit_id
     AND source IN ('visit-calendar', 'supabase_cron')   -- only DB-mastered visits
     AND visit_status = 'scheduled'
     AND deleted_at IS NULL
     -- optimistic concurrency: refuse if the row moved since the caller's snapshot
     AND (NOT p_enforce_expected
          OR (visit_date IS NOT DISTINCT FROM p_expected_visit_date
              AND start_at IS NOT DISTINCT FROM p_expected_start_at));
  GET DIAGNOSTICS v_hit = ROW_COUNT;
  IF v_hit > 0 THEN
    -- DB now equals Jobber: confirm so the */3-min stale-pending cron never blind-echoes the
    -- adopted schedule back to Jobber (which could revert a dispatch edit made in the window).
    -- sync_state-only UPDATE: trips no push trigger, no re-pending, no date rewrite (verified).
    UPDATE public.visits SET sync_state = 'confirmed'
     WHERE id = p_visit_id AND sync_state = 'pending';
  END IF;
  RETURN v_hit > 0;
END;
$function$;

commit;
