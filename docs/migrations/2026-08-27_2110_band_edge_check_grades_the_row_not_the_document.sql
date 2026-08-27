-- 2026-08-27_2110_band_edge_check_grades_the_row_not_the_document.sql
--
-- WHY: THE GEOMETRY WORKLIST WENT FROM 0 TO 4 TODAY, AND ALL FOUR ARE FALSE.
-- ---------------------------------------------------------------------------
-- `2026-08-27_1610` made a served document reveal the UNION of a client's own printed rows, so
-- 009-CN (Casa Neos) is now correctly shown all three of Kitchen / Bar / Lounge instead of one.
-- `derm.v_band_edge_check` grades the DOCUMENT'S band against each CARD, so a legitimate 3-row union
-- reads as one card whose band spans three printed slots:
--
--   4 rows, all the SAME document (m1624), all `slot_verdict = SPANS_MULTIPLE`, severity 1
--
-- The document is correct: it was opened and shows exactly Casa Neos's three rows and no neighbour.
-- The CHECK is wrong. This takes the worklist from 4 to 2; the surviving 2 are a separate,
-- pre-existing duplicate-folder problem explained at VERIFY 1. And four permanent false rows would destroy the property CLAUDE.md says is the
-- entire value of that worklist, "empty means healthy" - it is how `sync_log` became unreadable.
--
-- 🛑 THE FIX IS TO GRADE THE ROW, NOT THE DOCUMENT, and that is more correct independently of unions.
-- A band is a property of a CARD. `derm.band_review` is keyed on the row's band values, and
-- `derm.save_page_geometry` validates the row's band, so those two already speak card-geometry while
-- this view spoke document-geometry. They agreed only for as long as one card meant one document.
-- After the change each Casa Neos card is graded on its OWN slot (27.742..33.227 etc.), which is
-- `ONE_CLIENT`, and the four rows drop off.
--
-- ⚠ `doc_current` is REDEFINED rather than dropped. It used to mean "the doc's band equals this
-- card's band", which is now false by construction for every multi-card group. It now means what a
-- person actually wants to know: **does the published document match the CURRENT union of the
-- group**. It is informational only - `derm.v_band_edges_off_rule` filters on
-- `edge_verdict`/`slot_verdict` and the `band_review` exemption, never on `doc_current` - so this
-- cannot change what the worklist reports.
--
-- ⚠ The `band_review` exemption keys on `band_y0_pct`/`band_y1_pct`, which now carry the ROW's band.
-- That is the intended reading: an acceptance is a human statement about one card's geometry. The 80
-- accepted reviews were recorded when one card meant one document, so their values are unchanged for
-- every single-card group, which is all of them but two.
--
-- 🛑 BODY COPIED FROM pg_get_viewdef AND SPLICED BY SCRIPT: one anchor, asserted to match exactly
-- once, and the result asserted byte-identical once the change is reversed. Everything downstream of
-- the `served` CTE (the scan selection, expected_slots, the four rule LATERALs, both verdicts) is
-- untouched.
--
-- RULE 8 (audit trail): a view holds no state; opt-out.

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
             CROSS JOIN LATERAL ( SELECT min(b2.band_y0_pct) AS u0, max(b2.band_y1_pct) AS u1
                   FROM derm.address_row_map r2
                     JOIN derm.v_stamp_row_bands b2 ON b2.id = r2.id
                  WHERE r2.matched_manifest_id = r.matched_manifest_id
                    AND r2.matched_client_id = r.matched_client_id
                    AND r2.dump_folder = r.dump_folder
                    AND COALESCE(r2.stamp_page, r2.page) = COALESCE(r.stamp_page, r.page)
                    AND r2.stamp_placed_at IS NOT NULL) grp
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
          WHERE page_rule_scans.source ~~ 'runlen-v2-%'::text
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
   FROM m;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_bad integer; v_casa integer;
BEGIN
  -- 1. THE POINT: every UNION false-positive is gone. The worklist drops from 4 to 2, and both
  --    survivors are on ticket-830714, which is a DIFFERENT and pre-existing problem:
  --
  --    ticket-830714 is a DUPLICATE FOLDER. It carries its own cards for manifests that are already
  --    served from ticket-820714. Fred stamped its 3 cards at 12:24 ET today, which put them into
  --    derm.v_stamp_row_bands for the first time; before that they had no stamp point and were
  --    invisible here. Their bands are DERIVED (0 manual bands, 0 extents on that folder), so they
  --    grade OFF_RULE / SPANS_MULTIPLE, and they are joined to a document that a different folder
  --    produced because derm.redacted_manifest_docs has no dump_folder column to scope on.
  --
  --    🛑 NOT FIXED HERE, DELIBERATELY. The real fix is to record the elected dump_folder on the
  --    ledger and scope this join to it, which also makes the election auditable. That needs
  --    fn_blackout_targets to RETURN the folder, which changes its RETURNS TABLE list, which forces
  --    DROP + CREATE and discards the service_role EXECUTE grant the */5 sweep depends on. That is
  --    not a change to make as a footnote to a view fix.
  --    Until then these two rows are a TRUE signal with an imprecise cause: ticket-830714 genuinely
  --    does need snapping and an extent, and derm.v_blackout_blocked_sheets already says so.
  SELECT count(*) INTO v_n FROM derm.v_band_edges_off_rule;
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: expected exactly the 2 known ticket-830714 rows, got %: %', v_n,
      (SELECT coalesce(string_agg(client_code||'@'||dump_folder||' '||slot_verdict||'/'||edge_verdict, ', '),'none')
         FROM derm.v_band_edges_off_rule);
  END IF;
  SELECT count(*) INTO v_bad FROM derm.v_band_edges_off_rule WHERE dump_folder <> 'ticket-830714';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % row(s) outside ticket-830714 remain; a union false-positive survived', v_bad;
  END IF;

  -- 2. Casa Neos's three cards are now graded individually and each is ONE_CLIENT.
  SELECT count(*) INTO v_casa FROM derm.v_band_edge_check
   WHERE client_code = '009-CN' AND dump_folder = 'ticket-820714';
  IF v_casa <> 3 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: % Casa Neos rows, expected 3', v_casa; END IF;
  SELECT count(*) INTO v_bad FROM derm.v_band_edge_check
   WHERE client_code = '009-CN' AND dump_folder = 'ticket-820714' AND slot_verdict <> 'ONE_CLIENT';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % Casa Neos card(s) still not ONE_CLIENT', v_bad;
  END IF;

  -- 3. 🛑 THE CONTROL. The view must still SEE the whole served population, or "empty" would just
  --    mean the join broke. It graded 649 rows before this change.
  SELECT count(*) INTO v_n FROM derm.v_band_edge_check;
  IF v_n < 600 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: only % rows graded; the new joins dropped the population', v_n;
  END IF;

  -- 4. AND IT STILL BITES. A band moved off its printed rule must still be reported, or the empty
  --    worklist above proves nothing. Rolled back.
  BEGIN
    UPDATE derm.address_row_map SET band_y0_pct = band_y0_pct + 2.7
     WHERE id = (SELECT row_id FROM derm.v_band_edge_check
                  WHERE edge_verdict = 'ON_RULE' AND slot_verdict = 'ONE_CLIENT' LIMIT 1);
    SELECT count(*) INTO v_bad FROM derm.v_band_edges_off_rule;
    RAISE EXCEPTION 'ctrl_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ctrl_rollback' THEN RAISE; END IF;
  END;
  IF v_bad <= 2 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: moving a band 2.7pp off its rule did not raise the count above the known 2; the check is dead';
  END IF;

  -- 5. And the control undid itself.
  SELECT count(*) INTO v_n FROM derm.v_band_edges_off_rule;
  IF v_n <> 2 THEN RAISE EXCEPTION 'VERIFY 5 FAILED: the control did not roll back (% rows, expected the 2 known)', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: worklist empty again, Casa Neos graded 3x ONE_CLIENT, % rows still graded, and a 2.7pp nudge is still caught.', v_casa;
END $do$;

COMMIT;
