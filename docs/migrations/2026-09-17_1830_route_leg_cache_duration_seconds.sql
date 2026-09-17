-- ============================================================================
-- 2026-09-17_1830  ops.route_leg_cache gains duration_seconds (Calendar "Hours driven" rebuild, part A)
-- ============================================================================
-- Fred, 2026-09-17: "This is not working at the Calendar App, which is the Hours Driven, the logic
-- for it, is to use the Google API to have a time it takes coming out of the YARD, up to the 1st
-- visit, from the 1st visit to the 2nd visit, and so on and so forth, up to the last visit then to
-- YARD back again, all on the same day at the calendar. Check how it's built today, and fix it."
-- Then: "No need to use Samsara for that today ... we need to use Google API for knowing how much
-- time we will drive that day for future visits and so on."
--
-- WHY A SEPARATE FILE. ALTER TABLE ... ADD COLUMN takes an ACCESS EXCLUSIVE lock until COMMIT.
-- calculate-driving-time (the DUMP Schedule ETA and the Calendar's day markers) reads and writes this
-- table on every request; part B is a long transaction, so the ALTER lands first, in its own short one.
--
-- WHAT. The planning path (part B, ops.calendar_drive_days) sums whole days of legs, so it wants the
-- leg in SECONDS and rounds ONCE per chain. The sibling stores duration_minutes (rounded per leg).
-- Nullable: calculate-driving-time's upsert names only its own columns and keeps working unchanged;
-- rows it writes carry NULL here and the reader falls back to duration_minutes * 60 for them.
--
-- Rule 8: ops.route_leg_cache is audit OPT-OUT (derived data, safe to TRUNCATE, recorded 2026-08-05_1456);
-- a new column changes nothing about that. Grants untouched: relacl is read before and after and
-- asserted identical (a column add does not touch the ACL, this is the check that says so).
-- ============================================================================
BEGIN;

DO $pre$
DECLARE v_acl text;
BEGIN
  SELECT relacl::text INTO v_acl FROM pg_class WHERE oid = 'ops.route_leg_cache'::regclass;
  IF v_acl IS DISTINCT FROM '{postgres=arwdDxtm/postgres,service_role=arw/postgres,yannick_readonly=r/postgres}' THEN
    RAISE EXCEPTION 'PRE: ops.route_leg_cache relacl is not the expected one: %', v_acl;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='ops' AND table_name='route_leg_cache' AND column_name='duration_seconds') THEN
    RAISE EXCEPTION 'PRE: duration_seconds already exists';
  END IF;
END $pre$;

ALTER TABLE ops.route_leg_cache ADD COLUMN duration_seconds integer CHECK (duration_seconds > 0);
COMMENT ON COLUMN ops.route_leg_cache.duration_seconds IS
  'Leg duration in seconds as Google returned it (routes.duration). Written by plan-drive-fill (traffic_aware = false rows). NULL on rows written by calculate-driving-time, whose upsert does not name it; readers fall back to duration_minutes * 60.';

DO $verify$
DECLARE v_acl text; v_n int;
BEGIN
  SELECT relacl::text INTO v_acl FROM pg_class WHERE oid = 'ops.route_leg_cache'::regclass;
  IF v_acl IS DISTINCT FROM '{postgres=arwdDxtm/postgres,service_role=arw/postgres,yannick_readonly=r/postgres}' THEN
    RAISE EXCEPTION 'VERIFY: relacl changed: %', v_acl;
  END IF;
  SELECT count(*) INTO v_n FROM information_schema.columns WHERE table_schema='ops' AND table_name='route_leg_cache' AND column_name='duration_seconds' AND data_type='integer' AND is_nullable='YES';
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY: duration_seconds not as expected'; END IF;
END $verify$;

COMMIT;
