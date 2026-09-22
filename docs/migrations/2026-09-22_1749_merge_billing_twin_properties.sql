-- 2026-09-22_1749_merge_billing_twin_properties.sql
--
-- WHY. Fred, after seeing 192-FRK render two properties at one address: "we need to make sure we only
-- have one property shown ... I don't need a second property that cannot be seen so I don't see the
-- reason of having that second property of the billing." Approved: "1. go ahead", and for the ones
-- whose billing address is genuinely different, "if they're genuinely then keep them".
--
-- WHAT THE SECOND ROW IS. public.webhook-jobber handleClient creates a `properties` row from the
-- Jobber CLIENT's billingAddress. Jobber models a billing address on the Client object, so there is
-- no Property gid and the link is the synthetic `<client_gid>_billing`. The code comment calls that
-- branch "THE DOMINANT PROPERTY CREATOR". It is NOT from Airtable.
--
-- NOTHING READS IT. Every writer and reader was traced 2026-09-22: written only by webhook-jobber and
-- the old scripts/populate/populate.js; excluded everywhere else (create-client selects
-- is_billing=false, save-client-property refuses one, jobber-push-custom-field skips it,
-- client.global_search dedupes it and labels it "Billing address", Client App rule 2j filters every
-- picker). No consumer reads a billing property's ADDRESS for any purpose; Jobber holds it and Jobber
-- invoices from it.
--
-- WHAT THIS DOES. For each billing property that has a SAME-ADDRESS service twin on the same client
-- (454 of 471), re-point its work onto the twin and soft-delete it:
--   87 visits, 7 jobs, 24 gdos, 2 client_locations move. (The remainder of the 93/29/3 totals sit on
--   the 17 KEPT rows and are deliberately untouched.)
-- The 17 billing rows whose address matches no service property are KEPT on Fred's instruction: for
-- those, the billing address is genuinely a second address. 3 clients whose ONLY property is a billing
-- row fall inside that kept group, so no client is left with zero properties.
--
-- PICK RULE when a client has several same-address service rows: most jobs, then most visits, then
-- lowest id. Only ONE billing row is ambiguous under this (242-WYN, 5 units at one street address) and
-- it carries no visits, no jobs and no permits, so nothing can be misattributed.
--
-- SAFETY, measured before writing this file:
--   * trg_push_visit_update does NOT list property_id in its WHEN clause (it lists visit_date,
--     start_at, end_at, title, notes, job_id, service_line_item_id, line_items_rev, team_rev,
--     deleted_at, visit_status), so moving a visit's property pushes NOTHING to Jobber.
--   * fn_mark_visit_sync_pending likewise ignores property_id, so no visit is marked pending.
--   * trg_properties_enqueue_outbound fires only on grease_trap_size_gallons / lock_box_key, neither
--     of which this touches.
--   * uq_properties_one_primary_per_client is partial on (is_primary AND deleted_at IS NULL), so the
--     soft-delete frees the primary slot before the twin claims it. That is why the order below is
--     soft-delete FIRST, then promote.
--
-- RULE 8 (audit): OPT-IN, already in place on all four tables (audit_properties, audit_visits,
-- audit_jobs, audit_gdos, audit_client_locations), so every row moved or retired is recoverable from
-- audit.logs. JSON backup of the map, the 471 billing rows and every moving id:
-- backups/2026-09-22_billing_property_merge_before.json.
--
-- RULE 6 (never hard-delete): this is a SOFT delete (deleted_at), matching the 2026-08-21 property
-- soft-delete design. Nothing is removed.
--
-- ONE STATEMENT ON PURPOSE. A DO block is one transaction, so a failure anywhere rolls the whole
-- merge back. Do not split it into separate statements.

DO $$
DECLARE
  v_moved_visits int; v_moved_jobs int; v_moved_gdos int; v_moved_locs int;
  v_retired int; v_promoted int;
BEGIN
  CREATE TEMP TABLE _merge_map ON COMMIT DROP AS
  WITH p AS (
    SELECT id, client_id, COALESCE(is_billing,false) AS bill,
           lower(btrim(COALESCE(address,''))) AS addr, is_primary
    FROM public.properties WHERE deleted_at IS NULL
  ), cand AS (
    SELECT b.id AS billing_id, b.client_id, b.is_primary AS billing_was_primary, s.id AS keep_id,
           (SELECT count(*) FROM public.jobs j   WHERE j.property_id = s.id) AS jobs,
           (SELECT count(*) FROM public.visits v WHERE v.property_id = s.id) AS visits
    FROM p b
    JOIN p s ON s.client_id = b.client_id AND NOT s.bill AND s.addr = b.addr
    WHERE b.bill AND b.addr <> ''
  ), ranked AS (
    SELECT *, row_number() OVER (PARTITION BY billing_id
                                 ORDER BY jobs DESC, visits DESC, keep_id ASC) AS rn
    FROM cand
  )
  SELECT billing_id, client_id, keep_id, billing_was_primary FROM ranked WHERE rn = 1;

  UPDATE public.visits v SET property_id = m.keep_id
    FROM _merge_map m WHERE v.property_id = m.billing_id;
  GET DIAGNOSTICS v_moved_visits = ROW_COUNT;

  UPDATE public.jobs j SET property_id = m.keep_id
    FROM _merge_map m WHERE j.property_id = m.billing_id;
  GET DIAGNOSTICS v_moved_jobs = ROW_COUNT;

  UPDATE public.gdos g SET property_id = m.keep_id
    FROM _merge_map m WHERE g.property_id = m.billing_id;
  GET DIAGNOSTICS v_moved_gdos = ROW_COUNT;

  UPDATE public.client_locations cl SET property_id = m.keep_id
    FROM _merge_map m WHERE cl.property_id = m.billing_id;
  GET DIAGNOSTICS v_moved_locs = ROW_COUNT;

  -- Soft-delete FIRST: the partial unique index frees the primary slot on this update.
  UPDATE public.properties p SET deleted_at = now(), is_primary = false
    FROM _merge_map m WHERE p.id = m.billing_id AND p.deleted_at IS NULL;
  GET DIAGNOSTICS v_retired = ROW_COUNT;

  -- Then promote the surviving twin, but only where the retired row held the flag and the client has
  -- no live primary left.
  UPDATE public.properties p SET is_primary = true
   WHERE p.id IN (
     SELECT DISTINCT m.keep_id FROM _merge_map m
      WHERE m.billing_was_primary
        AND NOT EXISTS (SELECT 1 FROM public.properties q
                         WHERE q.client_id = m.client_id AND q.is_primary AND q.deleted_at IS NULL)
   );
  GET DIAGNOSTICS v_promoted = ROW_COUNT;

  RAISE NOTICE 'visits=% jobs=% gdos=% locs=% retired=% promoted=%',
    v_moved_visits, v_moved_jobs, v_moved_gdos, v_moved_locs, v_retired, v_promoted;

  IF v_retired <> 454 THEN
    RAISE EXCEPTION 'expected to retire 454 billing twins, retired % - rolling back', v_retired;
  END IF;
END $$;
