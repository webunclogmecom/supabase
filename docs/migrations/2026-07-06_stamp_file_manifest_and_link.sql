-- 2026-07-06_stamp_file_manifest_and_link.sql
-- Stamp Studio "+ Add client" modal, no-manifest case (Fred chose: file the
-- manifest + link in one click). When an added client has NO manifest on the
-- sheet (it's on the dump run but was never filed), clicking a visit should
-- create the manifest AND link the visit — visible in Stamp / DERM / everywhere.
--
-- Fred's insight: the manifest doesn't start incomplete — a single-load dump
-- shares ONE white form / WWTP receipt / address sheet across all its client
-- stops (same white_manifest_number), so the new manifest INHERITS those shared
-- docs from a sibling on the same ticket. (The existing BEFORE-INSERT trigger
-- fn_derm_inherit_ticket_fields already inherits dump_ticket_date + facility
-- from unanimous siblings; this RPC additionally inherits the document URLs,
-- which that trigger does not.)
--
--   derm.file_manifest_and_link(p_row_id, p_visit_id) RETURNS bigint (manifest id)
--     - x-stamp-key gated (derm._require_stamp_key); attributed derm-stamp-studio.
--     - Same-client guard (visit's client must equal the row's matched client).
--     - Idempotent: reuses an existing (ticket, client) manifest if present.
--     - Creates the manifest inheriting shared docs from a ticket sibling;
--       service_date = the linked visit's date; points the card
--       (address_row_map.matched_manifest_id) at it; links the visit.
--     - Audited (derm_manifests + manifest_visits both fire audit.log_change).
--
-- @Supabase (session 1): this is a NEW writer of public.derm_manifests +
-- manifest_visits from Stamp Studio. Additive, idempotent, inherits docs so the
-- created manifest is as complete/consistent as its ticket siblings. If a ticket
-- has no doc'd sibling, docs stay NULL (best effort) and DERM Tracker flags it as
-- needing docs — same as any freshly-filed manifest.

BEGIN;

CREATE OR REPLACE FUNCTION derm.file_manifest_and_link(p_row_id bigint, p_visit_id bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
DECLARE
  v_wm text; v_cid bigint; v_vcid bigint; v_vdate date; v_mid bigint;
  v_sib public.derm_manifests%ROWTYPE;
BEGIN
  PERFORM derm._require_stamp_key();

  SELECT white_manifest_number, matched_client_id INTO v_wm, v_cid
    FROM derm.address_row_map WHERE id = p_row_id;
  IF v_wm IS NULL THEN
    RAISE EXCEPTION 'row % has no manifest number', p_row_id;
  END IF;
  IF v_cid IS NULL THEN
    RAISE EXCEPTION 'row % has no matched client — add a roster client first', p_row_id;
  END IF;

  SELECT client_id, visit_date INTO v_vcid, v_vdate
    FROM public.visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF v_vcid IS NULL THEN
    RAISE EXCEPTION 'visit % not found or deleted', p_visit_id;
  END IF;
  IF v_vcid <> v_cid THEN
    RAISE EXCEPTION 'visit % belongs to a different client than row %', p_visit_id, p_row_id;
  END IF;

  -- idempotent: reuse an existing (ticket, client) manifest if one exists
  SELECT id INTO v_mid FROM public.derm_manifests
    WHERE white_manifest_number = v_wm AND client_id = v_cid AND deleted_at IS NULL
    ORDER BY id LIMIT 1;

  IF v_mid IS NULL THEN
    -- inherit shared docs from a ticket sibling (a single-load dump shares them)
    SELECT * INTO v_sib FROM public.derm_manifests
      WHERE white_manifest_number = v_wm AND deleted_at IS NULL AND derm_manifest_url IS NOT NULL
      ORDER BY id LIMIT 1;

    INSERT INTO public.derm_manifests
      (white_manifest_number, client_id, service_date,
       derm_manifest_url, derm_address_url, derm_address_extra_urls,
       wwtp_receipt_document_path, disposal_facility_id, dump_ticket_date)
    VALUES
      (v_wm, v_cid, v_vdate,
       v_sib.derm_manifest_url, v_sib.derm_address_url, coalesce(v_sib.derm_address_extra_urls, '{}'::text[]),
       v_sib.wwtp_receipt_document_path, v_sib.disposal_facility_id, v_sib.dump_ticket_date)
    RETURNING id INTO v_mid;

    UPDATE derm.address_row_map SET matched_manifest_id = v_mid WHERE id = p_row_id;
  END IF;

  INSERT INTO public.manifest_visits (manifest_id, visit_id)
    VALUES (v_mid, p_visit_id) ON CONFLICT DO NOTHING;

  RETURN v_mid;
END $$;
GRANT EXECUTE ON FUNCTION derm.file_manifest_and_link(bigint, bigint) TO anon, authenticated;

COMMIT;
