-- ============================================================================================
-- 2026-09-14_0810_finisher_places_cards_awaiting_page_map.sql
--
-- STEP A OF THE GENERATED-SHEET FINISHER: place the cards a late sheet-number read left unplaced.
--
-- Design: docs/superpowers/specs/2026-09-14-generated-sheet-auto-measure-and-complete-design.md
--         section 4.A. Fred, 2026-09-14, on question 2 of that spec: "go ahead with all of them".
--
-- THE RACE. When a generated sheet is filed, derm.trg_autoplace_generated places every card in the
-- same instant, but a page-2 card can only be placed once the sheet-number read has said which scan
-- is page 2, and that read lands AFTER the filing (835076: 0.75 s late; 834742: 9 minutes). Those
-- cards were left unplaced until a person pressed Auto-place. derm.v_cards_awaiting_page_map has
-- listed them since 2026-09-03; nothing acted on it.
--
-- WHAT THIS DOES. derm.fn_place_cards_awaiting_page_map(limit) walks that view and re-runs the
-- insert trigger's own chain for each card, with THREE gates the trigger does not have:
--   1. the row OCR must have read THIS client's code on THIS printed row
--      (derm.fn_row_read_confirms(...) IS TRUE; the trigger accepts IS NOT FALSE, i.e. no opinion);
--   2. the client must hold exactly ONE card on the folder (a multi-permit client's cards would all
--      resolve to its FIRST printed row and stack, the 834986 lesson; a person places those);
--   3. the folder must not be completed or reopened (the resolver's own pin, 2026-08-24).
-- Everything else is the trigger's: stamp_page = the image position of the printed page,
-- stamp x/y = the layout's stamp for that row, stamp_placed_by = 'stamp-studio-ai' (Fred: one label
-- for everything machine-made). trg_ac_stamp_witness records the image as on any fresh placement.
--
-- WHY THIS IS SAFE WHERE THE 2026-09-03 DECISION ("unattended re-placement is deliberately not
-- shipped") was right. That decision was taken when placement could fall back to an IDENTITY page
-- map with no read at all, which is what put every stamp on the wrong scan on three folders. Here
-- the page map is a high-confidence SUFFIXED read (fn_sheet_image_position refuses otherwise), and
-- the row OCR has to name the client. A card that fails either gate stays unplaced, visibly, in the
-- same view, with the plain reason in this function's return value.
--
-- THE CRON: public.fn_request_generated_measure() runs it first (step 0), before completion and
-- measurement, so a card placed here is measured in the same tick and completed once its page has
-- geometry. The wrapper body is spliced from pg_get_functiondef by
-- scripts/probes/generated_finisher/assemble_step_a_migration.py with ONE anchored insert.
--
-- OFF SWITCH: public.app_config 'generated_sheet_auto_place' = 'true' (missing = on), the same shape
-- as generated_sheet_auto_complete.
--
-- AND ONE GAP CLOSED IN THE PUBLISH GATE, found by this file's own VERIFY. derm.fn_sheet_publishable
-- flagged a derived (stamp-midpoint) band only on a page WITHOUT an extent, because that is what
-- derm.v_blackout_blocked_sheets reports. A stamp cleared and placed again on an already-measured
-- page arrives with NO band while the page keeps its extent, so the sheet read as publishable and the
-- blackout would have published the heuristic band: the 2026-08-19 shape, reachable by hand in the
-- Studio today (clear, place, Mark completed) and automatically by this step. The gate gains a fourth
-- arm: any stamped card without a saved band is 'needs_snap_then_extent', whatever the extent says.
-- The finisher then measures that page (it is in the measure backlog: banded < stamped) before it
-- can complete. Measured at install, 3 pages estate-wide are in that state (ticket-831102 p1+p2,
-- ticket-831325 p1: the dark scans of 2026-08-20, all completed and serving); they stay completed,
-- and would be refused only if re-completed unmeasured. Body spliced from pg_get_functiondef.
--
-- RULE 8: no table changes (app_config is audited). Grants: service_role only.
-- ============================================================================================
BEGIN;

DO $pre$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'fn_request_generated_measure') THEN
    RAISE EXCEPTION 'PRE 1: apply 2026-09-14_0620 first';
  END IF;
  IF pg_get_functiondef('public.fn_request_generated_measure()'::regprocedure) LIKE '%fn_place_cards_awaiting_page_map%' THEN
    RAISE EXCEPTION 'PRE 2: the wrapper already calls the placement step; this file was applied already';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'derm' AND c.relname = 'v_cards_awaiting_page_map') THEN
    RAISE EXCEPTION 'PRE 3: derm.v_cards_awaiting_page_map is missing';
  END IF;
  IF pg_get_functiondef('derm.fn_sheet_publishable(text)'::regprocedure) NOT LIKE '%THEN ''needs_extent''
      ELSE NULL
    END);%' THEN
    RAISE EXCEPTION 'PRE 4: derm.fn_sheet_publishable is not the body this file was patched from';
  END IF;
END
$pre$;

-- --------------------------------------------------------------------------------------------
-- PART 1. The placement step.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_place_cards_awaiting_page_map(p_limit integer DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_cfg text; v_placed int := 0; v_n int; v_skipped jsonb := '[]'::jsonb; v_reason text; r record;
BEGIN
  SELECT lower(btrim(value)) INTO v_cfg FROM public.app_config WHERE key = 'generated_sheet_auto_place';
  IF v_cfg = 'false' THEN
    RETURN jsonb_build_object('placed', 0, 'skipped', '[]'::jsonb, 'switched_off', true);
  END IF;

  FOR r IN
    SELECT v.card_id, v.dump_folder, v.ticket, v.slot, v.image_position, v.matched_client_id,
           c.client_code, geo.o_x_pct, geo.o_y_pct,
           ((v.slot - 1) % 5) + 1 AS row_on_page,
           derm.fn_row_read_confirms(v.dump_folder, v.image_position, ((v.slot - 1) % 5) + 1, c.client_code) AS confirms,
           (SELECT count(*) FROM derm.address_row_map x
             WHERE x.dump_folder = v.dump_folder AND x.matched_client_id = v.matched_client_id) AS cards_of_client,
           coalesce(s.completed, false) AS completed, s.reopened_at
      FROM derm.v_cards_awaiting_page_map v
      JOIN public.clients c ON c.id = v.matched_client_id
      CROSS JOIN LATERAL derm.fn_generated_row_geometry(v.slot) geo
      LEFT JOIN derm.stamp_sheet_status s ON s.dump_folder = v.dump_folder
     ORDER BY v.created_at, v.card_id
     LIMIT greatest(1, least(coalesce(p_limit, 20), 100))
  LOOP
    v_reason := CASE
      WHEN r.reopened_at IS NOT NULL THEN 'This sheet was reopened for a person to look at.'
      WHEN r.completed THEN 'This sheet is already marked complete.'
      WHEN r.o_y_pct IS NULL THEN 'The printed layout has no stamp position for this row.'
      WHEN r.cards_of_client <> 1 THEN 'This client holds several cards on this sheet; a person places them.'
      WHEN r.confirms IS NULL THEN 'This printed row has not been read yet.'
      WHEN r.confirms IS FALSE THEN 'The printed row names a different client.'
    END;
    IF v_reason IS NOT NULL THEN
      v_skipped := v_skipped || jsonb_build_object('card_id', r.card_id, 'dump_folder', r.dump_folder, 'reason', v_reason);
      CONTINUE;
    END IF;
    UPDATE derm.address_row_map a
       SET stamp_page      = r.image_position,
           stamp_x_pct     = round(r.o_x_pct, 3),
           stamp_y_pct     = round(r.o_y_pct, 3),
           stamp_placed_at = now(),
           stamp_placed_by = 'stamp-studio-ai'
     WHERE a.id = r.card_id AND a.stamp_placed_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_placed := v_placed + v_n;
  END LOOP;

  RETURN jsonb_build_object('placed', v_placed, 'skipped', v_skipped);
END $function$;
REVOKE ALL ON FUNCTION derm.fn_place_cards_awaiting_page_map(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_place_cards_awaiting_page_map(integer) TO service_role;

-- --------------------------------------------------------------------------------------------
-- PART 2. The off switch (missing = on).
-- --------------------------------------------------------------------------------------------
INSERT INTO public.app_config (key, value)
SELECT 'generated_sheet_auto_place', 'true'
 WHERE NOT EXISTS (SELECT 1 FROM public.app_config WHERE key = 'generated_sheet_auto_place');

-- --------------------------------------------------------------------------------------------
-- PART 2b. The publish gate refuses a derived band on an extent-bearing page. Body spliced from
-- pg_get_functiondef (one anchored insert).
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_sheet_publishable(p_dump_folder text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  -- NULL means publishable. Any other value is the REASON it is not, and is shown to the operator.
  SELECT COALESCE(
    -- 1. the estate's own detector. It already knows every way a sheet can be unpublishable
    --    (needs_extent, needs_snap_then_extent, cards_withheld, no_stamp_timestamp,
    --    held_by_constraint, frozen_closed_world) and carries the what_to_do text beside it.
    (SELECT b.blocker FROM derm.v_blackout_blocked_sheets b
      WHERE b.dump_folder = p_dump_folder LIMIT 1),
    CASE
      -- 2. nothing placed: there is no document to produce, so "complete" would be meaningless.
      WHEN NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                        WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL)
        THEN 'no_stamps'
      -- 3. a stamped page with no measured extent. This is the exact hard gate in
      --    fn_blackout_targets' geo CTE, restated so completion cannot outrun the measurement.
      WHEN EXISTS (
        SELECT 1
          FROM (SELECT DISTINCT COALESCE(r.stamp_page, r.page) AS pg
                  FROM derm.address_row_map r
                 WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL) sp
         WHERE NOT EXISTS (SELECT 1 FROM derm.page_block_extents e
                            WHERE e.dump_folder = p_dump_folder AND e.effective_page = sp.pg))
        THEN 'needs_extent'
      -- 4. (2026-09-14) a stamped card whose band is still the stamp-midpoint heuristic on a page
      --    that HAS an extent. An extent opens the gate onto whatever bands exist (2026-08-19), and
      --    a stamp cleared and placed again arrives with no band, so this is the one shape the
      --    blocked-sheets view cannot see: it reports derived bands only on pages WITHOUT an extent.
      --    Measured at install: 3 pages estate-wide (ticket-831102 p1+p2, ticket-831325 p1, the dark
      --    scans of 2026-08-20), all completed and serving; they stay completed and are refused only
      --    if re-completed unmeasured, which is the rule.
      WHEN EXISTS (SELECT 1 FROM derm.address_row_map r
                    WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL
                      AND (r.band_y0_pct IS NULL OR r.band_y1_pct IS NULL))
        THEN 'needs_snap_then_extent'
      ELSE NULL
    END);
$function$;

-- --------------------------------------------------------------------------------------------
-- PART 3. The cron wrapper runs it first. Body spliced from pg_get_functiondef (one anchored insert).
-- --------------------------------------------------------------------------------------------
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

-- --------------------------------------------------------------------------------------------
-- VERIFY. Real folder (ticket-835076 page 2: five cards, five confirming row reads), everything
-- inside rolled-back savepoints.
-- --------------------------------------------------------------------------------------------
DO $verify$
DECLARE
  v_folder text := 'ticket-835076'; v_ticket text := '835076'; v_card bigint; v_client bigint; v_row int;
  v_j jsonb; v_r record; v_q0 bigint; v_q1 bigint; v_tech text := '(_|\[|\]|jsonb|numeric|null|IS TRUE|stamp_)';
  v_mine constant text := '%/functions/v1/measure-generated-page';
BEGIN
  -- the fixture card: a page-2 card whose row read confirms it today
  SELECT r.id, r.matched_client_id, ((derm.fn_generated_sheet_slot(r.matched_manifest_id) - 1) % 5) + 1
    INTO v_card, v_client, v_row
    FROM derm.address_row_map r JOIN public.clients c ON c.id = r.matched_client_id
   WHERE r.dump_folder = v_folder AND coalesce(r.stamp_page, r.page) = 2 AND r.stamp_placed_at IS NOT NULL
     AND derm.fn_row_read_confirms(v_folder, 2, ((derm.fn_generated_sheet_slot(r.matched_manifest_id) - 1) % 5) + 1, c.client_code) IS TRUE
   ORDER BY r.id LIMIT 1;
  IF v_card IS NULL THEN RAISE EXCEPTION 'SETUP: no confirming page-2 card on %', v_folder; END IF;
  IF NOT EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = v_folder AND completed) THEN RAISE EXCEPTION 'SETUP: % is not completed', v_folder; END IF;
  IF (SELECT value FROM public.app_config WHERE key = 'generated_sheet_auto_place') <> 'true' THEN RAISE EXCEPTION 'SETUP: switch'; END IF;
  IF EXISTS (SELECT 1 FROM derm.v_cards_awaiting_page_map) THEN RAISE EXCEPTION 'SETUP: the awaiting view is not empty; read it before applying'; END IF;

  -- A. happy path: cleared card, open folder -> placed by the machine, on the right scan, with a witness
  BEGIN
    PERFORM derm.clear_stamp_position(v_card);
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL, completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = v_folder;
    IF (SELECT count(*) FROM derm.v_cards_awaiting_page_map WHERE card_id = v_card AND image_position = 2) <> 1 THEN RAISE EXCEPTION 'VERIFY A SETUP: the cleared card is not awaiting'; END IF;
    v_j := derm.fn_place_cards_awaiting_page_map(20);
    IF (v_j->>'placed')::int <> 1 THEN RAISE EXCEPTION 'VERIFY A FAILED: %', v_j; END IF;
    SELECT * INTO v_r FROM derm.address_row_map WHERE id = v_card;
    IF v_r.stamp_placed_at IS NULL OR v_r.stamp_placed_by <> 'stamp-studio-ai' OR v_r.stamp_page <> 2
       OR v_r.stamp_y_pct <> (SELECT round(g.o_y_pct, 3) FROM derm.fn_generated_row_geometry(derm.fn_generated_sheet_slot(v_r.matched_manifest_id)) g)
       OR v_r.stamp_image_url IS DISTINCT FROM (derm.ticket_page_images(v_ticket))[2] THEN
      RAISE EXCEPTION 'VERIFY A FAILED: placed card is %', to_jsonb(v_r);
    END IF;
    IF EXISTS (SELECT 1 FROM derm.v_cards_awaiting_page_map WHERE card_id = v_card) THEN RAISE EXCEPTION 'VERIFY A FAILED: still awaiting'; END IF;
    -- a second run places nothing more
    v_j := derm.fn_place_cards_awaiting_page_map(20);
    IF (v_j->>'placed')::int <> 0 THEN RAISE EXCEPTION 'VERIFY A2 FAILED: %', v_j; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- B. the row read names ANOTHER client: not placed, plain reason
  BEGIN
    PERFORM derm.clear_stamp_position(v_card);
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL, completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = v_folder;
    UPDATE derm.address_sheet_row_reads SET client_code_read = '999-ZZZ' WHERE dump_folder = v_folder AND page = 2 AND row_index = v_row;
    v_j := derm.fn_place_cards_awaiting_page_map(20);
    IF (v_j->>'placed')::int <> 0 OR v_j->'skipped'->0->>'reason' <> 'The printed row names a different client.' OR v_j->'skipped'->0->>'reason' ~ v_tech THEN
      RAISE EXCEPTION 'VERIFY B FAILED: %', v_j;
    END IF;
    IF EXISTS (SELECT 1 FROM derm.address_row_map WHERE id = v_card AND stamp_placed_at IS NOT NULL) THEN RAISE EXCEPTION 'VERIFY B FAILED: placed on a contradicting read'; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- C. no row read at all: not placed
  BEGIN
    PERFORM derm.clear_stamp_position(v_card);
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL, completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = v_folder;
    DELETE FROM derm.address_sheet_row_reads WHERE dump_folder = v_folder AND page = 2 AND row_index = v_row;
    v_j := derm.fn_place_cards_awaiting_page_map(20);
    IF (v_j->>'placed')::int <> 0 OR v_j->'skipped'->0->>'reason' <> 'This printed row has not been read yet.' THEN RAISE EXCEPTION 'VERIFY C FAILED: %', v_j; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- D. a reopened folder: not placed (the clear itself pins the reopen; leave the pin)
  BEGIN
    PERFORM derm.clear_stamp_position(v_card);
    IF (SELECT reopened_at FROM derm.stamp_sheet_status WHERE dump_folder = v_folder) IS NULL THEN RAISE EXCEPTION 'VERIFY D SETUP: the clear did not pin a reopen'; END IF;
    v_j := derm.fn_place_cards_awaiting_page_map(20);
    IF (v_j->>'placed')::int <> 0 OR v_j->'skipped'->0->>'reason' NOT LIKE 'This sheet was reopened%' THEN RAISE EXCEPTION 'VERIFY D FAILED: %', v_j; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- E. a client holding two cards on the folder: not placed (the second card inserted ALREADY stamped)
  BEGIN
    PERFORM derm.clear_stamp_position(v_card);
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL, completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = v_folder;
    INSERT INTO derm.address_row_map (dump_folder, white_manifest_number, page, row_index, image_url, matched_client_id, matched_manifest_id,
                                      assignment_status, confidence, source, flags, stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_at, stamp_placed_by)
    SELECT dump_folder, white_manifest_number, page, 99, image_url, matched_client_id, matched_manifest_id,
           'matched', 'high', 'derm-link', '{"verify_fixture":true}'::jsonb, 2, 8.0, 60.04, now(), 'verify'
      FROM derm.address_row_map WHERE id = v_card;
    v_j := derm.fn_place_cards_awaiting_page_map(20);
    IF (v_j->>'placed')::int <> 0 OR v_j->'skipped'->0->>'reason' NOT LIKE 'This client holds several cards%' THEN RAISE EXCEPTION 'VERIFY E FAILED: %', v_j; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- F. the switch off: nothing placed, and the return says so
  BEGIN
    PERFORM derm.clear_stamp_position(v_card);
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL, completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = v_folder;
    UPDATE public.app_config SET value = 'false' WHERE key = 'generated_sheet_auto_place';
    v_j := derm.fn_place_cards_awaiting_page_map(20);
    IF (v_j->>'placed')::int <> 0 OR NOT (v_j->>'switched_off')::boolean THEN RAISE EXCEPTION 'VERIFY F FAILED: %', v_j; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- G. through the cron wrapper: the card is placed, and its page (now stamped but with one band
  --    missing) is handed to the measurer in the SAME tick; completion is correctly refused.
  --    The page's human-marked scan is removed for the fixture: a page a person has marked is
  --    deliberately never in the measure backlog, and this fixture page carries one (2026-09-14_0030).
  BEGIN
    PERFORM derm.clear_stamp_position(v_card);
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL, completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = v_folder;
    DELETE FROM derm.page_row_rules  WHERE dump_folder = v_folder AND effective_page = 2 AND source LIKE 'human-v1-%';
    DELETE FROM derm.page_rule_scans WHERE dump_folder = v_folder AND effective_page = 2 AND source LIKE 'human-v1-%';
    SELECT count(*) INTO v_q0 FROM net.http_request_queue WHERE url LIKE v_mine;
    PERFORM public.fn_request_generated_measure();
    SELECT count(*) INTO v_q1 FROM net.http_request_queue WHERE url LIKE v_mine;
    IF NOT EXISTS (SELECT 1 FROM derm.address_row_map WHERE id = v_card AND stamp_placed_at IS NOT NULL AND stamp_placed_by = 'stamp-studio-ai') THEN
      RAISE EXCEPTION 'VERIFY G FAILED: the wrapper did not place the card';
    END IF;
    IF v_q1 - v_q0 <> 1 THEN RAISE EXCEPTION 'VERIFY G FAILED: % measure request(s) queued, expected 1 for the page with the cleared band', v_q1 - v_q0; END IF;
    IF EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = v_folder AND completed) THEN RAISE EXCEPTION 'VERIFY G FAILED: completed with a band missing'; END IF;
    -- the gate, stated for a person: the placed card has no saved band, so the sheet is not publishable
    IF derm.fn_sheet_publishable(v_folder) IS DISTINCT FROM 'needs_snap_then_extent' THEN
      RAISE EXCEPTION 'VERIFY G2 FAILED: publishable reads %', derm.fn_sheet_publishable(v_folder);
    END IF;
    BEGIN
      PERFORM derm.set_sheet_completed(v_folder, true);
      RAISE EXCEPTION 'VERIFY G3 FAILED: Mark completed accepted a sheet with a derived band on a measured page';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE 'VERIFY G3%' THEN RAISE; END IF;
      IF SQLERRM NOT LIKE 'This sheet cannot be marked complete yet. Page 2: Some rows on this page are still on an estimated position%' THEN
        RAISE EXCEPTION 'VERIFY G3 FAILED: refusal reads "%"', SQLERRM;
      END IF;
    END;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- after the rollbacks: nothing moved, nothing queued
  IF NOT EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = v_folder AND completed AND reopened_at IS NULL)
     OR EXISTS (SELECT 1 FROM derm.address_row_map WHERE id = v_card AND stamp_placed_at IS NULL)
     OR EXISTS (SELECT 1 FROM derm.address_row_map WHERE flags->>'verify_fixture' = 'true')
     OR EXISTS (SELECT 1 FROM derm.v_cards_awaiting_page_map)
     OR (SELECT value FROM public.app_config WHERE key = 'generated_sheet_auto_place') <> 'true' THEN
    RAISE EXCEPTION 'CLEANUP FAILED';
  END IF;
  -- the census the header quotes: the pages on derived bands with an extent now read as unpublishable
  -- and are still completed (the gate binds the transition only)
  IF (SELECT count(*) FROM (SELECT DISTINCT r.dump_folder FROM derm.address_row_map r
                             WHERE r.stamp_y_pct IS NOT NULL AND (r.band_y0_pct IS NULL OR r.band_y1_pct IS NULL)) d
       WHERE derm.fn_sheet_publishable(d.dump_folder) IS DISTINCT FROM 'needs_snap_then_extent') <> 0 THEN
    RAISE EXCEPTION 'VERIFY J FAILED: a folder with a derived band still reads as publishable';
  END IF;
  IF EXISTS (SELECT 1 FROM derm.stamp_sheet_status s WHERE s.dump_folder IN ('ticket-831102', 'ticket-831325') AND NOT s.completed) THEN
    RAISE EXCEPTION 'VERIFY J2 FAILED: a serving folder lost its completion';
  END IF;
  IF pg_get_functiondef('public.fn_request_generated_measure()'::regprocedure) NOT LIKE '%PERFORM derm.fn_place_cards_awaiting_page_map(20);%' THEN
    RAISE EXCEPTION 'VERIFY H FAILED: the wrapper does not call the placement step';
  END IF;
  IF has_function_privilege('authenticated', 'derm.fn_place_cards_awaiting_page_map(integer)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'derm.fn_place_cards_awaiting_page_map(integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY I FAILED: grants';
  END IF;
  RAISE NOTICE 'ALL VERIFY PASSED: a cleared page-2 card is placed by the machine only when its row read confirms the client; a contradicting read, a missing read, a reopened sheet, a two-card client and the switch each stop it; the cron places then measures in one tick.';
END
$verify$;

COMMIT;
