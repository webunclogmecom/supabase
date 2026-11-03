-- ============================================================================
-- 2026-11-03_1500_time_on_site_s3b_overrides_stages_viktor  Visit duration re-check, stage S3b part 1 (live today)
-- ============================================================================
-- THE ASK
--   Trello vpF5PLQj. Fred, 2026-11-03: "go ahead with S3b now", then (AskUserQuestion) "Build today, deploy Thu": the
--   new nightly code (edge function v15, its read and save functions, the close-out) is deployed on Thu 11-05 after a
--   clean night; the parts that stand on their own go live today. Spec: docs/specs/2026-11-02-time-on-site-nightly-rule.md
--   section 7; plan section 5.2 (Objects), 5.5 b (stage CHECK) and 5.1 RC6 / RC8 (Viktor's door).
-- WHAT CHANGES
--   1. New table public.time_on_site_site_overrides: Fred's Q8 measuring overrides of 2026-10-18 as data (they were a
--      local file read only by the 10-18 instruments). One row per property; a spot is the id of a stored GPS fix, never
--      coordinates (this repo is public). Read only by the v15 nightly's read function (Thu). RLS on, no policy, no grant
--      to anon or authenticated, SELECT to service_role; audited (Fred's decisions).
--        property 983   spot = stored fix 1463838 (map point about 340 m off; proof visit 7741)
--        property 132   extra Place 4000001823124 (served from inside a neighbouring client's Place; proof visit 1516)
--        property 210   spot = stored fix 558840, and its own linked Place 322485303 named so the "moved" rule keeps it
--                       (map point 13.4 km off; proof visit 1286)
--        property 666   Place unlinked (its link pointed at another client's Place; proof visit 1797)
--        property 7     Place 4000001996004 instead of the linked one (its link pointed at another client's; visit 7810)
--   2. The ledger's stage CHECK gains 'nightly' (the v15 close-out's rows) and 'person' (the Monday loop's superseding
--      rows). Measured first: no function or view filters the ledger on stage or method (readers: fn_time_on_site_checks
--      and log_truck_gps_health, by status only), so the widening switches nothing on.
--   3. viktor_set_visit_truck (anchored edit of the live body, md5 a07204ef5ad74e0f8d397f2ee1989fdd -> c7cbae66a7d33503688138224cc96feb):
--      - RC6: it no longer calls fn_fill_blank_time_on_site. Right after a person names the truck, another truck's time
--        is the wrong answer by definition; the named truck is still measured (stop fill and 150 m measure).
--      - RC8: its reply says what happened. A locked time (Fred, Q-E; since S3a it is never re-measured): "Time on site
--        stays N min: it is a settled value, so a truck change does not re-measure it." A visit of the last 10 days adds
--        "The nightly Samsara check can still correct it." Before, a locked visit's kept value read as a fresh measure.
-- WHAT DOES NOT CHANGE
--   No visit is written. The nightly (v14) and every other writer are untouched; nothing reads the new table until v15.
-- VERIFY: the table's RLS, grants (anon / authenticated: nothing), audit trigger and its 5 rows (each spot fix exists and
--   is the named truck's at the named time; 210's named Place is its current link); the stage CHECK allows the two new
--   stages and every existing row; Viktor's body has its new md5, holds the lock call and no any-truck fill; no visit
--   written; T1 to T8 not newly failing.
-- REHEARSED: S3b/rehearse1.mjs (local; every run rolled back): (a) as written; (c) the Viktor PIN altered raises; the
--   rollback on top restores Viktor's md5 and the CHECK and drops the table; Viktor's real path as service_role on a
--   locked visit, an unlocked visit of the last 10 days and an older unlocked one (the three replies).
-- LOCKS: lock_timeout 3s (the ledger ALTER takes a short exclusive lock). Apply 11:15 to 17:30 ET, clear of :05 to :10,
--   :15 to :20, :30 to :45.
-- ROLLBACK: docs/migrations/2026-11-03_rollback_time_on_site_s3b_overrides_stages_viktor.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF to_regclass('public.time_on_site_site_overrides') IS NOT NULL THEN RAISE EXCEPTION 'S3b: the overrides table already exists'; END IF;
  IF to_regprocedure('public.fn_time_on_site_is_locked(bigint)') IS NULL THEN RAISE EXCEPTION 'S3b: S3a is not applied (no lock function)'; END IF;
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'public.visit_time_on_site_corrections'::regclass
       AND conname = 'visit_time_on_site_corrections_stage_check')
     <> $c$CHECK ((stage = ANY (ARRAY['2'::text, '3'::text, '4'::text, 'catch_up'::text])))$c$ THEN
    RAISE EXCEPTION 'S3b: the ledger stage CHECK is not the expected one'; END IF;
END $pin$;
CREATE TEMP TABLE _s3b_ctx ON COMMIT DROP AS SELECT public.fn_time_on_site_checks() AS checks0, (SELECT max(id) FROM audit.logs) AS audit_id0;

-- 1. The overrides table
CREATE TABLE public.time_on_site_site_overrides (
  property_id     bigint PRIMARY KEY REFERENCES public.properties(id),
  spot_fix_id     bigint REFERENCES public.vehicle_telemetry_readings(id),
  place_id        text CHECK (place_id ~ '^[0-9]{1,20}$'),
  place_unlink    boolean NOT NULL DEFAULT false,
  extra_place_id  text CHECK (extra_place_id ~ '^[0-9]{1,20}$'),
  proof_visit_id  bigint REFERENCES public.visits(id),
  decision_ref    text NOT NULL CHECK (decision_ref ~ '^[A-Za-z0-9:_.-]{1,64}$'),
  reason          text NOT NULL CHECK (length(reason) BETWEEN 10 AND 500),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT time_on_site_site_overrides_something CHECK (spot_fix_id IS NOT NULL OR place_id IS NOT NULL OR place_unlink OR extra_place_id IS NOT NULL),
  CONSTRAINT time_on_site_site_overrides_unlink_alone CHECK (NOT (place_unlink AND place_id IS NOT NULL))
);
COMMENT ON TABLE public.time_on_site_site_overrides IS
  'Fred''s measuring overrides for time on site (Q8, 2026-10-18), read by the v15 nightly rule: a spot (a stored GPS fix id, never coordinates) replaces the map point; place_id replaces the linked Samsara Place (or names it so a "moved" verdict does not drop it); place_unlink drops a wrong link; extra_place_id adds a Place the property is served from. public.properties is never edited for this. Spec docs/specs/2026-11-02-time-on-site-nightly-rule.md.';
ALTER TABLE public.time_on_site_site_overrides ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.time_on_site_site_overrides FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.time_on_site_site_overrides TO service_role;
CREATE TRIGGER audit_time_on_site_site_overrides AFTER INSERT OR UPDATE OR DELETE ON public.time_on_site_site_overrides
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

DO $ins$
DECLARE v_hdr text := current_setting('request.headers', true);
BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-recheck-2026',
         'x-change-reason', 'Visit duration re-check S3b: Fred''s Q8 measuring overrides of 2026-10-18 loaded as data for the v15 nightly rule.'))::text, true);
  INSERT INTO public.time_on_site_site_overrides (property_id, spot_fix_id, place_id, place_unlink, extra_place_id, proof_visit_id, decision_ref, reason) VALUES
    (983, 1463838, NULL, false, NULL, 7741, 'fred:2026-10-18:q8', 'Map point about 340 m off: measured from where the truck parks at the client''s own address (the stored fix of the parking that proved it).'),
    (132, NULL, NULL, false, '4000001823124', 1516, 'fred:2026-10-18:q8', 'Served from inside a neighbouring client''s Samsara Place (the same spot on several visits); its own Place is 572 m off.'),
    (210, 558840, '322485303', false, NULL, 1286, 'fred:2026-10-18:q8', 'Map point 13.4 km off: measured from where the truck parks, inside the client''s own Place, which is named here so it stays used.'),
    (666, NULL, NULL, true, NULL, 1797, 'fred:2026-10-18:q8', 'Its Samsara link pointed at another client''s Place: unlinked, measured on its map point only.'),
    (7, NULL, '4000001996004', false, NULL, 7810, 'fred:2026-10-18:q8', 'Its Samsara link pointed at another client''s Place: relinked to its own Place, 71 m from the map point.');
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $ins$;

-- 2. The ledger's stage CHECK
ALTER TABLE public.visit_time_on_site_corrections DROP CONSTRAINT visit_time_on_site_corrections_stage_check;
ALTER TABLE public.visit_time_on_site_corrections ADD CONSTRAINT visit_time_on_site_corrections_stage_check
  CHECK (stage = ANY (ARRAY['2'::text, '3'::text, '4'::text, 'catch_up'::text, 'nightly'::text, 'person'::text]));

-- 3. Viktor's door
DO $vk$
DECLARE
  d text := pg_get_functiondef('public.viktor_set_visit_truck(bigint,text,text,text,boolean)'::regprocedure);
  n text;
  a1 text := $a$  perform public.fn_fill_blank_time_on_site(v.visit_date, v.visit_date + 1, true);
$a$;
  b1 text := $b$  -- 2026-11-03_1500 (re-check S3b, RC6): no any-truck fill here. Right after a person names the truck, another
  -- truck's time is the wrong answer by definition; fn_compute_time_on_site above measures the named truck.
$b$;
  a2 text := $a$      || case when v_after.duration_minutes is not null
              then format('Time on site: %s min (%s to %s).', v_after.duration_minutes,
                          to_char(v_after.actual_arrival_at at time zone 'America/New_York', 'FMHH12:MI AM'),
                          to_char(v_after.actual_departure_at at time zone 'America/New_York', 'FMHH12:MI AM'))
              else format('Time on site is still empty: %s''s GPS shows no stop near the property when the visit was marked complete, nor a stay within 150 m of it that day.', t.name) end);
$a$;
  b2 text := $b$      || case
           -- 2026-11-03_1500 (re-check S3b, RC8): say what really happened. A locked time (Fred, Q-E) is not re-measured
           -- by a truck change; a visit of the last 10 days can still be corrected by the nightly Samsara check.
           when public.fn_time_on_site_is_locked(v.id) and v_after.duration_minutes is not null
             then format('Time on site stays %s min: it is a settled value, so a truck change does not re-measure it.', v_after.duration_minutes)
           when public.fn_time_on_site_is_locked(v.id)
             then 'Time on site stays empty: it is a settled value, so a truck change does not re-measure it.'
           when v_after.duration_minutes is not null
             then format('Time on site: %s min (%s to %s).', v_after.duration_minutes,
                          to_char(v_after.actual_arrival_at at time zone 'America/New_York', 'FMHH12:MI AM'),
                          to_char(v_after.actual_departure_at at time zone 'America/New_York', 'FMHH12:MI AM'))
                  || case when v.visit_date >= (now() at time zone 'America/New_York')::date - 10
                          then ' The nightly Samsara check can still correct it.' else '' end
           else format('Time on site is still empty: %s''s GPS shows no stop near the property when the visit was marked complete, nor a stay within 150 m of it that day.', t.name)
                  || case when v.visit_date >= (now() at time zone 'America/New_York')::date - 10
                          then ' The nightly Samsara check looks again.' else '' end
         end);
$b$;
BEGIN
  IF md5(d) <> 'a07204ef5ad74e0f8d397f2ee1989fdd' THEN RAISE EXCEPTION 'S3b: viktor_set_visit_truck is not the expected body (md5 %)', md5(d); END IF;
  IF (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 THEN RAISE EXCEPTION 'S3b: viktor anchor 1 not found exactly once'; END IF;
  IF (length(d) - length(replace(d, a2, ''))) / length(a2) <> 1 THEN RAISE EXCEPTION 'S3b: viktor anchor 2 not found exactly once'; END IF;
  n := replace(replace(d, a1, b1), a2, b2);
  EXECUTE n;
  IF pg_get_functiondef('public.viktor_set_visit_truck(bigint,text,text,text,boolean)'::regprocedure) <> n THEN RAISE EXCEPTION 'S3b: viktor re-read differs'; END IF;
  IF md5(n) <> 'c7cbae66a7d33503688138224cc96feb' THEN RAISE EXCEPTION 'S3b: viktor edited md5 is %', md5(n); END IF;
END $vk$;


-- 4. VERIFY
DO $v$
DECLARE n int; ck jsonb; ck0 jsonb; t text;
BEGIN
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.time_on_site_site_overrides'::regclass) THEN RAISE EXCEPTION 'VERIFY S3b: RLS is off'; END IF;
  IF has_table_privilege('anon', 'public.time_on_site_site_overrides', 'SELECT') OR has_table_privilege('authenticated', 'public.time_on_site_site_overrides', 'SELECT')
     OR has_table_privilege('anon', 'public.time_on_site_site_overrides', 'INSERT') OR has_table_privilege('authenticated', 'public.time_on_site_site_overrides', 'INSERT')
     OR has_table_privilege('authenticated', 'public.time_on_site_site_overrides', 'UPDATE') OR has_table_privilege('authenticated', 'public.time_on_site_site_overrides', 'DELETE') THEN
    RAISE EXCEPTION 'VERIFY S3b: anon or authenticated holds a privilege on the overrides table'; END IF;
  IF NOT has_table_privilege('service_role', 'public.time_on_site_site_overrides', 'SELECT') OR has_table_privilege('service_role', 'public.time_on_site_site_overrides', 'INSERT') THEN
    RAISE EXCEPTION 'VERIFY S3b: service_role grants are not SELECT only'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.time_on_site_site_overrides'::regclass AND tgname = 'audit_time_on_site_site_overrides') THEN
    RAISE EXCEPTION 'VERIFY S3b: no audit trigger'; END IF;
  SELECT count(*) INTO n FROM public.time_on_site_site_overrides;
  IF n <> 5 THEN RAISE EXCEPTION 'VERIFY S3b: % override rows, expected 5', n; END IF;
  IF (SELECT count(*) FROM audit.logs a WHERE a.id > (SELECT audit_id0 FROM _s3b_ctx) AND a.txid = txid_current()
        AND a.table_name = 'time_on_site_site_overrides' AND a.app_source = 'time-on-site-recheck-2026') <> 5 THEN
    RAISE EXCEPTION 'VERIFY S3b: the 5 inserts are not audited and labelled'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.vehicle_telemetry_readings r WHERE r.id = 1463838 AND r.vehicle_id = 2
                   AND r.recorded_at BETWEEN timestamptz '2026-08-17 15:00 America/New_York' AND timestamptz '2026-08-17 15:06 America/New_York')
     OR NOT EXISTS (SELECT 1 FROM public.vehicle_telemetry_readings r WHERE r.id = 558840 AND r.vehicle_id = 3
                   AND r.recorded_at BETWEEN timestamptz '2026-01-16 00:46 America/New_York' AND timestamptz '2026-01-16 00:55 America/New_York') THEN
    RAISE EXCEPTION 'VERIFY S3b: a spot fix is not the named truck''s at the named time'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.entity_source_links e WHERE e.entity_type = 'property' AND e.entity_id = 210 AND e.source_system = 'samsara' AND e.source_id = '322485303') THEN
    RAISE EXCEPTION 'VERIFY S3b: 322485303 is no longer property 210''s linked Place'; END IF;
  IF position('''nightly''' in (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'public.visit_time_on_site_corrections'::regclass AND conname = 'visit_time_on_site_corrections_stage_check')) = 0
     OR position('''person''' in (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'public.visit_time_on_site_corrections'::regclass AND conname = 'visit_time_on_site_corrections_stage_check')) = 0 THEN
    RAISE EXCEPTION 'VERIFY S3b: the stage CHECK does not allow nightly and person'; END IF;
  IF md5(pg_get_functiondef('public.viktor_set_visit_truck(bigint,text,text,text,boolean)'::regprocedure)) <> 'c7cbae66a7d33503688138224cc96feb'
     OR position('fn_fill_blank_time_on_site(' in pg_get_functiondef('public.viktor_set_visit_truck(bigint,text,text,text,boolean)'::regprocedure)) > 0
     OR position('fn_time_on_site_is_locked(' in pg_get_functiondef('public.viktor_set_visit_truck(bigint,text,text,text,boolean)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'VERIFY S3b: viktor_set_visit_truck is not the edited body'; END IF;
  IF (SELECT count(*) FROM audit.logs a WHERE a.id > (SELECT audit_id0 FROM _s3b_ctx) AND a.txid = txid_current() AND a.table_name <> 'time_on_site_site_overrides') > 0 THEN
    RAISE EXCEPTION 'VERIFY S3b: something other than the overrides table was written'; END IF;
  ck0 := (SELECT checks0 FROM _s3b_ctx); ck := public.fn_time_on_site_checks();
  FOREACH t IN ARRAY ARRAY['T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8'] LOOP
    IF coalesce((ck->>t)::int, 0) > coalesce((ck0->>t)::int, 0) THEN RAISE EXCEPTION 'VERIFY S3b: % went from % to %', t, ck0->>t, ck->>t; END IF;
  END LOOP;
  RAISE NOTICE 'S3b part 1: overrides table (5 rows), stage CHECK widened, Viktor edited; checks %', ck - 'T_detail';
END $v$;

COMMIT;
