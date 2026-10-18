-- ============================================================================
-- ROLLBACK of 2026-10-18_0217_time_on_site_one_time_fix_stage0.sql
-- ============================================================================
-- Restores fn_fill_time_on_site_from_stops, fn_fill_blank_time_on_site, fn_time_on_site_checks and
-- fn_refresh_stop_facts to their bodies before Stage 0 (verbatim pg_get_functiondef, read 2026-10-18 01:59 ET),
-- then drops the ledger if no row was ever applied.
--   - Refuses unless the four live bodies are exactly Stage 0's (md5). If another change landed since, stop and
--     merge by hand: re-creating the old bodies would silently delete it.
--   - Refuses while a ledger row is applied (status or truck_status 'applied'): roll the applied stages back first
--     (their rollback files set rolled_back); otherwise their values would lose the fillers' protection and T7/T8.
--   - Keeps the ledger when a row was once applied and then rolled back: it is the record of what was written.
--     Its rows are also in audit.logs (audit_visit_time_on_site_corrections).
--   - Writes no visit row.
--   Old md5s restored (checked below):
--     fn_fill_time_on_site_from_stops(boolean)                 acaaf87971f7ca4536f96c6772acc170 -> 75229b6b827b570a3a86ab8f35ecf00f
--     fn_fill_blank_time_on_site(date,date,boolean)            b1d8cea3a5f2fc01c62b2a2d1fccbe5d -> 84b40a44075eb6bda67c219452e0c6e3
--     fn_time_on_site_checks()                                 bd9ee5c6a27a21271750d76f3cab3c9c -> 66918d8c099ffc744f602aa4ca0fc7e9
--     fn_refresh_stop_facts(bigint,timestamp with time zone)   a1d91a0a28604c25852429d697c1622f -> a3e39f8f319cc3b146c6611cec30e308
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$
DECLARE n int;
BEGIN
  IF md5(pg_get_functiondef('public.fn_fill_time_on_site_from_stops(boolean)'::regprocedure)) <> 'acaaf87971f7ca4536f96c6772acc170' THEN
    RAISE EXCEPTION '% is not the Stage 0 body: something changed it since, merge by hand', 'fn_fill_time_on_site_from_stops(boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_fill_blank_time_on_site(date,date,boolean)'::regprocedure)) <> 'b1d8cea3a5f2fc01c62b2a2d1fccbe5d' THEN
    RAISE EXCEPTION '% is not the Stage 0 body: something changed it since, merge by hand', 'fn_fill_blank_time_on_site(date,date,boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> 'bd9ee5c6a27a21271750d76f3cab3c9c' THEN
    RAISE EXCEPTION '% is not the Stage 0 body: something changed it since, merge by hand', 'fn_time_on_site_checks()'; END IF;
  IF md5(pg_get_functiondef('public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure)) <> 'a1d91a0a28604c25852429d697c1622f' THEN
    RAISE EXCEPTION '% is not the Stage 0 body: something changed it since, merge by hand', 'fn_refresh_stop_facts(bigint,timestamp with time zone)'; END IF;
  IF to_regclass('public.visit_time_on_site_corrections') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.visit_time_on_site_corrections WHERE status = ''applied'' OR truck_status = ''applied''' INTO n;
    IF n > 0 THEN
      RAISE EXCEPTION '% ledger rows are applied: roll the applied stages back first', n; END IF;
  END IF;
END $pin$;

CREATE OR REPLACE FUNCTION public.fn_fill_time_on_site_from_stops(p_execute boolean DEFAULT false)
 RETURNS TABLE(candidates integer, filled integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cand integer := 0;
  v_filled integer := 0;
  v_hdr text;
begin
  drop table if exists _fill_stops;
  -- 2026-10-13 step 3: a customer visit's time on site is its completion stop plus the earlier adjacent stops joined to
  -- it (completion_chain); a stop holding several completions is split at the completion times. A dump site visit keeps
  -- its single dump link. Other links (window, same_site_earlier) are tank volume links and never set the time.
  create temp table _fill_stops on commit drop as
  with cand as (   -- 2026-10-13_2350: the rule lives in public.v_visit_stop_reference (shared with the audit)
    select r.visit_id, r.arrival, r.departure, r.basis from public.v_visit_stop_reference r where r.split_ok)
  select f.visit_id, f.arrival, f.departure, f.basis
    from cand f
    join public.visits v on v.id = f.visit_id
   where v.visit_status = 'completed' and v.deleted_at is null and f.departure > f.arrival
     -- a blank, or (step 3) a value the labelled GPS measurement wrote inside its own 10-day window (it ran before the
     -- stop existed): the stop is better. Values from before 2026-10-13 (source NULL) wait for the step 5 audit.
     and (v.duration_minutes is null
          or (v.time_on_site_source = 'gps_150m_cluster'
              and v.visit_date >= (now() at time zone 'America/New_York')::date - 10))
     and (v.actual_arrival_at is distinct from f.arrival or v.actual_departure_at is distinct from f.departure
          or v.duration_minutes is distinct from round(extract(epoch from f.departure - f.arrival) / 60)::integer
          or v.time_on_site_source is distinct from
             case when f.basis = 'completion' then 'stop_at_completion' else 'dump_site_dwell' end);

  select count(*) into v_cand from _fill_stops;

  if p_execute then
    -- 2026-10-13_2025: labelled, and the source recorded (a completion link, or a dump site visit)
    v_hdr := current_setting('request.headers', true);
    perform set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
      || jsonb_build_object('x-app-source', 'time-on-site-from-stops',
           'x-change-reason', 'Time on site copied from the truck stop that holds the completion time (with the truck''s earlier stops there, split when several visits share it), or from the dump site visit.'))::text, true);
    update public.visits v
       set actual_arrival_at = f.arrival, actual_departure_at = f.departure,
           duration_minutes  = round(extract(epoch from f.departure - f.arrival) / 60)::integer,
           time_on_site_source = case when f.basis = 'completion' then 'stop_at_completion' else 'dump_site_dwell' end
      from _fill_stops f
     where v.id = f.visit_id
       and v.visit_status = 'completed' and v.deleted_at is null
       and (v.duration_minutes is null
            or (v.time_on_site_source = 'gps_150m_cluster'
                and v.visit_date >= (now() at time zone 'America/New_York')::date - 10));
    get diagnostics v_filled = row_count;
    perform set_config('request.headers', coalesce(v_hdr, ''), true);
  end if;

  return query select v_cand, v_filled;
end
$function$
;

CREATE OR REPLACE FUNCTION public.fn_fill_blank_time_on_site(p_from date, p_to date, p_execute boolean DEFAULT false)
 RETURNS TABLE(blank_considered integer, filled integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_blank integer := 0;
  v_filled integer := 0;
  v_hdr text;
  -- 2026-10-15_2230: 'infinity' while the GPS feed is live; otherwise visits whose GPS window is not fully stored wait
  -- (this fill writes once, so a value cut by a GPS gap would stay)
  v_gps timestamptz := coalesce(public.fn_samsara_data_complete_through('gps'), '-infinity');
begin
  drop table if exists _fill_tos;
  create temp table _fill_tos on commit drop as
  with blank as (
    select v.id, v.visit_date, v.completed_at,
           p.latitude::float8 plat, p.longitude::float8 plon
      from public.visits v
      join public.properties p on p.id = v.property_id
     where v.visit_status = 'completed' and v.deleted_at is null
       and v.visit_date >= p_from and v.visit_date < p_to
       and v.duration_minutes is null
       and v.completed_at is not null
       and p.latitude is not null and p.longitude is not null
       and not public.fn_is_non_customer(v.client_id)
       and ((v.visit_date + 1) + time '10:00') at time zone 'America/New_York' <= v_gps
  ), pings as (
    select b.id, r.vehicle_id, r.recorded_at
      from blank b
      join public.vehicle_telemetry_readings r
        on r.recorded_at >= (b.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
       and r.recorded_at <  ((b.visit_date + 1) + time '10:00') at time zone 'America/New_York'
       and sqrt(power((r.latitude - b.plat) * 111320, 2) +
                power((r.longitude - b.plon) * 111320 * cos(radians(b.plat)), 2)) <= 150
  ), mk as (
    select id, vehicle_id, recorded_at,
           case when lag(recorded_at) over w is null
                  or recorded_at - lag(recorded_at) over w > interval '15 minutes' then 1 else 0 end n
      from pings window w as (partition by id, vehicle_id order by recorded_at)
  ), cl as (
    select id, vehicle_id, recorded_at, sum(n) over (partition by id, vehicle_id order by recorded_at) c from mk
  ), sp as (
    select id, vehicle_id, c, min(recorded_at) arrival, max(recorded_at) departure,
           extract(epoch from max(recorded_at) - min(recorded_at)) / 60 minutes
      from cl group by 1, 2, 3
  )
  select distinct on (sp.id) sp.id as visit_id, sp.arrival, sp.departure, round(sp.minutes)::integer as minutes
    from sp join blank b on b.id = sp.id
   where sp.minutes >= 3
     and b.completed_at between sp.arrival - interval '15 minutes' and sp.departure + interval '15 minutes'
   order by sp.id, sp.minutes desc;

  select count(*) into v_blank
    from public.visits v
   where v.visit_status = 'completed' and v.deleted_at is null
     and v.visit_date >= p_from and v.visit_date < p_to
     and v.duration_minutes is null and not public.fn_is_non_customer(v.client_id);

  if p_execute then
    -- 2026-10-13_2025: labelled, and the source recorded
    v_hdr := current_setting('request.headers', true);
    perform set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
      || jsonb_build_object('x-app-source', 'time-on-site-any-truck',
           'x-change-reason', 'Time on site measured from the GPS of a truck that stayed within 150 m of the property when the job was marked complete.'))::text, true);
    update public.visits v
       set actual_arrival_at = f.arrival, actual_departure_at = f.departure, duration_minutes = f.minutes,
           time_on_site_source = 'gps_150m_any_truck'
      from _fill_tos f
     where v.id = f.visit_id and v.duration_minutes is null
       and v.visit_status = 'completed' and v.deleted_at is null;
    get diagnostics v_filled = row_count;
    perform set_config('request.headers', coalesce(v_hdr, ''), true);
  else
    select count(*) into v_filled from _fill_tos;
  end if;

  return query select v_blank, v_filled;
end
$function$
;

CREATE OR REPLACE FUNCTION public.fn_time_on_site_checks()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-14_1110 (time on site plan step 8): the checks that keep the time on site honest. Each must read 0; they ride
-- in fn_stop_facts_checks' integrity set, so fn_refresh_stop_facts (hourly) writes stop_facts_integrity as error when one
-- is not, and log_jobber_sync_health raises it to the health email. T_detail names the visits (never counted).
DECLARE
  v_today date := (now() at time zone 'America/New_York')::date;
  v_since timestamptz := greatest(now() - interval '24 hours', timestamptz '2026-10-14 02:00+00');   -- writers labelled from step 2
  t1 bigint[]; t3 bigint[]; t4 bigint[]; t5 bigint[]; t6 bigint[]; t2 int; g jsonb;
BEGIN
  -- T1 a client visit from 3 to 10 days ago (the nightly fill has run) whose truck stop holds the completion, but its
  --    time is blank or under 70% of the stop and at least 5 min shorter
  SELECT array_agg(v.id ORDER BY v.id) INTO t1
    FROM public.visits v JOIN public.v_visit_stop_reference r ON r.visit_id = v.id AND r.basis = 'completion' AND r.split_ok
   WHERE v.visit_status = 'completed' AND v.deleted_at IS NULL AND NOT public.fn_is_non_customer(v.client_id)
     AND v.visit_date BETWEEN v_today - 10 AND v_today - 3
     AND coalesce(v.time_on_site_source, '') NOT IN ('review', 'reviewed_blank', 'samsara_stay')   -- 2026-10-14_1600: Samsara's own stay is the judge
     AND (v.duration_minutes IS NULL
          OR (v.duration_minutes < 0.7 * extract(epoch FROM r.departure - r.arrival) / 60
              AND extract(epoch FROM r.departure - r.arrival) / 60 - v.duration_minutes >= 5));
  -- T2 positive control: visit 6509 (the truck parked 164 m from the map point) keeps its 34 min stop. Fires if the
  --    matching rule is narrowed again.
  t2 := CASE WHEN EXISTS (SELECT 1 FROM public.v_visit_stop_reference r JOIN public.visits v ON v.id = r.visit_id
                           WHERE r.visit_id = 6509 AND r.basis = 'completion'
                             AND r.arrival = timestamptz '2026-09-25 14:29:11+00' AND r.departure = timestamptz '2026-09-25 15:02:59+00'
                             AND v.duration_minutes BETWEEN 31 AND 35) THEN 0 ELSE 1 END;
  -- T3 a time on site written without a source or a reason (in the last 24 hours)
  SELECT array_agg(DISTINCT (a.record_pk->>'id')::bigint) INTO t3 FROM audit.logs a
   WHERE a.table_name = 'visits' AND a.changed_at > v_since
     AND a.new_row->>'duration_minutes' IS NOT NULL AND a.new_row->>'duration_minutes' IS DISTINCT FROM a.old_row->>'duration_minutes'
     AND (a.new_row->>'time_on_site_source' IS NULL OR coalesce(a.request_context->>'change_reason', '') = '');
  -- T4 a stop-based or reviewed time overwritten by a GPS fallback (ever, since the source column exists)
  SELECT array_agg(DISTINCT (a.record_pk->>'id')::bigint) INTO t4 FROM audit.logs a
   WHERE a.table_name = 'visits' AND a.changed_at > timestamptz '2026-10-14 01:00+00'
     AND a.old_row->>'time_on_site_source' IN ('stop_at_completion', 'dump_site_dwell', 'review', 'reviewed_blank', 'samsara_stay')
     AND a.new_row->>'time_on_site_source' IN ('gps_150m_cluster', 'gps_150m_any_truck');
  -- T5 the 11 AM alert's instrument misses a stop the stop table has (yesterday's blanks): the alert would say
  --    "passed by" or "no truck" about a truck that was parked there
  g := public.fn_time_on_site_gaps(v_today - 1);
  SELECT array_agg((x->>'visit_id')::bigint) INTO t5 FROM jsonb_array_elements(coalesce(g->'visits', '[]')) x
   WHERE (x->'stop_at_completion' IS NULL OR jsonb_typeof(x->'stop_at_completion') = 'null')
     AND EXISTS (SELECT 1 FROM public.v_visit_stop_reference r WHERE r.visit_id = (x->>'visit_id')::bigint AND r.basis = 'completion');
  -- T6 a visit that is not completed still carries a time on site
  SELECT array_agg(v.id ORDER BY v.id) INTO t6 FROM public.visits v
   WHERE v.deleted_at IS NULL AND v.visit_status <> 'completed'
     AND (v.duration_minutes IS NOT NULL OR v.actual_arrival_at IS NOT NULL OR v.actual_departure_at IS NOT NULL);
  RETURN jsonb_build_object('T1', coalesce(cardinality(t1), 0), 'T2', t2, 'T3', coalesce(cardinality(t3), 0),
    'T4', coalesce(cardinality(t4), 0), 'T5', coalesce(cardinality(t5), 0), 'T6', coalesce(cardinality(t6), 0),
    'T_detail', jsonb_build_object('T1', t1, 'T3', t3, 'T4', t4, 'T5', t5, 'T6', t6));
END $function$
;

CREATE OR REPLACE FUNCTION public.fn_refresh_stop_facts(p_rebuild_vehicle_id bigint DEFAULT NULL::bigint, p_rebuild_from timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_started timestamptz := clock_timestamp();
  v_wm      timestamptz;
  v_until   timestamptz;
  v_vehicle bigint;
  v_build   jsonb := '[]';  v_measure jsonb;  v_link jsonb;  v_checks jsonb;
  v_errors  jsonb := '[]';  v_state text;  v_msg text;
  v_ins     int := 0;  v_int_n int;  v_feed_n int;  v_z6 int;
  v_gps     timestamptz;
begin
  if (p_rebuild_vehicle_id is null) <> (p_rebuild_from is null) then
    raise exception 'fn_refresh_stop_facts: give both rebuild arguments or neither' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('public.fn_refresh_stop_facts'));
  perform set_config('request.headers', '{"x-app-source":"stop-facts"}', true);

  -- watermark: never build past the readings feed (site events), nor closer than 30 minutes to now.
  -- 2026-10-15_2230: only readings runs that stored every stream (resume_point), from Railway or the GitHub fallback;
  -- and never past the GPS feed either: stops are built from GPS, so a GPS outage now pauses the builder instead of
  -- writing stops cut by the gap (stops are append-only). fn_samsara_data_complete_through('gps') is 'infinity' while
  -- the GPS feed is live, so a healthy day builds exactly as before. NULL (a feed that never ran) skips the build:
  -- least() ignores NULLs, which is why the old "NULL when the feed never ran" comment did not hold.
  select max(sl.started_at) into v_wm from public.sync_log sl
   where sl.sync_source in ('railway_samsara_readings', 'github_samsara_readings') and sl.status = 'success'
     and coalesce(sl.details->'summary'->>'resume_point', 'true') = 'true';
  v_gps := public.fn_samsara_data_complete_through('gps');
  v_until := case when v_wm is null or v_gps is null then null
                  else least(now() - interval '30 minutes', v_wm - interval '15 minutes', v_gps - interval '15 minutes') end;

  -- 1. build
  begin
    if v_until is null then
      v_errors := v_errors || jsonb_build_object('step', 'build', 'sqlstate', 'P0002', 'message', 'no successful readings or GPS run: build skipped');
    else
      for v_vehicle in
        select distinct e.entity_id from public.entity_source_links e join public.vehicles ve on ve.id = e.entity_id
         where e.entity_type = 'vehicle' and e.source_system = 'samsara' order by 1
      loop
        v_build := v_build || public.fn_build_vehicle_stops(v_vehicle, v_until, true,
                                case when v_vehicle = p_rebuild_vehicle_id then p_rebuild_from end);
      end loop;
    end if;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    v_errors := v_errors || jsonb_build_object('step', 'build', 'sqlstate', v_state, 'message', left(v_msg, 300));
  end;

  -- 2. measure (35-day horizon, plus every Z2/Z3 pair whatever its age)
  begin
    v_measure := public.fn_measure_vehicle_stop_tank_levels(
                   least(now() - interval '35 days', coalesce(p_rebuild_from, 'infinity')), true);
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    v_errors := v_errors || jsonb_build_object('step', 'measure', 'sqlstate', v_state, 'message', left(v_msg, 300));
  end;

  -- 3. link (whole era)
  begin
    v_link := public.fn_link_visit_vehicle_stops(true);
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    v_errors := v_errors || jsonb_build_object('step', 'link', 'sqlstate', v_state, 'message', left(v_msg, 300));
  end;

  -- 4. checks -> four sync_log sources (separate sources, so a long-open data finding cannot hide a process failure)
  begin
    v_checks := public.fn_stop_facts_checks();
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    v_errors := v_errors || jsonb_build_object('step', 'checks', 'sqlstate', v_state, 'message', left(v_msg, 300));
  end;

  v_ins := coalesce((select sum((b->>'inserted')::int) from jsonb_array_elements(v_build) b), 0)
         + coalesce((v_measure->>'inserted')::int, 0) + coalesce((v_link->>'inserted')::int, 0);

  insert into public.sync_log (sync_source, started_at, finished_at, rows_inserted, status, error_details, details, duration_seconds)
  values ('stop_facts_refresh', v_started, clock_timestamp(), v_ins,
          case when jsonb_array_length(v_errors) = 0 then 'success' else 'error' end,
          case when jsonb_array_length(v_errors) = 0 then null else v_errors end,
          jsonb_build_object('until', v_until, 'watermark', v_wm, 'gps_through', v_gps, 'rebuild_vehicle_id', p_rebuild_vehicle_id,
                             'rebuild_from', p_rebuild_from, 'build', v_build, 'measure', v_measure, 'link', v_link,
                             'flags', v_checks->'flags'),
          extract(epoch from clock_timestamp() - v_started));

  if v_checks is not null then
    select count(*) into v_feed_n from jsonb_each(v_checks->'feed') x where (x.value)::text::int > 0;
    select count(*) into v_int_n from jsonb_each(v_checks->'integrity') x
     where x.key in ('Z1','Z2','Z3','Z4','Z7','Z8','Z9','T1','T2','T3','T4','T5','T6') and (x.value)::text::int > 0;
    if (v_checks->'integrity'->>'Z8_control_found')::boolean is not true then v_int_n := v_int_n + 1; end if;
    v_z6 := (v_checks->'integrity'->>'Z6')::int;
    insert into public.sync_log (sync_source, started_at, finished_at, status, details, duration_seconds)
    values ('tank_feed_freshness', v_started, clock_timestamp(), case when v_feed_n = 0 then 'success' else 'error' end,
            v_checks->'feed', extract(epoch from clock_timestamp() - v_started)),
           ('stop_facts_integrity', v_started, clock_timestamp(), case when v_int_n = 0 then 'success' else 'error' end,
            (v_checks->'integrity') - 'Z6' - 'Z6_detail', extract(epoch from clock_timestamp() - v_started)),
           ('tank_geometry_drift', v_started, clock_timestamp(), case when v_z6 = 0 then 'success' else 'error' end,
            jsonb_build_object('Z6', v_z6, 'per_sensor', v_checks->'integrity'->'Z6_detail'),
            extract(epoch from clock_timestamp() - v_started));
  end if;

  return jsonb_build_object('until', v_until, 'build', v_build, 'measure', v_measure, 'link', v_link,
                            'checks', v_checks, 'errors', v_errors);
end $function$
;

DO $drop$
DECLARE n int;
BEGIN
  IF to_regclass('public.visit_time_on_site_corrections') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.visit_time_on_site_corrections WHERE applied_at IS NOT NULL OR truck_applied_at IS NOT NULL' INTO n;
    IF n = 0 THEN
      DROP TABLE public.visit_time_on_site_corrections;
    ELSE
      RAISE NOTICE 'ledger kept: % rows were applied once (now rolled back)', n;
    END IF;
  END IF;
END $drop$;

DO $v$ BEGIN
  IF md5(pg_get_functiondef('public.fn_fill_time_on_site_from_stops(boolean)'::regprocedure)) <> '75229b6b827b570a3a86ab8f35ecf00f' THEN
    RAISE EXCEPTION 'VERIFY: % is not the pre-Stage 0 body (md5)', 'fn_fill_time_on_site_from_stops(boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_fill_blank_time_on_site(date,date,boolean)'::regprocedure)) <> '84b40a44075eb6bda67c219452e0c6e3' THEN
    RAISE EXCEPTION 'VERIFY: % is not the pre-Stage 0 body (md5)', 'fn_fill_blank_time_on_site(date,date,boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> '66918d8c099ffc744f602aa4ca0fc7e9' THEN
    RAISE EXCEPTION 'VERIFY: % is not the pre-Stage 0 body (md5)', 'fn_time_on_site_checks()'; END IF;
  IF md5(pg_get_functiondef('public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure)) <> 'a3e39f8f319cc3b146c6611cec30e308' THEN
    RAISE EXCEPTION 'VERIFY: % is not the pre-Stage 0 body (md5)', 'fn_refresh_stop_facts(bigint,timestamp with time zone)'; END IF;
  IF (public.fn_time_on_site_checks()) ?| ARRAY['T7', 'T8'] THEN RAISE EXCEPTION 'VERIFY: T7/T8 still reported'; END IF;
END $v$;

COMMIT;
