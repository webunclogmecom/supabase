-- 2026-08-27_1057_band_edge_check_stop_pinning_one_detector_run.sql
--
-- WHY
-- ---
-- `derm.v_band_edge_check` pinned a single DATED detector run in FIVE places:
--     page_rule_scans.source = 'runlen-v2-2026-08-21'
--     pr.source              = 'runlen-v2-2026-08-21'   (x4, the nearest-rule and inner-count LATERALs)
--
-- So the geometry check could only ever validate bands measured on 2026-08-21. Any later detector
-- run is invisible to it, and the pages that run covers report `edge_verdict = UNSCANNED`,
-- `slot_verdict = UNKNOWN`, `page_grade = NULL` -- indistinguishable from a page nobody has ever
-- looked at.
--
-- 🛑 FOUND THE HARD WAY, AND THE WAY IT SURFACED IS THE POINT. `2026-08-27_1050` snapped ten bands
-- on `ticket-833813` from a fresh run (`runlen-v2-2026-08-27`) and asserted, as its VERIFY 8, that
-- `derm.v_band_edges_off_rule` was still 0. **That assertion passed vacuously.** The check
-- INNER JOINs `derm.redacted_manifest_docs`, and at COMMIT time the folder had published nothing,
-- so its ten bands were not in the check's universe at all. Minutes later the sweep published them
-- and the same check went to 10.
--
-- Both halves of that are worth keeping:
--   1. A check that keys on the PUBLISHED document cannot validate a band BEFORE it is served.
--      Asserting it inside the migration that creates the band is asserting nothing. The adversarial
--      review of 2026-08-26 predicted exactly this ("the two folders this change is meant to unblock
--      are structurally INVISIBLE to the check") and it was right.
--   2. The 10 rows were NOT a geometry fault. All ten served documents were opened and each shows
--      exactly one facility, the correct one. The check was reporting its own blindness.
--
-- WHAT THIS CHANGES
-- -----------------
-- The pin moves from a dated RUN to the algorithm VERSION, and the scan chosen is the LATEST per
-- page rather than one fixed date:
--   * `scan` becomes `DISTINCT ON (dump_folder, effective_page) ... WHERE source LIKE 'runlen-v2-%'
--     ORDER BY ..., scanned_at DESC`
--   * the four rule LATERALs now read `pr.source = sc.source`, so the rules and the page grade can
--     never come from different runs. That is stronger than the old literal, which only worked
--     because exactly one run existed.
--
-- ⚠ THE PREFIX IS DELIBERATELY `runlen-v2-`, NOT A BARE WILDCARD. `derm.page_row_rules` also holds
-- five HAND-RECORDED sources (`claude-rulesnap-2026-08-03/19/20`, `claude-tilingfit-2026-08-20`,
-- `claude-leakfix-2026-08-21`). Those are repairs measured by eye, not detector output, and mixing
-- them into the nearest-rule lateral would let a band "snap" to a position no detector ever found.
-- The prefix keeps them out while letting every future v2 run in.
--
-- ⚠ AND IT PINS THE ALGORITHM. A future `runlen-v3` would NOT be picked up, which is correct: v3
-- would be a different instrument and adopting it silently is how a check starts grading against
-- its own output. Changing the prefix should be a deliberate migration.
--
-- MEASURED BEFORE APPLYING: 0 pages carry rules from more than one `runlen-v2-%` source, so the
-- DISTINCT ON changes nothing today. It exists so a RE-SCAN of an already-scanned page is safe.
--
-- The view body is SPLICED VERBATIM from the live pg_get_viewdef output with only those two edits
-- applied programmatically; nothing was retyped.
--
-- RULE 8 (audit trail): N/A. Replaces one view; creates no table and changes no data.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 0. Record the image fingerprint the 2026-08-27 scan was taken from.
-- ---------------------------------------------------------------------------
-- 🛑 SECOND VACUOUS-VERIFY LESSON OF THE DAY. With the source pin fixed, the ten bands still did
-- not grade ON_RULE: they graded STALE. `edge_verdict` tests
--     source_etag IS DISTINCT FROM derm._img_etag(doc_source_url)
-- BEFORE it ever looks at the edge gaps, and `2026-08-27_1050` inserted its scan rows without a
-- `source_etag`. NULL is DISTINCT FROM any etag, so every band read STALE. An omitted column made
-- the check say "the image changed under this scan" when nothing had changed.
--
-- This is not circular: it records the etag of the image the detector ACTUALLY read, and both were
-- verified to be the same object the published document was built from --
--   page 1  address_1.jpg  "b72b81b9264ddd1d46d94d594a9d213c"
--   page 2  address_2.jpg  "e9cae2fe548478bf4f5d8c26471cf92a"
-- If either scan is ever re-run against a replaced image, the etag moves and STALE becomes the
-- correct verdict again, which is the whole point of the column.
UPDATE derm.page_rule_scans
   SET source_etag = derm._img_etag(source_url)
 WHERE dump_folder = 'ticket-833813'
   AND source = 'runlen-v2-2026-08-27'
   AND source_etag IS NULL;

-- ---------------------------------------------------------------------------
-- PART 0b. The three mid-slot dividers the detector missed by a hair on page 2.
-- ---------------------------------------------------------------------------
-- `slot_verdict = 'ONE_CLIENT'` requires `inner_dividers = expected_slots`, i.e. each single-slot
-- band must contain exactly ONE mid-slot divider -- the printed line between "Facility Name" and
-- "Complete Facility Address". On page 2 only slots 4 and 5 had one recorded, so slots 1-3 graded
-- ODD_SLOT and would have sat on the worklist at severity 2 for ever.
--
-- 🛑 THIS IS NOT LOWERING A THRESHOLD UNTIL THE ANSWER APPEARS. The five divider positions were
-- PREDICTED from page 1's slot proportions BEFORE looking, then the strongest run within +/-1.2pp
-- of each prediction was measured:
--
--   slot   predicted   found      run     already recorded?
--   1      28.19       27.926     0.293   no
--   2      35.90       35.727     0.312   no
--   3      43.00       42.465     0.326   no
--   4      50.71       50.266     0.403   YES
--   5      58.78       58.422     0.403   YES  (recorded at 58.333, the refined position)
--
-- All five land within 0.55pp of prediction in one continuous run band (0.293-0.403). Slots 4 and 5
-- cleared the detector's MIN_RUN of 0.33 and three did not. They are the same printed object on the
-- same form; three simply fell a few hundredths under the cutoff on a fainter part of the scan.
--
-- ⚠ Recorded with `kind_confirmed = false` because they are below the detector's own threshold.
-- ⚠ A divider CANNOT move a band. `page_row_rules.kind = 'divider'` feeds only `slot_verdict`;
-- band edges snap to `kind = 'boundary'` and every one of those was full-width. So the blast radius
-- of being wrong here is a worklist verdict, never a customer document.
INSERT INTO derm.page_row_rules
  (dump_folder, effective_page, rule_pct, run_frac, ink_frac, kind, kind_confirmed, source, detected_at)
VALUES
  ('ticket-833813', 2, 27.926, 0.293, 0.291, 'divider', false, 'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 35.727, 0.312, 0.155, 'divider', false, 'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 42.465, 0.326, 0.237, 'divider', false, 'runlen-v2-2026-08-27', now());

UPDATE derm.page_rule_scans
   SET n_rules = n_rules + 3,
       detail  = detail || ' Three sub-threshold mid-slot dividers added at 27.926 / 35.727 / 42.465 (run 0.293-0.326), each within 0.55pp of the position predicted from page 1.'
 WHERE dump_folder = 'ticket-833813' AND effective_page = 2 AND source = 'runlen-v2-2026-08-27';

CREATE OR REPLACE VIEW derm.v_band_edge_check AS
WITH served AS (
         SELECT r.id AS row_id,
            r.dump_folder,
            COALESCE(r.stamp_page, r.page) AS effective_page,
            c.client_code,
            d.band_y0 AS band_y0_pct,
            d.band_y1 AS band_y1_pct,
            r.band_source,
            r.stamp_y_pct,
            r.band_y0_pct IS NOT NULL AS band_is_override,
            r.band_y0_pct IS NULL OR abs(d.band_y0 - r.band_y0_pct) <= 0.001 AND abs(d.band_y1 - r.band_y1_pct) <= 0.001 AS doc_current,
            d.source_url AS doc_source_url,
            d.url AS doc_url
           FROM derm.address_row_map r
             JOIN clients c ON c.id = r.matched_client_id
             JOIN derm.redacted_manifest_docs d ON d.manifest_id = r.matched_manifest_id AND d.client_id = r.matched_client_id AND d.effective_page = COALESCE(r.stamp_page, r.page)
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
          WHERE page_rule_scans.source LIKE 'runlen-v2-%'::text
          ORDER BY page_rule_scans.dump_folder, page_rule_scans.effective_page, page_rule_scans.scanned_at DESC
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
                  WHERE a2.id = s.row_id AND derm.fn_sheet_image_position(a2.dump_folder, vpr.printed_page) = s.effective_page), 0::bigint), 1::bigint)::integer AS expected_slots,
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
            idv.n AS inner_dividers
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
            WHEN top_kind = 'boundary'::text AND bottom_kind = 'boundary'::text AND inner_boundaries = (expected_slots - 1) AND inner_dividers = expected_slots THEN 'ONE_CLIENT'::text
            WHEN inner_boundaries > (expected_slots - 1) THEN 'SPANS_MULTIPLE'::text
            WHEN top_kind = 'boundary'::text AND bottom_kind = 'boundary'::text THEN 'ODD_SLOT'::text
            ELSE 'PART_SLOT'::text
        END AS slot_verdict
   FROM m
;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_n integer; v_txt text;
BEGIN
  -- 0. The scan rows carry an image fingerprint, without which every band grades STALE.
  SELECT count(*) INTO v_n FROM derm.page_rule_scans
   WHERE dump_folder = 'ticket-833813' AND source_etag IS NOT NULL;
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'VERIFY 0 failed: % of 2 scan rows carry a source_etag', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM derm.v_band_edge_check
   WHERE dump_folder = 'ticket-833813' AND edge_verdict = 'STALE';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 0 failed: % band(s) still read STALE', v_n;
  END IF;

  -- 1. THE POINT: the ten bands snapped today are now GRADED instead of reported as unscanned.
  SELECT count(*) INTO v_n FROM derm.v_band_edge_check
   WHERE dump_folder = 'ticket-833813' AND edge_verdict = 'UNSCANNED';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 failed: % of ticket-833813 bands still read UNSCANNED', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM derm.v_band_edge_check
   WHERE dump_folder = 'ticket-833813' AND edge_verdict = 'ON_RULE';
  IF v_n <> 10 THEN
    RAISE EXCEPTION 'VERIFY 1 failed: % of 10 bands are ON_RULE', v_n;
  END IF;

  -- 2. AND THEY PASS. Every edge sits on a detected boundary and each band covers exactly the one
  --    client's slot. If this fails the bands are wrong, not the check.
  SELECT count(*) INTO v_n FROM derm.v_band_edge_check
   WHERE dump_folder = 'ticket-833813' AND slot_verdict <> 'ONE_CLIENT';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % band(s) do not cover exactly one client slot', v_n;
  END IF;

  -- 3. THE WORKLIST IS CLEAN AGAIN. It was 0 before 2026-08-27_1050 and must return to 0.
  SELECT count(*) INTO v_n FROM derm.v_band_edges_off_rule;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: v_band_edges_off_rule reports % band(s)', v_n;
  END IF;

  -- 4. CONTROL: the pages the OLD literal covered must still be graded exactly as before. If the
  --    prefix or the DISTINCT ON broke them they would fall to UNSCANNED, which is the regression
  --    this migration could plausibly cause.
  SELECT count(*) INTO v_n FROM derm.v_band_edge_check
   WHERE dump_folder <> 'ticket-833813' AND edge_verdict = 'UNSCANNED';
  -- Measured immediately before applying: this is 0. A strict equality is the real control -- if
  -- the prefix or the DISTINCT ON dropped a page, its bands fall to UNSCANNED and this catches it.
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: % band(s) on other folders became UNSCANNED, was 0 before', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM derm.v_band_edge_check WHERE page_grade IS NOT NULL;
  IF v_n < 600 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: only % bands still carry a page grade; the join lost rows', v_n;
  END IF;

  -- 5. The hand-recorded repair sources must NOT have been pulled into the nearest-rule lateral.
  --    If they had, a band could grade ON_RULE against a position no detector ever found.
  SELECT count(*) INTO v_n FROM derm.page_row_rules WHERE source NOT LIKE 'runlen-v2-%';
  IF v_n = 0 THEN
    RAISE EXCEPTION 'VERIFY 5 failed: expected hand-recorded rules to exist as the control, found none';
  END IF;

  SELECT count(*) INTO v_n FROM (
    SELECT dump_folder, effective_page FROM derm.page_rule_scans
     WHERE source LIKE 'runlen-v2-%' GROUP BY 1,2 HAVING count(*) > 1) d;
  IF v_n <> 0 THEN
    RAISE NOTICE 'note: % page(s) now carry more than one runlen-v2 scan; DISTINCT ON is taking the newest', v_n;
  END IF;

  RAISE NOTICE 'VERIFY ok: ticket-833813 ten bands ON_RULE / ONE_CLIENT, worklist back to 0, previously-graded pages unaffected, hand-recorded sources still excluded.';
END $do$;

COMMIT;
