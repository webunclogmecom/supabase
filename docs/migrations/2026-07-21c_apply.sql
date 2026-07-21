-- Companion of 2026-07-21c: full re-statement of derm.record_generated_address_sheet
-- with the derm_address_no mirror UPDATE (see the 21c header for rationale).

CREATE OR REPLACE FUNCTION derm.record_generated_address_sheet(p_sheet_no bigint, p_bucket text, p_path text, p_manifest_ids bigint[])
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_sheet_id bigint; v_bad text; v_other bigint;
BEGIN
  IF p_sheet_no IS NULL OR p_bucket IS NULL OR btrim(coalesce(p_path,'')) = ''
     OR p_manifest_ids IS NULL OR array_length(p_manifest_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'record_generated_address_sheet: all arguments are required (sheet=%, bucket=%, path=%)',
      p_sheet_no, p_bucket, p_path;
  END IF;

  -- GATE 1: refuse tickets carrying handwritten evidence. A photo always refuses. Cards refuse
  -- only when the ticket is NOT already this sheet (no live sibling linked to p_sheet_no).
  SELECT string_agg(DISTINCT k, ', ') INTO v_bad
  FROM (
    SELECT COALESCE(m.white_manifest_number, m.yellow_ticket_number) AS k
      FROM public.derm_manifests m
     WHERE m.id = ANY (p_manifest_ids) AND m.deleted_at IS NULL
       AND (
         m.derm_address_url IS NOT NULL
         OR (
           EXISTS (SELECT 1 FROM derm.address_row_map a
                    WHERE a.white_manifest_number = COALESCE(m.white_manifest_number, m.yellow_ticket_number))
           AND NOT EXISTS (
             SELECT 1
               FROM public.derm_manifests m2
               JOIN derm.address_sheet_manifests l2 ON l2.manifest_id = m2.id
               JOIN derm.address_sheets s2 ON s2.id = l2.sheet_id AND s2.deleted_at IS NULL
              WHERE COALESCE(m2.white_manifest_number, m2.yellow_ticket_number)
                    = COALESCE(m.white_manifest_number, m.yellow_ticket_number)
                AND m2.deleted_at IS NULL
                AND s2.sheet_no = p_sheet_no
           )
         )
       )
  ) q;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'refusing: ticket(s) % already carry handwritten evidence (uploaded sheet photo or Stamp Studio card)', v_bad;
  END IF;

  -- GATE 2 unchanged: never bind a manifest to a second sheet.
  SELECT s.sheet_no INTO v_other
    FROM derm.address_sheet_manifests l
    JOIN derm.address_sheets s ON s.id = l.sheet_id AND s.deleted_at IS NULL
   WHERE l.manifest_id = ANY (p_manifest_ids) AND s.sheet_no <> p_sheet_no
   LIMIT 1;
  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION 'refusing to renumber: one of these manifests already belongs to sheet %', v_other;
  END IF;

  INSERT INTO derm.address_sheets (sheet_no, pdf_bucket, pdf_path)
  VALUES (p_sheet_no, p_bucket, p_path)
  ON CONFLICT (sheet_no) WHERE deleted_at IS NULL
  DO UPDATE SET pdf_bucket = EXCLUDED.pdf_bucket,
                pdf_path   = EXCLUDED.pdf_path,
                last_generated_at = now()
  RETURNING id INTO v_sheet_id;

  INSERT INTO derm.address_sheet_manifests (sheet_id, manifest_id)
  SELECT v_sheet_id, unnest(p_manifest_ids)
  ON CONFLICT DO NOTHING;

  -- 2026-07-21c: maintain the derm_address_no mirror BY MANIFEST ID (never by
  -- ticket number -- that keying caused the 819788 ghost). Apps' base-table
  -- reads (DERM Tracker /manifests slim query) surface the sheet number from
  -- this column; source of truth stays the provenance tables above.
  UPDATE public.derm_manifests m
     SET derm_address_no = p_sheet_no
   WHERE m.id = ANY (p_manifest_ids)
     AND m.derm_address_no IS DISTINCT FROM p_sheet_no;

  RETURN v_sheet_id;
END $function$
;
