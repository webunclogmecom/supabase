-- ============================================================================================
-- 2026-09-14_0100_plain_language_publish_messages.sql
--
-- Every message the Stamp Studio shows an operator about why a sheet cannot be completed or
-- blacked out is now plain language, describes the CURRENT user interface, and carries no
-- technical word. The technical code moves to DETAIL, which the app never displays.
--
-- WHY (Fred, 2026-09-14, on the 835076 banner "cannot mark ticket-835076 complete:
-- needs_snap_then_extent"): "they're not semantic, we need to save in the docs that any error
-- message should be semantic with no tech words."
--
-- TWO DEFECTS, ONE PER FUNCTION.
--
-- 1. derm.set_sheet_completed raised 'cannot mark % complete: %' with the folder id and the
--    blocker CODE in the message, and the app shows the message verbatim. Now the MESSAGE is the
--    same page-aware sentence the header banner already shows (fn_sheet_publishable_detail ->
--    'message'), so the banner and the error can never disagree, and 'blocker=<code>
--    folder=<id>' goes to DETAIL for logs. No HINT: the sentence already ends in the next step.
--
-- 2. derm.fn_publishable_hint, the one place every operator sentence lives, still described the
--    DRAG EDITOR that was removed on 2026-09-13: "Drag every row edge onto a printed line",
--    "Shift-click to place the two Limit bands", "drag the boundary". An operator following those
--    words today finds nothing to drag. Every arm is reworded to the Draw the bands flow, with no
--    code, no "database level", no "Unrecognised publish check (<code>)".
--
-- The seven blocker codes are unchanged (they are data in derm.v_blackout_blocked_sheets and
-- fn_sheet_publishable, read by the watchdogs); only the sentences attached to them change.
--
-- BODY PROVENANCE: both bodies are pg_get_functiondef output patched by exact-anchor string
-- replacement (each anchor asserted to occur exactly once); nothing retyped. VERIFY 5 proves the
-- rest of set_sheet_completed is byte-identical by re-applying the old RAISE to the new body.
--
-- RULE 8: no schema change.
-- ============================================================================================

BEGIN;

CREATE TEMP TABLE _w5_before ON COMMIT DROP AS
  SELECT dump_folder, completed, completed_at, completed_by, reopened_at, updated_at
    FROM derm.stamp_sheet_status WHERE dump_folder = 'window5-sheet3';

CREATE TEMP TABLE _msg_before ON COMMIT DROP AS
  SELECT p.proname, p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS cfg, pg_get_functiondef(p.oid) AS def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'derm' AND p.proname IN ('fn_publishable_hint', 'set_sheet_completed');

-- ============================================================================================
-- PART 0. PRECONDITIONS: the two bodies are the ones this file was patched from.
-- ============================================================================================
DO $pre$
BEGIN
  IF (SELECT count(*) FROM _msg_before) <> 2 THEN RAISE EXCEPTION 'PRE 0.1: expected both functions'; END IF;
  IF (SELECT def FROM _msg_before WHERE proname = 'set_sheet_completed')
       NOT LIKE '%RAISE EXCEPTION ''cannot mark %% complete: %%'', p_dump_folder, v_block%' THEN
    RAISE EXCEPTION 'PRE 0.2: set_sheet_completed no longer carries the RAISE this file replaces';
  END IF;
  IF (SELECT def FROM _msg_before WHERE proname = 'fn_publishable_hint') NOT LIKE '%Drag every row edge%' THEN
    RAISE EXCEPTION 'PRE 0.3: fn_publishable_hint no longer carries the drag-editor wording this file replaces';
  END IF;
END
$pre$;

-- ============================================================================================
-- PART 1. THE SENTENCES.
-- ============================================================================================
CREATE OR REPLACE FUNCTION derm.fn_publishable_hint(p_code text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_code
    WHEN 'needs_extent' THEN
      'The rows are on their printed lines, but the top and bottom of Section B have not been saved for this page yet. Open Draw the bands, check that the two Limit bands sit on the first and the last printed line, and save.'
    WHEN 'needs_snap_then_extent' THEN
      'Some rows on this page are still on an estimated position instead of the printed lines. Open Draw the bands: when the page has been measured the lines are already drawn for you, otherwise draw one line on each printed line between the rows, plus the top and the bottom of Section B. Then save. The sheet can be blacked out once every page has been saved this way.'
    WHEN 'cards_withheld' THEN
      'A stamp on this sheet has a position but was never confirmed, so nothing can be published over that row. Place that stamp again, or remove the card.'
    WHEN 'no_stamp_timestamp' THEN
      'A stamp on this sheet has a position but was never actually placed. Place it again; measuring the page will not fix this.'
    WHEN 'held_by_constraint' THEN
      'This sheet is deliberately frozen because its page layout is known to be wrong. It cannot be published, and this is not something to work around. Tell Fred.'
    WHEN 'frozen_closed_world' THEN
      'One card on this sheet has no stamp at all, which holds back every client on the sheet. Place the missing stamp; clearing the bands will not release it.'
    WHEN 'no_stamps' THEN
      'Nothing has been stamped on this sheet yet, so there is no document to produce. Place the stamps first.'
    ELSE
      'This sheet cannot be published yet, and the reason has no message of its own. Tell Fred.'
  END;
$function$;

-- ============================================================================================
-- PART 2. THE COMPLETION REFUSAL.
-- ============================================================================================
CREATE OR REPLACE FUNCTION derm.set_sheet_completed(p_dump_folder text, p_completed boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_block text;
BEGIN
  PERFORM derm._require_stamp_key();

  -- 🛑 COMPLETION IS A STATEMENT ABOUT THE GEOMETRY. A sheet that cannot be blacked out must not
  -- be markable complete (Fred, 2026-09-03: "if it's marked as complete then after 5 min it needs a
  -- blackout. period, if not then it can't be marked as complete").
  IF p_completed THEN
    v_block := derm.fn_sheet_publishable(p_dump_folder);
    IF v_block IS NOT NULL THEN
      -- 2026-09-14 (Fred): what an operator reads must be plain language with no technical words.
      -- The blocker CODE and the folder go to DETAIL, which the app never shows; the MESSAGE is the
      -- same page-aware sentence the header banner already shows, so the two never disagree.
      RAISE EXCEPTION 'This sheet cannot be marked complete yet. %',
        COALESCE(derm.fn_sheet_publishable_detail(p_dump_folder)->>'message', derm.fn_publishable_hint(v_block))
        USING DETAIL = 'blocker=' || v_block || ' folder=' || p_dump_folder;
    END IF;
  END IF;
  INSERT INTO derm.stamp_sheet_status (dump_folder, completed, completed_at, completed_by, updated_at)
  VALUES (p_dump_folder, p_completed,
          CASE WHEN p_completed THEN now() END,
          CASE WHEN p_completed THEN coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio') END,
          now())
  ON CONFLICT (dump_folder) DO UPDATE SET
    completed    = EXCLUDED.completed,
    completed_at = CASE WHEN EXCLUDED.completed THEN now() ELSE NULL END,
    completed_by = CASE WHEN EXCLUDED.completed THEN EXCLUDED.completed_by ELSE NULL END,
    updated_at   = now();
END $function$;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE v_s text; v_r record; v_old text; v_new text; v_n int;
BEGIN
  -- 1. No operator sentence carries a code, a drag-editor gesture, or a technical word.
  FOR v_r IN SELECT unnest(ARRAY['needs_extent','needs_snap_then_extent','cards_withheld','no_stamp_timestamp',
                                 'held_by_constraint','frozen_closed_world','no_stamps','some_future_code']) AS code
  LOOP
    v_s := derm.fn_publishable_hint(v_r.code);
    IF v_s IS NULL OR length(v_s) < 40 THEN
      RAISE EXCEPTION 'VERIFY 1 FAILED: hint for % is empty or too short: %', v_r.code, v_s;
    END IF;
    IF v_s ~ '(needs_|_chk|database level|Shift-click|shift-click|Drag every|drag the boundary|Unrecognised|\(null\)|some_future_code)' THEN
      RAISE EXCEPTION 'VERIFY 1 FAILED: hint for % still carries a technical word or a removed gesture: %', v_r.code, v_s;
    END IF;
  END LOOP;
  -- and the two blocking sentences name the panel that now exists
  IF derm.fn_publishable_hint('needs_snap_then_extent') NOT LIKE '%Draw the bands%'
     OR derm.fn_publishable_hint('needs_extent') NOT LIKE '%Draw the bands%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: the geometry hints do not point at Draw the bands';
  END IF;

  -- 2. The completion refusal, exercised on the live blocked sheet: the MESSAGE is the page-aware
  --    plain sentence, the code is in DETAIL only.
  --    window5-sheet3 is blocked by no_stamp_timestamp and needs a person (CLAUDE.md), so it is a
  --    live fixture that will not change under this file.
  BEGIN
    PERFORM derm.set_sheet_completed('window5-sheet3', true);
    RAISE EXCEPTION 'VERIFY 2 FAILED: set_sheet_completed accepted a blocked sheet';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'VERIFY 2 FAILED%' THEN RAISE; END IF;
    GET STACKED DIAGNOSTICS v_s = PG_EXCEPTION_DETAIL;
    IF SQLERRM NOT LIKE 'This sheet cannot be marked complete yet. %' THEN
      RAISE EXCEPTION 'VERIFY 2 FAILED: message is "%"', SQLERRM;
    END IF;
    IF SQLERRM ~ '(no_stamp_timestamp|needs_|window5-sheet3|cannot mark)' THEN
      RAISE EXCEPTION 'VERIFY 2 FAILED: the message still carries the code or the folder: "%"', SQLERRM;
    END IF;
    IF v_s IS DISTINCT FROM 'blocker=no_stamp_timestamp folder=window5-sheet3' THEN
      RAISE EXCEPTION 'VERIFY 2 FAILED: DETAIL is "%"', v_s;
    END IF;
  END;
  -- the refusal wrote nothing: the row is byte-identical to before the call
  SELECT count(*) INTO v_n FROM (
    SELECT dump_folder, completed, completed_at, completed_by, reopened_at, updated_at FROM derm.stamp_sheet_status WHERE dump_folder = 'window5-sheet3'
    EXCEPT SELECT * FROM _w5_before) x;
  IF v_n <> 0 OR (SELECT count(*) FROM _w5_before) <> (SELECT count(*) FROM derm.stamp_sheet_status WHERE dump_folder = 'window5-sheet3') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: the refused call changed window5-sheet3''s status row';
  END IF;

  -- 3. A publishable sheet still completes, and the write still lands (rolled back).
  --    ticket-835076 was made publishable by 2026-09-14_0030 minutes before this file.
  BEGIN
    IF derm.fn_sheet_publishable('ticket-835076') IS NOT NULL THEN
      RAISE EXCEPTION 'VERIFY 3 SETUP: ticket-835076 is no longer publishable (%)', derm.fn_sheet_publishable('ticket-835076');
    END IF;
    PERFORM derm.set_sheet_completed('ticket-835076', true);
    IF NOT EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-835076' AND completed) THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: a publishable sheet did not complete';
    END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;
  IF EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-835076' AND completed) THEN
    RAISE EXCEPTION 'VERIFY 3 CLEANUP FAILED: ticket-835076 stayed completed after the rollback';
  END IF;

  -- 4. Grants, SECDEF and search_path unchanged on both.
  FOR v_r IN SELECT p.proname, p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS cfg
               FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'derm' AND p.proname IN ('fn_publishable_hint', 'set_sheet_completed')
  LOOP
    IF v_r.acl IS DISTINCT FROM (SELECT acl FROM _msg_before b WHERE b.proname = v_r.proname)
       OR v_r.prosecdef IS DISTINCT FROM (SELECT prosecdef FROM _msg_before b WHERE b.proname = v_r.proname)
       OR v_r.cfg IS DISTINCT FROM (SELECT cfg FROM _msg_before b WHERE b.proname = v_r.proname) THEN
      RAISE EXCEPTION 'VERIFY 4 FAILED: % acl/secdef/search_path moved', v_r.proname;
    END IF;
  END LOOP;

  -- 5. set_sheet_completed: everything but the RAISE is byte-identical. Re-apply the old RAISE to
  --    the new body and require the original text.
  SELECT def INTO v_old FROM _msg_before WHERE proname = 'set_sheet_completed';
  SELECT pg_get_functiondef(p.oid) INTO v_new FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'derm' AND p.proname = 'set_sheet_completed';
  v_new := regexp_replace(v_new,
    '      -- 2026-09-14 \(Fred\).*?USING DETAIL = ''blocker='' \|\| v_block \|\| '' folder='' \|\| p_dump_folder;',
    '      RAISE EXCEPTION ''cannot mark % complete: %'', p_dump_folder, v_block' || E'\n' ||
    '        USING HINT = ''Measure the page first: drag the boundary to the first and last printed rule and snap every band, then mark complete.'';');
  IF v_new IS DISTINCT FROM v_old THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: set_sheet_completed changed outside the RAISE';
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: every publish sentence is plain language pointing at Draw the bands, '
               'the completion refusal carries the page-aware sentence with the code in DETAIL only, a '
               'publishable sheet still completes, grants unchanged, body otherwise identical.';
END
$verify$;

COMMIT;
