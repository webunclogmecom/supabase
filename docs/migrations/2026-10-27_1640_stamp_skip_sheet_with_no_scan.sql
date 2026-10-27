-- ============================================================================
-- 2026-10-27_1640_stamp_skip_sheet_with_no_scan
-- Stamp Studio: a sheet with no scan (0 pages) can be SKIPPED, with a reason, by a person, reversibly.
-- ============================================================================
-- THE ASK
--   Fred, Slack DM to Viktor, 2026-10-26: "put a button in the Stamp App for when a visit has no manifest filed up
--   (0 pages) it shows in the Stamp App" ... "like this manifest 487956 that has no image but is a pumping one. so it
--   has a manifest number, but no image for some reason" ... "it's for marking them as complete or skipping them, for
--   the AI to check what i mean and think what is the best practice for this". Trello EizZ2IuY (card #144).
--   2026-10-27 Fred: "read it, understand it, and design a plan for it and build it, also smoke test it".
-- THE FACTS (2026-10-27 16:30 ET)
--   163 sheets, 162 completed, 1 open: ticket-487956, the only sheet with 0 pages. Manifest 2090, 041-MB, service
--   2025-03-28 (visit 8889, Mar 25 2025), filed by Yannick in the DERM Tracker on 2026-10-26 11:27 ET with no photo
--   at all. derm.set_sheet_completed already REFUSES it ('no_stamps'), so it stays open for ever and is posted in
--   the 11 AM Slack list every day.
--   65 live manifests have no address sheet photo of their own, but they share their dump ticket with one that has,
--   so "no scan" is a TICKET (sheet) state: today exactly one.
-- THE DESIGN (Fred left the best practice to us; plan: Building Apps/DERM Stamp Studio/docs/specs/
--   2026-10-27-skip-a-sheet-with-no-scan.md)
--   1. ONE action, Skip. Never "Complete": in this app Completed means stamped and published (the client's
--      blacked-out copy, then the city email), and Fred's rule of 2026-09-03 is that a completed sheet must produce
--      a blackout. A sheet with no scan cannot, so "completed" would claim a document that does not exist.
--      "Handled another way" is one of the skip reasons instead.
--   2. A reason is required (record_only, no_sheet, sheet_lost, handled_elsewhere, other; other needs a note).
--      Who (the signed-in person's email, read from auth.users by auth.uid()) and when are stored, and every change
--      is in audit.logs (stamp_sheet_status is audited since 2026-07-04).
--   3. Reversible, and re-queued by itself: a skip COUNTS only while the sheet has no page and is not completed
--      (derived in the view, no trigger). Upload a scan and the sheet is "Not started" again; the stored skip stays
--      as history. Undo clears it.
--   4. Nothing downstream moves: a skip never sets completed, so there is no blackout, no Field Portal copy and no
--      city email (the city email waits on a blackout), and nothing counts it as compliant. The 11 AM post leaves a
--      skipped sheet out and says why an unskipped one waits.
--   5. Why the scan is missing, in plain words (derm.fn_sheet_missing_scan): no photo uploaded / only the manifest
--      photo uploaded / a photo recorded but its file missing (the upload failed).
-- WHAT CHANGES
--   derm.stamp_sheet_status + skipped_at, skipped_by, skip_reason, skip_note (+2 CHECKs). The completion triggers
--     act only on completed=true, so a skip row is inert to them.
--   NEW derm.fn_sheet_missing_scan(wm), NEW derm.set_sheet_skipped(folder, skipped, reason, note) (access check,
--     then the stamp key, like the 11 other edit functions; plain MESSAGE, code in DETAIL).
--   derm.v_stamp_sheets: 6 APPENDED columns (skipped, skipped_at, skipped_by, skip_reason, skip_note, missing_scan);
--     the existing 14 columns do not move (VERIFY 1).
--   derm.fn_stamp_open_sheets: leaves skipped sheets out; a 0-page sheet's reason is the missing-scan sentence.
-- NOT CHANGED: set_sheet_completed, the publish / blackout / city email code, the edge function stamp-sheets-reminder.
-- Rule 8: one table changed, audit already opted in. ROLLBACK: 2026-10-27_rollback_stamp_skip_sheet_with_no_scan.sql
-- LOCKS: the DDL holds ACCESS EXCLUSIVE on the sheet status table and the Studio's sheet list until COMMIT, so the
--   transaction holds the DDL only. The snapshots are taken BEFORE it and the VERIFY runs AFTER it (this file with
--   the VERIFY inside the transaction measured 16 s, past the 8 s an app read waits). A failed VERIFY means: run
--   the rollback file (rehearsed).
-- ============================================================================
CREATE TEMP TABLE sheets_before AS
  SELECT dump_folder, white_manifest_number, service_date, page_count, page_image_urls, total_rows, matched_rows,
         placed_rows, completed, completed_at, dump_date, is_generated, ai_placed_rows, filled_by_ai
    FROM derm.v_stamp_sheets;
CREATE TEMP TABLE open_before AS SELECT derm.fn_stamp_open_sheets() AS j;

BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_viewdef('derm.v_stamp_sheets'::regclass, true)) IS DISTINCT FROM 'bf040c4294a85d691fef58b26fc7a678' THEN
    RAISE EXCEPTION 'derm.v_stamp_sheets changed since this file was written: splice again';
  END IF;
  IF md5(pg_get_functiondef('derm.fn_stamp_open_sheets()'::regprocedure)) IS DISTINCT FROM '6169f30369a09d8bb95b10c3353849b1' THEN
    RAISE EXCEPTION 'derm.fn_stamp_open_sheets changed since this file was written: splice again';
  END IF;
  IF to_regprocedure('derm.set_sheet_skipped(text,boolean,text,text)') IS NOT NULL THEN RAISE EXCEPTION 'already applied'; END IF;
END $g$;

ALTER TABLE derm.stamp_sheet_status
  ADD COLUMN skipped_at  timestamptz,
  ADD COLUMN skipped_by  text,
  ADD COLUMN skip_reason text,
  ADD COLUMN skip_note   text,
  ADD CONSTRAINT stamp_sheet_status_skip_reason_check
    CHECK (skip_reason IN ('record_only', 'no_sheet', 'sheet_lost', 'handled_elsewhere', 'other')),
  ADD CONSTRAINT stamp_sheet_status_skip_whole_check
    CHECK ((skipped_at IS NULL) = (skip_reason IS NULL)
           AND (skip_reason IS DISTINCT FROM 'other' OR btrim(coalesce(skip_note, '')) <> ''));
COMMENT ON COLUMN derm.stamp_sheet_status.skipped_at IS
  'A person skipped this sheet because it has no scan (Stamp Studio, 2026-10-27, Trello EizZ2IuY). Counts only while the sheet has no page and is not completed (derm.v_stamp_sheets.skipped); kept as history after a scan arrives. Written only by derm.set_sheet_skipped.';
COMMENT ON COLUMN derm.stamp_sheet_status.skip_reason IS
  'Why the sheet was skipped: record_only, no_sheet, sheet_lost, handled_elsewhere, other (other needs skip_note). The Studio shows the words.';

-- Why a sheet has no page, in one plain sentence (NULL when it has a page). The three cases are the only ways a
-- ticket can have no page: derm.ticket_page_images keeps a manifest's address photo only when its file is in storage.
CREATE FUNCTION derm.fn_sheet_missing_scan(p_wm text)
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
REVOKE ALL ON FUNCTION derm.fn_sheet_missing_scan(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION derm.fn_sheet_missing_scan(text) TO authenticated, service_role;

CREATE OR REPLACE VIEW derm.v_stamp_sheets AS
 SELECT ss.dump_folder,
    ss.white_manifest_number,
    ss.service_date,
    ss.page_count,
    ss.page_image_urls,
    ss.total_rows,
    ss.matched_rows,
    ss.placed_rows,
    ss.completed,
    ss.completed_at,
    ss.dump_date,
    ss.is_generated,
    ai.ai_placed AS ai_placed_rows,
    ss.placed_rows > 0 AND ai.ai_placed = ss.placed_rows AS filled_by_ai,
    ss.skipped,
        CASE WHEN ss.skipped THEN ss.skipped_at ELSE NULL::timestamp with time zone END AS skipped_at,
        CASE WHEN ss.skipped THEN ss.skipped_by ELSE NULL::text END AS skipped_by,
        CASE WHEN ss.skipped THEN ss.skip_reason ELSE NULL::text END AS skip_reason,
        CASE WHEN ss.skipped THEN ss.skip_note ELSE NULL::text END AS skip_note,
        CASE WHEN ss.page_count = 0 THEN derm.fn_sheet_missing_scan(ss.white_manifest_number) ELSE NULL::text END AS missing_scan
   FROM ( WITH tickets AS (
                 SELECT DISTINCT COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number) AS wm
                   FROM derm_manifests
                  WHERE derm_manifests.deleted_at IS NULL AND COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number) IS NOT NULL
                UNION
                 SELECT DISTINCT address_row_map.white_manifest_number
                   FROM derm.address_row_map
                  WHERE address_row_map.white_manifest_number IS NOT NULL
                ), folder AS (
                 SELECT address_row_map.white_manifest_number AS wm,
                    min(address_row_map.dump_folder) AS f
                   FROM derm.address_row_map
                  WHERE address_row_map.white_manifest_number IS NOT NULL
                  GROUP BY address_row_map.white_manifest_number
                ), vis AS (
                 SELECT r.white_manifest_number AS wm,
                    count(*) AS total,
                    count(*) FILTER (WHERE r.matched_client_id IS NOT NULL OR r.manual_code IS NOT NULL) AS matched,
                    count(*) FILTER (WHERE r.stamp_placed_at IS NOT NULL) AS placed
                   FROM derm.address_row_map r
                     LEFT JOIN clients c ON c.id = r.matched_client_id
                  WHERE r.white_manifest_number IS NOT NULL AND (r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL OR r.manual_code IS NOT NULL) AND (r.stamp_placed_at IS NOT NULL OR r.manual_code IS NOT NULL OR r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
                           FROM derm_manifests m
                          WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL)))
                  GROUP BY r.white_manifest_number
                )
         SELECT COALESCE(folder.f, 'ticket-'::text || t.wm) AS dump_folder,
            t.wm AS white_manifest_number,
            ( SELECT min(m.service_date) AS min
                   FROM derm_manifests m
                  WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = t.wm AND m.deleted_at IS NULL) AS service_date,
            COALESCE(array_length(spi.imgs, 1), 0)::bigint AS page_count,
            spi.imgs AS page_image_urls,
            COALESCE(vis.total, 0::bigint) AS total_rows,
            COALESCE(vis.matched, 0::bigint) AS matched_rows,
            COALESCE(vis.placed, 0::bigint) AS placed_rows,
            COALESCE(s.completed, false) AS completed,
            s.completed_at,
            s.skipped_at IS NOT NULL AND NOT COALESCE(s.completed, false) AND COALESCE(array_length(spi.imgs, 1), 0) = 0 AS skipped,
            s.skipped_at,
            s.skipped_by,
            s.skip_reason,
            s.skip_note,
            COALESCE(( SELECT max(m.dump_ticket_date) AS max
                   FROM derm_manifests m
                  WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = t.wm AND m.deleted_at IS NULL), ( SELECT max(m.service_date) AS max
                   FROM derm_manifests m
                  WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = t.wm AND m.deleted_at IS NULL)) AS dump_date,
            derm.fn_sheet_is_generated(t.wm) AS is_generated
           FROM tickets t
             LEFT JOIN folder ON folder.wm = t.wm
             LEFT JOIN vis ON vis.wm = t.wm
             LEFT JOIN derm.stamp_sheet_status s ON s.dump_folder = COALESCE(folder.f, 'ticket-'::text || t.wm)
             CROSS JOIN LATERAL ( SELECT derm.ticket_page_images(t.wm) AS imgs) spi) ss
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE a.stamp_placed_by = 'stamp-studio-ai'::text) AS ai_placed
           FROM derm.address_row_map a
             LEFT JOIN clients c2 ON c2.id = a.matched_client_id
          WHERE a.dump_folder = ss.dump_folder AND a.stamp_placed_at IS NOT NULL AND (a.matched_client_id IS NOT NULL AND c2.client_code IS NOT NULL OR a.manual_code IS NOT NULL)) ai ON true
  WHERE NOT ((EXISTS ( SELECT 1
           FROM derm_manifests m
             JOIN disposal_facilities df ON df.id = m.disposal_facility_id
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = ss.white_manifest_number AND m.deleted_at IS NULL AND fn_dump_county_bucket(df.county) = 'BROWARD'::text AND COALESCE(m.dump_ticket_date, m.service_date) >= '2026-09-02'::date)) AND NOT (EXISTS ( SELECT 1
           FROM derm_manifests m
             LEFT JOIN disposal_facilities df ON df.id = m.disposal_facility_id
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = ss.white_manifest_number AND m.deleted_at IS NULL AND fn_dump_county_bucket(df.county) IS DISTINCT FROM 'BROWARD'::text))) AND NOT ((EXISTS ( SELECT 1
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = ss.white_manifest_number AND m.deleted_at IS NOT NULL)) AND NOT (EXISTS ( SELECT 1
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = ss.white_manifest_number AND m.deleted_at IS NULL)));

COMMENT ON VIEW derm.v_stamp_sheets IS 'Stamp Studio sheet list (one row per ticket). 2026-10-06: a ticket whose manifests are all soft-deleted (at least one, none live) is left out; a ticket with no manifest under its number still shows. Read by derm.fn_stamp_open_sheets (the 10 AM reminder). 2026-10-27: skipped, skipped_at, skipped_by, skip_reason, skip_note and missing_scan appended (a sheet with no scan can be skipped, derm.set_sheet_skipped; a skip counts only while the sheet has no page and is not completed).';

CREATE OR REPLACE FUNCTION derm.fn_stamp_open_sheets()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'manifest', s.white_manifest_number,
           'service_date', s.service_date,
           'dump_date', s.dump_date,
           'placed', s.placed_rows,
           'total', s.total_rows,
           'pages', s.page_count,
           'status', case when s.placed_rows > 0 then 'In progress' else 'Not started' end,
           'days_waiting', (now() at time zone 'America/New_York')::date - coalesce(s.dump_date, s.service_date),
           -- 2026-10-17: what the sheet waits for, from the Studio's own answer (derm.fn_stamp_sheet_wait_reason)
           -- 2026-10-27: a sheet with no scan says so (derm.fn_sheet_missing_scan, one sentence)
           'reason', coalesce(rtrim(lower(left(s.missing_scan, 1)) || substr(s.missing_scan, 2), '.'),
                              derm.fn_stamp_sheet_wait_reason(s.dump_folder)))
         order by coalesce(s.dump_date, s.service_date) nulls last, s.white_manifest_number), '[]'::jsonb)
    from derm.v_stamp_sheets s
    -- 2026-10-12: the clients the sheet names (its live manifests and its cards) and how many of them are test or
    -- fixture clients (public.fn_is_non_customer, the shared registry). A manifest with no client, or a card known only
    -- by its manual code, counts as a real client, so this can never hide a real sheet.
    cross join lateral (
      select count(*) as named,
             count(*) filter (where public.fn_is_non_customer(c.client_id, array['test', 'fixture'])) as test
        from (select m.client_id from public.derm_manifests m
               where coalesce(m.white_manifest_number, m.yellow_ticket_number) = s.white_manifest_number
                 and m.deleted_at is null
              union all
              select r.matched_client_id from derm.address_row_map r
               where r.white_manifest_number = s.white_manifest_number
                 and (r.matched_client_id is not null or r.manual_code is not null)) c) k
   where not s.completed
     -- 2026-10-27: a sheet skipped because it has no scan is not waiting for anyone (Trello EizZ2IuY)
     and not s.skipped
     -- a sheet whose clients are ALL test or fixture clients is not posted: the real post tags Diego and Serena
     and not (k.named > 0 and k.test = k.named);
$function$;

-- Skip (p_skipped true) or undo a skip (false). Only a sheet with no page that is not completed can be skipped.
-- Every refusal is a plain sentence in MESSAGE (shown verbatim by the Studio) with the code in DETAIL.
CREATE FUNCTION derm.set_sheet_skipped(p_dump_folder text, p_skipped boolean, p_reason text DEFAULT NULL, p_note text DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v record;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_by text;
BEGIN
  PERFORM hr.fn_check_app('stamp_studio', 'edit', 'skip a sheet with no scan');
  PERFORM derm._require_stamp_key();

  SELECT s.page_count, s.completed INTO v FROM derm.v_stamp_sheets s WHERE s.dump_folder = p_dump_folder;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'This sheet was not found. Reload the page.' USING DETAIL = 'blocker=not_found folder=' || coalesce(p_dump_folder, '');
  END IF;

  IF NOT coalesce(p_skipped, false) THEN
    UPDATE derm.stamp_sheet_status
       SET skipped_at = NULL, skipped_by = NULL, skip_reason = NULL, skip_note = NULL
     WHERE dump_folder = p_dump_folder AND skipped_at IS NOT NULL;
    RETURN;
  END IF;

  IF v.page_count > 0 THEN
    RAISE EXCEPTION 'This sheet has a scan, so it cannot be skipped.' USING DETAIL = 'blocker=has_pages folder=' || p_dump_folder;
  END IF;
  IF v.completed THEN
    RAISE EXCEPTION 'This sheet is already completed, so it cannot be skipped.' USING DETAIL = 'blocker=completed folder=' || p_dump_folder;
  END IF;
  IF p_reason IS NULL OR p_reason NOT IN ('record_only', 'no_sheet', 'sheet_lost', 'handled_elsewhere', 'other') THEN
    RAISE EXCEPTION 'Pick why this sheet is skipped.' USING DETAIL = 'blocker=reason folder=' || p_dump_folder;
  END IF;
  IF p_reason = 'other' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Write a short note saying why this sheet is skipped.' USING DETAIL = 'blocker=note folder=' || p_dump_folder;
  END IF;
  IF length(v_note) > 500 THEN
    RAISE EXCEPTION 'The note is too long. Keep it under 500 characters.' USING DETAIL = 'blocker=note_length folder=' || p_dump_folder;
  END IF;

  -- the signed-in person (request.jwt.claim.email is no longer set by PostgREST: set_sheet_completed records
  -- 'stamp-studio' for that reason)
  SELECT u.email INTO v_by FROM auth.users u WHERE u.id = auth.uid();
  INSERT INTO derm.stamp_sheet_status (dump_folder, completed, skipped_at, skipped_by, skip_reason, skip_note, updated_at)
  VALUES (p_dump_folder, false, now(), coalesce(v_by, 'stamp-studio'), p_reason, v_note, now())
  ON CONFLICT (dump_folder) DO UPDATE SET
    skipped_at = EXCLUDED.skipped_at, skipped_by = EXCLUDED.skipped_by,
    skip_reason = EXCLUDED.skip_reason, skip_note = EXCLUDED.skip_note, updated_at = now();
END $function$;
REVOKE ALL ON FUNCTION derm.set_sheet_skipped(text, boolean, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION derm.set_sheet_skipped(text, boolean, text, text) TO authenticated, service_role;

COMMIT;

-- VERIFY (after the commit; the control in 4 is undone) ---------------------
DO $v$
DECLARE v_n int; v_r jsonb; v_ctl text; v_msg text;
BEGIN
  -- 1. the 14 existing columns are unchanged on every sheet
  SELECT count(*) INTO v_n FROM (
    (SELECT * FROM sheets_before EXCEPT
     SELECT dump_folder, white_manifest_number, service_date, page_count, page_image_urls, total_rows, matched_rows,
            placed_rows, completed, completed_at, dump_date, is_generated, ai_placed_rows, filled_by_ai FROM derm.v_stamp_sheets)
    UNION ALL
    (SELECT dump_folder, white_manifest_number, service_date, page_count, page_image_urls, total_rows, matched_rows,
            placed_rows, completed, completed_at, dump_date, is_generated, ai_placed_rows, filled_by_ai FROM derm.v_stamp_sheets
     EXCEPT SELECT * FROM sheets_before)) d;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 1: % sheet rows moved', v_n; END IF;

  -- 2. no sheet counts as skipped yet; only 0-page sheets carry a missing-scan sentence
  IF EXISTS (SELECT 1 FROM derm.v_stamp_sheets WHERE skipped) THEN RAISE EXCEPTION 'VERIFY 2: a sheet is skipped already'; END IF;
  IF EXISTS (SELECT 1 FROM derm.v_stamp_sheets WHERE (page_count = 0) IS DISTINCT FROM (missing_scan IS NOT NULL)) THEN
    RAISE EXCEPTION 'VERIFY 2: missing_scan does not follow page_count';
  END IF;

  -- 3. the open list keeps the same sheets in the same order; only a 0-page sheet's reason changes
  SELECT derm.fn_stamp_open_sheets() INTO v_r;
  IF (SELECT jsonb_agg(e - 'reason') FROM jsonb_array_elements(v_r) e)
     IS DISTINCT FROM (SELECT jsonb_agg(e - 'reason') FROM open_before, jsonb_array_elements(j) e) THEN
    RAISE EXCEPTION 'VERIFY 3: the open list changed: %', v_r;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_r) e JOIN open_before o ON true
               JOIN jsonb_array_elements(o.j) b ON b->>'manifest' = e->>'manifest'
              WHERE (e->>'pages')::int > 0 AND (e->'reason') IS DISTINCT FROM (b->'reason')) THEN
    RAISE EXCEPTION 'VERIFY 3: a reason changed on a sheet with pages';
  END IF;

  -- 4. control, undone: skip a 0-page sheet and it leaves the list; a sheet with pages is refused
  SELECT dump_folder INTO v_ctl FROM derm.v_stamp_sheets WHERE page_count = 0 AND NOT completed LIMIT 1;
  IF v_ctl IS NOT NULL THEN
    BEGIN
      PERFORM derm.set_sheet_skipped(v_ctl, true, 'other', 'migration control');
      IF NOT (SELECT skipped FROM derm.v_stamp_sheets WHERE dump_folder = v_ctl) THEN RAISE EXCEPTION 'VERIFY 4: not skipped'; END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(derm.fn_stamp_open_sheets()) e
                  WHERE 'ticket-' || (e->>'manifest') = v_ctl) THEN RAISE EXCEPTION 'VERIFY 4: still listed'; END IF;
      PERFORM derm.set_sheet_skipped(v_ctl, false);
      IF (SELECT skipped FROM derm.v_stamp_sheets WHERE dump_folder = v_ctl) THEN RAISE EXCEPTION 'VERIFY 4: undo failed'; END IF;
      RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = 'undo the control';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    END;
  END IF;
  BEGIN
    PERFORM derm.set_sheet_skipped((SELECT dump_folder FROM derm.v_stamp_sheets WHERE page_count > 0 ORDER BY dump_folder LIMIT 1), true, 'other', 'x');
    v_msg := 'no refusal';
  EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
  END;
  IF v_msg IS DISTINCT FROM 'This sheet has a scan, so it cannot be skipped.' THEN
    RAISE EXCEPTION 'VERIFY 4: a sheet with pages was not refused: %', v_msg;
  END IF;
  IF EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE skipped_at IS NOT NULL) THEN RAISE EXCEPTION 'VERIFY 4: control not undone'; END IF;

  -- 5. privileges
  IF has_function_privilege('anon', 'derm.set_sheet_skipped(text,boolean,text,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'derm.set_sheet_skipped(text,boolean,text,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'derm.fn_sheet_missing_scan(text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'derm.fn_stamp_open_sheets()', 'EXECUTE')
     OR NOT has_table_privilege('authenticated', 'derm.v_stamp_sheets', 'SELECT')
     OR has_table_privilege('anon', 'derm.v_stamp_sheets', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 5: privileges';
  END IF;
  RAISE NOTICE 'VERIFY passed (control %)', coalesce(v_ctl, '(none)');
END $v$;
