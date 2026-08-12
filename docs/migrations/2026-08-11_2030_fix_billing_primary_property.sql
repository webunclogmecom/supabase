-- 2026-08-11_2030_fix_billing_primary_property.sql
--
-- WHAT: public.fn_fix_billing_primary_property(client_id) — if a client's PRIMARY property is the
--       synthetic billing row and a real Jobber-linked property exists, swap them.
--
-- WHY, measured on client 545 during step 3 of the create-client work (2026-08-11):
--
--   property 1026  is_primary=TRUE   link '...Client/149172455=_billing'   <- jobCreate REFUSES this
--   property 1027  is_primary=false  link '...Property/155878688=='        <- the real, job-capable one
--
--   `save-client-job` line 698 resolves a Jobber propertyId via gidFor('property', id) and returns
--   `property_not_in_jobber` when the link is not a real EncodedId. So a client in this shape cannot
--   be given a job through the property the UI is most likely to offer.
--
-- 🛑 IT IS AN ORDERING PROBLEM, NOT A BUG IN EITHER BRANCH, and that is why it cannot be fixed by
--    reordering. Both webhook-jobber branches assign primary on a "first property for this client
--    wins" rule, each guarded by `uq_properties_one_primary_per_client`:
--      - handleClient  (index.ts ~534) inserts the BILLING address property, primary if none exists
--      - handleProperty(index.ts ~1298) inserts the REAL property, forced non-primary if one exists
--    The create saga must replay CLIENT before PROPERTY, because handleProperty DEFERS with
--    entity_id 0 when the owning client is not canonical yet (index.ts ~1256). So CLIENT-first is
--    required, and CLIENT-first is exactly what makes the billing row primary. Neither order works;
--    the repair has to run after both.
--
-- ⚠ AND JOBBER CAUSES IT, NOT US. Step 3 sent NO billingAddress specifically to avoid this, and
--    Jobber BACK-FILLED billingAddress from properties[0] anyway (verified on the re-read). So the
--    "just don't send a billing address" mitigation in the original plan does not work and should
--    not be attempted again.
--
-- SCOPE: this function is TARGETED, one client at a time, and is called by the create-client saga.
--    It is deliberately NOT applied estate-wide here. 423 of 852 jobber property links are
--    billing-shaped and 76 of those rows are primary, so a blanket sweep would move primary on 76
--    live clients, which is a separate decision with its own blast radius. Filed, not fixed.
--
-- SAFETY: `uq_properties_one_primary_per_client` is a PARTIAL UNIQUE INDEX and is checked per row,
--    not deferred, so a single UPDATE flipping both rows can transiently hold two primaries and
--    fail depending on row order. This demotes first, then promotes, inside one transaction.
--
-- AUDIT (ADR 010): public.properties carries audit triggers, so both writes are logged.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_fix_billing_primary_property(p_client_id bigint)
RETURNS TABLE (demoted_property_id bigint, promoted_property_id bigint, action text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_bad  bigint;   -- current primary, but only if its link is synthetic
  v_good bigint;   -- a real Jobber-linked property on the same client
BEGIN
  -- the current primary, ONLY when its jobber link is the synthetic billing id
  SELECT p.id INTO v_bad
    FROM public.properties p
    JOIN public.entity_source_links l
      ON l.entity_type = 'property' AND l.source_system = 'jobber' AND l.entity_id = p.id
   WHERE p.client_id = p_client_id
     AND p.is_primary
     AND l.source_id LIKE '%\_billing'
   LIMIT 1;

  IF v_bad IS NULL THEN
    RETURN QUERY SELECT NULL::bigint, NULL::bigint, 'no_change: primary is not a billing row'::text;
    RETURN;
  END IF;

  -- the best real-linked candidate on the same client
  SELECT p.id INTO v_good
    FROM public.properties p
    JOIN public.entity_source_links l
      ON l.entity_type = 'property' AND l.source_system = 'jobber' AND l.entity_id = p.id
   WHERE p.client_id = p_client_id
     AND p.id <> v_bad
     AND l.source_id NOT LIKE '%\_billing'
   ORDER BY p.id
   LIMIT 1;

  IF v_good IS NULL THEN
    -- Leave it alone. A billing-only client has no job-capable property either way, and demoting
    -- the only primary would make it worse, not better.
    RETURN QUERY SELECT v_bad, NULL::bigint, 'no_change: no real-linked property to promote'::text;
    RETURN;
  END IF;

  -- demote THEN promote: the partial unique index is immediate, not deferrable
  UPDATE public.properties SET is_primary = false WHERE id = v_bad;
  UPDATE public.properties SET is_primary = true  WHERE id = v_good;

  RETURN QUERY SELECT v_bad, v_good, 'swapped'::text;
END;
$fn$;

REVOKE ALL ON FUNCTION public.fn_fix_billing_primary_property(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_fix_billing_primary_property(bigint) FROM anon;
REVOKE ALL ON FUNCTION public.fn_fix_billing_primary_property(bigint) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fn_fix_billing_primary_property(bigint) TO service_role;

DO $$
DECLARE n int;
BEGIN
  -- Supabase's ALTER DEFAULT PRIVILEGES makes new public functions authenticated-EXECUTABLE.
  -- Assert the revoke held rather than trusting the GRANT statements above.
  IF has_function_privilege('authenticated', 'public.fn_fix_billing_primary_property(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated can EXECUTE the repair fn; the REVOKE did not hold';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.fn_fix_billing_primary_property(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role cannot EXECUTE the repair fn';
  END IF;
  -- POSITIVE CONTROL: the same probe must return TRUE for something authenticated really can run.
  IF NOT has_function_privilege('authenticated', 'public.fn_visit_requires_derm(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'CONTROL FAILED: the privilege probe is not discriminating, so the assertions above prove nothing';
  END IF;

  -- the index this function is written around must actually exist
  SELECT count(*) INTO n FROM pg_indexes
   WHERE schemaname='public' AND indexname='uq_properties_one_primary_per_client';
  IF n <> 1 THEN RAISE EXCEPTION 'uq_properties_one_primary_per_client is missing; the demote-then-promote ordering is written for it'; END IF;

  RAISE NOTICE 'OK: fn_fix_billing_primary_property created, service_role only';
END $$;

COMMIT;
