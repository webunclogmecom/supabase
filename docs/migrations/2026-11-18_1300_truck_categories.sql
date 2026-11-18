-- 2026-11-18_1300_truck_categories.sql
-- Trello #170 (iElTShdF): truck by category. Step A of two: the categories and where they are set. Nothing reads them yet.
--
-- Source: Fred and Diego's huddle of 2026-11-04 (Diego: "We would have 2 trucks category. One being pumping and one
-- would be emergency."). Fred's picks, 2026-11-18 (Supabase docs/decisions-to-build.md, "Truck by category"):
--   1. two categories, Pumping (Moises, David, the second Moises coming in December) and Emergency (Cloggy, the next
--      one), stored on each truck, so a new truck only needs its category set;
--   2. the LINE ITEMS decide the category a visit needs: the pumping items 01 to 04 and 09 to 11 need a Pumping truck;
--      05 to 08 and 12 to 24 (cleaning, unclogging, camera, dye test, assessment, labor, parts, labor bus, warranty)
--      an Emergency truck; 25 to 28 (fees, GDO reporting, dump) ask nothing. Fred asked for a message to Diego and Yan
--      to confirm the list (Slack draft in #new-app-issues, not sent): a change they ask for is an UPDATE of
--      service_line_items.truck_category, nothing else.
-- Step B (2026-11-18_1330) makes the Calendar read them.
--
-- 3NF: a category is a fact of the truck (vehicles.truck_category) and of the line item (service_line_items.truck_category);
-- its name lives once, in truck_categories. Nothing is copied.
-- Audit (rule 8): truck_categories OPTS IN (reference data a person decides). vehicles and service_line_items are already
-- audited (audit_vehicles, audit_service_line_items); the new columns are captured in their full-row JSON.
-- Access: RLS comes on by itself (rls_auto_enable). No policy and no grant to anon or authenticated: nothing reads this
-- table directly; the Calendar views and ops.fn_truck_check (step B), owned by postgres, do.
-- Writers checked 2026-11-18: no function writes vehicles or service_line_items; the only code that inserts trucks is the
-- one-time populate.js; webhook-samsara only reads them. So nothing can overwrite the new columns.
-- Rollback: 2026-11-18_1300_truck_categories_rollback.sql.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF to_regclass('public.truck_categories') IS NOT NULL THEN
    RAISE EXCEPTION 'public.truck_categories already exists: this migration has run';
  END IF;
  IF (SELECT string_agg(id || ':' || name || ':' || status, ',' ORDER BY id) FROM public.vehicles)
     <> '1:Moises:ACTIVE,2:Cloggy:ACTIVE,3:David:ACTIVE,4:Goliath:INACTIVE' THEN
    RAISE EXCEPTION 'the trucks are not the four measured on 2026-11-18: re-read them before setting categories';
  END IF;
END
$guard$;

CREATE TABLE public.truck_categories (
  code       text PRIMARY KEY CHECK (code ~ '^[a-z]+$'),
  name       text NOT NULL UNIQUE CHECK (btrim(name) <> ''),
  sort       smallint NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.truck_categories IS
  'Truck categories (Trello #170, Fred 2026-11-18): pumping and emergency. A truck has one (vehicles.truck_category); a '
  'service line item says which one its work needs (service_line_items.truck_category). Read by ops.v_calendar_visit, '
  'ops.v_calendar_truck and ops.fn_truck_check.';
REVOKE ALL ON public.truck_categories FROM PUBLIC, anon, authenticated;
CREATE TRIGGER audit_truck_categories AFTER INSERT OR UPDATE OR DELETE ON public.truck_categories
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

INSERT INTO public.truck_categories (code, name, sort) VALUES
  ('pumping',   'Pumping',   1),
  ('emergency', 'Emergency', 2);

ALTER TABLE public.vehicles ADD COLUMN truck_category text REFERENCES public.truck_categories (code);
COMMENT ON COLUMN public.vehicles.truck_category IS
  'The truck''s category (public.truck_categories). NULL = not set: the Calendar then cannot tell whether it fits a '
  'visit, and says so. Set for Moises, David (pumping) and Cloggy (emergency) on 2026-11-18 (Trello #170).';
ALTER TABLE public.service_line_items ADD COLUMN truck_category text REFERENCES public.truck_categories (code);
COMMENT ON COLUMN public.service_line_items.truck_category IS
  'The truck category this line item''s work needs (public.truck_categories). NULL = no truck question (fees, GDO '
  'reporting, dump). Set 2026-11-18 (Trello #170, Fred''s pick); Diego and Yan to confirm the list.';

UPDATE public.vehicles SET truck_category = 'pumping'   WHERE id IN (1, 3);   -- Moises, David
UPDATE public.vehicles SET truck_category = 'emergency' WHERE id = 2;          -- Cloggy
UPDATE public.service_line_items SET truck_category = 'pumping'
 WHERE code IN ('01','02','03','04','09','10','11');
UPDATE public.service_line_items SET truck_category = 'emergency'
 WHERE code IN ('05','06','07','08','12','13','14','15','16','17','18','19','20','21','22','23','24');

-- VERIFY (cheap: four tables of a few rows)
DO $verify$
DECLARE r record;
BEGIN
  IF (SELECT string_agg(name || '=' || coalesce(truck_category, '-'), ',' ORDER BY id) FROM public.vehicles)
     <> 'Moises=pumping,Cloggy=emergency,David=pumping,Goliath=-' THEN
    RAISE EXCEPTION 'truck categories not as decided';
  END IF;
  SELECT count(*) FILTER (WHERE truck_category = 'pumping') p, count(*) FILTER (WHERE truck_category = 'emergency') e,
         count(*) FILTER (WHERE truck_category IS NULL) n, count(*) t INTO r FROM public.service_line_items;
  IF (r.p, r.e, r.n, r.t) <> (7::bigint, 17::bigint, 4::bigint, 28::bigint) THEN
    RAISE EXCEPTION 'line item categories: % pumping, % emergency, % none of % (want 7, 17, 4 of 28)', r.p, r.e, r.n, r.t;
  END IF;
  -- the map follows the line items' own service type, so a reader by service type and one by line item agree today
  IF EXISTS (SELECT 1 FROM public.service_line_items WHERE truck_category = 'pumping' AND service_type IS DISTINCT FROM 'Pumping')
     OR EXISTS (SELECT 1 FROM public.service_line_items WHERE truck_category = 'emergency' AND (service_type IS NULL OR service_type IN ('Pumping','Dump Offload')))
     OR EXISTS (SELECT 1 FROM public.service_line_items WHERE truck_category IS NULL AND service_type IS NOT NULL AND service_type <> 'Dump Offload') THEN
    RAISE EXCEPTION 'a line item category disagrees with its service type';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.truck_categories'::regclass) THEN
    RAISE EXCEPTION 'RLS is not on for truck_categories';
  END IF;
  IF has_table_privilege('anon', 'public.truck_categories', 'SELECT')
     OR has_table_privilege('authenticated', 'public.truck_categories', 'SELECT')
     OR has_table_privilege('authenticated', 'public.truck_categories', 'INSERT') THEN
    RAISE EXCEPTION 'anon or authenticated holds a privilege on truck_categories';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.truck_categories'::regclass AND tgname = 'audit_truck_categories') THEN
    RAISE EXCEPTION 'audit trigger missing';
  END IF;
END
$verify$;

COMMIT;
