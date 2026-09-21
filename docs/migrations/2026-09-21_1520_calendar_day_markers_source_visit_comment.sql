-- ============================================================================
-- 2026-09-21_1520  ops.calendar_day_markers.source_visit_id: the comment said it goes NULL on a
--                  hand edit of the time. It does not; only eta_minutes and eta_computed_at do.
-- ----------------------------------------------------------------------------
-- Comment-only. Found by the refuter review of the Start pill app prompt (2026-09-21): plan
-- section 3.3 always said "a hand-edited time keeps the truck, the driver and the Task, sets
-- eta_minutes NULL"; plan 4.1 and the 2026-09-21_1225 comment widened that to all three new
-- columns. The app keeps source_visit_id on a hand edit because the popover's read-only driver
-- line ("Fred, from 112-YA at 6:00 AM") reads it. DERIVED is decided by eta_minutes alone.
-- Rule 8: comment only, no audit change. No grants touched.
-- ============================================================================
COMMENT ON COLUMN ops.calendar_day_markers.source_visit_id IS
  'Truck-placed Start only: the visit the Start was derived from (the truck''s first timed, geo-coded visit that day). NULL on End, Dump, driver-placed and legacy rows. It SURVIVES a hand edit of the time (only eta_minutes and eta_computed_at go NULL then; eta_minutes alone says whether the minute is derived). ON DELETE SET NULL.';

DO $$
DECLARE v text;
BEGIN
  SELECT col_description('ops.calendar_day_markers'::regclass,
         (SELECT attnum FROM pg_attribute WHERE attrelid = 'ops.calendar_day_markers'::regclass AND attname = 'source_visit_id'))
    INTO v;
  IF v NOT LIKE '%SURVIVES a hand edit%' THEN RAISE EXCEPTION 'comment not applied'; END IF;
  RAISE NOTICE 'ok: source_visit_id comment updated';
END $$;
