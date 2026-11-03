-- ============================================================================
-- 2026-11-03_1330_time_on_site_s3a_lock_in_writers  Visit duration re-check, stage S3a: the lock in every writer
-- ============================================================================
-- THE ASK
--   Trello vpF5PLQj. Fred, 2026-11-02, Q-E (a) and (i): "locked" means a reviewed label OR a current applied or proposed
--   row in public.visit_time_on_site_corrections, with one test in every writer, and the reopen trigger keeps a locked
--   value. On 2026-11-03: "go ahead with S3a now". Spec: docs/specs/2026-11-02-time-on-site-nightly-rule.md, sections 3
--   to 6 (this file is exactly that).
-- WHY
--   Until now a value was protected by its label, or by a date window: 899 completed visits are protected ONLY by a
--   ledger row (measured 11-03). Of those, 35 blanks could still be filled by the stop fill or the any-truck fill,
--   6270 (no label) could be rewritten by the 150 m measure, and 767 samsara_stay / 96 stop_at_completion values by
--   the nightly saves once a range run reaches them.
-- WHAT CHANGES
--   1. New public.fn_time_on_site_is_locked(bigint): source in (review, reviewed_blank, dump_site_dwell) OR a current
--      ledger row with status applied or proposed. SECURITY DEFINER, search_path '', STABLE; EXECUTE service_role only.
--   2. One clause, AND NOT public.fn_time_on_site_is_locked(v.id), anchored into (each anchor must occur exactly once;
--      the live body is pinned by md5 and the re-read must equal the edited text):
--        fn_fill_time_on_site_from_stops  where it picks its rows (_fill_stops) and in its UPDATE
--        fn_compute_time_on_site          its target CTE and its UPDATE
--        fn_fill_blank_time_on_site       its blank CTE and its UPDATE
--        fn_save_samsara_stay             its UPDATE (it then returns false, which the edge function counts as refused)
--        fn_save_samsara_stay_went_once   its UPDATE (the same)
--   3. fn_clear_time_on_site_on_reopen (the reopen trigger) clears the four time columns only when the visit is not
--      locked (Q-E part 2). A reopened locked visit keeps its value; T6 / T8 are red until it is completed again.
--      dump_site_dwell is part of "locked", so a reopened dump-site visit (9 today) now keeps its dwell.
--   md5 of each body, before -> after:
--   fn_fill_time_on_site_from_stops(boolean)  acaaf87971f7ca4536f96c6772acc170 -> 624d5e168bbc7745ad9af73ac1c03c41
--   fn_compute_time_on_site(date,date,boolean,integer,integer,integer)  9ed2ff46ec7ed92f13fe83093673f928 -> c1da67bc05399a3af1b81537c76487ef
--   fn_fill_blank_time_on_site(date,date,boolean)  b1d8cea3a5f2fc01c62b2a2d1fccbe5d -> 2c2f358c93aac5a89dd826142284e116
--   fn_save_samsara_stay(bigint,timestamp with time zone,timestamp with time zone,integer,text)  4f220a19decc75585753f7e1dad4a62a -> 305c7198a50e430c5f512f35e4d09ae4
--   fn_save_samsara_stay_went_once(bigint,timestamp with time zone,timestamp with time zone,integer,text)  2395825e3019c1910031552b8f9f3a56 -> 10c58990fa5851447121b40af69b96f3
--   fn_clear_time_on_site_on_reopen()  8cb07e2569923869e9da325fbfc3d868 -> c38d5a5ed8c5b9f1bfa99c3bf2321638
-- WHAT DOES NOT CHANGE
--   No visit is written (VERIFY: no audit row on public.visits in this transaction). No edge function is deployed: both
--   saves already return a boolean the nightly treats as refused when it is false. No view, no check function, no cron.
--   The fillers' return counts are discarded by every caller (cron 26 selects them; the reminder and
--   viktor_set_visit_truck PERFORM them). Viktor's reply text after a truck change is fixed in S3b (RC8), not here.
-- CONSEQUENCES (prediction register, S3a/PREDICT.md, local)
--   No visit changes, today or tonight: no visit with a ledger row is in the 10-day window (measured 0). Today's
--   cron 26 and the reminder's refresh write the same visits with and without the lock (rehearsed: 9054, unlocked, in
--   both). The stop-fill candidates stay 0. T1 to T8 stay 0. Tonight's 02:20 and 02:50 runs: counts in their usual
--   range, no refusal caused by the lock (none of their candidates is locked).
-- VERIFY: the predicate's privileges (anon and authenticated false, service_role true) and definer settings; it answers
--   true for a review visit, a visit locked only by an applied row, one locked only by a proposed row, a dump-site
--   visit, and false for an unlocked completed visit and a missing id; each of the six bodies has its new md5 and holds
--   the call; no visit written; T1 to T8 not newly failing, T7 = T8 = 0.
-- REHEARSED (S3a/rehearse.mjs, local; every run rolled back)
--   (a) as written: pass. (c) the reopen body's md5 altered: raises. The rollback alone: refuses; on top: the six
--   bodies back to their old md5s, the function gone. (R2) the three fillers, dry and executed as cron 26 and the
--   reminder call them, old bodies vs new: identical candidate sets and writes. (R3) the OLD body writes a locked
--   visit and the NEW one does not: stop fill, 150 m measure and any-truck fill on 6512, the save on 8588, the
--   went-once save on 8773 (true -> false). (R4) reopen as service_role: locked 8854 cleared -> kept, unlocked 9045
--   cleared both, review 8851 kept both. (R5) service_role runs the predicate; authenticated is refused 42501.
--   (R5b) viktor_set_visit_truck on 6512 as service_role: no error, truck changed, time kept, T8 names it.
-- LOCKS: lock_timeout 3s. Apply 11:15 to 17:30 ET, clear of :05 to :10, :15 to :20, :30 to :45 (PLAN G-9).
-- ROLLBACK: docs/migrations/2026-11-03_rollback_time_on_site_s3a_lock_in_writers.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

-- 0. PIN: no lock function yet (a second run refuses); the checks body is S1's. Each edit below pins its own body.
DO $pin$ BEGIN
  IF to_regprocedure('public.fn_time_on_site_is_locked(bigint)') IS NOT NULL THEN
    RAISE EXCEPTION 'S3a: public.fn_time_on_site_is_locked already exists (already applied?)'; END IF;
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> '11e4b8113c609737ea8edd5798faa833' THEN
    RAISE EXCEPTION 'S3a: fn_time_on_site_checks() is not the S1 body'; END IF;
END $pin$;
CREATE TEMP TABLE _s3a_ctx ON COMMIT DROP AS
SELECT public.fn_time_on_site_checks() AS checks0, (SELECT max(id) FROM audit.logs) AS audit_id0;

-- 1. The predicate (spec section 4)
CREATE FUNCTION public.fn_time_on_site_is_locked(p_visit_id bigint) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $f$
  SELECT EXISTS (SELECT 1 FROM public.visits v WHERE v.id = p_visit_id
                   AND v.time_on_site_source IN ('review', 'reviewed_blank', 'dump_site_dwell'))
      OR EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections c
                  WHERE c.visit_id = p_visit_id AND c.superseded_at IS NULL AND c.status IN ('applied', 'proposed'))
$f$;
COMMENT ON FUNCTION public.fn_time_on_site_is_locked(bigint) IS
  'Time on site lock (Fred, Q-E, 2026-11-02): a reviewed label (review, reviewed_blank, dump_site_dwell) OR a current applied or proposed row in public.visit_time_on_site_corrections. Every time-on-site writer and the reopen trigger call it. Spec docs/specs/2026-11-02-time-on-site-nightly-rule.md.';
REVOKE ALL ON FUNCTION public.fn_time_on_site_is_locked(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_time_on_site_is_locked(bigint) TO service_role;

-- 2. The six anchored edits (spec sections 4 and 5)
DO $s3a0$
DECLARE
  d text := pg_get_functiondef('public.fn_fill_time_on_site_from_stops(boolean)'::regprocedure);
  n text;
  a0 text := $a$   where v.visit_status = 'completed' and v.deleted_at is null and f.departure > f.arrival
$a$;
  b0 text := $b$   where v.visit_status = 'completed' and v.deleted_at is null and f.departure > f.arrival
     and not public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
$b$;
  a1 text := $a$     where v.id = f.visit_id
       and v.visit_status = 'completed' and v.deleted_at is null
$a$;
  b1 text := $b$     where v.id = f.visit_id
       and v.visit_status = 'completed' and v.deleted_at is null
       and not public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
$b$;
BEGIN
  IF md5(d) <> 'acaaf87971f7ca4536f96c6772acc170' THEN RAISE EXCEPTION 'S3a: fn_fill_time_on_site_from_stops is not the expected body (md5 %)', md5(d); END IF;
  IF (length(d) - length(replace(d, a0, ''))) / length(a0) <> 1 THEN RAISE EXCEPTION 'S3a: fn_fill_time_on_site_from_stops anchor 0 not found exactly once'; END IF;
  IF (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 THEN RAISE EXCEPTION 'S3a: fn_fill_time_on_site_from_stops anchor 1 not found exactly once'; END IF;
  n := replace(replace(d, a0, b0), a1, b1);
  EXECUTE n;
  IF pg_get_functiondef('public.fn_fill_time_on_site_from_stops(boolean)'::regprocedure) <> n THEN RAISE EXCEPTION 'S3a: fn_fill_time_on_site_from_stops re-read differs from the edited text'; END IF;
  IF md5(n) <> '624d5e168bbc7745ad9af73ac1c03c41' THEN RAISE EXCEPTION 'S3a: fn_fill_time_on_site_from_stops edited md5 is %', md5(n); END IF;
END $s3a0$;

DO $s3a1$
DECLARE
  d text := pg_get_functiondef('public.fn_compute_time_on_site(date,date,boolean,integer,integer,integer)'::regprocedure);
  n text;
  a0 text := $a$     where v.visit_status = 'completed'
       and v.deleted_at is null
       and v.visit_date >= p_from and v.visit_date < p_to
       and v.vehicle_id is not null
$a$;
  b0 text := $b$     where v.visit_status = 'completed'
       and v.deleted_at is null
       and v.visit_date >= p_from and v.visit_date < p_to
       and v.vehicle_id is not null
       and not public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
$b$;
  a1 text := $a$       and (v.time_on_site_source is null or v.time_on_site_source = 'gps_150m_cluster')
       and (v.actual_arrival_at   is distinct from r.arrival
$a$;
  b1 text := $b$       and (v.time_on_site_source is null or v.time_on_site_source = 'gps_150m_cluster')
       and not public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
       and (v.actual_arrival_at   is distinct from r.arrival
$b$;
BEGIN
  IF md5(d) <> '9ed2ff46ec7ed92f13fe83093673f928' THEN RAISE EXCEPTION 'S3a: fn_compute_time_on_site is not the expected body (md5 %)', md5(d); END IF;
  IF (length(d) - length(replace(d, a0, ''))) / length(a0) <> 1 THEN RAISE EXCEPTION 'S3a: fn_compute_time_on_site anchor 0 not found exactly once'; END IF;
  IF (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 THEN RAISE EXCEPTION 'S3a: fn_compute_time_on_site anchor 1 not found exactly once'; END IF;
  n := replace(replace(d, a0, b0), a1, b1);
  EXECUTE n;
  IF pg_get_functiondef('public.fn_compute_time_on_site(date,date,boolean,integer,integer,integer)'::regprocedure) <> n THEN RAISE EXCEPTION 'S3a: fn_compute_time_on_site re-read differs from the edited text'; END IF;
  IF md5(n) <> 'c1da67bc05399a3af1b81537c76487ef' THEN RAISE EXCEPTION 'S3a: fn_compute_time_on_site edited md5 is %', md5(n); END IF;
END $s3a1$;

DO $s3a2$
DECLARE
  d text := pg_get_functiondef('public.fn_fill_blank_time_on_site(date,date,boolean)'::regprocedure);
  n text;
  a0 text := $a$       and v.time_on_site_source is null   -- 2026-10-18 Stage 0: a reviewed_blank stays blank
$a$;
  b0 text := $b$       and v.time_on_site_source is null   -- 2026-10-18 Stage 0: a reviewed_blank stays blank
       and not public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
$b$;
  a1 text := $a$     where v.id = f.visit_id and v.duration_minutes is null and v.time_on_site_source is null
$a$;
  b1 text := $b$     where v.id = f.visit_id and v.duration_minutes is null and v.time_on_site_source is null
       and not public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
$b$;
BEGIN
  IF md5(d) <> 'b1d8cea3a5f2fc01c62b2a2d1fccbe5d' THEN RAISE EXCEPTION 'S3a: fn_fill_blank_time_on_site is not the expected body (md5 %)', md5(d); END IF;
  IF (length(d) - length(replace(d, a0, ''))) / length(a0) <> 1 THEN RAISE EXCEPTION 'S3a: fn_fill_blank_time_on_site anchor 0 not found exactly once'; END IF;
  IF (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 THEN RAISE EXCEPTION 'S3a: fn_fill_blank_time_on_site anchor 1 not found exactly once'; END IF;
  n := replace(replace(d, a0, b0), a1, b1);
  EXECUTE n;
  IF pg_get_functiondef('public.fn_fill_blank_time_on_site(date,date,boolean)'::regprocedure) <> n THEN RAISE EXCEPTION 'S3a: fn_fill_blank_time_on_site re-read differs from the edited text'; END IF;
  IF md5(n) <> '2c2f358c93aac5a89dd826142284e116' THEN RAISE EXCEPTION 'S3a: fn_fill_blank_time_on_site edited md5 is %', md5(n); END IF;
END $s3a2$;

DO $s3a3$
DECLARE
  d text := pg_get_functiondef('public.fn_save_samsara_stay(bigint,timestamp with time zone,timestamp with time zone,integer,text)'::regprocedure);
  n text;
  a0 text := $a$     AND coalesce(v.time_on_site_source, '') NOT IN ('review', 'reviewed_blank', 'dump_site_dwell')
$a$;
  b0 text := $b$     AND coalesce(v.time_on_site_source, '') NOT IN ('review', 'reviewed_blank', 'dump_site_dwell')
     AND NOT public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
$b$;
BEGIN
  IF md5(d) <> '4f220a19decc75585753f7e1dad4a62a' THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay is not the expected body (md5 %)', md5(d); END IF;
  IF (length(d) - length(replace(d, a0, ''))) / length(a0) <> 1 THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay anchor 0 not found exactly once'; END IF;
  n := replace(d, a0, b0);
  EXECUTE n;
  IF pg_get_functiondef('public.fn_save_samsara_stay(bigint,timestamp with time zone,timestamp with time zone,integer,text)'::regprocedure) <> n THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay re-read differs from the edited text'; END IF;
  IF md5(n) <> '305c7198a50e430c5f512f35e4d09ae4' THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay edited md5 is %', md5(n); END IF;
END $s3a3$;

DO $s3a4$
DECLARE
  d text := pg_get_functiondef('public.fn_save_samsara_stay_went_once(bigint,timestamp with time zone,timestamp with time zone,integer,text)'::regprocedure);
  n text;
  a0 text := $a$     AND coalesce(v.time_on_site_source, '') NOT IN ('review', 'reviewed_blank', 'dump_site_dwell')
$a$;
  b0 text := $b$     AND coalesce(v.time_on_site_source, '') NOT IN ('review', 'reviewed_blank', 'dump_site_dwell')
     AND NOT public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
$b$;
BEGIN
  IF md5(d) <> '2395825e3019c1910031552b8f9f3a56' THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay_went_once is not the expected body (md5 %)', md5(d); END IF;
  IF (length(d) - length(replace(d, a0, ''))) / length(a0) <> 1 THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay_went_once anchor 0 not found exactly once'; END IF;
  n := replace(d, a0, b0);
  EXECUTE n;
  IF pg_get_functiondef('public.fn_save_samsara_stay_went_once(bigint,timestamp with time zone,timestamp with time zone,integer,text)'::regprocedure) <> n THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay_went_once re-read differs from the edited text'; END IF;
  IF md5(n) <> '10c58990fa5851447121b40af69b96f3' THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay_went_once edited md5 is %', md5(n); END IF;
END $s3a4$;

DO $s3a5$
DECLARE
  d text := pg_get_functiondef('public.fn_clear_time_on_site_on_reopen()'::regprocedure);
  n text;
  a0 text := $a$  if coalesce(OLD.time_on_site_source, '') not in ('review', 'reviewed_blank')
$a$;
  b0 text := $b$  if coalesce(OLD.time_on_site_source, '') not in ('review', 'reviewed_blank')
     and not public.fn_time_on_site_is_locked(OLD.id)   -- 2026-11-03_1330 S3a: a locked value is kept (Fred, Q-E part 2)
$b$;
BEGIN
  IF md5(d) <> '8cb07e2569923869e9da325fbfc3d868' THEN RAISE EXCEPTION 'S3a: fn_clear_time_on_site_on_reopen is not the expected body (md5 %)', md5(d); END IF;
  IF (length(d) - length(replace(d, a0, ''))) / length(a0) <> 1 THEN RAISE EXCEPTION 'S3a: fn_clear_time_on_site_on_reopen anchor 0 not found exactly once'; END IF;
  n := replace(d, a0, b0);
  EXECUTE n;
  IF pg_get_functiondef('public.fn_clear_time_on_site_on_reopen()'::regprocedure) <> n THEN RAISE EXCEPTION 'S3a: fn_clear_time_on_site_on_reopen re-read differs from the edited text'; END IF;
  IF md5(n) <> 'c38d5a5ed8c5b9f1bfa99c3bf2321638' THEN RAISE EXCEPTION 'S3a: fn_clear_time_on_site_on_reopen edited md5 is %', md5(n); END IF;
END $s3a5$;


-- 3. VERIFY (each check raises, so a failure rolls the whole file back)
DO $v$
DECLARE ck jsonb; ck0 jsonb; t text; n int; bad text; v_id bigint;
BEGIN
  -- (a) privileges and definer settings
  IF has_function_privilege('anon', 'public.fn_time_on_site_is_locked(bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_time_on_site_is_locked(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY S3a: anon or authenticated can run fn_time_on_site_is_locked'; END IF;
  IF NOT has_function_privilege('service_role', 'public.fn_time_on_site_is_locked(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY S3a: service_role cannot run fn_time_on_site_is_locked'; END IF;
  IF NOT (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = 'public.fn_time_on_site_is_locked(bigint)'::regprocedure)
     OR position($q$SET search_path TO ''$q$ in pg_get_functiondef('public.fn_time_on_site_is_locked(bigint)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'VERIFY S3a: fn_time_on_site_is_locked is not SECURITY DEFINER with an empty search_path'; END IF;
  -- (b) the predicate's answers (each fixture must exist: a missing one is a failed instrument, not a pass)
  SELECT v.id INTO v_id FROM public.visits v WHERE v.time_on_site_source = 'review' ORDER BY v.id LIMIT 1;
  IF v_id IS NULL OR NOT public.fn_time_on_site_is_locked(v_id) THEN RAISE EXCEPTION 'VERIFY S3a: a review visit is not locked (%)', v_id; END IF;
  SELECT v.id INTO v_id FROM public.visits v WHERE v.time_on_site_source = 'dump_site_dwell' ORDER BY v.id LIMIT 1;
  IF v_id IS NULL OR NOT public.fn_time_on_site_is_locked(v_id) THEN RAISE EXCEPTION 'VERIFY S3a: a dump-site visit is not locked (%)', v_id; END IF;
  SELECT v.id INTO v_id FROM public.visits v JOIN public.visit_time_on_site_corrections c ON c.visit_id = v.id AND c.superseded_at IS NULL AND c.status = 'applied'
   WHERE v.time_on_site_source IN ('samsara_stay', 'stop_at_completion') ORDER BY v.id LIMIT 1;
  IF v_id IS NULL OR NOT public.fn_time_on_site_is_locked(v_id) THEN RAISE EXCEPTION 'VERIFY S3a: a visit locked only by an applied row is not locked (%)', v_id; END IF;
  SELECT v.id INTO v_id FROM public.visits v JOIN public.visit_time_on_site_corrections c ON c.visit_id = v.id AND c.superseded_at IS NULL AND c.status = 'proposed'
   WHERE coalesce(v.time_on_site_source, '') NOT IN ('review', 'reviewed_blank', 'dump_site_dwell') ORDER BY v.id LIMIT 1;
  IF v_id IS NULL OR NOT public.fn_time_on_site_is_locked(v_id) THEN RAISE EXCEPTION 'VERIFY S3a: a visit locked only by a proposed row is not locked (%)', v_id; END IF;
  SELECT v.id INTO v_id FROM public.visits v
   WHERE v.visit_status = 'completed' AND v.deleted_at IS NULL AND v.time_on_site_source IN ('samsara_stay', 'stop_at_completion')
     AND NOT EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections c WHERE c.visit_id = v.id AND c.superseded_at IS NULL AND c.status IN ('applied', 'proposed'))
   ORDER BY v.id DESC LIMIT 1;
  IF v_id IS NULL OR public.fn_time_on_site_is_locked(v_id) THEN RAISE EXCEPTION 'VERIFY S3a: an unlocked visit reads locked (%)', v_id; END IF;
  IF public.fn_time_on_site_is_locked(-1) THEN RAISE EXCEPTION 'VERIFY S3a: a missing visit reads locked'; END IF;
  -- (c) the six bodies are the edited ones and hold the call
  SELECT string_agg(x.fn, ', ') INTO bad FROM (VALUES
    ('fn_fill_time_on_site_from_stops(boolean)', '624d5e168bbc7745ad9af73ac1c03c41'),
    ('fn_compute_time_on_site(date,date,boolean,integer,integer,integer)', 'c1da67bc05399a3af1b81537c76487ef'),
    ('fn_fill_blank_time_on_site(date,date,boolean)', '2c2f358c93aac5a89dd826142284e116'),
    ('fn_save_samsara_stay(bigint,timestamp with time zone,timestamp with time zone,integer,text)', '305c7198a50e430c5f512f35e4d09ae4'),
    ('fn_save_samsara_stay_went_once(bigint,timestamp with time zone,timestamp with time zone,integer,text)', '10c58990fa5851447121b40af69b96f3'),
    ('fn_clear_time_on_site_on_reopen()', 'c38d5a5ed8c5b9f1bfa99c3bf2321638')
  ) AS x(fn, m)
   WHERE md5(pg_get_functiondef(('public.' || x.fn)::regprocedure)) <> x.m
      OR position('public.fn_time_on_site_is_locked(' in pg_get_functiondef(('public.' || x.fn)::regprocedure)) = 0;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY S3a: not the edited body: %', bad; END IF;
  -- (d) no visit written, nothing else audited
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > (SELECT audit_id0 FROM _s3a_ctx) AND a.txid = txid_current();
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S3a: % audit rows in this transaction (nothing may be written)', n; END IF;
  -- (e) T1 to T8: none newly failing, T7 and T8 zero
  ck0 := (SELECT checks0 FROM _s3a_ctx);
  ck := public.fn_time_on_site_checks();
  FOREACH t IN ARRAY ARRAY['T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8'] LOOP
    IF coalesce((ck->>t)::int, 0) > coalesce((ck0->>t)::int, 0) THEN
      RAISE EXCEPTION 'VERIFY S3a: % went from % to %: %', t, ck0->>t, ck->>t, ck->'T_detail'; END IF;
  END LOOP;
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY S3a: T7 % T8 %', ck->>'T7', ck->>'T8'; END IF;
  RAISE NOTICE 'S3a: lock function created, 6 bodies edited, checks %', ck - 'T_detail';
END $v$;

COMMIT;
