-- ============================================================================================
-- 2026-09-07_1810_band_edge_check_honours_human_precedence.sql
--
-- Finish 2026-09-07_1745. That migration made a human rule set outrank the detector in
-- derm.v_page_printed_rules and asserted, in its VERIFY 4, that the view was the ONLY place a scan
-- is selected. THAT ASSERTION WAS WRONG, and its own test could not have caught it.
--
-- 🛑 MY ERROR, AND THE SHAPE IS WORTH MORE THAN THE FIX. VERIFY 4 read pg_proc:
--       SELECT count(*) FROM pg_proc p ... WHERE p.prosrc LIKE '%page_rule_scans%'
--                                           AND p.prosrc LIKE '%DISTINCT ON%'
-- A VIEW is not in pg_proc. Its body lives in pg_rewrite and is read with pg_get_viewdef, so the
-- check was structurally incapable of finding a second selection point in a view, which is exactly
-- where the second one is. It returned 0 and read as an all-clear. This is the estate's most
-- repeated failure: an instrument that cannot see the thing it is pointed at, reporting silence.
-- Found by an adversarial review, not by the test.
--
-- derm.v_band_edge_check carries its own copy:
--       SELECT DISTINCT ON (dump_folder, effective_page) ...
--        WHERE source ~~ 'runlen-v2-%' OR source ~~ 'human-v1-%'
--        ORDER BY dump_folder, effective_page, scanned_at DESC        <-- recency alone
--
-- WHAT IT COSTS while they disagree: v_band_edge_check is the grader behind
-- derm.v_band_edges_off_rule, the "empty is healthy" worklist this estate checks after any stamping
-- session. With the two views selecting different scans, a band snapped to a HUMAN rule would be
-- graded against DETECTOR rules and report OFF_RULE, and a band snapped to detector rules on a
-- page later measured by hand would grade clean while the guards used different geometry. The
-- worklist would fill with false positives and, worse, its silence would stop meaning anything.
-- Nothing served to a customer changes either way: this view grades, it does not redact.
--
-- ⚠ THE DUPLICATION ITSELF IS NOT FIXED HERE, ONLY THE DIVERGENCE. The right end state is that
-- v_band_edge_check reads derm.v_page_printed_rules instead of re-deriving the selection, which is
-- what that view's own COMMENT already tells people to do. Collapsing it means restructuring four
-- LATERAL joins that key on `pr.source = sc.source`, and doing that in the same breath as an
-- incident response is how a grader gets quietly broken. Recorded as owed work.
--
-- BODY PROVENANCE: pg_get_viewdef output, patched by anchored replacement of ONE line
-- (scripts/probes/rev/, anchor asserted to match exactly once). Never retyped.
--
-- RULE 8: no schema change, view only.
-- ============================================================================================

BEGIN;

CREATE TEMP TABLE _bec_before ON COMMIT DROP AS
  SELECT dump_folder, effective_page, row_id, edge_verdict, slot_verdict
    FROM derm.v_band_edge_check;

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
   FROM m;;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  v_n     int;
  v_src_a text;
BEGIN
  ------------------------------------------------------------------------------------------
  -- 1. NO GRADE MOVED. Every row must keep the verdicts it had before.
  --    CONTROL: the snapshot must be non-empty and must contain both verdict vocabularies,
  --    or "nothing changed" is a statement about an empty set.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM _bec_before;
  IF v_n < 100 THEN
    RAISE EXCEPTION 'VERIFY 1 CONTROL FAILED: snapshot holds only % rows', v_n;
  END IF;
  SELECT count(DISTINCT edge_verdict) INTO v_n FROM _bec_before;
  IF v_n < 2 THEN
    RAISE EXCEPTION 'VERIFY 1 CONTROL FAILED: the snapshot carries only % distinct edge_verdict '
                    'value(s), so a comparison over it discriminates nothing', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM (
    (SELECT dump_folder, effective_page, row_id, edge_verdict, slot_verdict FROM _bec_before
     EXCEPT
     SELECT dump_folder, effective_page, row_id, edge_verdict, slot_verdict FROM derm.v_band_edge_check)
    UNION ALL
    (SELECT dump_folder, effective_page, row_id, edge_verdict, slot_verdict FROM derm.v_band_edge_check
     EXCEPT
     SELECT dump_folder, effective_page, row_id, edge_verdict, slot_verdict FROM _bec_before)) x;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % row(s) changed verdict. Expected a no-op on live data.', v_n;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 2. THE TWO SELECTION POINTS NOW AGREE, page by page, over the WHOLE estate.
  --    This is the assertion 1745's VERIFY 4 was trying to make and could not.
  ------------------------------------------------------------------------------------------
  -- The view exposes no scan_source column, so compare the RULE COUNT each side resolves for a
  -- page. The two selection points picking different scans on the same page shows up here,
  -- because a scan's n_rules travels with it. CONTROL below proves the comparison discriminates.
  SELECT count(*) INTO v_n
    FROM (SELECT DISTINCT dump_folder, effective_page, n_rules FROM derm.v_band_edge_check
           WHERE n_rules IS NOT NULL) b
    JOIN (SELECT dump_folder, effective_page, count(*) AS n
            FROM derm.v_page_printed_rules GROUP BY 1,2) g
      ON g.dump_folder = b.dump_folder AND g.effective_page = b.effective_page
   WHERE g.n <> b.n_rules;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % page(s) where the grader resolved a different rule count '
                    'than the guards, i.e. a different scan', v_n;
  END IF;

  SELECT count(*) INTO v_n
    FROM (SELECT DISTINCT dump_folder, effective_page FROM derm.v_band_edge_check
           WHERE n_rules IS NOT NULL) b
    JOIN (SELECT DISTINCT dump_folder, effective_page FROM derm.v_page_printed_rules) g
      ON g.dump_folder = b.dump_folder AND g.effective_page = b.effective_page;
  IF v_n < 50 THEN
    RAISE EXCEPTION 'VERIFY 2 CONTROL FAILED: only % page(s) are compared, so the assertion above '
                    'is close to vacuous', v_n;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 3. THE NEW ARM, EXERCISED. Live data cannot reach it, so build the displacing scan in a
  --    rolled-back savepoint and prove BOTH views hold the human set.
  --    MUTATION CONTROL: the OLD ordering, evaluated over the same rows, must pick the fixture.
  ------------------------------------------------------------------------------------------
  BEGIN
    INSERT INTO derm.page_rule_scans
      (dump_folder, effective_page, source_url, n_rules, n_boundaries, pitch_pct, grade, detail,
       source, scanned_at, source_etag, skew_saturated)
    SELECT s.dump_folder, s.effective_page, s.source_url, 1, 1, s.pitch_pct, 'OK',
           'VERIFY FIXTURE, rolled back', 'runlen-v2-9999-01-01', now(), s.source_etag, false
      FROM derm.page_rule_scans s
     WHERE s.dump_folder = 'ticket-833049' AND s.effective_page = 1
       AND s.source LIKE 'human-v1-%';

    INSERT INTO derm.page_row_rules
      (dump_folder, effective_page, rule_pct, kind, run_frac, ink_frac, source)
    VALUES ('ticket-833049', 1, 11.111, 'boundary', 0.99, 0.9, 'runlen-v2-9999-01-01');

    SELECT source INTO v_src_a FROM derm.v_page_printed_rules
     WHERE dump_folder = 'ticket-833049' AND effective_page = 1 LIMIT 1;
    IF v_src_a NOT LIKE 'human-v1-%' THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: v_page_printed_rules was displaced (now %)', v_src_a;
    END IF;

    -- The grader exposes no source, so discriminate on n_rules: the human set carries 7, the
    -- fixture carries 1. A displaced grader reads 1.
    SELECT max(n_rules) INTO v_n FROM derm.v_band_edge_check
     WHERE dump_folder = 'ticket-833049' AND effective_page = 1;
    IF v_n IS NOT NULL AND v_n <> 7 THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: the grader resolved % rules for a page whose human set has '
                      '7, so it was displaced by the newer detector fixture', v_n;
    END IF;

    -- MUTATION CONTROL: recency alone must pick the fixture, or the fixture does not reproduce
    -- the defect and the two assertions above prove nothing.
    SELECT source INTO v_src_a FROM (
      SELECT DISTINCT ON (s.dump_folder, s.effective_page) s.source
        FROM derm.page_rule_scans s
       WHERE (s.source LIKE 'runlen-v2-%' OR s.source LIKE 'human-v1-%')
         AND s.dump_folder = 'ticket-833049' AND s.effective_page = 1
       ORDER BY s.dump_folder, s.effective_page, s.scanned_at DESC) o;
    IF v_src_a <> 'runlen-v2-9999-01-01' THEN
      RAISE EXCEPTION 'VERIFY 3 CONTROL FAILED: the old ordering picks %, not the fixture', v_src_a;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_FIXTURE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_FIXTURE' THEN RAISE; END IF;
  END;

  SELECT count(*) INTO v_n FROM derm.page_rule_scans WHERE source = 'runlen-v2-9999-01-01';
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 3 CLEANUP FAILED: % fixture row(s) survived', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.page_row_rules WHERE source = 'runlen-v2-9999-01-01';
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 3 CLEANUP FAILED: % fixture rule(s) survived', v_n; END IF;

  ------------------------------------------------------------------------------------------
  -- 4. THE CHECK 1745 SHOULD HAVE RUN. Sweep VIEWS as well as functions for a third selection
  --    point. pg_proc cannot see a view body; pg_get_viewdef can.
  --    CONTROL: the same sweep with the exclusion removed must find v_band_edge_check itself,
  --    or it is another instrument that cannot see its target.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname IN ('derm','public','ops') AND c.relkind IN ('v','m')
     AND pg_get_viewdef(c.oid, true) LIKE '%page_rule_scans%'
     AND pg_get_viewdef(c.oid, true) LIKE '%DISTINCT ON%'
     AND c.relname NOT IN ('v_page_printed_rules','v_band_edge_check');
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: % further view(s) select a scan themselves', v_n;
  END IF;

  SELECT count(*) INTO v_n
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname IN ('derm','public','ops') AND c.relkind IN ('v','m')
     AND pg_get_viewdef(c.oid, true) LIKE '%page_rule_scans%'
     AND pg_get_viewdef(c.oid, true) LIKE '%DISTINCT ON%';
  IF v_n < 2 THEN
    RAISE EXCEPTION 'VERIFY 4 CONTROL FAILED: the view sweep finds only % selection point(s), so '
                    'it cannot see what it is looking for', v_n;
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: no grade moved, the grader and the guards select the same scan '
               'on every page, the new arm is exercised with a mutation control, and the view '
               'sweep that 1745 owed is now run with its own positive control.';
END
$verify$;

COMMIT;
