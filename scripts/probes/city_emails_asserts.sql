-- Assertions appended to the migration INSIDE the same transaction, then rolled back.
-- Every one RAISES on failure, so a silent pass is impossible: the mgmt API returns the error.
-- 🛑 Each assertion carries a POSITIVE CONTROL where a zero could otherwise mean "nothing to see".

DO $assert$
DECLARE
  v_surfside_props   int;
  v_hallandale_props int;
  v_test_props       int;
  v_test_regs        int;
  v_a_id             bigint;
  v_b_id             bigint;
  v_b_before         text[];
  v_b_after          text[];
  v_a_after          text[];
  v_view_val         text[];
  v_vce_true         int;
  v_vce_total        int;
  v_mr_has           int;
BEGIN
  -- (A) BACKFILL. Controls: both counts must be > 0, or the backfill silently did nothing.
  SELECT count(*) INTO v_surfside_props FROM public.properties
   WHERE deleted_at IS NULL AND lower(btrim(city))='surfside' AND cardinality(city_emails) > 0;
  SELECT count(*) INTO v_hallandale_props FROM public.properties
   WHERE deleted_at IS NULL AND lower(btrim(city))='hallandale beach' AND cardinality(city_emails) > 0;
  IF v_surfside_props = 0 OR v_hallandale_props = 0 THEN
    RAISE EXCEPTION 'A FAILED: backfill empty (surfside=%, hallandale=%)', v_surfside_props, v_hallandale_props;
  END IF;
  RAISE NOTICE 'A ok: surfside=% hallandale=% properties carry city_emails', v_surfside_props, v_hallandale_props;

  -- (B) THE TEST ADDRESS IS GONE from both stores.
  SELECT count(*) INTO v_test_props FROM public.properties
   WHERE EXISTS (SELECT 1 FROM unnest(city_emails) e WHERE lower(e) LIKE '%ayache%' OR lower(e) LIKE '%fredzerpa%');
  SELECT count(*) INTO v_test_regs FROM public.municipality_regulators
   WHERE EXISTS (SELECT 1 FROM unnest(emails) e WHERE lower(e) LIKE '%ayache%' OR lower(e) LIKE '%fredzerpa%');
  IF v_test_props <> 0 OR v_test_regs <> 0 THEN
    RAISE EXCEPTION 'B FAILED: test address still present (properties=%, regulators=%)', v_test_props, v_test_regs;
  END IF;
  RAISE NOTICE 'B ok: no test address in properties or municipality_regulators';

  -- (C) THE VIEW READS THE PROPERTY. Pick a backfilled Surfside property.
  SELECT id INTO v_a_id FROM public.properties
   WHERE deleted_at IS NULL AND lower(btrim(city))='surfside' AND cardinality(city_emails) > 0
   ORDER BY id LIMIT 1;
  SELECT city_emails INTO v_view_val FROM client.properties WHERE id = v_a_id;
  IF v_view_val IS NULL OR cardinality(v_view_val) = 0 THEN
    RAISE EXCEPTION 'C FAILED: client.properties.city_emails empty for property %', v_a_id;
  END IF;
  RAISE NOTICE 'C ok: client.properties exposes % for property %', v_view_val, v_a_id;

  -- (D) 🛑 THE WHOLE POINT. Writing property A must not touch property B in the SAME city.
  --     Control: A and B must both exist and start EQUAL, or "B did not change" proves nothing.
  SELECT id INTO v_b_id FROM public.properties
   WHERE deleted_at IS NULL AND lower(btrim(city))='surfside' AND id <> v_a_id
   ORDER BY id LIMIT 1;
  IF v_b_id IS NULL THEN
    RAISE EXCEPTION 'D FAILED (control): no second Surfside property to compare against';
  END IF;
  SELECT city_emails INTO v_b_before FROM public.properties WHERE id = v_b_id;
  IF v_b_before IS DISTINCT FROM v_view_val THEN
    RAISE EXCEPTION 'D control weak: A and B did not start equal (A=%, B=%)', v_view_val, v_b_before;
  END IF;

  PERFORM client.update_property_city_email(v_a_id, ARRAY['solo@example.gov']);

  SELECT city_emails INTO v_a_after FROM public.properties WHERE id = v_a_id;
  SELECT city_emails INTO v_b_after FROM public.properties WHERE id = v_b_id;
  IF v_a_after <> ARRAY['solo@example.gov'] THEN
    RAISE EXCEPTION 'D FAILED: property A did not take the new value (got %)', v_a_after;
  END IF;
  IF v_b_after IS DISTINCT FROM v_b_before THEN
    RAISE EXCEPTION 'D FAILED: property B CHANGED from % to % - still not per-property', v_b_before, v_b_after;
  END IF;
  RAISE NOTICE 'D ok: A=% changed, sibling B=% unchanged (%)', v_a_id, v_b_id, v_b_after;

  -- (D2) MUTATION TEST of assertion D: if the RPC were still city-wide, D must FAIL.
  --      Simulate the old behaviour and prove the check catches it.
  UPDATE public.properties SET city_emails = ARRAY['citywide@example.gov']
   WHERE deleted_at IS NULL AND lower(btrim(city))='surfside';
  SELECT city_emails INTO v_b_after FROM public.properties WHERE id = v_b_id;
  IF v_b_after IS NOT DISTINCT FROM v_b_before THEN
    RAISE EXCEPTION 'D2 FAILED: the mutation did not move B, so assertion D cannot detect a city-wide write';
  END IF;
  RAISE NOTICE 'D2 ok: a city-wide write DOES move B, so D is a real test';
  -- put it back so the later assertions read the migrated state, not the mutation
  UPDATE public.properties SET city_emails = v_b_before
   WHERE deleted_at IS NULL AND lower(btrim(city))='surfside';

  -- (E) DOWNSTREAM VIEWS still resolve. Controls: totals > 0 as well as the true-count.
  SELECT count(*) FILTER (WHERE city_email_on_file), count(*)
    INTO v_vce_true, v_vce_total FROM public.v_visit_city_email;
  IF v_vce_total = 0 THEN
    RAISE EXCEPTION 'E FAILED (control): v_visit_city_email returned no rows at all';
  END IF;
  IF v_vce_true = 0 THEN
    RAISE EXCEPTION 'E FAILED: no visit resolves a city email after the move (total=%)', v_vce_total;
  END IF;
  RAISE NOTICE 'E ok: v_visit_city_email % of % visits have a city email', v_vce_true, v_vce_total;

  SELECT count(*) INTO v_mr_has FROM derm.manifest_recipients WHERE has_city_email;
  RAISE NOTICE 'F: derm.manifest_recipients rows with has_city_email = %', v_mr_has;

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END
$assert$;

-- final readback so the tool output carries something inspectable
SELECT (SELECT count(*) FROM public.properties WHERE cardinality(city_emails) > 0)::int AS props_with_city_email,
       (SELECT count(DISTINCT city) FROM public.properties WHERE cardinality(city_emails) > 0)::int AS cities_covered,
       (SELECT count(*) FROM public.municipality_regulators WHERE status='ACTIVE')::int AS active_regulator_rows;

ROLLBACK;
