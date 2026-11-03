-- ============================================================================
-- 2026-11-03_rollback_time_on_site_s3a_lock_in_writers  Undo 2026-11-03_1330_time_on_site_s3a_lock_in_writers
-- ============================================================================
-- WHAT IT DOES: the six bodies go back to their pre-S3a text by the reverse anchored edit (each pinned on its S3a md5,
--   so a body changed since is refused, never overwritten), then public.fn_time_on_site_is_locked is dropped.
--   Nothing is written to any visit. md5 of each body, before S3a -> after S3a (this file goes right to left):
--   fn_fill_time_on_site_from_stops(boolean)  acaaf87971f7ca4536f96c6772acc170 -> 624d5e168bbc7745ad9af73ac1c03c41
--   fn_compute_time_on_site(date,date,boolean,integer,integer,integer)  9ed2ff46ec7ed92f13fe83093673f928 -> c1da67bc05399a3af1b81537c76487ef
--   fn_fill_blank_time_on_site(date,date,boolean)  b1d8cea3a5f2fc01c62b2a2d1fccbe5d -> 2c2f358c93aac5a89dd826142284e116
--   fn_save_samsara_stay(bigint,timestamp with time zone,timestamp with time zone,integer,text)  4f220a19decc75585753f7e1dad4a62a -> 305c7198a50e430c5f512f35e4d09ae4
--   fn_save_samsara_stay_went_once(bigint,timestamp with time zone,timestamp with time zone,integer,text)  2395825e3019c1910031552b8f9f3a56 -> 10c58990fa5851447121b40af69b96f3
--   fn_clear_time_on_site_on_reopen()  8cb07e2569923869e9da325fbfc3d868 -> c38d5a5ed8c5b9f1bfa99c3bf2321638
-- VERIFY: the six bodies have their pre-S3a md5 and no longer name the function; the function is gone; no audit row
--   in this transaction; T7 = T8 = 0.
-- REHEARSED: on top of the forward file in one rolled-back transaction (S3a/rehearse.mjs r, local). Alone, before S3a,
--   it refuses (its PIN needs the function).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF to_regprocedure('public.fn_time_on_site_is_locked(bigint)') IS NULL THEN
    RAISE EXCEPTION 'S3a rollback: public.fn_time_on_site_is_locked does not exist (S3a is not applied)'; END IF;
END $pin$;
CREATE TEMP TABLE _s3a_rb_ctx ON COMMIT DROP AS SELECT (SELECT max(id) FROM audit.logs) AS audit_id0;

DO $s3a0$
DECLARE
  d text := pg_get_functiondef('public.fn_fill_time_on_site_from_stops(boolean)'::regprocedure);
  n text;
  a0 text := $a$   where v.visit_status = 'completed' and v.deleted_at is null and f.departure > f.arrival
     and not public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
$a$;
  b0 text := $b$   where v.visit_status = 'completed' and v.deleted_at is null and f.departure > f.arrival
$b$;
  a1 text := $a$     where v.id = f.visit_id
       and v.visit_status = 'completed' and v.deleted_at is null
       and not public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
$a$;
  b1 text := $b$     where v.id = f.visit_id
       and v.visit_status = 'completed' and v.deleted_at is null
$b$;
BEGIN
  IF md5(d) <> '624d5e168bbc7745ad9af73ac1c03c41' THEN RAISE EXCEPTION 'S3a: fn_fill_time_on_site_from_stops is not the expected body (md5 %)', md5(d); END IF;
  IF (length(d) - length(replace(d, a0, ''))) / length(a0) <> 1 THEN RAISE EXCEPTION 'S3a: fn_fill_time_on_site_from_stops anchor 0 not found exactly once'; END IF;
  IF (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 THEN RAISE EXCEPTION 'S3a: fn_fill_time_on_site_from_stops anchor 1 not found exactly once'; END IF;
  n := replace(replace(d, a0, b0), a1, b1);
  EXECUTE n;
  IF pg_get_functiondef('public.fn_fill_time_on_site_from_stops(boolean)'::regprocedure) <> n THEN RAISE EXCEPTION 'S3a: fn_fill_time_on_site_from_stops re-read differs from the edited text'; END IF;
  IF md5(n) <> 'acaaf87971f7ca4536f96c6772acc170' THEN RAISE EXCEPTION 'S3a: fn_fill_time_on_site_from_stops edited md5 is %', md5(n); END IF;
END $s3a0$;

DO $s3a1$
DECLARE
  d text := pg_get_functiondef('public.fn_compute_time_on_site(date,date,boolean,integer,integer,integer)'::regprocedure);
  n text;
  a0 text := $a$     where v.visit_status = 'completed'
       and v.deleted_at is null
       and v.visit_date >= p_from and v.visit_date < p_to
       and v.vehicle_id is not null
       and not public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
$a$;
  b0 text := $b$     where v.visit_status = 'completed'
       and v.deleted_at is null
       and v.visit_date >= p_from and v.visit_date < p_to
       and v.vehicle_id is not null
$b$;
  a1 text := $a$       and (v.time_on_site_source is null or v.time_on_site_source = 'gps_150m_cluster')
       and not public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
       and (v.actual_arrival_at   is distinct from r.arrival
$a$;
  b1 text := $b$       and (v.time_on_site_source is null or v.time_on_site_source = 'gps_150m_cluster')
       and (v.actual_arrival_at   is distinct from r.arrival
$b$;
BEGIN
  IF md5(d) <> 'c1da67bc05399a3af1b81537c76487ef' THEN RAISE EXCEPTION 'S3a: fn_compute_time_on_site is not the expected body (md5 %)', md5(d); END IF;
  IF (length(d) - length(replace(d, a0, ''))) / length(a0) <> 1 THEN RAISE EXCEPTION 'S3a: fn_compute_time_on_site anchor 0 not found exactly once'; END IF;
  IF (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 THEN RAISE EXCEPTION 'S3a: fn_compute_time_on_site anchor 1 not found exactly once'; END IF;
  n := replace(replace(d, a0, b0), a1, b1);
  EXECUTE n;
  IF pg_get_functiondef('public.fn_compute_time_on_site(date,date,boolean,integer,integer,integer)'::regprocedure) <> n THEN RAISE EXCEPTION 'S3a: fn_compute_time_on_site re-read differs from the edited text'; END IF;
  IF md5(n) <> '9ed2ff46ec7ed92f13fe83093673f928' THEN RAISE EXCEPTION 'S3a: fn_compute_time_on_site edited md5 is %', md5(n); END IF;
END $s3a1$;

DO $s3a2$
DECLARE
  d text := pg_get_functiondef('public.fn_fill_blank_time_on_site(date,date,boolean)'::regprocedure);
  n text;
  a0 text := $a$       and v.time_on_site_source is null   -- 2026-10-18 Stage 0: a reviewed_blank stays blank
       and not public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
$a$;
  b0 text := $b$       and v.time_on_site_source is null   -- 2026-10-18 Stage 0: a reviewed_blank stays blank
$b$;
  a1 text := $a$     where v.id = f.visit_id and v.duration_minutes is null and v.time_on_site_source is null
       and not public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
$a$;
  b1 text := $b$     where v.id = f.visit_id and v.duration_minutes is null and v.time_on_site_source is null
$b$;
BEGIN
  IF md5(d) <> '2c2f358c93aac5a89dd826142284e116' THEN RAISE EXCEPTION 'S3a: fn_fill_blank_time_on_site is not the expected body (md5 %)', md5(d); END IF;
  IF (length(d) - length(replace(d, a0, ''))) / length(a0) <> 1 THEN RAISE EXCEPTION 'S3a: fn_fill_blank_time_on_site anchor 0 not found exactly once'; END IF;
  IF (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 THEN RAISE EXCEPTION 'S3a: fn_fill_blank_time_on_site anchor 1 not found exactly once'; END IF;
  n := replace(replace(d, a0, b0), a1, b1);
  EXECUTE n;
  IF pg_get_functiondef('public.fn_fill_blank_time_on_site(date,date,boolean)'::regprocedure) <> n THEN RAISE EXCEPTION 'S3a: fn_fill_blank_time_on_site re-read differs from the edited text'; END IF;
  IF md5(n) <> 'b1d8cea3a5f2fc01c62b2a2d1fccbe5d' THEN RAISE EXCEPTION 'S3a: fn_fill_blank_time_on_site edited md5 is %', md5(n); END IF;
END $s3a2$;

DO $s3a3$
DECLARE
  d text := pg_get_functiondef('public.fn_save_samsara_stay(bigint,timestamp with time zone,timestamp with time zone,integer,text)'::regprocedure);
  n text;
  a0 text := $a$     AND coalesce(v.time_on_site_source, '') NOT IN ('review', 'reviewed_blank', 'dump_site_dwell')
     AND NOT public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
$a$;
  b0 text := $b$     AND coalesce(v.time_on_site_source, '') NOT IN ('review', 'reviewed_blank', 'dump_site_dwell')
$b$;
BEGIN
  IF md5(d) <> '305c7198a50e430c5f512f35e4d09ae4' THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay is not the expected body (md5 %)', md5(d); END IF;
  IF (length(d) - length(replace(d, a0, ''))) / length(a0) <> 1 THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay anchor 0 not found exactly once'; END IF;
  n := replace(d, a0, b0);
  EXECUTE n;
  IF pg_get_functiondef('public.fn_save_samsara_stay(bigint,timestamp with time zone,timestamp with time zone,integer,text)'::regprocedure) <> n THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay re-read differs from the edited text'; END IF;
  IF md5(n) <> '4f220a19decc75585753f7e1dad4a62a' THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay edited md5 is %', md5(n); END IF;
END $s3a3$;

DO $s3a4$
DECLARE
  d text := pg_get_functiondef('public.fn_save_samsara_stay_went_once(bigint,timestamp with time zone,timestamp with time zone,integer,text)'::regprocedure);
  n text;
  a0 text := $a$     AND coalesce(v.time_on_site_source, '') NOT IN ('review', 'reviewed_blank', 'dump_site_dwell')
     AND NOT public.fn_time_on_site_is_locked(v.id)   -- 2026-11-03_1330 S3a: the ledger lock (Fred, Q-E)
$a$;
  b0 text := $b$     AND coalesce(v.time_on_site_source, '') NOT IN ('review', 'reviewed_blank', 'dump_site_dwell')
$b$;
BEGIN
  IF md5(d) <> '10c58990fa5851447121b40af69b96f3' THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay_went_once is not the expected body (md5 %)', md5(d); END IF;
  IF (length(d) - length(replace(d, a0, ''))) / length(a0) <> 1 THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay_went_once anchor 0 not found exactly once'; END IF;
  n := replace(d, a0, b0);
  EXECUTE n;
  IF pg_get_functiondef('public.fn_save_samsara_stay_went_once(bigint,timestamp with time zone,timestamp with time zone,integer,text)'::regprocedure) <> n THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay_went_once re-read differs from the edited text'; END IF;
  IF md5(n) <> '2395825e3019c1910031552b8f9f3a56' THEN RAISE EXCEPTION 'S3a: fn_save_samsara_stay_went_once edited md5 is %', md5(n); END IF;
END $s3a4$;

DO $s3a5$
DECLARE
  d text := pg_get_functiondef('public.fn_clear_time_on_site_on_reopen()'::regprocedure);
  n text;
  a0 text := $a$  if coalesce(OLD.time_on_site_source, '') not in ('review', 'reviewed_blank')
     and not public.fn_time_on_site_is_locked(OLD.id)   -- 2026-11-03_1330 S3a: a locked value is kept (Fred, Q-E part 2)
$a$;
  b0 text := $b$  if coalesce(OLD.time_on_site_source, '') not in ('review', 'reviewed_blank')
$b$;
BEGIN
  IF md5(d) <> 'c38d5a5ed8c5b9f1bfa99c3bf2321638' THEN RAISE EXCEPTION 'S3a: fn_clear_time_on_site_on_reopen is not the expected body (md5 %)', md5(d); END IF;
  IF (length(d) - length(replace(d, a0, ''))) / length(a0) <> 1 THEN RAISE EXCEPTION 'S3a: fn_clear_time_on_site_on_reopen anchor 0 not found exactly once'; END IF;
  n := replace(d, a0, b0);
  EXECUTE n;
  IF pg_get_functiondef('public.fn_clear_time_on_site_on_reopen()'::regprocedure) <> n THEN RAISE EXCEPTION 'S3a: fn_clear_time_on_site_on_reopen re-read differs from the edited text'; END IF;
  IF md5(n) <> '8cb07e2569923869e9da325fbfc3d868' THEN RAISE EXCEPTION 'S3a: fn_clear_time_on_site_on_reopen edited md5 is %', md5(n); END IF;
END $s3a5$;


DROP FUNCTION public.fn_time_on_site_is_locked(bigint);

DO $v$
DECLARE bad text; n int; ck jsonb;
BEGIN
  SELECT string_agg(x.fn, ', ') INTO bad FROM (VALUES
    ('fn_fill_time_on_site_from_stops(boolean)', 'acaaf87971f7ca4536f96c6772acc170'),
    ('fn_compute_time_on_site(date,date,boolean,integer,integer,integer)', '9ed2ff46ec7ed92f13fe83093673f928'),
    ('fn_fill_blank_time_on_site(date,date,boolean)', 'b1d8cea3a5f2fc01c62b2a2d1fccbe5d'),
    ('fn_save_samsara_stay(bigint,timestamp with time zone,timestamp with time zone,integer,text)', '4f220a19decc75585753f7e1dad4a62a'),
    ('fn_save_samsara_stay_went_once(bigint,timestamp with time zone,timestamp with time zone,integer,text)', '2395825e3019c1910031552b8f9f3a56'),
    ('fn_clear_time_on_site_on_reopen()', '8cb07e2569923869e9da325fbfc3d868')
  ) AS x(fn, m)
   WHERE md5(pg_get_functiondef(('public.' || x.fn)::regprocedure)) <> x.m
      OR position('fn_time_on_site_is_locked' in pg_get_functiondef(('public.' || x.fn)::regprocedure)) > 0;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY S3a rollback: not the pre-S3a body: %', bad; END IF;
  IF to_regprocedure('public.fn_time_on_site_is_locked(bigint)') IS NOT NULL THEN RAISE EXCEPTION 'VERIFY S3a rollback: the function is still there'; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > (SELECT audit_id0 FROM _s3a_rb_ctx) AND a.txid = txid_current();
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S3a rollback: % audit rows in this transaction', n; END IF;
  ck := public.fn_time_on_site_checks();
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY S3a rollback: T7 % T8 %', ck->>'T7', ck->>'T8'; END IF;
  RAISE NOTICE 'S3a rollback: 6 bodies restored, lock function dropped, checks %', ck - 'T_detail';
END $v$;

COMMIT;
