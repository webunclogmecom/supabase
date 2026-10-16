-- ============================================================================
-- 2026-10-16_1126 Water views: water leaving the water tank at a dump or the yard goes into the sludge tank (labels)
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-16, answering the two open questions of the water balance design note:
--   Dump: "At the dump we can transfer the water to the sludge compartment. We can use the water to clean the filter and
--   it ultimately goes to the sludge. Once the water is in the sludge, we can dispose of it at the tank."
--   Yard: "... yes, grease goes in and out at the yard sometimes. This is because if David is full and Moises needs to
--   go to the dump, we transfer David to Moises so Moises is full when we go to the dump. If David is empty and we need
--   space in Moises to do the rat (route?) tonight, we transfer from Moises to David." (the word was unclear)
--
-- WHAT THE DATA SHOWS (read-only, 2026-10-16; scratchpad hw2/dump, hw3/rv_water, hw3/rv_verify)
--   Dumps since 2026-10-02: the water tank fell at 4 of 9 (exactly the 4 that arrived with 840 gal or more), 2,090.6 gal
--   in all, and the falls are permanent. At 1237 and 1253 the water fell while the sludge tank was emptying; at 1213 it
--   fell after the sludge tank already read empty and never showed in it; at 1221 the sludge tank rose +286.8 of the
--   556.1 before emptying. At the yard the water fell twice: 1252 (no transfer: the water stayed in Moises's sludge
--   tank, +512.6 net, and was dumped at 1253) and 1264 (with a transfer to David). Where it can be seen, the sludge
--   tank shows about half of the fall (49 to 52% of the stop's fall). The yard part is inferred from these 2 stops;
--   Fred's answer is about the dump.
--   Yard sludge: from 10-02 to 10-15 every change of 1,000 gal or more net (1272 and 1733 into Moises, each dumped the
--   same day; 1714 and 1759 out of Moises), and the 872 and 419 gal falls at 1264, came with David's pump on at the
--   yard, 0 to 9 m away. 1215 (+975.8 net) had no David pump reading. Before 10-02 seven such changes had none, so this
--   is not a rule.
--
-- WHAT CHANGES (no logic change; nothing reads these columns: no app bundle, no function, no dependent view; only
--   their defining migration 2026-10-15_1950 names them)
--   public.v_vehicle_water_ledger.pumped_out_gallons      -> moved_to_sludge_tank_gallons (yard and dump stops)
--   public.v_visit_water_balance.water_pumped_out_at_dump_gallons -> water_moved_to_sludge_at_dump_gallons
--   New comments on both views and the two columns; v_vehicle_dumps' comment gains what its offload and its
--   collected_since_previous_dump_gallons do not include.
--   ⚠ After this, the CREATE text of the two water views in 2026-10-15_1950 no longer replays (CREATE OR REPLACE
--   cannot rename a column back): take pg_get_viewdef as the source. And 2026-10-15_rollback_tank_pipeline_v3.sql's
--   md5 guard refuses until this migration is rolled back first.
-- Rule 8: views only.
-- ROLLBACK: docs/migrations/2026-10-16_rollback_water_views_moved_to_sludge_labels.sql (run it BEFORE the v3 rollback).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

ALTER VIEW public.v_vehicle_water_ledger RENAME COLUMN pumped_out_gallons TO moved_to_sludge_tank_gallons;
ALTER VIEW public.v_visit_water_balance RENAME COLUMN water_pumped_out_at_dump_gallons TO water_moved_to_sludge_at_dump_gallons;

COMMENT ON VIEW public.v_vehicle_water_ledger IS
'Every stop of a truck with a water sensor, in order: the water tank at arrival, peak, low and departure, and its rises and falls. At a client: separated / put back (Fred''s model). At the yard (the office): refilled_gallons, a clean-water refill (Fred: refills are "usually at the office"). At a dump or the yard: moved_to_sludge_tank_gallons, the water tank''s fall. At a dump Fred said (2026-10-16): "At the dump we can transfer the water to the sludge compartment. We can use the water to clean the filter and it ultimately goes to the sludge. Once the water is in the sludge, we can dispose of it at the tank." So at a dump that water leaves in the same stop and is not in v_vehicle_dumps.offload_gallons. At the yard it is the same move, inferred from 2 stops (1252, 1264): the water stays in the sludge tank unless the grease is moved to another truck, so it is in the next dump''s offload_gallons and missing from collected_since_previous_dump_gallons (yard 1252 then dump 1253: ratio 1.556, 1.036 with it). Measured 2026-10-02 to 10-15: falls at 4 of 9 dumps (the 4 that arrived with 840 gal or more) and at 2 yard stops; where it can be seen the sludge tank shows about half of the fall, so the gallons moved are an upper bound. change_since_previous_stop_gallons closes the ledger between stops (measured: no separation on the road). Service role only.';
COMMENT ON COLUMN public.v_vehicle_water_ledger.moved_to_sludge_tank_gallons IS
'Dump and yard stops only: the water tank''s fall during the stop (sum of falls at the sensor''s 10-minute pace): water moved into the sludge tank to wash the filter and taken out with the grease (Fred, 2026-10-16, for the dump; the yard is inferred from 2 stops). An upper bound of what reached the sludge tank: where it can be seen the sludge tank shows about half of it (49 to 52%). NULL at client and other stops.';
COMMENT ON COLUMN public.v_vehicle_water_ledger.refilled_gallons IS
'Yard stops only: the water tank''s rise, a clean-water refill. NULL elsewhere.';

COMMENT ON VIEW public.v_visit_water_balance IS
'Fred''s water model per completed visit of a truck with a water sensor (Moises since 2026-10-02): start + separated = peak; peak - put back = end (water_balance_closes, water_unexplained_gallons). Separated and put back are sums of every rise and fall during the visit (several cycles are common), so they are lower bounds at the sensor''s 10-minute pace; they are given for pumping visits (visit_kind volume) only. Put-back water counts for the visit whose trap it went into; brought_in_at_least / left_in_truck_at_least are bounds that need no rule about whose water is whose. On a dump visit the water tank''s fall is water moved into the sludge tank and dumped with the grease (Fred, 2026-10-16): water_moved_to_sludge_at_dump_gallons; it is not in the dump''s sludge offload (v_vehicle_dumps). Flags only: water_tank_full (separation capped), no_water_separated (the grease number holds water), the change after leaving. Built on v_visit_tank_service (same stops). Service role only; not for filings. Design: docs/superpowers/specs/2026-10-15-moises-water-balance-design.md.';
COMMENT ON COLUMN public.v_visit_water_balance.water_moved_to_sludge_at_dump_gallons IS
'Dump visits only: the water tank''s fall at the visit''s dump stop(s), water moved into the sludge tank and dumped with the grease (Fred, 2026-10-16). An upper bound (see v_vehicle_water_ledger.moved_to_sludge_tank_gallons).';

COMMENT ON VIEW public.v_vehicle_dumps IS
'Per live dump stop (dump-site properties only; a yard stop is never a dump): offload, confidence (owner rule 2026-10-12: low when the offload is below 10 % of capacity or the departure fill is 0.90 or more), collected since the previous dump, off-site drop, ratio, dump visit. offload_gallons is the sludge tank''s arrival minus departure: water moved from the water tank into the sludge tank during the dump stop and dumped with it is not in it (v_vehicle_water_ledger.moved_to_sludge_tank_gallons). collected_since_previous_dump_gallons counts client and other stops only, so any sludge rise at the yard is not in it and the ratio reads high: a load from David (Fred, 2026-10-16: David to Moises when David is full and Moises goes to the dump; Moises to David when David is empty and Moises needs space), water from Moises''s own water tank (1252 before dump 1253), or an unexplained rise (1215 before dump 1221). A move out of Moises of 300 gal or more sets cycle_offsite_drop and the ratio is NULL.';

DO $v$
DECLARE n int;
BEGIN
  -- the new names exist where the old ones were, and the old names are gone
  IF (SELECT ordinal_position FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'v_vehicle_water_ledger'
       AND column_name = 'moved_to_sludge_tank_gallons') IS NULL
     OR (SELECT ordinal_position FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'v_visit_water_balance'
       AND column_name = 'water_moved_to_sludge_at_dump_gallons') IS NULL
     OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                 AND column_name IN ('pumped_out_gallons', 'water_pumped_out_at_dump_gallons')
                 AND table_name IN ('v_vehicle_water_ledger', 'v_visit_water_balance'))
  THEN RAISE EXCEPTION 'VERIFY: the renames did not land'; END IF;
  -- privileges unchanged: service role reads, nobody else
  IF has_table_privilege('anon', 'public.v_vehicle_water_ledger', 'SELECT') OR has_table_privilege('authenticated', 'public.v_vehicle_water_ledger', 'SELECT')
     OR has_table_privilege('anon', 'public.v_visit_water_balance', 'SELECT') OR has_table_privilege('authenticated', 'public.v_visit_water_balance', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.v_vehicle_water_ledger', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.v_visit_water_balance', 'SELECT')
  THEN RAISE EXCEPTION 'VERIFY: a privilege moved'; END IF;
  -- the values did not move (positive controls): yard and dump stops still carry their falls under the new name, and
  -- visit 8725 still equals its dump stop 1213
  SELECT count(*) INTO n FROM public.v_vehicle_water_ledger l
   WHERE l.stop_kind IN ('yard', 'dump') AND l.moved_to_sludge_tank_gallons > 0;
  IF n < 4 THEN RAISE EXCEPTION 'VERIFY: only % yard or dump stops with water moved', n; END IF;
  IF (SELECT w.water_moved_to_sludge_at_dump_gallons FROM public.v_visit_water_balance w WHERE w.visit_id = 8725)
     IS DISTINCT FROM (SELECT sum(l.moved_to_sludge_tank_gallons) FROM public.v_vehicle_water_ledger l WHERE l.vehicle_stop_id = 1213)
  THEN RAISE EXCEPTION 'VERIFY: 8725 no longer equals its dump stop'; END IF;
  -- nothing that reads these views broke
  EXECUTE 'SET LOCAL ROLE service_role';
  PERFORM 1 FROM public.v_vehicle_water_ledger LIMIT 1;
  PERFORM 1 FROM public.v_visit_water_balance LIMIT 1;
  PERFORM 1 FROM public.v_vehicle_dumps LIMIT 1;
  EXECUTE 'RESET ROLE';
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
