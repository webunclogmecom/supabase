-- 2026-11-15_0745_derm_missing_scan_words.sql
--
-- WHAT
-- ----
-- Pick NN: the three sentences derm.fn_sheet_missing_scan writes for a stamp sheet with no scan name no app and say no
-- "there", so they are true on both hosts. Three anchored edits in one body (each asserted to match once), nothing else:
--   recorded, file gone : "An address sheet photo was recorded but its file is missing, so the upload most likely failed:
--                          add it again, or skip this sheet if there will never be one."
--   manifest photo only : "Only the manifest photo was uploaded, not the address sheet photo: add the address sheet photo,
--                          or skip this sheet if there will never be one."
--   no photo            : "No address sheet photo was uploaded: add it, or skip this sheet if there will never be one."
-- (each was "... in the DERM Tracker ... upload it there / upload the address sheet there / upload it again there ...").
-- Grants, owner, language, volatility and SECURITY DEFINER are unchanged (CREATE OR REPLACE).
--
-- WHY
-- ---
-- Fred, 2026-11-15 ~2:45 AM ET, answering the page of the built stamping screen: "go ahead with recomended" (NN: "reword
-- the three no-scan sentences the database writes so they name no app ... They change on the old Stamp Studio and in the
-- 11 AM Slack post too"; Building Apps/Ops Portal/docs/00-fred-picks-2026-11-12-manifests-and-stamping.md). The portal's
-- new stamping screen shows the server's sentence as it comes (rule E17) right above its own "Add the photo", where
-- "upload it there" was false. Plan: Building Apps/Ops Portal/docs/specs/2026-11-14-stamping-screen-build-plan.md, S6.
--
-- REACH (measured 2026-11-15 ~07:40 ET)
-- -----
-- Readers of the function: derm.v_stamp_sheets.missing_scan and derm.fn_stamp_open_sheets() (its "reason", first letter
-- lowercased, final period dropped). So the new words show on:
--   * the no-scan card of a sheet with no page: the old Stamp host (stamp.unclogme.app), the portal's /stamp/<n> today,
--     and the new stamping screen's NoScanCard (stage-d-stamp, not published yet);
--   * the 11 AM Slack post (edge function stamp-sheets-reminder, through fn_stamp_open_sheets), for a page-less sheet
--     that is not skipped.
-- Today ONE sheet has no scan, #487956 (ticket-487956), skipped (record only): its card reads the new sentence; it is
-- not in the 11 AM post (skipped), so the post's text does not change today. The bell (ops.portal_waiting) counts
-- sheets only; the Manifests rows (fn_manifest_row_states_core) name fn_stamp_open_sheets in a comment only.
-- Not changed: three other bodies that carry "in the DERM Tracker" (public.fn_notification_health_items,
-- public.log_blackout_health, derm.v_stamp_placement_health) are other sentences, not NN's.
-- The standing check scripts/checks/stamp_skip_sheet.mjs matches these sentences by their unchanged parts
-- ('No address sheet photo was uploaded%', 'Only the manifest photo%', '%its file is missing%').
--
-- REHEARSED (rolled back, 2026-11-15 ~07:42 ET, one statement ending in P0099):
--   nothing else moved: all 170 rows of derm.v_stamp_sheets identical, every column but missing_scan, old body against
--   new; missing_scan changed on ticket-487956 only (the one non-null); derm.fn_stamp_open_sheets() identical.
--   CONTROL on the OLD body: a [TEST] 112-YA sheet with no photo does NOT read the new sentence (it reads the old one).
--   NEW body, the same fixture: no photo, manifest photo only, address photo whose file is gone: each the new sentence
--   word for word; with a stored photo, no sentence.
--   The 11 AM line: #487956 un-skipped as Fred through derm.set_sheet_skipped reads "no address sheet photo was uploaded:
--   add it, or skip this sheet if there will never be one"; the fixture (test client only) stays out of the list.
--   Rollback rehearsed in the same statement: md5 back to c20a3f0a99d72968f3ecb0e3e16b1b2f, the old sentence back,
--   grants {postgres, authenticated, service_role} unchanged throughout.
-- Rollback: 2026-11-15_rollback_derm_missing_scan_words.sql (the old body byte for byte).

BEGIN;
SET LOCAL lock_timeout = '3s';

-- GUARD: the body this was generated from (md5 in the replace(..., chr(13), '') form, read 2026-11-15 06:55 ET)
DO $g$
BEGIN
  IF md5(replace(pg_get_functiondef('derm.fn_sheet_missing_scan(text)'::regprocedure), chr(13), '')) <> 'c20a3f0a99d72968f3ecb0e3e16b1b2f'
    THEN RAISE EXCEPTION 'GUARD: derm.fn_sheet_missing_scan changed since it was read'; END IF;
END $g$;

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
      THEN 'An address sheet photo was recorded but its file is missing, so the upload most likely failed: add it again, or skip this sheet if there will never be one.'
    WHEN EXISTS (SELECT 1 FROM public.derm_manifests m
                  WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = p_wm AND m.deleted_at IS NULL
                    AND (m.derm_manifest_url IS NOT NULL OR coalesce(cardinality(m.derm_manifest_extra_urls), 0) > 0))
      THEN 'Only the manifest photo was uploaded, not the address sheet photo: add the address sheet photo, or skip this sheet if there will never be one.'
    ELSE 'No address sheet photo was uploaded: add it, or skip this sheet if there will never be one.'
  END;
$function$;

-- VERIFY
DO $v$
BEGIN
  IF md5(replace(pg_get_functiondef('derm.fn_sheet_missing_scan(text)'::regprocedure), chr(13), '')) <> '38aa57249c90ea0a89abadc9929b55fe'
    THEN RAISE EXCEPTION 'VERIFY: the new body is not the rehearsed one'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'derm.fn_sheet_missing_scan(text)'::regprocedure)
     <> '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
    THEN RAISE EXCEPTION 'VERIFY: grants moved'; END IF;
  IF strpos(pg_get_functiondef('derm.fn_sheet_missing_scan(text)'::regprocedure), 'DERM Tracker') > 0
    THEN RAISE EXCEPTION 'VERIFY: a sentence still names the DERM Tracker'; END IF;
  IF (SELECT missing_scan FROM derm.v_stamp_sheets WHERE dump_folder = 'ticket-487956') IS DISTINCT FROM 'No address sheet photo was uploaded: add it, or skip this sheet if there will never be one.'
    THEN RAISE EXCEPTION 'VERIFY: ticket-487956 does not read the new sentence'; END IF;
END $v$;

COMMIT;
