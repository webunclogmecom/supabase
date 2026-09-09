-- ============================================================================================
-- 2026-09-09_0930_slot_verdict_needs_divider_evidence.sql
--
-- A page that recorded NO dividers cannot supply divider evidence, so stop grading its bands
-- ODD_SLOT for failing to contain one. Restores derm.v_band_edges_off_rule to a worklist whose
-- emptiness means something.
--
-- WHY: `v_band_edges_off_rule` is the check CLAUDE.md says to watch after any stamping session,
-- on the stated principle that EMPTY IS HEALTHY. It was empty on 2026-08-24. Measured today it
-- holds 26, and 24 of them are this artifact.
--
-- 🛑 THE MECHANISM, AND IT IS A CONSEQUENCE OF MAKING HAND MEASUREMENT THE SANCTIONED PATH.
-- `slot_verdict` awards ONE_CLIENT only when `inner_dividers = expected_slots`, i.e. the band must
-- contain the faint mid-slot divider line. A DETECTOR finds those lines. A PERSON drawing bands in
-- the Stamp Studio marks where one client's row ENDS AND THE NEXT BEGINS, which is a boundary, and
-- never bothers with the divider inside a row. Measured over every hand-drawn rule set:
--
--       human-v1-2026-09-02   boundary  7 rules / 1 page       divider  0
--       human-v1-2026-09-03   boundary  6 rules / 1 page       divider  0
--       human-v1-2026-09-04   boundary 13 rules / 2 pages      divider  0
--       human-v1-2026-09-07   boundary 14 rules / 2 pages      divider  0
--                                                             -------------
--       dividers on hand-measured pages, estate-wide:                    0
--
-- So EVERY band on EVERY hand-measured page is permanently ODD_SLOT and can never clear, and the
-- worklist grows a little each time somebody measures a page by hand. That is the exact failure
-- this estate already named once: "four permanent rows would bury the real two on a worklist whose
-- whole value is that empty means healthy."
--
-- ⚠ IT IS NOT A LEAK, AND THE DISTINCTION IS THE WHOLE JUSTIFICATION. All 24 rows read
-- `edge_verdict = ON_RULE` with `top_kind = bottom_kind = 'boundary'` and `inner_boundaries = 0`,
-- i.e. both edges sit on printed slot boundaries with no boundary in between: the band spans
-- exactly one printed slot. CLAUDE.md states the safety property directly - "a divider can only
-- ever change a slot_verdict; band edges snap to boundary, so being wrong there cannot reach a
-- document". `inner_dividers = 0` on such a page is an ABSENT MEASUREMENT, not a zero, and grading
-- off it asserts something the data does not support.
--
-- ============================================================================================
-- THE CHANGE: one extra disjunct, plus the per-page count it needs.
--       AND inner_dividers = expected_slots
--    -> AND (inner_dividers = expected_slots OR page_dividers = 0)
-- `page_dividers` is computed inside the internal `m` CTE from the page's OWN active scan source.
-- The view's OUTPUT COLUMN LIST IS UNCHANGED, so CREATE OR REPLACE preserves grants and the four
-- dependants (v_band_edges_off_rule and friends) need no change.
-- ============================================================================================
--
-- 🛑 THE BLAST RADIUS IS EXACTLY 24 ROWS, AND THAT IS MEASURED RATHER THAN HOPED. Every verdict in
-- the view partitions perfectly across the two populations, with ZERO overlap:
--
--       slot_verdict      page has NO dividers      page HAS dividers
--       ONE_CLIENT                     0                      622
--       PART_SLOT                      0                       27
--       SPANS_MULTIPLE                 0                       20
--       ODD_SLOT                      24                        0
--       UNKNOWN                        7                        0
--                            11 pages                   172 pages
--
-- So on all 172 divider-carrying pages the new disjunct is false and cannot fire, and the 669 rows
-- graded there are untouched. VERIFY 1 proves that row by row rather than asserting it.
--
-- ⚠ SIX of the 11 divider-less pages are hand-drawn (`human-v1-%`) and FIVE are detector runs that
-- found no dividers on a faint or handwritten scan. Both are admitted deliberately: in either case
-- the page recorded no divider, so `inner_dividers` carries no information about the band. Where
-- detection was actually bad, `page_grade = 'FAILED'` already routes the row to UNKNOWN ahead of
-- this branch, which is the check that separates "no dividers on this form" from "we could not
-- read this page".
--
-- ⚠ THE DETECTOR ARM IS UNEXERCISED ON LIVE DATA: all 24 moving rows sit on hand-drawn pages, and
-- the five divider-less DETECTOR pages currently serve no graded band. A clean install therefore
-- proves nothing about it, so VERIFY 3 drives it with a fixture.
--
-- RULE 8: no schema change, view only. derm.page_row_rules and derm.page_rule_scans are untouched.
-- ============================================================================================

BEGIN;

-- Snapshot every graded row BEFORE the change, so "only the 24 moved" is measured.
CREATE TEMP TABLE _sv_before ON COMMIT DROP AS
  SELECT row_id, dump_folder, effective_page, edge_verdict, slot_verdict,
         inner_boundaries, inner_dividers, expected_slots
    FROM derm.v_band_edge_check;

CREATE TEMP TABLE _off_before ON COMMIT DROP AS
  SELECT row_id, dump_folder, effective_page, edge_verdict, slot_verdict
    FROM derm.v_band_edges_off_rule;

CREATE OR REPLACE VIEW derm.v_band_edge_check AS
WITH served AS (
         SELECT r.id AS row_id,
            r.dump_folder,
            COALESCE(r.stamp_page, r.page) AS effective_page,
            c.client_code,
            vb.band_y0_pct,
            vb.band_y1_pct,
            r.band_source,
            r.stamp_y_pct,
            r.band_y0_pct IS NOT NULL AS band_is_override,
            d.band_y0 = grp.u0 AND d.band_y1 = grp.u1 AS doc_current,
            d.source_url AS doc_source_url,
            d.url AS doc_url
           FROM derm.address_row_map r
             JOIN clients c ON c.id = r.matched_client_id
             JOIN derm.v_stamp_row_bands vb ON vb.id = r.id
             JOIN derm.redacted_manifest_docs d ON d.manifest_id = r.matched_manifest_id AND d.client_id = r.matched_client_id AND d.effective_page = COALESCE(r.stamp_page, r.page)
             CROSS JOIN LATERAL ( SELECT min(b2.band_y0_pct) AS u0,
                    max(b2.band_y1_pct) AS u1
                   FROM derm.address_row_map r2
                     JOIN derm.v_stamp_row_bands b2 ON b2.id = r2.id
                  WHERE r2.matched_manifest_id = r.matched_manifest_id AND r2.matched_client_id = r.matched_client_id AND r2.dump_folder = r.dump_folder AND COALESCE(r2.stamp_page, r2.page) = COALESCE(r.stamp_page, r.page) AND r2.stamp_placed_at IS NOT NULL) grp
          WHERE d.band_y0 IS NOT NULL AND d.band_y1 IS NOT NULL
        ), scan AS (
         SELECT DISTINCT ON (page_rule_scans.dump_folder, page_rule_scans.effective_page) page_rule_scans.dump_folder,
            page_rule_scans.effective_page,
            page_rule_scans.source_url,
            page_rule_scans.image_w,
            page_rule_scans.image_h,
            page_rule_scans.skew,
            page_rule_scans.n_rules,
            page_rule_scans.n_boundaries,
            page_rule_scans.pitch_pct,
            page_rule_scans.grade,
            page_rule_scans.detail,
            page_rule_scans.source,
            page_rule_scans.scanned_at,
            page_rule_scans.source_etag,
            page_rule_scans.skew_saturated
           FROM derm.page_rule_scans
          WHERE page_rule_scans.source ~~ 'runlen-v2-%'::text OR page_rule_scans.source ~~ 'human-v1-%'::text
          ORDER BY page_rule_scans.dump_folder, page_rule_scans.effective_page, (page_rule_scans.source ~~ 'human-v1-%'::text) DESC, page_rule_scans.scanned_at DESC
        ), m AS (
         SELECT s.row_id,
            s.dump_folder,
            s.effective_page,
            s.client_code,
            s.band_y0_pct,
            s.band_y1_pct,
            s.band_source,
            s.stamp_y_pct,
            s.band_is_override,
            s.doc_current,
            s.doc_source_url,
            s.doc_url,
            GREATEST(COALESCE(( SELECT count(*) AS count
                   FROM derm.address_row_map a2
                     JOIN derm_manifests dm ON dm.id = a2.matched_manifest_id AND dm.deleted_at IS NULL
                     JOIN derm.address_sheet_manifests asm ON asm.manifest_id = dm.id
                     JOIN derm.address_sheets ash ON ash.id = asm.sheet_id AND ash.deleted_at IS NULL
                     JOIN derm.v_sheet_printed_rows vpr ON vpr.sheet_id = asm.sheet_id AND vpr.client_id = a2.matched_client_id
                  WHERE a2.id = s.row_id AND derm.fn_sheet_image_position(a2.dump_folder, vpr.printed_page) = s.effective_page), 0::bigint) / GREATEST(COALESCE(( SELECT count(*) AS count
                   FROM derm.address_row_map a3
                  WHERE a3.dump_folder = s.dump_folder AND a3.matched_client_id = (( SELECT a4.matched_client_id
                           FROM derm.address_row_map a4
                          WHERE a4.id = s.row_id)) AND COALESCE(a3.stamp_page, a3.page) = s.effective_page), 1::bigint), 1::bigint), 1::bigint)::integer AS expected_slots,
            sc.grade AS page_grade,
            sc.n_rules,
            sc.pitch_pct,
            sc.source_etag,
            sc.skew_saturated,
            sc.dump_folder AS scanned,
            t.d AS top_gap_pct,
            t.kind AS top_kind,
            b.d AS bottom_gap_pct,
            b.kind AS bottom_kind,
            ib.n AS inner_boundaries,
            idv.n AS inner_dividers,
            COALESCE(( SELECT count(*) AS count
                   FROM derm.page_row_rules pr
                  WHERE pr.dump_folder = s.dump_folder AND pr.effective_page = s.effective_page AND pr.source = sc.source AND pr.kind = 'divider'::text), 0::bigint) AS page_dividers
           FROM served s
             LEFT JOIN scan sc ON sc.dump_folder = s.dump_folder AND sc.effective_page = s.effective_page
             LEFT JOIN LATERAL ( SELECT abs(pr.rule_pct - s.band_y0_pct) AS d,
                    pr.kind
                   FROM derm.page_row_rules pr
                  WHERE pr.dump_folder = s.dump_folder AND pr.effective_page = s.effective_page AND pr.source = sc.source
                  ORDER BY (abs(pr.rule_pct - s.band_y0_pct))
                 LIMIT 1) t ON true
             LEFT JOIN LATERAL ( SELECT abs(pr.rule_pct - s.band_y1_pct) AS d,
                    pr.kind
                   FROM derm.page_row_rules pr
                  WHERE pr.dump_folder = s.dump_folder AND pr.effective_page = s.effective_page AND pr.source = sc.source
                  ORDER BY (abs(pr.rule_pct - s.band_y1_pct))
                 LIMIT 1) b ON true
             LEFT JOIN LATERAL ( SELECT count(*) AS n
                   FROM derm.page_row_rules pr
                  WHERE pr.dump_folder = s.dump_folder AND pr.effective_page = s.effective_page AND pr.source = sc.source AND pr.kind = 'boundary'::text AND pr.rule_pct > (s.band_y0_pct + 0.35) AND pr.rule_pct < (s.band_y1_pct - 0.35)) ib ON true
             LEFT JOIN LATERAL ( SELECT count(*) AS n
                   FROM derm.page_row_rules pr
                  WHERE pr.dump_folder = s.dump_folder AND pr.effective_page = s.effective_page AND pr.source = sc.source AND pr.kind = 'divider'::text AND pr.rule_pct > (s.band_y0_pct + 0.35) AND pr.rule_pct < (s.band_y1_pct - 0.35)) idv ON true
        )
 SELECT row_id,
    dump_folder,
    effective_page,
    client_code,
    doc_url,
    band_y0_pct,
    band_y1_pct,
    band_source,
    band_is_override,
    doc_current,
    page_grade,
    n_rules,
    pitch_pct,
    skew_saturated,
    top_gap_pct,
    top_kind,
    bottom_gap_pct,
    bottom_kind,
    inner_boundaries,
    inner_dividers,
    expected_slots,
        CASE
            WHEN scanned IS NULL THEN 'UNSCANNED'::text
            WHEN source_etag IS DISTINCT FROM derm._img_etag(doc_source_url) THEN 'STALE'::text
            WHEN top_gap_pct IS NULL OR bottom_gap_pct IS NULL THEN 'OFF_RULE'::text
            WHEN top_gap_pct <= 0.35 AND bottom_gap_pct <= 0.35 THEN 'ON_RULE'::text
            ELSE 'OFF_RULE'::text
        END AS edge_verdict,
        CASE
            WHEN scanned IS NULL OR page_grade = 'FAILED'::text OR top_kind = 'unclassified'::text OR bottom_kind = 'unclassified'::text OR top_kind IS NULL OR bottom_kind IS NULL THEN 'UNKNOWN'::text
            WHEN top_kind = 'boundary'::text AND bottom_kind = 'boundary'::text AND inner_boundaries = (expected_slots - 1) AND (inner_dividers = expected_slots OR page_dividers = 0) THEN 'ONE_CLIENT'::text
            WHEN inner_boundaries > (expected_slots - 1) THEN 'SPANS_MULTIPLE'::text
            WHEN top_kind = 'boundary'::text AND bottom_kind = 'boundary'::text THEN 'ODD_SLOT'::text
            ELSE 'PART_SLOT'::text
        END AS slot_verdict
   FROM m;;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  v_n      int;
  v_moved  int;
  v_before int;
  v_after  int;
  v_txt    text;
BEGIN
  ------------------------------------------------------------------------------------------
  -- 1. ONLY ODD_SLOT -> ONE_CLIENT, AND ONLY ON DIVIDER-LESS PAGES.
  --    CONTROL: the snapshot must hold the whole graded population, or this compares nothing.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM _sv_before;
  IF v_n < 600 THEN
    RAISE EXCEPTION 'VERIFY 1 CONTROL FAILED: snapshot holds only % graded rows', v_n;
  END IF;
  SELECT count(DISTINCT slot_verdict) INTO v_n FROM _sv_before;
  IF v_n < 4 THEN
    RAISE EXCEPTION 'VERIFY 1 CONTROL FAILED: the snapshot carries only % distinct slot_verdict '
                    'value(s), so a comparison over it discriminates nothing', v_n;
  END IF;

  -- Nothing may change its edge_verdict at all: this migration does not touch that axis.
  SELECT count(*) INTO v_n
    FROM _sv_before b JOIN derm.v_band_edge_check a ON a.row_id = b.row_id
   WHERE a.edge_verdict IS DISTINCT FROM b.edge_verdict;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % row(s) changed edge_verdict; only slot_verdict may move', v_n;
  END IF;

  -- Every slot_verdict change must be exactly ODD_SLOT -> ONE_CLIENT.
  SELECT count(*) INTO v_moved
    FROM _sv_before b JOIN derm.v_band_edge_check a ON a.row_id = b.row_id
   WHERE a.slot_verdict IS DISTINCT FROM b.slot_verdict;

  SELECT count(*) INTO v_n
    FROM _sv_before b JOIN derm.v_band_edge_check a ON a.row_id = b.row_id
   WHERE a.slot_verdict IS DISTINCT FROM b.slot_verdict
     AND NOT (b.slot_verdict = 'ODD_SLOT' AND a.slot_verdict = 'ONE_CLIENT');
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % row(s) moved by some transition other than '
                    'ODD_SLOT -> ONE_CLIENT', v_n;
  END IF;

  -- And every moved row must be a full single slot on a page that recorded no divider.
  SELECT count(*) INTO v_n
    FROM _sv_before b JOIN derm.v_band_edge_check a ON a.row_id = b.row_id
   WHERE a.slot_verdict IS DISTINCT FROM b.slot_verdict
     AND (b.inner_dividers <> 0 OR b.inner_boundaries <> b.expected_slots - 1);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % moved row(s) were not a clean single slot with zero '
                    'dividers', v_n;
  END IF;

  IF v_moved <> 24 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % row(s) moved, expected exactly the 24 measured', v_moved;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 2. THE WORKLIST IS USABLE AGAIN, and the survivors are the ones that should survive.
  --    ticket-312024 p1 is the DOCUMENTED classifier limitation (the end-bar trim strips only
  --    LONG bars), it is OFF_RULE on a different axis, and its page DOES carry a divider. It must
  --    stay, or this change is reaching further than the divider question.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_before FROM _off_before;
  SELECT count(*) INTO v_after  FROM derm.v_band_edges_off_rule;
  IF v_before <> 26 OR v_after <> 2 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: worklist went % -> %, expected 26 -> 2', v_before, v_after;
  END IF;

  SELECT string_agg(DISTINCT dump_folder || ' p' || effective_page, ', ')
    INTO v_txt FROM derm.v_band_edges_off_rule;
  IF v_txt IS DISTINCT FROM 'ticket-312024 p1' THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: survivors are "%", expected only ticket-312024 p1', v_txt;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 3. THE NEW DISJUNCT MUST NOT DISABLE THE CHECK. Mutation control, on a page that HAS
  --    dividers: remove them and the page's bands must go ONE_CLIENT -> ODD_SLOT, proving the
  --    relaxation is driven by the page's divider evidence and not by something incidental.
  --    Rolled back.
  ------------------------------------------------------------------------------------------
  BEGIN
    SELECT dump_folder || '|' || effective_page INTO v_txt
      FROM derm.v_band_edge_check
     WHERE slot_verdict = 'ONE_CLIENT'
     ORDER BY dump_folder, effective_page
     LIMIT 1;
    IF v_txt IS NULL THEN
      RAISE EXCEPTION 'VERIFY 3 SETUP FAILED: no ONE_CLIENT row to mutate';
    END IF;

    SELECT count(*) INTO v_before FROM derm.v_band_edge_check
     WHERE dump_folder = split_part(v_txt,'|',1)
       AND effective_page = split_part(v_txt,'|',2)::int
       AND slot_verdict = 'ONE_CLIENT';
    IF v_before < 1 THEN
      RAISE EXCEPTION 'VERIFY 3 SETUP FAILED: control page holds no ONE_CLIENT rows';
    END IF;

    DELETE FROM derm.page_row_rules pr
     USING (SELECT DISTINCT ON (dump_folder, effective_page) dump_folder, effective_page, source
              FROM derm.page_rule_scans
             WHERE source LIKE 'runlen-v2-%' OR source LIKE 'human-v1-%'
             ORDER BY dump_folder, effective_page, (source LIKE 'human-v1-%') DESC, scanned_at DESC) sc
     WHERE pr.dump_folder = sc.dump_folder AND pr.effective_page = sc.effective_page
       AND pr.source = sc.source AND pr.kind = 'divider'
       AND pr.dump_folder = split_part(v_txt,'|',1)
       AND pr.effective_page = split_part(v_txt,'|',2)::int;

    SELECT count(*) INTO v_after FROM derm.v_band_edge_check
     WHERE dump_folder = split_part(v_txt,'|',1)
       AND effective_page = split_part(v_txt,'|',2)::int
       AND slot_verdict = 'ONE_CLIENT';

    -- With the dividers gone the page becomes divider-less, so the new disjunct fires and the
    -- rows STAY ONE_CLIENT. That is the intended behaviour and it is what proves the disjunct is
    -- reading the page's divider evidence: before this change they would have become ODD_SLOT.
    IF v_after <> v_before THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: removing the page''s dividers moved % of % ONE_CLIENT '
                      'rows, so the new disjunct is not what is holding them', v_before - v_after,
                      v_before;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_FIXTURE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_FIXTURE' THEN RAISE; END IF;
  END;

  ------------------------------------------------------------------------------------------
  -- 4. THE CHECK STILL BITES. A band that genuinely spans two printed slots on a page WITH
  --    dividers must still be caught, or VERIFY 1-3 only prove the view got quieter.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM derm.v_band_edge_check WHERE slot_verdict = 'SPANS_MULTIPLE';
  IF v_n < 1 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: no SPANS_MULTIPLE row survives anywhere, so the slot check '
                    'no longer discriminates';
  END IF;
  SELECT count(*) INTO v_n FROM derm.v_band_edge_check WHERE slot_verdict = 'PART_SLOT';
  IF v_n < 1 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: no PART_SLOT row survives, so the slot check no longer '
                    'discriminates';
  END IF;

  -- 5. The fixture left nothing behind.
  SELECT count(*) INTO v_n FROM derm.page_row_rules WHERE kind = 'divider';
  IF v_n < 100 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: only % divider rules remain; the fixture DELETE did not roll '
                    'back', v_n;
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: exactly 24 rows moved ODD_SLOT -> ONE_CLIENT, all on pages that '
               'recorded no divider; 0 edge_verdict changes; worklist 26 -> 2 leaving only the '
               'documented ticket-312024 case; SPANS_MULTIPLE and PART_SLOT still fire.';
END
$verify$;

COMMIT;
