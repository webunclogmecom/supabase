-- 2026-11-15_rollback_derm_missing_scan_words.sql
-- Undoes 2026-11-15_0745_derm_missing_scan_words.sql: derm.fn_sheet_missing_scan back to its body of 2026-10-27
-- byte for byte (the three sentences that name the DERM Tracker). VERIFY checks md5 c20a3f0a99d72968f3ecb0e3e16b1b2f
-- and the grants. Rehearsed inside the migration's rolled-back rehearsal (2026-11-15 ~07:42 ET).
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE OR REPLACE FUNCTION derm.fn_sheet_missing_scan(p_wm text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  SELECT CASE
    WHEN coalesce(cardinality(derm.ticket_page_images(p_wm)), 0) > 0 THEN NULL
    WHEN EXISTS (SELECT 1 FROM public.derm_manifests m
                  WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = p_wm AND m.deleted_at IS NULL
                    AND (m.derm_address_url IS NOT NULL OR coalesce(cardinality(m.derm_address_extra_urls), 0) > 0))
      THEN 'An address sheet photo was recorded in the DERM Tracker but its file is missing, so the upload most likely failed: upload it again there, or skip this sheet if there will never be one.'
    WHEN EXISTS (SELECT 1 FROM public.derm_manifests m
                  WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = p_wm AND m.deleted_at IS NULL
                    AND (m.derm_manifest_url IS NOT NULL OR coalesce(cardinality(m.derm_manifest_extra_urls), 0) > 0))
      THEN 'Only the manifest photo was uploaded in the DERM Tracker, not the address sheet photo: upload the address sheet there, or skip this sheet if there will never be one.'
    ELSE 'No address sheet photo was uploaded in the DERM Tracker: upload it there, or skip this sheet if there will never be one.'
  END;
$function$;

DO $v$
BEGIN
  IF md5(replace(pg_get_functiondef('derm.fn_sheet_missing_scan(text)'::regprocedure), chr(13), '')) <> 'c20a3f0a99d72968f3ecb0e3e16b1b2f'
    THEN RAISE EXCEPTION 'VERIFY: the old body is not back byte for byte'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'derm.fn_sheet_missing_scan(text)'::regprocedure)
     <> '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
    THEN RAISE EXCEPTION 'VERIFY: grants moved'; END IF;
END $v$;

COMMIT;
