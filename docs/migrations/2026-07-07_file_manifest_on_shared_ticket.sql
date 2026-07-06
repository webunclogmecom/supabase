-- 2026-07-07_file_manifest_on_shared_ticket.sql
-- Handoff from session 1 (DERM Tracker "Attach visit" UX): trg_aa_link_same_client
-- correctly REJECTS attaching another client's visit to a manifest — but on a
-- CO-LOADED ticket (multiple facilities pumped on one physical sheet) the right
-- resolution is a SECOND derm_manifests row for that client on the same white#,
-- inheriting the shared sheet's documents. The guard stays; this RPC is the
-- sanctioned workflow around it.
--
--   public.file_manifest_on_shared_ticket(p_white_manifest_number, p_client_id, p_visit_id)
--     RETURNS (manifest_id bigint, created boolean, linked boolean)
--
--   1. Finds-or-creates the (white#, client) live manifest row. On create it
--      INHERITS the shared-sheet docs from the best-documented live sibling on
--      the same white#: derm_manifest_url + derm_manifest_extra_urls (white
--      form), derm_address_url + derm_address_extra_urls (address sheet),
--      wwtp_receipt_document_path, disposal_facility_id, dump_ticket_date —
--      same physical sheet, same image URLs (same pattern as Stamp Studio's
--      derm.file_manifest_and_link; fn_derm_inherit_ticket_fields also fills
--      dump date/facility from unanimous siblings on the way in).
--      NOTE: derm_manifests has NO county column (county derives from the
--      client/property) and fog_manifest_url is per-client generated — neither
--      is inherited. service_date (on create) = the linked visit's visit_date.
--      If the ticket has NO live sibling, raises (nothing to co-load with —
--      file the first manifest through the normal flow).
--   2. Links p_visit_id (must belong to p_client_id -> passes
--      trg_aa_link_same_client; must not be linked to another white# ->
--      trg_ab_link_one_white enforces). ON CONFLICT DO NOTHING (idempotent).
--      trg_zz_card_from_link then materializes/resolves the Stamp card.
--   3. Audited via the standard triggers (app_source resolves from the caller's
--      origin — 'derm-tracker' when DERM Tracker calls it via PostgREST).
--   4. SECURITY DEFINER; EXECUTE granted to anon, authenticated, service_role
--      (revoked from PUBLIC), matching DERM Tracker's other public RPCs.
--
-- Verified on the Fred-confirmed co-loaded case #821239 (032-LG + 070-TCE dumped
-- together 4/12): filed 070-TCE's row inheriting m174's white form + address
-- sheet + dump 4/12, linked visits 1597 (4/9) + 1601 (4/10); second call reused
-- the row (created=false); no cross-client link; the pre-existing 070-TCE Stamp
-- card auto-resolved. Backup: backups/2026-07-07_821239_shared_ticket_backup.json.

BEGIN;

CREATE OR REPLACE FUNCTION public.file_manifest_on_shared_ticket(
  p_white_manifest_number text,
  p_client_id bigint,
  p_visit_id bigint,
  OUT manifest_id bigint,
  OUT created boolean,
  OUT linked boolean)
RETURNS record LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, derm AS $$
DECLARE
  v_wm text := btrim(p_white_manifest_number);
  v_vcid bigint; v_vdate date; v_vcode text; v_ccode text; v_rows int;
  sib public.derm_manifests%ROWTYPE;
BEGIN
  IF coalesce(v_wm, '') = '' THEN
    RAISE EXCEPTION 'p_white_manifest_number required';
  END IF;
  IF p_client_id IS NULL OR p_visit_id IS NULL THEN
    RAISE EXCEPTION 'p_client_id and p_visit_id required';
  END IF;

  SELECT v.client_id, v.visit_date INTO v_vcid, v_vdate
    FROM public.visits v WHERE v.id = p_visit_id AND v.deleted_at IS NULL;
  IF v_vcid IS NULL THEN
    RAISE EXCEPTION 'visit % not found or deleted', p_visit_id;
  END IF;
  IF v_vcid <> p_client_id THEN
    SELECT client_code INTO v_vcode FROM public.clients WHERE id = v_vcid;
    SELECT client_code INTO v_ccode FROM public.clients WHERE id = p_client_id;
    RAISE EXCEPTION 'visit % belongs to % — call this RPC with that client, not %',
      p_visit_id, coalesce(v_vcode, v_vcid::text), coalesce(v_ccode, p_client_id::text);
  END IF;

  -- find-or-create the (white#, client) row
  SELECT dm.id INTO manifest_id FROM public.derm_manifests dm
   WHERE dm.white_manifest_number = v_wm AND dm.client_id = p_client_id
     AND dm.deleted_at IS NULL
   ORDER BY dm.id LIMIT 1;
  created := manifest_id IS NULL;

  IF created THEN
    SELECT * INTO sib FROM public.derm_manifests dm
     WHERE dm.white_manifest_number = v_wm AND dm.deleted_at IS NULL
     ORDER BY (dm.derm_manifest_url IS NOT NULL) DESC,
              (dm.derm_address_url IS NOT NULL) DESC, dm.id
     LIMIT 1;
    IF sib.id IS NULL THEN
      RAISE EXCEPTION 'no manifest exists on ticket % to share docs from — file the first manifest through the normal flow', v_wm;
    END IF;

    INSERT INTO public.derm_manifests
      (white_manifest_number, client_id, service_date,
       derm_manifest_url, derm_manifest_extra_urls,
       derm_address_url, derm_address_extra_urls,
       wwtp_receipt_document_path, disposal_facility_id, dump_ticket_date)
    VALUES
      (v_wm, p_client_id, v_vdate,
       sib.derm_manifest_url, coalesce(sib.derm_manifest_extra_urls, '{}'::text[]),
       sib.derm_address_url,  coalesce(sib.derm_address_extra_urls,  '{}'::text[]),
       sib.wwtp_receipt_document_path, sib.disposal_facility_id, sib.dump_ticket_date)
    RETURNING id INTO manifest_id;
  END IF;

  INSERT INTO public.manifest_visits (manifest_id, visit_id)
    VALUES (manifest_id, p_visit_id) ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  linked := v_rows > 0;
END $$;

REVOKE ALL ON FUNCTION public.file_manifest_on_shared_ticket(text, bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.file_manifest_on_shared_ticket(text, bigint, bigint)
  TO anon, authenticated, service_role;

COMMIT;
