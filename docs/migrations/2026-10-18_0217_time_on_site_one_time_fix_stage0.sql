-- ============================================================================
-- 2026-10-18_0217 One-time 2026 duration fix, Stage 0: the ledger, blank fillers that keep a reviewed blank,
--                 and drift checks T7 and T8 that reach the health email
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-18: "design a plan ... on what needs to be done, so the durations we currently have in our DB is as
--   precise as possible, this is a one time fix". The plan (local, outside the repos because it names clients) is
--   samsara-checks/duration_fix_plan_2026-10-18/PLAN.md; this file is its section 7.4. Stage 0 writes no visit value.
--   It is the code that has to be in place before any value is written: somewhere to record each correction, fillers
--   that cannot undo a reviewed blank overnight, and alarms that ring if a corrected value moves afterwards.
-- WHAT CHANGES
--   1. NEW public.visit_time_on_site_corrections, the ledger: one current row per visit (unique on visit_id where superseded_at is null)
--      with the old and new time (arrival, departure, minutes, source) and truck, the stage, action and status, the
--      method (the rule that produced the value), the error classes, the confidence tier, the decision reference, the
--      group of a shared parking or of summed loads, the evidence and the alternatives as jsonb, and the lineage
--      timestamps. Codes, ids, numbers, hashes and timestamps only (CHECKs on every text column): no street, name or
--      note. The full evidence file stays in the local run folder, tied by evidence_file_sha256.
--      No foreign key to public.visits on purpose: it would hold SHARE ROW EXCLUSIVE on public.visits (blocking every
--      visit write) for as long as the creating transaction runs. Visits are soft-deleted only, and T8 counts a ledger
--      row whose visit is missing.
--   2. public.fn_fill_time_on_site_from_stops (03:20 nightly, any date) and public.fn_fill_blank_time_on_site (same
--      cron, 10-day window): a blank is filled only while its time_on_site_source is NULL. Before this a
--      'reviewed_blank' visit (all four columns NULL on purpose) was refilled by the next nightly run as soon as a stop
--      or a GPS cluster appeared for it. A blank the reopen trigger cleared has source NULL and is still filled. The
--      stale "split when several visits share it" in the stop filler's change reason now says the whole stop counts
--      for each (Fred, 2026-10-15 decision 3).
--   3. public.fn_time_on_site_checks gains:
--      T7 a visit the fix applied (keep_verified included) whose four time columns differ from the ledger's new value;
--      T8 a visit the fix applied (time or truck) whose truck, visit_date or completed_at differ from the ledger, or
--         that is now deleted, not completed or missing.
--      T1 to T6 are byte-identical. T_detail lists the T7 and T8 visit ids (never counted).
--   4. public.fn_refresh_stop_facts (cron 141, hourly :35) counts 'T7' and 'T8' in stop_facts_integrity. It counts a
--      fixed key list, so without them the two checks would sit in the jsonb and the row would stay 'success': the
--      false all-clear the checks exist to prevent. Nothing else in it changes. log_jobber_sync_health already watches
--      stop_facts_integrity (two failed runs in 24 hours make a sync_failed item in the health email).
-- WHAT DOES NOT CHANGE
--   No visit row. Not the nightly recheck, the source CHECK, the linker, the reopen trigger, fn_compute_time_on_site,
--   fn_stop_facts_checks or the health email's source list.
-- HOW THE BODIES WERE CHANGED
--   Copied from the live pg_get_functiondef read 2026-10-18 01:59 ET (begin read only), never retyped; each
--   edit an anchored replace asserted to match an exact number of times (samsara-checks/duration_fix_run_2026-10-18/
--   stage0/build_stage0.mjs, local). The diff adds only the predicate, the two checks, the key and comments.
--     fn_fill_time_on_site_from_stops(boolean)                 75229b6b827b570a3a86ab8f35ecf00f -> acaaf87971f7ca4536f96c6772acc170
--     fn_fill_blank_time_on_site(date,date,boolean)            84b40a44075eb6bda67c219452e0c6e3 -> b1d8cea3a5f2fc01c62b2a2d1fccbe5d
--     fn_time_on_site_checks()                                 66918d8c099ffc744f602aa4ca0fc7e9 -> bd9ee5c6a27a21271750d76f3cab3c9c
--     fn_refresh_stop_facts(bigint,timestamp with time zone)   a3e39f8f319cc3b146c6611cec30e308 -> a1d91a0a28604c25852429d697c1622f
--   The PIN refuses to run if a live body differs from the copy (re-copy it, never force it).
-- REHEARSAL (one transaction forced to roll back by a raised exception; stage0/rehearsal/*.out.json, local)
--   A reviewed_blank visit with a completion stop and a GPS cluster is NOT filled by either new filler; the same visit
--   as a NULL-source blank IS filled by both (positive control); the old bodies, kept under temporary names, DO fill the
--   reviewed_blank one (the control that gives the test meaning); the gps_150m_cluster branch still upgrades to the stop.
--   T7 reads 1 on a drift fixture and 0 without it, T8 the same on a moved completed_at and on a missing visit;
--   fn_refresh_stop_facts() called as cron 141 calls it writes stop_facts_integrity 'error' with T7 = 1 (T8 = 1), the
--   old body under a temporary name writes 'success' on the same fixture, and log_jobber_sync_health() then raises
--   sync_failed:stop_facts_integrity; a clean fixture leaves 'success'. T1 to T6 read the same before and after.
--   The rollback file restores the four old md5s and drops the empty ledger, refuses while a ledger row is applied,
--   and refuses on bodies that are not Stage 0's.
-- LOCKS
--   lock_timeout 3s (the 2-hourly backup holds ACCESS SHARE). CREATE TABLE and CREATE OR REPLACE FUNCTION lock no
--   business table. Apply between 10:00 and 18:00 ET on a weekday, not :30 to :45 past the hour (cron 141 at :35).
-- ROLLBACK: docs/migrations/2026-10-18_rollback_time_on_site_one_time_fix_stage0.sql
-- AUDIT (rule 8): the ledger OPTS IN (audit_visit_time_on_site_corrections), so every status change has its own row in
--   audit.logs. Access: service_role only (SELECT, INSERT, UPDATE; rows are superseded, never deleted), RLS on with
--   no policy, revoked by name from anon and authenticated (Supabase's default privileges grant both), sequence too.
--   3NF: every column depends on the visit's correction in one run.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

-- 0. PIN: the live bodies are the ones copied, and the ledger does not exist yet.
DO $pin$ BEGIN
  IF md5(pg_get_functiondef('public.fn_fill_time_on_site_from_stops(boolean)'::regprocedure)) <> '75229b6b827b570a3a86ab8f35ecf00f' THEN
    RAISE EXCEPTION '% changed since it was copied for Stage 0: re-copy the live body', 'fn_fill_time_on_site_from_stops(boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_fill_blank_time_on_site(date,date,boolean)'::regprocedure)) <> '84b40a44075eb6bda67c219452e0c6e3' THEN
    RAISE EXCEPTION '% changed since it was copied for Stage 0: re-copy the live body', 'fn_fill_blank_time_on_site(date,date,boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> '66918d8c099ffc744f602aa4ca0fc7e9' THEN
    RAISE EXCEPTION '% changed since it was copied for Stage 0: re-copy the live body', 'fn_time_on_site_checks()'; END IF;
  IF md5(pg_get_functiondef('public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure)) <> 'a3e39f8f319cc3b146c6611cec30e308' THEN
    RAISE EXCEPTION '% changed since it was copied for Stage 0: re-copy the live body', 'fn_refresh_stop_facts(bigint,timestamp with time zone)'; END IF;
  IF to_regclass('public.visit_time_on_site_corrections') IS NOT NULL THEN
    RAISE EXCEPTION 'public.visit_time_on_site_corrections already exists'; END IF;
END $pin$;

-- 1. The ledger.
CREATE TABLE public.visit_time_on_site_corrections (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  visit_id              bigint NOT NULL,
  run_id                text NOT NULL CHECK (run_id ~ '^[a-z0-9][a-z0-9-]{0,62}$'),
  param_version         text NOT NULL CHECK (param_version ~ '^[A-Za-z0-9._:-]{1,64}$'),
  input_hashes          jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(input_hashes) = 'object'),
  -- the truck part (Stage 1)
  old_vehicle_id        bigint,
  new_vehicle_id        bigint,
  truck_stage           text CHECK (truck_stage = '1'),
  truck_status          text CHECK (truck_status IN ('proposed', 'approved', 'applied', 'skipped_guard', 'rolled_back', 'rejected', 'deferred')),
  truck_applied_at      timestamptz,
  -- the time part (Stages 2 to 4, and the catch-up pass of visits dated 10-08 to 10-17)
  stage                 text NOT NULL CHECK (stage IN ('2', '3', '4', 'catch_up')),
  action                text NOT NULL CHECK (action IN ('change', 'relabel', 'blank', 'keep_verified', 'lock_decided')),
  status                text NOT NULL DEFAULT 'proposed'
                        CHECK (status IN ('proposed', 'approved', 'applied', 'skipped_guard', 'rolled_back', 'rejected', 'deferred')),
  superseded_at         timestamptz,
  -- what the dry run saw (the snapshot guard, T8 and the rollback read these)
  old_arrival           timestamptz,
  old_departure         timestamptz,
  old_minutes           integer,
  old_source            text CHECK (old_source ~ '^[a-z0-9_]{1,40}$'),
  old_visit_date        date NOT NULL,
  old_completed_at      timestamptz,
  bonus_decided_at_seen timestamptz,
  -- the value written
  new_arrival           timestamptz,
  new_departure         timestamptz,
  new_minutes           integer,
  new_source            text CHECK (new_source ~ '^[a-z0-9_]{1,40}$'),
  -- why
  method                text NOT NULL CHECK (method ~ '^[a-z_]{2,40}(:[a-z_]{2,20})?$'),
  confidence            text CHECK (confidence IN ('high', 'shared', 'medium', 'low', 'person')),
  error_classes         text[] NOT NULL DEFAULT '{}' CHECK (array_to_string(error_classes, ',') ~ '^(E[0-9]{1,2}(,E[0-9]{1,2})*)?$'),
  decision_ref          text CHECK (decision_ref ~ '^[A-Za-z0-9:_.-]{1,64}$'),
  shared_group_id       text CHECK (shared_group_id ~ '^[A-Za-z0-9:_.-]{1,64}$'),
  group_size            integer CHECK (group_size >= 1),
  group_total_minutes   integer CHECK (group_total_minutes >= 0),
  activity_minutes      numeric CHECK (activity_minutes >= 0),
  alternatives          jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(alternatives) = 'array'),
  evidence              jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(evidence) = 'object'),
  evidence_file_sha256  text CHECK (evidence_file_sha256 ~ '^[0-9a-f]{64}$'),
  -- lineage
  created_at            timestamptz NOT NULL DEFAULT now(),
  reviewed_at           timestamptz,
  applied_at            timestamptz,
  applied_by_migration  text CHECK (applied_by_migration ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[A-Za-z0-9_.-]{1,120}$'),
  rolled_back_at        timestamptz,
  CONSTRAINT visit_tos_corr_new_all_or_none CHECK (num_nulls(new_arrival, new_departure, new_minutes) IN (0, 3)),
  CONSTRAINT visit_tos_corr_new_span CHECK (new_departure > new_arrival AND new_minutes >= 0),
  CONSTRAINT visit_tos_corr_reviewed_blank_empty CHECK (new_source IS DISTINCT FROM 'reviewed_blank' OR new_minutes IS NULL),
  CONSTRAINT visit_tos_corr_truck_kept CHECK (truck_stage IS NOT NULL OR new_vehicle_id IS NOT DISTINCT FROM old_vehicle_id),
  CONSTRAINT visit_tos_corr_truck_part CHECK ((truck_stage IS NULL) = (truck_status IS NULL)),
  CONSTRAINT visit_tos_corr_applied_at CHECK (status <> 'applied' OR applied_at IS NOT NULL),
  CONSTRAINT visit_tos_corr_truck_applied_at CHECK (truck_status IS DISTINCT FROM 'applied' OR truck_applied_at IS NOT NULL),
  CONSTRAINT visit_tos_corr_group CHECK ((shared_group_id IS NULL) = (group_size IS NULL))
);
CREATE UNIQUE INDEX visit_time_on_site_corrections_current_uq ON public.visit_time_on_site_corrections (visit_id) WHERE superseded_at IS NULL;
COMMENT ON TABLE public.visit_time_on_site_corrections IS
  'One-time 2026 duration fix (2026-10-18), reused by the later time-on-site capture: one current row per visit (superseded_at null) with the old and new time and truck, the stage, status, method, confidence, decision and evidence. Codes and numbers only; the evidence file stays local (evidence_file_sha256). fn_time_on_site_checks T7 and T8 compare applied rows with the live visit. service_role only.';
COMMENT ON COLUMN public.visit_time_on_site_corrections.new_vehicle_id IS 'Equals old_vehicle_id when the truck does not change (CHECK visit_tos_corr_truck_kept); the stage snapshot guard and T8 compare the live truck with it.';
COMMENT ON COLUMN public.visit_time_on_site_corrections.method IS 'The rule that produced the value: single, reparks_joined, loads_summed, errand_parts, two_parkings_split, shared_split:<timer|stamps|pto|rpm|move>, shared_whole, short_stop, went_once, other_day, no_stay, no_data, no_samsara_presence, kept_by_decision. loads_summed and errand_parts are the rows whose minutes are not departure minus arrival.';
COMMENT ON COLUMN public.visit_time_on_site_corrections.shared_group_id IS 'Ties the visits of one shared parking (or the parts of one summed load) so a total counts the time once; group_size and group_total_minutes beside it.';
ALTER TABLE public.visit_time_on_site_corrections ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.visit_time_on_site_corrections FROM public, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON public.visit_time_on_site_corrections TO service_role;
DO $seq$ BEGIN
  EXECUTE format('REVOKE ALL ON SEQUENCE %s FROM public, anon, authenticated', pg_get_serial_sequence('public.visit_time_on_site_corrections', 'id'));
END $seq$;
CREATE TRIGGER audit_visit_time_on_site_corrections AFTER INSERT OR UPDATE OR DELETE ON public.visit_time_on_site_corrections
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- 2. The stop filler: a blank is filled only while its source is NULL.
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
     -- 2026-10-18 (one-time 2026 duration fix, Stage 0): a blank is filled only while its source is NULL, so a
     -- reviewed_blank (a person found nothing to measure) stays blank; a blank the reopen trigger cleared is still filled.
     and ((v.duration_minutes is null and v.time_on_site_source is null)
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
           'x-change-reason', 'Time on site copied from the truck stop that holds the completion time (with the truck''s earlier stops there; a stop several visits share counts in full for each), or from the dump site visit.'))::text, true);
    update public.visits v
       set actual_arrival_at = f.arrival, actual_departure_at = f.departure,
           duration_minutes  = round(extract(epoch from f.departure - f.arrival) / 60)::integer,
           time_on_site_source = case when f.basis = 'completion' then 'stop_at_completion' else 'dump_site_dwell' end
      from _fill_stops f
     where v.id = f.visit_id
       and v.visit_status = 'completed' and v.deleted_at is null
       and ((v.duration_minutes is null and v.time_on_site_source is null)
            or (v.time_on_site_source = 'gps_150m_cluster'
                and v.visit_date >= (now() at time zone 'America/New_York')::date - 10));
    get diagnostics v_filled = row_count;
    perform set_config('request.headers', coalesce(v_hdr, ''), true);
  end if;

  return query select v_cand, v_filled;
end
$function$
;

-- 3. The any-truck GPS filler: the same at its three blank tests.
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
       and v.time_on_site_source is null   -- 2026-10-18 Stage 0: a reviewed_blank stays blank
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
     and v.duration_minutes is null and v.time_on_site_source is null and not public.fn_is_non_customer(v.client_id);

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
     where v.id = f.visit_id and v.duration_minutes is null and v.time_on_site_source is null
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

-- 4. The checks: T7 and T8.
CREATE OR REPLACE FUNCTION public.fn_time_on_site_checks()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-14_1110 (time on site plan step 8): the checks that keep the time on site honest. Each must read 0; they ride
-- in fn_stop_facts_checks' integrity set, so fn_refresh_stop_facts (hourly) writes stop_facts_integrity as error when one
-- is not, and log_jobber_sync_health raises it to the health email. T_detail names the visits (never counted).
-- 2026-10-18 (one-time 2026 duration fix, Stage 0): T7 and T8 watch the visits the fix applied, from its ledger
-- public.visit_time_on_site_corrections; fn_refresh_stop_facts counts both keys.
DECLARE
  v_today date := (now() at time zone 'America/New_York')::date;
  v_since timestamptz := greatest(now() - interval '24 hours', timestamptz '2026-10-14 02:00+00');   -- writers labelled from step 2
  t1 bigint[]; t3 bigint[]; t4 bigint[]; t5 bigint[]; t6 bigint[]; t2 int; g jsonb;
  t7 bigint[]; t8 bigint[];
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
  -- T7 a visit the fix applied (keep_verified included) whose four time columns no longer equal the ledger's new
  --    value: a writer moved a corrected value (or filled a blank the fix left NULL). Re-apply or find the writer.
  SELECT array_agg(l.visit_id ORDER BY l.visit_id) INTO t7
    FROM public.visit_time_on_site_corrections l LEFT JOIN public.visits v ON v.id = l.visit_id
   WHERE l.status = 'applied' AND l.superseded_at IS NULL
     AND (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source)
         IS DISTINCT FROM (l.new_minutes, l.new_arrival, l.new_departure, l.new_source);
  -- T8 a visit the fix applied (its time or its truck) that moved under it: another truck, date or completion time
  --    than the ledger holds, or now deleted, not completed or gone. Its saved value may be stale: re-measure it.
  SELECT array_agg(l.visit_id ORDER BY l.visit_id) INTO t8
    FROM public.visit_time_on_site_corrections l LEFT JOIN public.visits v ON v.id = l.visit_id
   WHERE l.superseded_at IS NULL AND (l.status = 'applied' OR l.truck_status = 'applied')
     AND (v.id IS NULL OR v.deleted_at IS NOT NULL OR v.visit_status IS DISTINCT FROM 'completed'
          OR v.vehicle_id IS DISTINCT FROM l.new_vehicle_id
          OR v.visit_date IS DISTINCT FROM l.old_visit_date
          OR v.completed_at IS DISTINCT FROM l.old_completed_at);
  RETURN jsonb_build_object('T1', coalesce(cardinality(t1), 0), 'T2', t2, 'T3', coalesce(cardinality(t3), 0),
    'T4', coalesce(cardinality(t4), 0), 'T5', coalesce(cardinality(t5), 0), 'T6', coalesce(cardinality(t6), 0),
    'T7', coalesce(cardinality(t7), 0), 'T8', coalesce(cardinality(t8), 0),
    'T_detail', jsonb_build_object('T1', t1, 'T3', t3, 'T4', t4, 'T5', t5, 'T6', t6, 'T7', t7, 'T8', t8));
END $function$
;

-- 5. The hourly builder counts T7 and T8.
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
     -- 2026-10-18 Stage 0: T7 and T8 (the one-time duration fix's drift checks) counted too; a key missing here never errors
     where x.key in ('Z1','Z2','Z3','Z4','Z7','Z8','Z9','T1','T2','T3','T4','T5','T6','T7','T8') and (x.value)::text::int > 0;
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

-- 6. VERIFY (cheap; each raises).
DO $v$
DECLARE ck jsonb; k text; n int;
BEGIN
  IF md5(pg_get_functiondef('public.fn_fill_time_on_site_from_stops(boolean)'::regprocedure)) <> 'acaaf87971f7ca4536f96c6772acc170' THEN
    RAISE EXCEPTION 'VERIFY: % is not the edited copy (md5)', 'fn_fill_time_on_site_from_stops(boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_fill_blank_time_on_site(date,date,boolean)'::regprocedure)) <> 'b1d8cea3a5f2fc01c62b2a2d1fccbe5d' THEN
    RAISE EXCEPTION 'VERIFY: % is not the edited copy (md5)', 'fn_fill_blank_time_on_site(date,date,boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> 'bd9ee5c6a27a21271750d76f3cab3c9c' THEN
    RAISE EXCEPTION 'VERIFY: % is not the edited copy (md5)', 'fn_time_on_site_checks()'; END IF;
  IF md5(pg_get_functiondef('public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure)) <> 'a1d91a0a28604c25852429d697c1622f' THEN
    RAISE EXCEPTION 'VERIFY: % is not the edited copy (md5)', 'fn_refresh_stop_facts(bigint,timestamp with time zone)'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_fill_time_on_site_from_stops(boolean)'::regprocedure) IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN
    RAISE EXCEPTION 'VERIFY: the grants on fn_fill_time_on_site_from_stops(boolean) changed'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_fill_blank_time_on_site(date,date,boolean)'::regprocedure) IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN
    RAISE EXCEPTION 'VERIFY: the grants on fn_fill_blank_time_on_site(date,date,boolean) changed'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_time_on_site_checks()'::regprocedure) IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN
    RAISE EXCEPTION 'VERIFY: the grants on fn_time_on_site_checks() changed'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure) IS DISTINCT FROM '{postgres=X/postgres}' THEN
    RAISE EXCEPTION 'VERIFY: the grants on fn_refresh_stop_facts(bigint,timestamp with time zone) changed'; END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.visit_time_on_site_corrections'::regclass) THEN RAISE EXCEPTION 'VERIFY: RLS off'; END IF;
  IF EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.visit_time_on_site_corrections'::regclass) THEN RAISE EXCEPTION 'VERIFY: a policy exists'; END IF;
  IF has_table_privilege('anon', 'public.visit_time_on_site_corrections', 'SELECT') OR has_table_privilege('anon', 'public.visit_time_on_site_corrections', 'INSERT')
     OR has_table_privilege('anon', 'public.visit_time_on_site_corrections', 'UPDATE') OR has_table_privilege('anon', 'public.visit_time_on_site_corrections', 'DELETE')
     OR has_table_privilege('authenticated', 'public.visit_time_on_site_corrections', 'SELECT') OR has_table_privilege('authenticated', 'public.visit_time_on_site_corrections', 'INSERT')
     OR has_table_privilege('authenticated', 'public.visit_time_on_site_corrections', 'UPDATE') OR has_table_privilege('authenticated', 'public.visit_time_on_site_corrections', 'DELETE')
     OR has_table_privilege('service_role', 'public.visit_time_on_site_corrections', 'DELETE') OR NOT has_table_privilege('service_role', 'public.visit_time_on_site_corrections', 'INSERT') THEN
    RAISE EXCEPTION 'VERIFY: the ledger grants are not service_role only'; END IF;
  IF has_sequence_privilege('anon', pg_get_serial_sequence('public.visit_time_on_site_corrections', 'id'), 'USAGE')
     OR has_sequence_privilege('authenticated', pg_get_serial_sequence('public.visit_time_on_site_corrections', 'id'), 'USAGE')
     OR has_sequence_privilege('anon', pg_get_serial_sequence('public.visit_time_on_site_corrections', 'id'), 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY: anon or authenticated hold the ledger sequence'; END IF;
  -- relacl read back after the fact (CREATE TABLE hands out grants a REVOKE list can miss): no anon or authenticated entry
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'public.visit_time_on_site_corrections'::regclass) ~ '(anon|authenticated)='
     OR (SELECT relacl::text FROM pg_class WHERE oid = pg_get_serial_sequence('public.visit_time_on_site_corrections', 'id')::regclass) ~ '(anon|authenticated)=' THEN
    RAISE EXCEPTION 'VERIFY: relacl still names anon or authenticated'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.visit_time_on_site_corrections'::regclass AND tgname = 'audit_visit_time_on_site_corrections'
                   AND tgfoid = 'audit.log_change()'::regprocedure AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'VERIFY: the audit trigger is missing'; END IF;
  -- the new bodies run (PL/pgSQL is only parsed at creation): both fillers in dry-run mode, the checks for real
  PERFORM public.fn_fill_time_on_site_from_stops(false);
  PERFORM public.fn_fill_blank_time_on_site((now() AT TIME ZONE 'America/New_York')::date - 10,
                                            (now() AT TIME ZONE 'America/New_York')::date + 1, false);
  ck := public.fn_time_on_site_checks();
  FOREACH k IN ARRAY ARRAY['T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8'] LOOP
    IF NOT ck ? k THEN RAISE EXCEPTION 'VERIFY: fn_time_on_site_checks has no %', k; END IF;
  END LOOP;
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY: T7 or T8 not 0 on an empty ledger: %', ck; END IF;
END $v$;

COMMIT;
