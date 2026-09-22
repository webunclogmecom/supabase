-- 2026-09-22_1816_restore_operational_fields_from_merged_twins.sql
--
-- 🛑 THIS REPAIRS A REGRESSION I CAUSED EARLIER TODAY IN 2026-09-22_1749_merge_billing_twin_properties.sql.
--
-- WHAT WENT WRONG. That migration moved the WORK off each billing twin (visits, jobs, gdos,
-- client_locations) and then soft-deleted the row. It did NOT move the twin's own OPERATIONAL
-- COLUMNS, and some twins carried values the surviving service row does not have. Soft-deleting the
-- twin therefore made those values disappear from every app, because `client.properties` and
-- `client.clients` filter `deleted_at`.
--
-- HOW IT WAS FOUND. The app-side visual check after the publish. Yan's original screenshot of 192-FRK
-- showed "25 gal" in the Grease trap size column; the same row now rendered an em dash. The twin held
-- `grease_trap_size_gallons = 25` and the kept row holds NULL.
--
-- 🛑 IT IS NOT COSMETIC. `grease_trap_size_gallons` is what the LWT monthly report files with
-- Miami-Dade for a Broward-offloaded ticket (Client App rule 2o, Supabase 2026-09-18_1455,
-- rpa-derm-monthly v17). A property with no size makes its whole ticket unfileable.
--
-- MEASURED LOSS, twin had a value AND the kept row is NULL:
--   zone_id 21, access_schedule 12, grease_trap_size_gallons 8, notes 1, county 1, sample_port_count 1.
--   lock_box_key 0, city_emails 0, access_notes 0, grease_trap_manhole_count 0, latitude 0.
--
-- WHAT THIS DOES. Copies each of those columns from the retired twin onto its kept row, and ONLY where
-- the kept row is NULL or empty. It never overwrites a value the service row already holds, so it can
-- only add information back.
--
-- 🛑 IT USES THE SAME DETERMINISTIC MAPPING AS THE MERGE (most jobs, then most visits, then lowest id),
-- NOT a loose same-address join. 242-WYN has five real units at one street address, so an address join
-- matches several kept rows and would write a twin's value onto the wrong unit. That is why the pair
-- count under an address join is 458 while the merge made 454 pairs.
--
-- ⚠ EXPECTED SIDE EFFECT, and it is the correct direction: writing `grease_trap_size_gallons` fires
-- `trg_properties_enqueue_outbound`, so those 8 rows queue a Jobber custom-field push drained by the
-- `*/2` cron. The value belongs on the real Jobber property; the twin it sat on had no Jobber property
-- gid at all and `jobber-push-custom-field` skips billing rows, so it was never pushed from there.
-- Watch `sync.v_outbound_queue_health`, not the cron log.
--
-- RULE 8 (audit): no new table; `audit_properties` already covers every row touched.

DO $$
DECLARE v_trap int; v_sched int; v_zone int; v_notes int; v_county int; v_port int;
BEGIN
  CREATE TEMP TABLE _repair_map ON COMMIT DROP AS
  WITH p AS (
    SELECT id, client_id, COALESCE(is_billing,false) AS bill,
           lower(btrim(COALESCE(address,''))) AS addr, deleted_at
    FROM public.properties
  ), cand AS (
    SELECT b.id AS twin_id, s.id AS keep_id,
           (SELECT count(*) FROM public.jobs j   WHERE j.property_id = s.id) AS jobs,
           (SELECT count(*) FROM public.visits v WHERE v.property_id = s.id) AS visits
    FROM p b
    JOIN p s ON s.client_id = b.client_id AND NOT s.bill AND s.deleted_at IS NULL AND s.addr = b.addr
    WHERE b.bill AND b.addr <> '' AND b.deleted_at::date = date '2026-09-22'
  ), ranked AS (
    SELECT *, row_number() OVER (PARTITION BY twin_id ORDER BY jobs DESC, visits DESC, keep_id ASC) rn
    FROM cand
  )
  SELECT twin_id, keep_id FROM ranked WHERE rn = 1;

  UPDATE public.properties k SET grease_trap_size_gallons = b.grease_trap_size_gallons
    FROM _repair_map m JOIN public.properties b ON b.id = m.twin_id
   WHERE k.id = m.keep_id AND k.grease_trap_size_gallons IS NULL
     AND b.grease_trap_size_gallons IS NOT NULL;
  GET DIAGNOSTICS v_trap = ROW_COUNT;

  UPDATE public.properties k SET access_schedule = b.access_schedule
    FROM _repair_map m JOIN public.properties b ON b.id = m.twin_id
   WHERE k.id = m.keep_id AND k.access_schedule IS NULL
     AND b.access_schedule IS NOT NULL AND b.access_schedule::text <> '{}';
  GET DIAGNOSTICS v_sched = ROW_COUNT;

  UPDATE public.properties k SET zone_id = b.zone_id
    FROM _repair_map m JOIN public.properties b ON b.id = m.twin_id
   WHERE k.id = m.keep_id AND k.zone_id IS NULL AND b.zone_id IS NOT NULL;
  GET DIAGNOSTICS v_zone = ROW_COUNT;

  UPDATE public.properties k SET notes = b.notes
    FROM _repair_map m JOIN public.properties b ON b.id = m.twin_id
   WHERE k.id = m.keep_id AND nullif(k.notes,'') IS NULL AND nullif(b.notes,'') IS NOT NULL;
  GET DIAGNOSTICS v_notes = ROW_COUNT;

  UPDATE public.properties k SET county = b.county
    FROM _repair_map m JOIN public.properties b ON b.id = m.twin_id
   WHERE k.id = m.keep_id AND nullif(k.county,'') IS NULL AND nullif(b.county,'') IS NOT NULL;
  GET DIAGNOSTICS v_county = ROW_COUNT;

  UPDATE public.properties k SET sample_port_count = b.sample_port_count
    FROM _repair_map m JOIN public.properties b ON b.id = m.twin_id
   WHERE k.id = m.keep_id AND k.sample_port_count IS NULL AND b.sample_port_count IS NOT NULL;
  GET DIAGNOSTICS v_port = ROW_COUNT;

  RAISE NOTICE 'trap=% schedule=% zone=% notes=% county=% sample_port=%',
    v_trap, v_sched, v_zone, v_notes, v_county, v_port;

  IF v_trap <> 8 THEN
    RAISE EXCEPTION 'expected 8 grease trap sizes restored, got % - rolling back', v_trap;
  END IF;
END $$;
