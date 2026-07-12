-- 2026-07-12_anon_surface_harden.sql
-- FULL ANON-SURFACE HARDEN (Fred-routed via Building Apps). Continues Phase 3 + the 4-column harden.
-- Closes the legacy anon direct-DB write/exec surface left from when the apps ran as anon. All 4 staff
-- apps now run `authenticated` (Phase-2 login gates); Field Portal is anon + READ-ONLY via customer.*;
-- edge fns build their client with SERVICE_KEY; crons run as postgres/service_role.
--
-- VERIFIED before writing (backups/2026-07-12_anon_surface_audit_before.json + a 3-lens adversarial audit,
-- wf_d58a1a4b-c03, + follow-up catalog checks):
--   * authenticated has EXECUTE on every target RPC AND an authenticated RLS write policy + column/table
--     GRANT on every target table (incl. gdos: attacl {anon=w,authenticated=w} on all 4 cols) -> revoking
--     anon cannot break an authenticated caller.
--   * service_role keeps everything (edge/cron): explicit GRANT below + table-level relacl.
--   * KEEP anon on: customer.get_visit_by_slug_and_token + customer.{bigint_from_uuid,public_url,
--     thumbnail_url,uuid_from_bigint} (FP core read); pure no-write helpers derm.normalize_facility /
--     public.fn_line_item_requires_derm / public.fn_visit_requires_derm; public.fn_visit_in_jobber_scope.
--     (These last three are read-only/immutable — kept as defense-in-depth. NOTE on view semantics: a
--     function embedded in an OWNER-RIGHTS view executes as the view owner, so revoking anon EXECUTE does
--     NOT break anon SELECT of such a view — empirically confirmed for derm.v_stamp_sheets<-ticket_page_images,
--     which IS owner-rights, so revoking ticket_page_images below is safe. The KEEPs only matter if a view
--     is ever recreated WITH security_invoker=true; view-embedding was scanned for ALL 29 revoked fns and the
--     only hit was that one owner-rights case.)
--   * LEAVE untouched: trigger functions with anon EXECUTE (not PostgREST-callable; run as table owner) +
--     pgaudit_* (Supabase-owned); anon SELECT on tables/views (read surface = out of scope for this task).
--   * Default-priv trap handled: REVOKE ... FROM PUBLIC, anon on every function.
--
-- ⚠ CLOSES A REAL RESIDUAL PHASE-3 BYPASS: public.v_visits_live + public.visits_with_status are OWNER-RIGHTS
-- AUTO-UPDATABLE views over the Phase-3-locked `visits` table, with anon INSERT/UPDATE/DELETE grants. An anon
-- write through them executes against base `visits` as the view OWNER (postgres) -> would bypass the Phase-3
-- column lock. Revoking anon I/U/D on these views (section B) shuts that path.
--
-- Grant/policy-only change (no audited-table schema change -> ADR 010 N/A). Reversible: re-GRANT + re-CREATE
-- POLICY from the backup. Atomic (single DO block).

DO $$
DECLARE r record;
BEGIN
  ------------------------------------------------------------------------------------------------------
  -- (A) RPCs: SECDEF-volatile writes (HIGH — anon executed as OWNER, incl. zones_hard_delete) + read-only
  --     exposure RPCs + 3 volatile mutators the ledger missed (log_calendar_push_health,
  --     rederive_visits_derm_required, set_visit_derm_required). Revoke PUBLIC+anon EXECUTE; keep
  --     authenticated + service_role. Loop over pg_proc so all overloads get exact signatures.
  ------------------------------------------------------------------------------------------------------
  FOR r IN
    SELECT n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE (n.nspname, p.proname) IN (
      ('derm','add_client_card_and_link'),('derm','add_sheet_client'),('derm','clear_stamp_position'),
      ('derm','file_manifest_and_link'),('derm','link_row_visit'),('derm','remove_sheet_client'),
      ('derm','set_row_band'),('derm','set_row_reviewed'),('derm','set_sheet_completed'),
      ('derm','set_stamp_position'),('derm','unlink_row_visit'),('derm','audit_pack'),
      ('derm','audit_pack_client'),('derm','lookup_client_alias'),('derm','sheet_page_images'),
      ('derm','ticket_page_images'),
      ('public','edit_manifest'),('public','file_manifest'),('public','file_manifest_on_shared_ticket'),
      ('public','set_visit_manholes'),('public','zones_hard_delete'),('public','gen_short_id'),
      ('public','get_record_history'),('public','calendar_visit_drift_candidates'),
      ('public','visit_last_schedule_edit'),('public','log_calendar_push_health'),
      ('public','rederive_visits_derm_required'),('public','set_visit_derm_required'),
      ('ops','get_record_history')
    )
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM PUBLIC, anon', r.nspname, r.proname, r.args);
    EXECUTE format('GRANT  EXECUTE ON FUNCTION %I.%I(%s) TO authenticated, service_role', r.nspname, r.proname, r.args);
  END LOOP;

  ------------------------------------------------------------------------------------------------------
  -- (B) Base tables + views: revoke anon INSERT/UPDATE/DELETE ONLY (keep anon SELECT + authenticated +
  --     service_role). Live-write tables + RLS-off snapshot + 5 RLS-blocked tables + 13 views (incl. the
  --     two owner-rights auto-updatable Phase-3-bypass views). REVOKE of an absent privilege is a no-op.
  ------------------------------------------------------------------------------------------------------
  FOR r IN SELECT unnest AS rel FROM unnest(ARRAY[
      'derm_manifests','manifest_visits','shift_reviews','visit_reviews','photo_classifications','zones',
      'derm_manifest_number_proposals','derm_required_backfill_snapshot_2026_06_24',
      'client_locations','service_line_items','visit_locations','visit_recommendations','visit_team',
      'client_services_flat','clients_due_service','driver_inspection_status','inspections_with_review',
      'manifest_detail','manifest_pickable_visits','v_vehicle_telemetry_latest','v_visits_live',
      'visit_manhole_options','visits_recent','visits_with_review','visits_with_status','zones_with_usage'
    ])
  LOOP
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON public.%I FROM anon', r.rel);
  END LOOP;

  -- gdos: anon had only column-level UPDATE (authenticated holds a parallel column grant + shares the policy).
  EXECUTE 'REVOKE UPDATE (location_label, notes, property_id, status) ON public.gdos FROM anon';

  ------------------------------------------------------------------------------------------------------
  -- (C) Defense-in-depth: drop the now-inert ANON-ONLY write RLS policies so the RLS layer matches the grant
  --     layer (a future stray GRANT TO anon can't silently re-open writes). The parallel *_authn / *_auth_all
  --     policies keep the logged-in apps working. The SHARED authenticated,anon policies (zones_anon_insert/
  --     update, anon_update_gdo_labels) are LEFT INTACT — authenticated needs them; anon is already blocked by
  --     the grant revoke above.
  ------------------------------------------------------------------------------------------------------
  DROP POLICY IF EXISTS anon_insert_dmnp             ON public.derm_manifest_number_proposals;
  DROP POLICY IF EXISTS anon_update_dmnp             ON public.derm_manifest_number_proposals;
  DROP POLICY IF EXISTS anon_insert_derm_manifests   ON public.derm_manifests;
  DROP POLICY IF EXISTS anon_update_derm_manifests   ON public.derm_manifests;
  DROP POLICY IF EXISTS anon_insert_manifest_visits  ON public.manifest_visits;
  DROP POLICY IF EXISTS anon_delete_manifest_visits  ON public.manifest_visits;
  DROP POLICY IF EXISTS photo_classifications_anon_insert ON public.photo_classifications;
  DROP POLICY IF EXISTS photo_classifications_anon_update ON public.photo_classifications;
  DROP POLICY IF EXISTS shift_reviews_anon_insert    ON public.shift_reviews;
  DROP POLICY IF EXISTS shift_reviews_anon_update    ON public.shift_reviews;
  DROP POLICY IF EXISTS visit_reviews_anon_insert    ON public.visit_reviews;
  DROP POLICY IF EXISTS visit_reviews_anon_update    ON public.visit_reviews;
END $$;
