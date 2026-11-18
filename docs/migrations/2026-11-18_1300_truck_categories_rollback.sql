-- Rollback of 2026-11-18_1300_truck_categories.sql (Trello #170). Run step B's rollback FIRST
-- (2026-11-18_1330_calendar_truck_by_category_rollback.sql): its views and function read these columns.
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $guard$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_depend d JOIN pg_rewrite rw ON rw.oid = d.objid
             JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
             WHERE d.refobjid IN ('public.vehicles'::regclass, 'public.service_line_items'::regclass)
               AND a.attname = 'truck_category') THEN
    RAISE EXCEPTION 'a view still reads truck_category: roll back step B (2026-11-18_1330) first';
  END IF;
END
$guard$;
ALTER TABLE public.service_line_items DROP COLUMN truck_category;
ALTER TABLE public.vehicles DROP COLUMN truck_category;
DROP TABLE public.truck_categories;
COMMIT;
