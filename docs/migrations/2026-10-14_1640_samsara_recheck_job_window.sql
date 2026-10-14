-- ============================================================================
-- 2026-10-14_1640 Time on site recheck: hand the whole job window to the recheck
-- ============================================================================
-- WHY
--   The first dry run of time-on-site-samsara-recheck (2026-08-19 to today) would change 199 saved times. Of the 40
--   big changes, 17 are old values our own stop and Samsara both contradict (safe), but 23 are jobs where the truck
--   MOVED during the job (re-parked, or a short Samsara trip inside our stop): Samsara splits them into two stays and
--   the recheck would keep only the one holding the tap (6105: 80 -> 43; 6595: 50 -> 13). Whether such a job counts in
--   full is Fred's call, so the recheck leaves them alone until he decides.
-- WHAT CHANGES
--   public.fn_time_on_site_samsara_candidates also returns the job window from public.v_visit_stop_reference
--   (ref_arrived, ref_departed: the completion stop plus earlier stops chained to it). The edge function skips a visit
--   when more than one Samsara stay overlaps that window (counted as moved_during_job). Same signature and grants.
-- ROLLBACK: re-run the function from 2026-10-14_1630.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE OR REPLACE FUNCTION public.fn_time_on_site_samsara_candidates(p_from date, p_to date)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $f$
  select coalesce(jsonb_agg(jsonb_build_object(
           'visit_id', v.id, 'truck_samsara_id', e.source_id, 'arrived', s.arrived_at, 'departed', s.departed_at,
           'ref_arrived', r.arrival, 'ref_departed', r.departure,
           'completed_at', v.completed_at,
           'holds_tap', v.completed_at between s.arrived_at - interval '5 minutes' and s.departed_at + interval '15 minutes',
           'duration_minutes', v.duration_minutes, 'source', v.time_on_site_source) order by v.id), '[]'::jsonb)
    from public.visits v
    join public.visit_vehicle_stops l on l.visit_id = v.id and l.deleted_at is null and l.match_basis = 'completion'
    join public.vehicle_stops s on s.id = l.vehicle_stop_id and s.superseded_at is null
    join public.entity_source_links e on e.entity_type = 'vehicle' and e.source_system = 'samsara' and e.entity_id = s.vehicle_id
    left join public.v_visit_stop_reference r on r.visit_id = v.id and r.basis = 'completion'
   where v.visit_status = 'completed' and v.deleted_at is null
     and v.visit_date >= p_from and v.visit_date < p_to
     and not public.fn_is_non_customer(v.client_id)
     and coalesce(v.time_on_site_source, '') not in ('review', 'reviewed_blank', 'dump_site_dwell')
     and (select count(*) from public.visit_vehicle_stops o
           where o.vehicle_stop_id = l.vehicle_stop_id and o.deleted_at is null and o.match_basis = 'completion') = 1
$f$;

DO $v$ DECLARE c jsonb; BEGIN
  c := public.fn_time_on_site_samsara_candidates(date '2026-08-19', current_date + 1);
  IF jsonb_array_length(c) < 200 OR EXISTS (SELECT 1 FROM jsonb_array_elements(c) x WHERE x->>'ref_arrived' IS NULL) THEN
    RAISE EXCEPTION 'VERIFY: candidates % or a missing job window', jsonb_array_length(c); END IF;
  IF has_function_privilege('authenticated', 'public.fn_time_on_site_samsara_candidates(date, date)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: authenticated can execute'; END IF;
END $v$;
COMMIT;
