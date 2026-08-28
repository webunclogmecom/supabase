-- 2026-08-28_2150_expected_slots_is_per_card_not_per_client.sql
--
-- WHY: THE MULTI-GDO SPLIT MADE THE BAND GRADER EXPECT THE WRONG NUMBER OF SLOTS.
-- ---------------------------------------------------------------------------
-- `derm.v_band_edge_check.expected_slots` counts every printed row a CLIENT owns on a page, by
-- joining `derm.v_sheet_printed_rows` on `client_id`. `slot_verdict` then requires
-- `inner_dividers = expected_slots`, so a band grades ONE_CLIENT only when it covers that many slots.
--
-- That was right while a client held exactly ONE card. Since the multi-GDO work a client can hold
-- one card PER PERMIT, each covering exactly one printed row, and the CLIENT total was still being
-- applied to every one of them. Casa Neos on ticket-312433 p1 holds three permits, so all three of
-- its cards were graded against `expected_slots = 3` while each correctly covers a single row, and
-- all three landed on `derm.v_band_edges_off_rule` as ODD_SLOT.
--
-- Measured before this migration: the worklist held 6 rows and 3 were exactly those Casa Neos cards,
-- every one `edge_verdict = ON_RULE` with real edge gaps of 0.102 to 0.228pp against a 0.35pp
-- tolerance, and bands tiling 33.104 -> 40.108 -> 47.251 -> 54.778 with no gap or overlap.
-- The bands are correct. The expectation was not.
--
-- THE FIX: divide by the number of cards the client holds on that page. Correct in BOTH directions,
-- which is what makes it a fix rather than a special case carved out for one folder:
--     3 printed rows / 3 cards = 1   ticket-312433, Casa Neos, split per permit
--     3 printed rows / 1 card  = 3   ticket-833395, 242-WYN, still un-split, and that band really
--                                    must span all three of its printed rows
--     1 printed row  / 1 card  = 1   every single-permit client
-- VERIFY 2 is the 242-WYN control, and it is the assertion that matters: a divisor that flattened a
-- genuinely multi-row band to 1 would satisfy VERIFY 1 just as well and be wrong.
--
-- Integer division truncates. That is the lenient direction and it still FLAGS rather than hides: a
-- band covering more slots than expected reports SPANS_MULTIPLE, which is the loud outcome.
--
-- BODY COPIED FROM pg_get_viewdef AND SPLICED BY SCRIPT, per this repo's CREATE OR REPLACE rule.
-- One anchor, asserted to match exactly once; every other byte of the view, including the scan
-- selection, the four rule LATERALs and both verdicts, is unchanged. Nothing was retyped.
--
-- NOT FIXED HERE, and it is a different defect: `ticket-312024` p1 067-TCE joined the worklist this
-- evening as the redact sweep published that folder. Its band (24.312 .. 32.796) is right; the
-- newest scan of that page is missing the roster's FIRST boundary at 24.420, so the nearest rule to
-- the top edge is the divider at 28.608 and the gap reads 4.296pp. That is the classify.js end-trim
-- limitation recorded in `2026-08-28_2010`, whose general fix was deliberately not shipped because
-- it has to be validated against all 168 already-measured pages. The band's top edge sits 0.108pp
-- ABOVE the true boundary, i.e. outward into the header region and not into another client, so it
-- is a false positive on the worklist and not an exposure.
--
-- RULE 8 (audit trail): a view holds no state. Opt-out.

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
                  WHERE a2.id = s.row_id AND derm.fn_sheet_image_position(a2.dump_folder, vpr.printed_page) = s.effective_page), 0::bigint)
            /
            -- 🛑 PER CARD, NOT PER CLIENT. The subquery above counts every printed row the CLIENT
            -- owns on this page. Since the multi-GDO split a client can hold one card PER PERMIT,
            -- each covering exactly ONE printed row, so applying the client total to every card
            -- graded all three Casa Neos bands ODD_SLOT while each was correct. Dividing by the
            -- number of cards the client holds on this page is right in both directions:
            --   3 printed rows / 3 cards = 1  (ticket-312433, Casa Neos, split per permit)
            --   3 printed rows / 1 card  = 3  (ticket-833395, 242-WYN, still un-split: that band
            --                                  really must span all three of its printed rows)
            --   1 printed row  / 1 card  = 1  (every single-permit client)
            -- Integer division truncates, which is the lenient direction and still flags rather
            -- than hides: a band covering more slots than expected reports SPANS_MULTIPLE.
            GREATEST(COALESCE(( SELECT count(*) AS count
                   FROM derm.address_row_map a3
                  WHERE a3.dump_folder = s.dump_folder
                    AND a3.matched_client_id = ( SELECT a4.matched_client_id
                                                   FROM derm.address_row_map a4 WHERE a4.id = s.row_id)
                    AND COALESCE(a3.stamp_page, a3.page) = s.effective_page), 1::bigint), 1::bigint),
            1::bigint)::integer AS expected_slots,
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
DECLARE v_n integer; v_casa integer; v_wyn integer; v_graded integer;
        v_before integer; v_after integer; v_row bigint; v_folders text;
BEGIN
  -- 1. Casa Neos: three cards, each now expecting ONE slot and each grading ONE_CLIENT.
  SELECT count(*) INTO v_casa FROM derm.v_band_edge_check
   WHERE dump_folder = 'ticket-312433' AND client_code = '009-CN' AND expected_slots = 1;
  IF v_casa <> 3 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % Casa Neos cards expect 1 slot, wanted 3', v_casa;
  END IF;
  SELECT count(*) INTO v_n FROM derm.v_band_edge_check
   WHERE dump_folder = 'ticket-312433' AND client_code = '009-CN' AND slot_verdict <> 'ONE_CLIENT';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % Casa Neos card(s) still not ONE_CLIENT', v_n;
  END IF;

  -- 2. THE CONTROL IN THE OTHER DIRECTION. 242-WYN on ticket-833395 still holds ONE card against
  --    three printed rows, so it must STILL expect 3. If this reads 1, the divisor has flattened a
  --    genuinely multi-row band and the change is wrong rather than right.
  SELECT coalesce(max(expected_slots), 0) INTO v_wyn FROM derm.v_band_edge_check
   WHERE dump_folder = 'ticket-833395' AND client_code = '242-WYN';
  IF v_wyn <> 3 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: 242-WYN on ticket-833395 expects % slots, wanted 3', v_wyn;
  END IF;

  -- 3. Those three rows leave the worklist, and nothing else joins it. The count itself is NOT
  --    asserted: the redact sweep is actively publishing ticket-312024 and each new document adds a
  --    gradable band, so a pinned number would fail on timing rather than on correctness. What is
  --    asserted is the folder set, which is the claim that matters.
  SELECT count(*) INTO v_n FROM derm.v_band_edges_off_rule WHERE dump_folder = 'ticket-312433';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: % ticket-312433 row(s) still on the worklist', v_n;
  END IF;
  SELECT coalesce(string_agg(DISTINCT dump_folder, ', '), 'none') INTO v_folders
    FROM derm.v_band_edges_off_rule
   WHERE dump_folder NOT IN ('ticket-830714', 'ticket-312024');
  IF v_folders <> 'none' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: unexpected folder(s) on the worklist: %', v_folders;
  END IF;

  -- 4. THE POPULATION CONTROL. The view must still grade the whole served estate. Without this an
  --    empty worklist would be satisfied just as well by a splice that broke the join.
  SELECT count(*) INTO v_graded FROM derm.v_band_edge_check;
  IF v_graded < 600 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: only % bands graded; the splice dropped the population', v_graded;
  END IF;

  -- 5. AND IT STILL BITES. A band dragged 1.5pp off its rule must still be reported. The row is
  --    picked with a >4pp height so the nudge cannot violate address_row_map_band_range_chk, and
  --    1.5pp lands mid-gap between printed rules (pitch is ~3.4 to 4.2pp) so it cannot accidentally
  --    snap onto the next one. Rolled back by the subtransaction.
  SELECT count(*) INTO v_before FROM derm.v_band_edges_off_rule;
  SELECT row_id INTO v_row FROM derm.v_band_edge_check
   WHERE edge_verdict = 'ON_RULE' AND slot_verdict = 'ONE_CLIENT'
     AND band_y1_pct - band_y0_pct > 4.0
   ORDER BY row_id LIMIT 1;
  IF v_row IS NULL THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: no clean band available as a control subject';
  END IF;
  BEGIN
    UPDATE derm.address_row_map SET band_y0_pct = band_y0_pct + 1.5 WHERE id = v_row;
    SELECT count(*) INTO v_after FROM derm.v_band_edges_off_rule;
    RAISE EXCEPTION 'ctrl_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ctrl_rollback' THEN RAISE; END IF;
  END;
  IF v_after <> v_before + 1 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: a 1.5pp nudge moved the worklist % -> %, expected % -> %; the '
      'check is not biting and every clean row above is meaningless',
      v_before, v_after, v_before, v_before + 1;
  END IF;

  -- 6. Nothing served went short.
  SELECT count(*) INTO v_n FROM derm.v_served_blackout_short;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 6 FAILED: % served document(s) short', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: Casa Neos 3 cards expect 1 slot each and grade ONE_CLIENT, 242-WYN still '
    'expects 3, no ticket-312433 rows remain, % bands still graded, and a 1.5pp nudge still moves '
    'the worklist % -> %.', v_graded, v_before, v_after;
END $do$;

COMMIT;
