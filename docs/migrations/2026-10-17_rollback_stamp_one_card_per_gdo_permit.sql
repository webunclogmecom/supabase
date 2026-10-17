-- ============================================================================
-- ROLLBACK of 2026-10-17_0050_stamp_one_card_per_gdo_permit
-- Restores derm.fn_generated_page_cards and public.fn_request_generated_measure to their bodies
-- before that migration and drops derm.fn_ensure_permit_cards and derm.fn_card_printed_row.
-- The permit cards it created stay: they are correct data (a stamp per permit on its printed row).
-- With the old body the finisher refuses a multi-row client again, as before.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
CREATE OR REPLACE FUNCTION derm.fn_generated_page_cards(p_dump_folder text, p_page integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_ticket text; v_refusal text; v_detail text; v_cards jsonb; v_n int;
BEGIN
  SELECT r.white_manifest_number INTO v_ticket
    FROM derm.address_row_map r
   WHERE r.dump_folder = p_dump_folder AND r.white_manifest_number IS NOT NULL
   LIMIT 1;
  IF v_ticket IS NULL OR NOT coalesce(derm.fn_sheet_is_generated(v_ticket), false) THEN
    RETURN jsonb_build_object(
      'refusal', 'This sheet was not printed by us, so it cannot be measured automatically. Measure it with Draw the bands.',
      'detail', 'no generated-sheet link for ' || coalesce(v_ticket, p_dump_folder),
      'ticket', v_ticket, 'cards', '[]'::jsonb);
  END IF;

  WITH c AS (
    SELECT r.id, r.matched_client_id, r.stamp_y_pct, r.stamp_placed_at, s.slot,
           CASE WHEN s.slot IS NULL THEN NULL ELSE ((s.slot - 1) / 5) + 1 END AS printed_page,
           CASE WHEN s.slot IS NULL THEN NULL ELSE ((s.slot - 1) % 5) + 1 END AS row_on_page,
           (SELECT max(sc.rows_printed)
              FROM derm.address_sheet_manifests l
              JOIN derm.address_sheet_clients sc ON sc.sheet_id = l.sheet_id AND sc.slot = l.slot
             WHERE l.manifest_id = r.matched_manifest_id) AS rows_printed
      FROM derm.address_row_map r
      CROSS JOIN LATERAL (SELECT derm.fn_generated_sheet_slot(r.matched_manifest_id) AS slot) s
     WHERE r.dump_folder = p_dump_folder
       AND coalesce(r.stamp_page, r.page) = p_page
       AND r.stamp_y_pct IS NOT NULL
  )
  SELECT count(*),
         CASE
           WHEN count(*) = 0 THEN
             'Nothing has been stamped on this page yet.'
           WHEN bool_or(stamp_placed_at IS NULL) THEN
             'A stamp on this page has a position but was never actually placed. Place it again.'
           WHEN bool_or(slot IS NULL) THEN
             'A client on this page is not on the printed list of this sheet, so its row cannot be found automatically. A person needs to check this page in Draw the bands.'
           WHEN bool_or(derm.fn_sheet_image_position(p_dump_folder, printed_page) IS DISTINCT FROM p_page) THEN
             'A client on this page is printed on a different page of this sheet. A person needs to check this page in Draw the bands.'
           WHEN bool_or(rows_printed > 1) OR count(*) > count(DISTINCT matched_client_id) THEN
             'A client on this page is printed on several rows. Give it one card per permit and place each stamp on its own row, then measure the page with Draw the bands.'
           WHEN count(*) > count(DISTINCT row_on_page) THEN
             'Two stamps on this page sit on the same printed row. Place them again.'
         END,
         format('%s stamped cards, %s clients, %s without a printed slot, %s multi-row',
                count(*), count(DISTINCT matched_client_id),
                count(*) FILTER (WHERE slot IS NULL), count(*) FILTER (WHERE rows_printed > 1)),
         jsonb_agg(jsonb_build_object('row_id', id, 'client_id', matched_client_id,
                                      'row', row_on_page, 'y', stamp_y_pct)
                   ORDER BY row_on_page, id)
    INTO v_n, v_refusal, v_detail, v_cards
    FROM c;

  RETURN jsonb_build_object('refusal', v_refusal, 'detail', v_detail, 'ticket', v_ticket,
                            'cards', coalesce(v_cards, '[]'::jsonb));
END $function$;

CREATE OR REPLACE FUNCTION public.fn_request_generated_measure()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_key text; t record; f record;
BEGIN
  -- 0. (2026-09-14, Step A) place the cards a late sheet-number read left unplaced, only where
  --    the row OCR confirms the client on that printed row. No HTTP.
  PERFORM derm.fn_place_cards_awaiting_page_map(20);

  -- 1. completion first: no HTTP, and a generated sheet a person measured by hand completes here
  FOR f IN SELECT dump_folder FROM derm.v_generated_complete_backlog WHERE blocker IS NULL LOOP
    PERFORM derm.fn_complete_generated_sheet(f.dump_folder);
  END LOOP;

  -- 2. measurement requests, budgeted
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key';
  IF v_key IS NULL THEN
    RAISE WARNING 'edge_invoke_service_key vault secret missing; skipping generated-sheet measure';
    RETURN;
  END IF;
  FOR t IN SELECT * FROM derm.fn_generated_measure_targets(2) LOOP
    INSERT INTO derm.generated_measure_attempts (dump_folder, page, image_url, source_etag, attempts, last_outcome)
    VALUES (t.dump_folder, t.page, t.image_url, t.source_etag, 1, 'requested')
    ON CONFLICT (dump_folder, page) DO UPDATE
       SET attempts = CASE
                        WHEN derm.generated_measure_attempts.image_url IS DISTINCT FROM EXCLUDED.image_url
                          OR derm.generated_measure_attempts.source_etag IS DISTINCT FROM EXCLUDED.source_etag
                        THEN 1                                            -- new scan, fresh budget
                        ELSE derm.generated_measure_attempts.attempts + 1
                      END,
           image_url = EXCLUDED.image_url, source_etag = EXCLUDED.source_etag,
           last_outcome = 'requested', last_attempt_at = now();
    PERFORM net.http_post(
      url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/measure-generated-page',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
      body := jsonb_build_object('dump_folder', t.dump_folder, 'ticket', t.ticket, 'page', t.page, 'image_url', t.image_url),
      timeout_milliseconds := 120000);
  END LOOP;
END $function$;

DROP FUNCTION derm.fn_ensure_permit_cards(text);
DROP FUNCTION derm.fn_card_printed_row(bigint);
DO $v$ BEGIN
  IF md5(pg_get_functiondef('derm.fn_generated_page_cards(text,integer)'::regprocedure)) <> 'ad0d88967c661d6f49039dc3cf35879c'
     OR md5(pg_get_functiondef('public.fn_request_generated_measure()'::regprocedure)) <> '9d8bdf9b5332c2753dff714b113d3347' THEN
    RAISE EXCEPTION 'rollback VERIFY: bodies differ from the pre-migration ones';
  END IF;
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
