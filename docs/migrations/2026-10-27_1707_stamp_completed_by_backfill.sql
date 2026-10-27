-- ============================================================================
-- 2026-10-27_1707_stamp_completed_by_backfill (applied 2026-10-27 17:07 ET)
-- Stamp Studio: put the person back on the 43 completed sheets whose completion is attributed in audit.logs.
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-27, after 2026-10-27_1703 (Mark completed records the person again): "yes backfill the 43".
-- WHAT
--   143 completed sheets carry completed_by = 'stamp-studio' because set_sheet_completed read a sign-in setting
--   PostgREST no longer fills. For each, the audit row that wrote the CURRENT completion is found by folder AND the
--   exact completed_at it wrote. Where that row carries jwt_claims->>'email' (43: Fred 30, Yannick 9, contact@ 4 on
--   2026-10-27), completed_by takes that email. The other 100 have no email anywhere (the anon era before the login,
--   and direct SQL) and keep 'stamp-studio'. Emails are read from audit.logs at run time, never typed here.
-- SAFETY
--   Only completed_by (and updated_at, set by its trigger) moves. The completion triggers act only on a false -> true
--   change, the reopen pin leaves a completed row's reopened_* NULL (already NULL on every completed row), nothing reads
--   stamp_sheet_status.updated_at, and the blackout reads only completed. The UPDATE re-asserts its predicate
--   (completed, completed_by = 'stamp-studio', the same completed_at), so a sheet that changed meanwhile is skipped.
--   Audited table: every change is in audit.logs (app_source stamp-completed-by-backfill). Local backup:
--   backups/2026-10-27_stamp_completed_by_before_backfill.json (43 rows, outside the repo).
-- Rule 8: no schema change. ROLLBACK: set completed_by back to 'stamp-studio' for the rows this run wrote
--   (audit.logs app_source = 'stamp-completed-by-backfill', old_row->>'completed_by').
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
SELECT set_config('request.headers', '{"x-app-source":"stamp-completed-by-backfill"}', true);

CREATE TEMP TABLE plan ON COMMIT DROP AS
SELECT s.dump_folder, s.completed_at, e.email
  FROM derm.stamp_sheet_status s
  JOIN LATERAL (SELECT l.jwt_claims->>'email' AS email
                  FROM audit.logs l
                 WHERE l.table_schema = 'derm' AND l.table_name = 'stamp_sheet_status'
                   AND (l.new_row->>'completed')::boolean
                   AND l.new_row->>'dump_folder' = s.dump_folder
                   AND (l.new_row->>'completed_at')::timestamptz = s.completed_at
                 ORDER BY l.changed_at DESC LIMIT 1) e ON true
 WHERE s.completed AND s.completed_by = 'stamp-studio' AND nullif(btrim(e.email), '') IS NOT NULL;

CREATE TEMP TABLE before ON COMMIT DROP AS
SELECT dump_folder, completed, completed_at, completed_by, reopened_at, reopened_by FROM derm.stamp_sheet_status;

DO $g$ BEGIN
  IF (SELECT count(*) FROM plan) <> 43 THEN
    RAISE EXCEPTION 'expected 43 sheets to backfill, found %', (SELECT count(*) FROM plan);
  END IF;
  IF EXISTS (SELECT 1 FROM plan WHERE email !~ '^[^@[:space:]]+@[^@[:space:]]+$') THEN
    RAISE EXCEPTION 'an audit email is not an address';
  END IF;
END $g$;

UPDATE derm.stamp_sheet_status s
   SET completed_by = p.email
  FROM plan p
 WHERE s.dump_folder = p.dump_folder
   AND s.completed AND s.completed_by = 'stamp-studio' AND s.completed_at = p.completed_at;

DO $v$
DECLARE v_n int;
BEGIN
  -- exactly the 43 moved, to the planned email, and nothing else moved
  SELECT count(*) INTO v_n FROM derm.stamp_sheet_status s JOIN plan p USING (dump_folder) WHERE s.completed_by = p.email;
  IF v_n <> 43 THEN RAISE EXCEPTION 'VERIFY: % of 43 written', v_n; END IF;
  SELECT count(*) INTO v_n FROM before b JOIN derm.stamp_sheet_status s USING (dump_folder)
   WHERE (s.completed, s.completed_at, s.reopened_at, s.reopened_by) IS DISTINCT FROM (b.completed, b.completed_at, b.reopened_at, b.reopened_by)
      OR (s.completed_by IS DISTINCT FROM b.completed_by AND b.dump_folder NOT IN (SELECT dump_folder FROM plan));
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY: % other rows or fields moved', v_n; END IF;
  IF (SELECT count(*) FROM derm.stamp_sheet_status WHERE completed AND completed_by = 'stamp-studio') <> 100 THEN
    RAISE EXCEPTION 'VERIFY: expected 100 left as stamp-studio';
  END IF;
  -- the audit trail names this run
  IF (SELECT count(*) FROM audit.logs WHERE table_schema = 'derm' AND table_name = 'stamp_sheet_status'
        AND app_source = 'stamp-completed-by-backfill' AND changed_at >= now()) <> 43 THEN
    RAISE EXCEPTION 'VERIFY: audit rows not labelled';
  END IF;
END $v$;
COMMIT;
