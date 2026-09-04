-- 2026-09-04_1104_moises_grease_tank_capacity_3840.sql
--
-- WHY
-- ---
-- Fred, 2026-09-04: *"Moises is at 3,840 gallons, change it in the DB if needed."*
--
-- This settles a contradiction found while measuring the new Samsara LM11 Level Monitor fitted to
-- truck Moises on 2026-08-20 (asset 281475005688801, gateway GZ8K-E8N-PVX).
--
-- The sensor reports `totalCapacityVolume = 14535.981 LITERS`, which is 3,840.0 US gallons.
-- `public.vehicles.grease_tank_capacity_gallons` for Moises (id=1) held **9000**.
-- Those cannot both describe the same vessel. Fred confirmed the truck is 3,840.
--
-- The 9000 was never measured from anything; it has sat unchanged since 2026-07-15 18:32 UTC and
-- predates any level instrumentation. The LM11 figure is the configured vessel profile on a
-- radar level sensor that has been tracking real fill/dump cycles since 2026-08-20T18:38:12Z
-- (0 to 3,775 gal observed range, which is consistent with a 3,840 gal vessel and NOT with a
-- 9,000 gal one: the tank has never once read above 3,775 in 15 days of daily operation).
--
-- 🛑 THIS RETROACTIVELY CHANGES A REGULATOR-FACING REPORT, AND THAT IS INTENDED, NOT A SIDE EFFECT.
-- ----------------------------------------------------------------------------------------------
-- `derm.v_lwt_monthly_rows.truck_capacity_gallons` is defined as `ve.grease_tank_capacity_gallons`
-- read LIVE from this table. It is NOT snapshotted per manifest. So every historical row re-renders
-- with the new number the moment this commits.
--
-- Measured blast radius BEFORE the change:
--   446 LWT rows carry truck='Moises' (389 of them `in_scope`), pickups 2026-02-16 .. 2026-09-01.
--   By truck: Moises 446, David 229, Cloggy 45, NULL 6. Only Moises rows change.
--
-- This is a CORRECTION, not a falsification: those 446 rows were rendering 9,000 for a truck that
-- holds 3,840. Any Miami-Dade LWT monthly report already SUBMITTED for Feb-Aug 2026 stated a
-- capacity that was wrong, and a re-render will now disagree with the filed copy.
-- ⚠ Fred/Yannick own the decision about whether any filed report needs an amendment. This migration
--   does not attempt to preserve the old value for historical rows, because preserving a wrong
--   number to match a wrong filing is not a defensible data model.
--
-- OTHER READERS (7 views, all read-through, none compute a derived quantity from the capacity):
--   client.vehicles, derm.v_lwt_monthly_rows, ops.v_calendar_truck, ops.v_calendar_visit,
--   ops.v_route_today, ops.v_truck_utilization, ops.vehicles
-- `ops.v_truck_utilization` merely EXPOSES the column; nothing divides by it, so no utilisation
-- percentage silently doubles. Zero functions reference the column (`pg_get_functiondef` sweep,
-- prokind='f'). `v_vehicle_telemetry_latest.fuel_gallons_computed` uses fuel_tank_capacity_gallons,
-- a different column, and is untouched.
--
-- NOT CHANGED, ON PURPOSE
-- -----------------------
-- David (1800), Cloggy (126) and Goliath (4800) are left alone. Fred named only Moises, and no
-- sensor exists on the other trucks to contradict their stored values. Do not "tidy" them.
--
-- ⚠ STILL OPEN, and it decides what the 3,840 actually MEASURES: nobody has confirmed whether the
--   LM11 is mounted on the grease compartment, the water compartment, or a single combined tank.
--   `public.inspections` records sludge_gallons and water_gallons SEPARATELY, so the truck is
--   operated as if it has two. If the LM11 turns out to be on the water tank, this column is now
--   holding a water capacity under a grease name. Asked; unanswered at time of writing.
--
-- Backup of the pre-change row: backups/2026-09-04_moises_capacity_pre.json
-- Audit: public.vehicles carries the `audit_vehicles` AFTER INSERT/UPDATE/DELETE trigger (enabled),
-- so this UPDATE writes its own before/after row to audit.logs with no extra work here.

BEGIN;

-- Guard: refuse to run if the row is not in the state this migration was written against.
DO $$
DECLARE v_current numeric;
BEGIN
  SELECT grease_tank_capacity_gallons INTO v_current FROM public.vehicles WHERE id = 1;
  IF v_current IS DISTINCT FROM 9000 THEN
    RAISE EXCEPTION 'Expected Moises grease_tank_capacity_gallons = 9000, found %. Refusing to overwrite an unexpected value.', v_current;
  END IF;
END $$;

UPDATE public.vehicles
   SET grease_tank_capacity_gallons = 3840
 WHERE id = 1
   AND name = 'Moises';

-- Verify in-transaction: exactly one row, and it now reads 3840.
DO $$
DECLARE v_new numeric; v_n int;
BEGIN
  SELECT count(*), max(grease_tank_capacity_gallons) INTO v_n, v_new
    FROM public.vehicles WHERE id = 1 AND grease_tank_capacity_gallons = 3840;
  IF v_n <> 1 THEN RAISE EXCEPTION 'Post-check failed: % rows at 3840, expected 1', v_n; END IF;
  RAISE NOTICE 'Moises grease_tank_capacity_gallons now %', v_new;
END $$;

COMMIT;
