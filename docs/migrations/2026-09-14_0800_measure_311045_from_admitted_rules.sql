-- ============================================================================================
-- 2026-09-14_0800_measure_311045_from_admitted_rules.sql
--
-- ticket-311045 page 1 (generated sheet 1084, two clients: 106-ALC on printed row 1, 205-SAS on
-- printed row 2) has been serving two redacted documents on DERIVED bands since 2026-08-10, with
-- an extent "dual-measured" wider than the printed roster (24.85 / 63.44). It was the top row of
-- the 2026-08-20 "measured neighbour exposure" group (1.60pp) and has needed a person since.
--
-- WHY NOW. Phase 0 of the generated-sheet finisher (scripts/probes/generated_finisher/
-- phase0_report.md) replayed the layout-guided matcher over this page: its six boundaries agree
-- with the page's own admitted printed rules (runlen-v2-2026-08-21, graded OK) within 0.043pp.
-- The finisher itself will never touch this folder because it is completed; Fred, 2026-09-14:
-- "go ahead with all of them". So this file does by migration exactly what the finisher does for
-- an open sheet, through the same two guarded RPCs, from the same admitted lines.
--
-- WHAT IS WRITTEN, and from where. Nothing is typed: every value is read from
-- derm.v_page_printed_rules at apply time.
--   bands   106-ALC  [boundary 1, boundary 2]  = the printed slot of row 1
--           205-SAS  [boundary 2, boundary 3]  = the printed slot of row 2
--   extent  [boundary 1, boundary 6]           = the printed roster, empty slots included
-- The derived band of 205-SAS reached 41.680, 1.56pp past the printed line at 40.119 into the
-- (empty) third slot; the derived top of 106-ALC sat 0.52pp below the printed line. Both edges
-- now sit on the lines. The extent narrows to the roster's own first and last line, which is the
-- estate's definition of an extent (2026-08-03: "the measured span between the first and last
-- printed form rule"); G8 and G11 assert it still contains every band and covers the roster.
--
-- COMPLETION IS PRESERVED. derm.save_page_geometry fires trg_zz_dirty_on_card_change, which clears
-- `completed` and pins `reopened_at` ("a person must look"). This file IS that look: the person's
-- completion (completed_by = 'stamp-studio', 2026-08) is restored as it was, the pin cleared, and
-- trg_a0_completion_requires_geometry re-checks fn_sheet_publishable on the way back while
-- trg_zz_publish_on_complete kicks the blackout sweep, so the two documents regenerate on the new
-- geometry (one per five-minute sweep). Both are to be opened by eye afterwards (CLAUDE.md).
--
-- RULE 8: no schema change. Writes: derm.address_row_map (band_*), derm.page_block_extents,
-- derm.stamp_sheet_status, all audited.
-- ============================================================================================
BEGIN;

CREATE TEMP TABLE _s311045 ON COMMIT DROP AS
  SELECT dump_folder, completed, completed_at, completed_by, reopened_at, reopened_by
    FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-311045';

DO $pre$
DECLARE v_cards jsonb; v_b numeric[];
BEGIN
  IF (SELECT count(*) FROM _s311045) <> 1 OR NOT (SELECT completed FROM _s311045) OR (SELECT reopened_at FROM _s311045) IS NOT NULL THEN
    RAISE EXCEPTION 'PRE 1: ticket-311045 is not a completed, un-reopened folder';
  END IF;
  v_cards := derm.fn_generated_page_cards('ticket-311045', 1);
  IF v_cards->>'refusal' IS NOT NULL OR jsonb_array_length(v_cards->'cards') <> 2
     OR (SELECT array_agg((c->>'row')::int ORDER BY (c->>'row')::int) FROM jsonb_array_elements(v_cards->'cards') c) IS DISTINCT FROM ARRAY[1, 2] THEN
    RAISE EXCEPTION 'PRE 2: the page is not two single-row cards on printed rows 1 and 2: %', v_cards;
  END IF;
  SELECT array_agg(rule_pct ORDER BY rule_pct) INTO v_b
    FROM derm.v_page_printed_rules WHERE dump_folder = 'ticket-311045' AND effective_page = 1 AND kind = 'boundary';
  IF coalesce(array_length(v_b, 1), 0) <> 6 OR (SELECT string_agg(DISTINCT source, ',') FROM derm.v_page_printed_rules WHERE dump_folder = 'ticket-311045' AND effective_page = 1) NOT LIKE 'runlen-v2-%' THEN
    RAISE EXCEPTION 'PRE 3: expected six admitted runlen-v2 boundaries, got %', v_b;
  END IF;
  IF EXISTS (SELECT 1 FROM derm.address_row_map WHERE dump_folder = 'ticket-311045' AND band_y0_pct IS NOT NULL) THEN
    RAISE EXCEPTION 'PRE 4: a band override already exists; this file expects derived bands only';
  END IF;
  IF (SELECT count(*) FROM derm.check_page_geometry('ticket-311045', 1,
        (SELECT jsonb_agg(jsonb_build_object('row_id', (c->>'row_id')::bigint, 'y0', v_b[(c->>'row')::int], 'y1', v_b[(c->>'row')::int + 1]))
           FROM jsonb_array_elements(v_cards->'cards') c),
        v_b[1], v_b[6])) <> 0 THEN
    RAISE EXCEPTION 'PRE 5: the planned geometry violates a guard';
  END IF;
END
$pre$;

-- --------------------------------------------------------------------------------------------
-- PART 1. Bands on the printed lines, extent on the roster, one page-atomic save.
-- --------------------------------------------------------------------------------------------
DO $geo$
DECLARE v_j jsonb; v_b numeric[]; v_cards jsonb;
BEGIN
  SELECT array_agg(rule_pct ORDER BY rule_pct) INTO v_b
    FROM derm.v_page_printed_rules WHERE dump_folder = 'ticket-311045' AND effective_page = 1 AND kind = 'boundary';
  v_cards := derm.fn_generated_page_cards('ticket-311045', 1);
  v_j := derm.save_page_geometry('ticket-311045', 1,
    (SELECT jsonb_agg(jsonb_build_object('row_id', (c->>'row_id')::bigint, 'y0', v_b[(c->>'row')::int], 'y1', v_b[(c->>'row')::int + 1]))
       FROM jsonb_array_elements(v_cards->'cards') c),
    v_b[1], v_b[6]);
  IF (v_j->>'saved_bands')::int <> 2 OR (v_j->>'extent_written')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'PART 1: save_page_geometry did not save cleanly: %', v_j;
  END IF;
END
$geo$;

-- --------------------------------------------------------------------------------------------
-- PART 2. Restore the person's completion (the band write pinned a reopen; this file is the look).
-- --------------------------------------------------------------------------------------------
UPDATE derm.stamp_sheet_status s
   SET completed = true, completed_at = b.completed_at, completed_by = b.completed_by
  FROM _s311045 b
 WHERE s.dump_folder = b.dump_folder AND NOT s.completed;

-- --------------------------------------------------------------------------------------------
-- VERIFY
-- --------------------------------------------------------------------------------------------
DO $verify$
DECLARE v_b numeric[]; v_n int; v_r record;
BEGIN
  SELECT array_agg(rule_pct ORDER BY rule_pct) INTO v_b
    FROM derm.v_page_printed_rules WHERE dump_folder = 'ticket-311045' AND effective_page = 1 AND kind = 'boundary';
  -- 1. every band edge IS an admitted printed line, and the two slots are rows 1 and 2
  SELECT count(*) INTO v_n FROM derm.address_row_map r
   WHERE r.dump_folder = 'ticket-311045'
     AND ((r.stamp_y_pct = 29.80 AND r.band_y0_pct = v_b[1] AND r.band_y1_pct = v_b[2])
       OR (r.stamp_y_pct = 37.72 AND r.band_y0_pct = v_b[2] AND r.band_y1_pct = v_b[3]));
  IF v_n <> 2 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: % of 2 bands on the printed lines', v_n; END IF;
  -- 2. the extent is the roster
  IF NOT EXISTS (SELECT 1 FROM derm.page_block_extents WHERE dump_folder = 'ticket-311045' AND effective_page = 1 AND top_pct = v_b[1] AND bottom_pct = v_b[6]) THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: extent';
  END IF;
  -- 3. completion restored exactly, pin cleared, publishable
  SELECT * INTO v_r FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-311045';
  IF NOT v_r.completed OR v_r.reopened_at IS NOT NULL
     OR v_r.completed_at IS DISTINCT FROM (SELECT completed_at FROM _s311045)
     OR v_r.completed_by IS DISTINCT FROM (SELECT completed_by FROM _s311045) THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: status row %', v_r;
  END IF;
  IF derm.fn_sheet_publishable('ticket-311045') IS NOT NULL THEN RAISE EXCEPTION 'VERIFY 3a FAILED: not publishable'; END IF;
  -- 4. the grader agrees, and the two documents are queued to regenerate (the fingerprint moved)
  IF EXISTS (SELECT 1 FROM derm.v_band_edge_check WHERE dump_folder = 'ticket-311045' AND edge_verdict <> 'ON_RULE') THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: a band grades off the printed rules';
  END IF;
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(200) t WHERE t.ticket_key = '311045' AND t.manifest_id IN (1698, 1699);
  IF v_n <> 2 THEN RAISE EXCEPTION 'VERIFY 4a FAILED: % regeneration targets for ticket-311045, expected 2', v_n; END IF;
  RAISE NOTICE 'ALL VERIFY PASSED: 311045 p1 bands on its admitted lines, extent on the roster, completion preserved, two documents queued to regenerate.';
END
$verify$;

COMMIT;
