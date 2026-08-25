-- 2026-08-25_1525_grant_service_role_customer_work_orders.sql
--
-- WHY
-- ---
-- Fred, 2026-08-25: "if the email being send already have the DERM Manifests on it, then we
-- need to remove the note ... because it would make no sense otherwise." The note is the
-- "The DERM Manifest and Transporter Manifest will be sent in a separate email" block in
-- send-visit-photos-email.
--
-- To drop that note only when the attached report ACTUALLY carries the manifests, the edge
-- function reads customer.work_orders (derm_manifest_url / wwtp_receipt_url) -- the exact
-- source the Field Portal report renders those blocks from.
--
-- 🛑 IT COULD NOT. The function runs as service_role, and:
--     customer.work_orders relacl = postgres=arwdDxtm/postgres | authenticated=r/postgres
-- service_role holds NO grant. The lookup failed, the catch swallowed it, hasDermDocs stayed
-- false, and the note was still printed on a report that already contained the manifests.
-- Caught because a Gmail search still matched the note text after the change shipped.
--
-- ⚠ WHY KEYING ON THE VIEW MATTERS, AND WHY manifest_visits IS THE WRONG SOURCE.
-- Measured: 700 completed visits carry a manifest_visits link, but 53 of them have a NULL
-- customer.work_orders.derm_manifest_url because the FP blackout pipeline has not published a
-- redacted document for them yet. Keying on the LINK would strip the note from those 53 while
-- the report still shows no manifest, leaving the client with neither the documents nor the
-- promise of them. The view is the only source that matches what is in the PDF.
--
-- WHY THIS GRANT IS SAFE (measured, not assumed)
-- ----------------------------------------------
-- service_role can ALREADY read every table the view derives from:
--     derm.redacted_manifest_docs   true
--     derm.receipt_doc_class        true
--     public.visits                 true
--     public.manifest_visits        true
--     public.derm_manifests         true
-- So this exposes no data service_role could not already assemble. It is a convenience grant
-- on a derived view, not a widening of reach.
--
-- ⚠ THE EXISTING GRANTS ARE INCONSISTENT, WHICH IS THE TELL THAT THIS IS DRIFT, NOT POLICY.
-- service_role can read customer.clients, customer.permits and customer.client_access_photos,
-- but NOT customer.inspection_items, scheduled_visits, gdo_reports, recommendations,
-- work_orders or wo_photos. Nothing distinguishes those two sets. This is the
-- ALTER DEFAULT PRIVILEGES drift CLAUDE.md warns about, landing in the restrictive direction
-- for once.
--
-- 🛑 ONLY work_orders IS GRANTED HERE. The other five stay as they are: nothing needs them,
-- and widening past the need is how a grant sweep becomes unreviewable. If a later function
-- needs one, grant it then, with its own reason.
--
-- ⚠ anon IS NOT TOUCHED and must never be: anon reads nothing in customer.* (measured
-- 2026-08-10, and re-asserted in the VERIFY below).
--
-- RULE 8 (audit trail): N/A. This changes no table and adds no column; it is a GRANT on an
-- existing view. Nothing to opt in or out of.

BEGIN;

GRANT SELECT ON customer.work_orders TO service_role;

-- ---------------------------------------------------------------------------
-- VERIFY. Asserts the fix AND that nothing else moved.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_service   boolean;
  v_authn     boolean;
  v_anon      boolean;
  v_other_anon integer;
BEGIN
  SELECT has_table_privilege('service_role','customer.work_orders','SELECT') INTO v_service;
  SELECT has_table_privilege('authenticated','customer.work_orders','SELECT') INTO v_authn;
  SELECT has_table_privilege('anon','customer.work_orders','SELECT')          INTO v_anon;

  IF NOT v_service THEN
    RAISE EXCEPTION 'VERIFY failed: service_role still cannot SELECT customer.work_orders';
  END IF;

  -- The point of the change is ONE new grant. authenticated must be unchanged (the Field
  -- Portal reads this view as authenticated), and anon must remain shut out.
  IF NOT v_authn THEN
    RAISE EXCEPTION 'VERIFY failed: authenticated LOST its read on customer.work_orders';
  END IF;
  IF v_anon THEN
    RAISE EXCEPTION 'VERIFY failed: anon can now read customer.work_orders';
  END IF;

  -- Control: anon must still hold nothing anywhere in customer.*, so this migration cannot
  -- be read as having quietly opened that schema.
  SELECT count(*) INTO v_other_anon
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'customer' AND c.relkind = 'v'
     AND has_table_privilege('anon', c.oid, 'SELECT');
  IF v_other_anon <> 0 THEN
    RAISE EXCEPTION 'VERIFY failed: anon can read % customer.* view(s)', v_other_anon;
  END IF;

  RAISE NOTICE 'VERIFY ok: service_role=SELECT, authenticated unchanged, anon shut out (0 customer.* views)';
END $$;

COMMIT;
