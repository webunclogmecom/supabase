-- 2026-09-02_1610_band_worklist_sees_hand_measured_pages.sql
--
-- WHAT: derm.v_band_edge_check's scan CTE now admits 'human-v1-%' alongside 'runlen-v2-%'. One
--       WHERE clause. Same columns, same DISTINCT ON, same joins.
--
-- WHY:  2026-09-02_0330 widened derm.v_page_printed_rules to admit operator-marked scans, and
--       2026-09-02_1330 widened the writer. This view was the THIRD place the same predicate
--       lives, and it was missed both times. So an operator can hand-measure a page, the save
--       guards will grade it against those marks, and the fleet worklist will not see them.
--
--       Supabase/CLAUDE.md states that scan selection is "defined ONCE, in v_page_printed_rules"
--       and says "Do not re-implement the DISTINCT ON". That sentence describes an intention, not
--       the code: this view still carries its own copy. Measured before this migration:
--         v_band_edge_check definition mentions 'runlen-v2'  -> 1
--         v_band_edge_check definition mentions 'human-v1'   -> 0
--         v_band_edge_check reads v_page_printed_rules       -> false
--
-- WHAT IT WOULD COST, STATED HONESTLY. Today it costs NOTHING: exactly one page in the estate is
--       hand-measured (ticket-834489, 1 of 175 measured pages) and it publishes no documents, so it
--       cannot appear in this view at all -- the view INNER JOINs redacted_manifest_docs. This is a
--       latent defect, and it bites the first time somebody hand-measures a page that ALREADY
--       serves documents, which is precisely the backlog the hand-marking feature was built for.
--       The failure would be silent and in the dangerous direction: the band worklist is the
--       "empty is healthy" check for customer-facing redaction geometry, so a page it cannot see
--       reads as a page with nothing wrong.
--
-- WHY NOT CALL derm._is_rule_source() HERE, which would truly define it once. Because a SECURITY
--       INVOKER function inside a view adds an invoker-side EXECUTE check to the READ path, and
--       that regressed pg_read_all_data with a 42501 once already (2026-08-25_1400). The predicate
--       therefore stays a literal on both views, and VERIFY 2 asserts the two definitions agree so
--       they cannot drift again in silence.
--
-- THE DEFINITION WAS COPIED FROM pg_get_viewdef AND EDITED BY ANCHOR, NEVER RETYPED. Before/after
--    under scripts/probes/geom/. CREATE OR REPLACE keeps the column list identical, so grants
--    survive; VERIFY 4 checks that rather than assuming it.
--
-- RULE 8 (audit): no table or column changes. A view definition only.
-- RULE 2/3: nothing derived, copied or stored.

BEGIN;

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
          -- 2026-09-02: 'human-v1-%' admitted alongside 'runlen-v2-%', matching
          -- derm.v_page_printed_rules. Without this the band worklist cannot see a page an
          -- operator measured by hand: it would keep grading against an older detector scan,
          -- or report UNSCANNED, which reads exactly like a page nobody ever looked at.
          WHERE page_rule_scans.source ~~ 'runlen-v2-%'::text
             OR page_rule_scans.source ~~ 'human-v1-%'::text
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
   FROM m;

DO $$
DECLARE
  v_def text; v_pp text; v_n int; v_before int; v_after int; v_flag text := '';
  v_cols int; v_authn boolean;
BEGIN
  ----------------------------------------------------------------------------
  -- 1. both arms present, claude still excluded
  ----------------------------------------------------------------------------
  SELECT pg_get_viewdef('derm.v_band_edge_check'::regclass, true) INTO v_def;
  IF v_def NOT LIKE '%runlen-v2-%' OR v_def NOT LIKE '%human-v1-%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: the scan CTE does not admit both arms';
  END IF;
  IF v_def LIKE '%claude-%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: claude sources must stay excluded';
  END IF;

  ----------------------------------------------------------------------------
  -- 2. the two views now agree. This is the check that stops a fourth copy drifting.
  ----------------------------------------------------------------------------
  SELECT pg_get_viewdef('derm.v_page_printed_rules'::regclass, true) INTO v_pp;
  IF (v_pp LIKE '%human-v1-%') IS DISTINCT FROM (v_def LIKE '%human-v1-%')
     OR (v_pp LIKE '%runlen-v2-%') IS DISTINCT FROM (v_def LIKE '%runlen-v2-%') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: v_band_edge_check and v_page_printed_rules disagree on the admitted sources';
  END IF;

  ----------------------------------------------------------------------------
  -- 3. BEHAVIOURAL. A structural check cannot show the arm works, and no live page can show it
  --    either: exactly one page is hand-measured and it publishes nothing, so it is outside this
  --    view's universe. So arrange the state on a page that IS published, and roll it back.
  ----------------------------------------------------------------------------
  SELECT count(*) INTO v_before FROM derm.v_band_edge_check;

  BEGIN
    SELECT n_rules INTO v_n FROM derm.v_band_edge_check
     WHERE dump_folder = 'window7-sheet6' AND effective_page = 1 LIMIT 1;
    IF v_n IS NULL THEN
      RAISE EXCEPTION 'VERIFY 3 SETUP FAILED: window7-sheet6 p1 is not in the worklist, so this proves nothing';
    END IF;
    IF v_n = 99 THEN
      RAISE EXCEPTION 'VERIFY 3 SETUP FAILED: the sentinel value is already present';
    END IF;

    INSERT INTO derm.page_rule_scans
      (dump_folder, effective_page, source_url, n_rules, n_boundaries, grade, source, scanned_at, source_etag)
    SELECT 'window7-sheet6', 1, source_url, 99, 9, 'OK', 'human-v1-verify1610', now(), source_etag
      FROM derm.page_rule_scans
     WHERE dump_folder = 'window7-sheet6' AND effective_page = 1
     ORDER BY scanned_at DESC LIMIT 1;

    SELECT n_rules INTO v_n FROM derm.v_band_edge_check
     WHERE dump_folder = 'window7-sheet6' AND effective_page = 1 LIMIT 1;
    IF v_n IS DISTINCT FROM 99 THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: the hand-marked scan is still invisible to the worklist (n_rules=%)', v_n;
    END IF;

    v_flag := 'ok';
    RAISE EXCEPTION 'ROLLBACK' USING ERRCODE = 'ZZ031';
  EXCEPTION WHEN SQLSTATE 'ZZ031' THEN NULL;
  END;
  IF v_flag <> 'ok' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: the probe block did not complete';
  END IF;

  SELECT count(*) INTO v_n FROM derm.page_rule_scans WHERE source = 'human-v1-verify1610';
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 3 FAILED: % probe scan(s) survived', v_n; END IF;

  ----------------------------------------------------------------------------
  -- 4. no existing row moved, and the shape and grants survived CREATE OR REPLACE
  ----------------------------------------------------------------------------
  SELECT count(*) INTO v_after FROM derm.v_band_edge_check;
  IF v_after <> v_before THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: the worklist moved from % to % rows; no live page is hand-measured, so it must not change', v_before, v_after;
  END IF;
  SELECT count(*) INTO v_cols FROM information_schema.columns
   WHERE table_schema='derm' AND table_name='v_band_edge_check';
  IF v_cols <> 23 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: the view now has % columns, expected 23', v_cols;
  END IF;
  -- The grant is asserted as MEASURED, not as assumed: my first draft asserted authenticated held
  -- nothing here and that was simply wrong. CREATE OR REPLACE preserves grants, and this pins it.
  SELECT has_table_privilege('authenticated','derm.v_band_edge_check','SELECT') INTO v_authn;
  IF v_authn IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: authenticated lost SELECT on the worklist';
  END IF;

  RAISE NOTICE 'OK: the band worklist now sees hand-measured pages; % rows unchanged.', v_after;
END $$;

COMMIT;
