-- 2026-11-14_1315_derm_add_sheet_page.sql
--
-- WHAT
-- ----
-- New derm.add_sheet_page(p_dump_folder text, p_url text) RETURNS jsonb, SECURITY DEFINER: "Add a page" from the
-- stamping screen. In order:
--   1. hr.fn_check_app('stamp_studio', 'edit', 'add a page'), then derm._require_stamp_key().
--   2. The folder's ticket from its cards (a folder with no card is 'ticket-<number>', as derm.v_stamp_sheets maps it);
--      refused in plain words when the URL is not in the manifests bucket, is not .jpg/.jpeg/.png, has no stored object
--      (derm._img_etag NULL), or is a picture the ticket already has (same content, by etag, or the same URL).
--   3. Every live manifest of the ticket (locked first): derm_address_url when it has none (the "Add the photo" case
--      of a sheet with no scan), else one more derm_address_extra_urls entry.
--   4. The proof (manual rule MAN 294-296): the new URL is the LAST element of derm.ticket_page_images(ticket) and every
--      earlier element is unchanged; otherwise it raises and nothing is written.
--   5. A completed sheet is reopened (completed = false; trg_aa_reopen_pin records who). Returns {page, pages, reopened}.
-- Grants by name: authenticated + service_role, never PUBLIC or anon. Writes are audited on derm_manifests (and
-- stamp_sheet_status) with the caller's label (derm-stamp-studio from the Studio's client).
--
-- WHY
-- ---
-- Fred, 2026-11-12, "go ahead with all the recommendations" on the Manifests and stamping page, whose pick D
-- recommends: "Anyone with Edit on stamping. Add only, always as the last page. A completed sheet reopens." Its reason:
-- "A page added in the middle would shift the pages after it, and their rows and blackout would stop matching."
-- (`Building Apps/Ops Portal/docs/00-fred-picks-2026-11-12-manifests-and-stamping.md`; plan row S3 of
-- `Building Apps/Ops Portal/docs/specs/2026-11-14-stamping-screen-build-plan.md`.)
--
-- REACH
-- -----
-- Old Stamp host: none (it never calls it; its page tabs show a new page after a refresh, as after a DERM Tracker
-- upload). Nothing existing changes. What follows a call by itself: trg_zv_reconcile_stamp_pages (no stamp moves), the
-- sheet number read (zzz_request_sheet_number_ocr), the background measuring of a JPG page within about 10 minutes, the
-- live message on derm_manifests and stamp_sheet_status, and a skipped sheet back to Not started (the skip is derived).
--
-- APPLIED 2026-11-14 12:55 ET (the name is later than the apply time). REHEARSED (rolled back, ~12:54 ET, test ticket #111112, one REAL test picture uploaded beforehand to
-- manifests/derm/ticket-111112/page-2-<epoch ms>.jpg and removed with the service key afterwards):
--   as a Stamp editor: appended as page 2 (pages 1 -> 2), page 1 byte for byte, the stamp of card 3054 unmoved, the sheet
--   reopened with the editor named in reopened_by; controls in that state: the ticket's own page 1 picture again and the
--   same picture again, both refused "This sheet already has this picture."; a person made Stamp View for the
--   transaction refused with the access sentence; a URL with no stored object, a .pdf and another bucket refused in
--   words. City email for 2017 / 2020 the same before and after (already_sent / awaiting_manual_send, 7 sends).
--   Rollback (DROP FUNCTION) rehearsed in the same transaction.
-- Rollback: 2026-11-14_rollback_derm_add_sheet_page.sql. Standing check: scripts/checks/stamp_add_page.mjs.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
BEGIN
  IF to_regprocedure('derm.add_sheet_page(text, text)') IS NOT NULL THEN RAISE EXCEPTION 'GUARD: derm.add_sheet_page already exists'; END IF;
  IF md5(replace(pg_get_functiondef('derm.ticket_page_images(text)'::regprocedure), chr(13), '')) <> '1ac5ee5651412e456da54296c89f8e31'
    THEN RAISE EXCEPTION 'GUARD: derm.ticket_page_images changed since it was read'; END IF;
  IF md5(replace(pg_get_functiondef('derm._img_etag(text)'::regprocedure), chr(13), '')) <> '150b44ba3381df72b0bb023ac2d90ea4'
    THEN RAISE EXCEPTION 'GUARD: derm._img_etag changed since it was read'; END IF;
END $g$;

CREATE FUNCTION derm.add_sheet_page(p_dump_folder text, p_url text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
-- 2026-11-14 (Ops Portal Stage D, S3; Fred's pick D: "Anyone with Edit on stamping. Add only, always as the last page.
-- A completed sheet reopens."). Appends one uploaded picture as the LAST page of the sheet's ticket, proves that no
-- earlier page moved (stamp_page is a position in derm.ticket_page_images, so a page landing anywhere but last would
-- move every stamp after it), and reopens a completed sheet. Every refusal is a plain sentence; DETAIL carries blocker=.
DECLARE
  v_ticket  text;
  v_n       integer;
  v_etag    text;
  v_path    text := lower(split_part(coalesce(p_url, ''), '?', 1));
  v_before  text[];
  v_after   text[];
  v_live    integer;
  v_reopen  boolean := false;
BEGIN
  PERFORM hr.fn_check_app('stamp_studio', 'edit', 'add a page');
  PERFORM derm._require_stamp_key();

  -- the folder's ticket, from its cards (the Studio's own mapping); a folder with no card is 'ticket-<number>'
  SELECT min(r.white_manifest_number), count(DISTINCT r.white_manifest_number)
    INTO v_ticket, v_n
    FROM derm.address_row_map r
   WHERE r.dump_folder = p_dump_folder AND r.white_manifest_number IS NOT NULL;
  IF v_n > 1 THEN
    RAISE EXCEPTION 'This sheet belongs to more than one ticket, so a page cannot be added here. Add it in Edit manifest.'
      USING DETAIL = format('blocker=two_tickets folder=%s', p_dump_folder);
  END IF;
  IF v_ticket IS NULL AND p_dump_folder LIKE 'ticket-%' THEN
    v_ticket := substr(p_dump_folder, 8);
  END IF;
  IF v_ticket IS NULL OR v_ticket = '' THEN
    RAISE EXCEPTION 'This sheet could not be found. Reload the page.' USING DETAIL = format('blocker=no_ticket folder=%s', p_dump_folder);
  END IF;

  -- the picture: in the manifests bucket, a JPG or PNG, stored, and new to this ticket
  IF p_url IS NULL OR p_url NOT LIKE 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/%' THEN
    RAISE EXCEPTION 'The picture was not uploaded to the right place. Upload it again.' USING DETAIL = 'blocker=not_manifests_bucket';
  END IF;
  IF NOT (v_path LIKE '%.jpg' OR v_path LIKE '%.jpeg' OR v_path LIKE '%.png') THEN
    RAISE EXCEPTION 'Only a JPG or PNG picture can be added as a page.' USING DETAIL = 'blocker=bad_type';
  END IF;
  v_etag := derm._img_etag(p_url);
  IF v_etag IS NULL THEN
    RAISE EXCEPTION 'The picture did not finish uploading. Upload it again.' USING DETAIL = 'blocker=no_object';
  END IF;

  -- lock the ticket's live manifests before reading its pages, so two adds cannot interleave
  PERFORM 1 FROM public.derm_manifests dm
   WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = v_ticket AND dm.deleted_at IS NULL
     FOR UPDATE;
  GET DIAGNOSTICS v_live = ROW_COUNT;
  IF v_live = 0 THEN
    RAISE EXCEPTION 'This ticket has no manifest to add a page to.' USING DETAIL = format('blocker=no_manifest ticket=%s', v_ticket);
  END IF;

  v_before := coalesce(derm.ticket_page_images(v_ticket), '{}'::text[]);
  IF EXISTS (SELECT 1 FROM unnest(v_before) u WHERE derm._img_etag(u) = v_etag)
     OR EXISTS (SELECT 1 FROM public.derm_manifests dm
                 CROSS JOIN LATERAL unnest(array_remove(array_prepend(dm.derm_address_url, coalesce(dm.derm_address_extra_urls, '{}'::text[])), NULL)) u
                 WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = v_ticket AND dm.deleted_at IS NULL
                   AND (u = p_url OR derm._img_etag(u) = v_etag)) THEN
    RAISE EXCEPTION 'This sheet already has this picture.' USING DETAIL = format('blocker=duplicate_picture ticket=%s', v_ticket);
  END IF;

  -- every live manifest of the ticket: the address photo when it has none, else one more extra
  UPDATE public.derm_manifests dm
     SET derm_address_url = CASE WHEN dm.derm_address_url IS NULL THEN p_url ELSE dm.derm_address_url END,
         derm_address_extra_urls = CASE WHEN dm.derm_address_url IS NULL THEN dm.derm_address_extra_urls
                                        ELSE coalesce(dm.derm_address_extra_urls, '{}'::text[]) || p_url END
   WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = v_ticket AND dm.deleted_at IS NULL;

  -- the proof (manual rule MAN 294-296): the new picture is the LAST page and every earlier page is unchanged
  v_after := coalesce(derm.ticket_page_images(v_ticket), '{}'::text[]);
  IF cardinality(v_after) <> cardinality(v_before) + 1
     OR v_after[cardinality(v_after)] IS DISTINCT FROM p_url
     OR (cardinality(v_before) > 0 AND v_after[1:cardinality(v_before)] IS DISTINCT FROM v_before) THEN
    RAISE EXCEPTION 'The picture could not be added as the last page, so nothing was changed. Reload the sheet and try again.'
      USING DETAIL = format('blocker=page_order ticket=%s before=%s after=%s', v_ticket, cardinality(v_before), cardinality(v_after));
  END IF;

  -- a completed sheet reopens (the reopen pin records who)
  UPDATE derm.stamp_sheet_status SET completed = false WHERE dump_folder = p_dump_folder AND completed;
  v_reopen := FOUND;

  RETURN jsonb_build_object('page', cardinality(v_after), 'pages', cardinality(v_after), 'reopened', v_reopen);
END $function$;

REVOKE ALL ON FUNCTION derm.add_sheet_page(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION derm.add_sheet_page(text, text) TO authenticated, service_role;
COMMENT ON FUNCTION derm.add_sheet_page(text, text) IS 'Stamp Studio Add a page (pick D, 2026-11-14): appends one uploaded manifests-bucket JPG/PNG as the LAST page of the sheet''s ticket, proves no earlier page moved, reopens a completed sheet. Edit on Stamp Studio + the stamp key.';

DO $v$
BEGIN
  IF (SELECT array_agg(x ORDER BY x) FROM (SELECT coalesce(nullif(a.grantee, 0)::regrole::text, 'PUBLIC') || ':' || a.privilege_type AS x
        FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a WHERE p.oid = 'derm.add_sheet_page(text, text)'::regprocedure) acl)
     IS DISTINCT FROM ARRAY['authenticated:EXECUTE','postgres:EXECUTE','service_role:EXECUTE']
    THEN RAISE EXCEPTION 'VERIFY: derm.add_sheet_page grants are not authenticated + service_role'; END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'derm.add_sheet_page(text, text)'::regprocedure)
    THEN RAISE EXCEPTION 'VERIFY: not SECURITY DEFINER'; END IF;
END $v$;

COMMIT;
