-- ============================================================================
-- ROLLBACK of 2026-10-16_1126_water_views_moved_to_sludge_labels (run it BEFORE 2026-10-15_rollback_tank_pipeline_v3.sql)
-- The two column names and the three comments go back to 2026-10-15_1950's; nothing else changed.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
ALTER VIEW public.v_vehicle_water_ledger RENAME COLUMN moved_to_sludge_tank_gallons TO pumped_out_gallons;
ALTER VIEW public.v_visit_water_balance RENAME COLUMN water_moved_to_sludge_at_dump_gallons TO water_pumped_out_at_dump_gallons;
COMMENT ON COLUMN public.v_vehicle_water_ledger.pumped_out_gallons IS NULL;
COMMENT ON COLUMN public.v_vehicle_water_ledger.refilled_gallons IS NULL;
COMMENT ON COLUMN public.v_visit_water_balance.water_pumped_out_at_dump_gallons IS NULL;
COMMENT ON VIEW public.v_vehicle_water_ledger IS
'Every stop of a truck with a water sensor, in order: the water tank at arrival, peak, low and departure, and what the rises and falls were. At a client: separated / put back (Fred''s model). At the yard (the office): refilled / pumped out (Fred: refills are "usually at the office"). At a dump: pumped out (Fred: "we only dump the grease"; measured 2026-10-16, the water tank still fell at 4 of 9 dumps, destination unknown). change_since_previous_stop_gallons closes the ledger between stops (measured: no separation on the road). Service role only.';
COMMENT ON VIEW public.v_visit_water_balance IS
'Fred''s water model per completed visit of a truck with a water sensor (Moises since 2026-10-02): start + separated = peak; peak - put back = end (water_balance_closes, water_unexplained_gallons). Separated and put back are sums of every rise and fall during the visit (several cycles are common), so they are lower bounds at the sensor''s 10-minute pace; they are given for pumping visits (visit_kind volume) only. Put-back water counts for the visit whose trap it went into; brought_in_at_least / left_in_truck_at_least are bounds that need no rule about whose water is whose. A dump visit only pumps water out. Flags only: water_tank_full (separation capped), no_water_separated (the grease number holds water), the change after leaving. Built on v_visit_tank_service (same stops). Service role only; not for filings. Design: docs/superpowers/specs/2026-10-15-moises-water-balance-design.md.';
COMMENT ON VIEW public.v_vehicle_dumps IS
'Per live dump stop: offload, confidence (owner rule 2026-10-12: low when the offload is below 10 % of capacity or the departure fill is 0.90 or more), collected since the previous dump, off-site drop, ratio, dump visit.';
DO $v$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'v_vehicle_water_ledger' AND column_name = 'pumped_out_gallons')
     OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'v_visit_water_balance' AND column_name = 'water_pumped_out_at_dump_gallons')
  THEN RAISE EXCEPTION 'rollback: the old names are not back'; END IF;
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
