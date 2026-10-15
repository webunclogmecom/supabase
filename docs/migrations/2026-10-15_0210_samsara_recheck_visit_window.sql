-- ============================================================================
-- 2026-10-15_0210 Samsara recheck: the completion stop must be inside the visit's date window
-- ============================================================================
-- WHY
--   2026-10-15_0140 let a stop several visits share into the recheck (Fred: "that should be get the whole stop"). Its
--   dry run then proposed to replace 8017 and 8018 (Fred set 8017 to the 1 h 23 min stay of Sep 5: "give 8017 the
--   1h 23m") with a 77 min stay on Sep 7: the driver batch-tapped both on Sep 7, so the linker's late-tap rule
--   anchored them to that later stop. The visit only gives the date and the client (Fred, 2026-10-15), and every other
--   reading uses the visit's window: visit date -4 h to 10 AM the next day, ET (fn_time_on_site_went_once, the audit,
--   the report). A completion stop arriving outside that window is not this visit's stay, so it is not a candidate.
--   Such a visit is left to the went-once pass (the truck went to the address once in the window) or to a person.
-- WHAT CHANGES
--   public.fn_time_on_site_samsara_candidates: one added predicate on s.arrived_at. Body spliced from the live
--   definition (md5 pinned).
-- ROLLBACK: the previous body is in 2026-10-15_0140.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF pg_get_functiondef('public.fn_time_on_site_samsara_candidates'::regproc) NOT LIKE '%a stop several visits share is no longer left out%' THEN
    RAISE EXCEPTION 'fn_time_on_site_samsara_candidates is not the 2026-10-15_0140 body'; END IF;
END $g$;

CREATE OR REPLACE FUNCTION public.fn_time_on_site_samsara_candidates(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
     -- 2026-10-15_0140 (Fred, decision 3): a stop several visits share is no longer left out; each gets the whole stay
     -- 2026-10-15_0210: the stop arrives inside the visit's window (date -4 h to 10 AM next day ET), as every reading does
     and s.arrived_at >= (v.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
     and s.arrived_at < ((v.visit_date + 1) + time '10:00') at time zone 'America/New_York'
$function$;

DO $v$ DECLARE c jsonb; n int; BEGIN
  c := public.fn_time_on_site_samsara_candidates('2026-09-01', '2026-09-10');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(c) x WHERE (x->>'visit_id')::bigint IN (8017, 8018)) THEN
    RAISE EXCEPTION 'VERIFY: 8017/8018 (Sep 7 late-tap stop) are still candidates'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(c) x WHERE (x->>'visit_id')::bigint = 8013) THEN
    RAISE EXCEPTION 'VERIFY: control 8013 (its stop is inside its window) dropped out'; END IF;
  SELECT jsonb_array_length(public.fn_time_on_site_samsara_candidates('2026-08-19', '2026-10-20')) INTO n;
  IF n < 250 THEN RAISE EXCEPTION 'VERIFY: only % candidates left since Aug 19', n; END IF;
END $v$;

COMMIT;
