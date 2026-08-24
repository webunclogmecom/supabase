-- ============================================================================
-- 2026-08-24_1620  slot_verdict learns the permit grain
-- ============================================================================
--
-- Fred: "teach slot_verdict the permit grain".
--
-- ---------------------------------------------------------------------------
-- PART 0.  THE OLD RULE WAS THE N=1 CASE OF THIS ONE
-- ---------------------------------------------------------------------------
--
-- A generated DERM address sheet prints ONE ROW PER ACTIVE GDO PERMIT (2026-08-24_0450), so a
-- client with three permits owns three consecutive printed slots and its band must cover all three.
-- They are its own facilities; blacking two would hide the client's own compliance record from
-- itself.
--
-- slot_verdict assumed one printed slot per client, which was true of all 635 bands that existed
-- before ticket-833395 was stamped. Written out, the old rule was:
--
--     inner_boundaries = 0   AND inner_dividers = 1     -> ONE_SLOT
--
-- and the general rule for a client owning N printed slots on this page is simply:
--
--     inner_boundaries = N-1 AND inner_dividers = N     -> ONE_CLIENT
--
-- N=1 reproduces the old rule exactly, which is why 637 of 638 bands do not move.
--
-- ---------------------------------------------------------------------------
-- PART 1.  🛑 N IS PER PAGE, NOT PER CLIENT, AND GETTING THAT WRONG BREAKS A CORRECT BAND
-- ---------------------------------------------------------------------------
--
-- The obvious implementation reads address_sheet_clients.rows_printed, the client's permit count.
-- **That is wrong**, and there is a live case that proves it.
--
-- On sheet 1082 (ticket-832194), 043-MIL holds TWO permits and occupies printed rows 5 and 6. Five
-- rows fit on a page, so those two rows STRADDLE A PAGE BOUNDARY: row 5 is on printed page 1, row 6
-- on printed page 2. On either page it owns exactly ONE slot. Using its permit count would expect 2
-- slots on a page that holds 1, and this migration would flag a band that is correct today
-- (measured: 043-MIL is ONE_SLOT now and must stay passing).
--
-- So N counts derm.v_sheet_printed_rows entries for this client whose printed_page maps, THROUGH
-- derm.fn_sheet_image_position, to this band's effective_page. That mapping matters on its own:
-- effective_page is an IMAGE POSITION and printed_page is the LOGICAL page, and ticket-833395's two
-- images were stored in reverse order.
--
-- ⚠ 577 of 638 bands resolve no generated sheet at all -- the handwritten window<N>-sheet<M> set --
-- and for those N falls back to 1, i.e. exactly the old behaviour. The permit rule is a fact about
-- OUR generator, not about a sheet a driver filled in by hand.
--
-- ---------------------------------------------------------------------------
-- PART 2.  MEASURED BEFORE AND AFTER
-- ---------------------------------------------------------------------------
--
--     ONE_SLOT   583  ->  ONE_CLIENT   584
--     PART_SLOT   25  ->  PART_SLOT     25
--     SPANS_MUL   23  ->  SPANS_MUL     22
--     UNKNOWN      7  ->  UNKNOWN        7
--
-- **Exactly one band changes pass/fail**: ticket-833395 p1 / 242-WYN, SPANS_MULTIPLE -> ONE_CLIENT,
-- with expected_slots=3, inner_boundaries=2, inner_dividers=3.
--
-- ⚠ A first draft of the measurement reported FIVE changes. It had dropped the requirement that
-- both edges sit on a BOUNDARY, so four PART_SLOT bands (ticket-831102 p2/169-TCE,
-- window5-sheet3 p2/033-LG and p2/026-HAP, window4-sheet5 p2/209-TRUE) appeared to pass. They do
-- not, and they must not: an edge on a mid-slot divider is a different defect from a wrong slot
-- count and this change does not touch it.
--
-- ---------------------------------------------------------------------------
-- PART 3.  HOW THE DEFINITIONS WERE PRODUCED
-- ---------------------------------------------------------------------------
--
-- Not retyped. They are the live pg_views definitions with three anchored splices in
-- v_band_edge_check and one in v_band_edges_off_rule, applied by
-- scripts/probes/tmp/patch-slotverdict.js, which requires every anchor to match exactly once,
-- reverses each splice and demands byte equality with the original, and refuses if the retired
-- ONE_SLOT label survives anywhere.
--
-- expected_slots is added as a VISIBLE COLUMN, not hidden inside the CASE, so a person reading a
-- flagged row can see what the check expected and why.
--
-- ⚠ ONE_SLOT is RENAMED to ONE_CLIENT on purpose. The verdict never meant "one slot" -- it meant
-- "this band covers exactly the printed rows belonging to this client", and the two coincided until
-- a multi-permit client appeared. Leaving the old name would invite the next reader to re-derive the
-- one-slot assumption. CLAUDE.md is updated in the same commit.
--
-- ---------------------------------------------------------------------------
-- PART 4.  THE MANUAL ACCEPTANCE IS WITHDRAWN
-- ---------------------------------------------------------------------------
--
-- 2026-08-24_1555 put 242-WYN's three-slot band in derm.band_review because the check could not
-- express it. The check can now express it, so the acceptance is deleted: a human acceptance should
-- record a judgement a machine cannot make, never paper over a check that was simply wrong.
-- PART 6 deletes it and then requires the folder to STAY off the worklist on the check's own merits,
-- which is the real proof that this migration did the job.
--
-- ADR 010 rule 8 (audit): two views replaced; no table, column or trigger changes. The one row
-- deleted from derm.band_review is on an audited table (trigger added 2026-08-23_2333), so it is
-- recoverable from audit.logs.old_row.
-- ============================================================================

BEGIN;

-- the worklist depends on the check, so it goes first and comes back last
DROP VIEW IF EXISTS derm.v_band_edges_off_rule;
DROP VIEW IF EXISTS derm.v_band_edge_check;

CREATE VIEW derm.v_band_edge_check AS
WITH served AS (
         SELECT r.id AS row_id,
            r.dump_folder,
            COALESCE(r.stamp_page, r.page) AS effective_page,
            c.client_code,
            d.band_y0 AS band_y0_pct,
            d.band_y1 AS band_y1_pct,
            r.band_source,
            r.stamp_y_pct,
            (r.band_y0_pct IS NOT NULL) AS band_is_override,
            ((r.band_y0_pct IS NULL) OR ((abs((d.band_y0 - r.band_y0_pct)) <= 0.001) AND (abs((d.band_y1 - r.band_y1_pct)) <= 0.001))) AS doc_current,
            d.source_url AS doc_source_url,
            d.url AS doc_url
           FROM ((derm.address_row_map r
             JOIN clients c ON ((c.id = r.matched_client_id)))
             JOIN derm.redacted_manifest_docs d ON (((d.manifest_id = r.matched_manifest_id) AND (d.client_id = r.matched_client_id) AND (d.effective_page = COALESCE(r.stamp_page, r.page)))))
          WHERE ((d.band_y0 IS NOT NULL) AND (d.band_y1 IS NOT NULL))
        ), scan AS (
         SELECT page_rule_scans.dump_folder,
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
          WHERE (page_rule_scans.source = 'runlen-v2-2026-08-21'::text)
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
                   FROM (((derm.address_row_map a2
                     JOIN derm_manifests dm ON (((dm.id = a2.matched_manifest_id) AND (dm.deleted_at IS NULL))))
                     JOIN derm.address_sheet_manifests asm ON ((asm.manifest_id = dm.id)))
                     JOIN derm.address_sheets ash ON (((ash.id = asm.sheet_id) AND (ash.deleted_at IS NULL))))
                     JOIN derm.v_sheet_printed_rows vpr ON (((vpr.sheet_id = asm.sheet_id) AND (vpr.client_id = a2.matched_client_id)))
                  WHERE ((a2.id = s.row_id) AND (derm.fn_sheet_image_position(a2.dump_folder, vpr.printed_page) = s.effective_page))), 0), 1)::integer AS expected_slots,
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
           FROM (((((served s
             LEFT JOIN scan sc ON (((sc.dump_folder = s.dump_folder) AND (sc.effective_page = s.effective_page))))
             LEFT JOIN LATERAL ( SELECT abs((pr.rule_pct - s.band_y0_pct)) AS d,
                    pr.kind
                   FROM derm.page_row_rules pr
                  WHERE ((pr.dump_folder = s.dump_folder) AND (pr.effective_page = s.effective_page) AND (pr.source = 'runlen-v2-2026-08-21'::text))
                  ORDER BY (abs((pr.rule_pct - s.band_y0_pct)))
                 LIMIT 1) t ON (true))
             LEFT JOIN LATERAL ( SELECT abs((pr.rule_pct - s.band_y1_pct)) AS d,
                    pr.kind
                   FROM derm.page_row_rules pr
                  WHERE ((pr.dump_folder = s.dump_folder) AND (pr.effective_page = s.effective_page) AND (pr.source = 'runlen-v2-2026-08-21'::text))
                  ORDER BY (abs((pr.rule_pct - s.band_y1_pct)))
                 LIMIT 1) b ON (true))
             LEFT JOIN LATERAL ( SELECT count(*) AS n
                   FROM derm.page_row_rules pr
                  WHERE ((pr.dump_folder = s.dump_folder) AND (pr.effective_page = s.effective_page) AND (pr.source = 'runlen-v2-2026-08-21'::text) AND (pr.kind = 'boundary'::text) AND (pr.rule_pct > (s.band_y0_pct + 0.35)) AND (pr.rule_pct < (s.band_y1_pct - 0.35)))) ib ON (true))
             LEFT JOIN LATERAL ( SELECT count(*) AS n
                   FROM derm.page_row_rules pr
                  WHERE ((pr.dump_folder = s.dump_folder) AND (pr.effective_page = s.effective_page) AND (pr.source = 'runlen-v2-2026-08-21'::text) AND (pr.kind = 'divider'::text) AND (pr.rule_pct > (s.band_y0_pct + 0.35)) AND (pr.rule_pct < (s.band_y1_pct - 0.35)))) idv ON (true))
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
            WHEN (scanned IS NULL) THEN 'UNSCANNED'::text
            WHEN (source_etag IS DISTINCT FROM derm._img_etag(doc_source_url)) THEN 'STALE'::text
            WHEN ((top_gap_pct IS NULL) OR (bottom_gap_pct IS NULL)) THEN 'OFF_RULE'::text
            WHEN ((top_gap_pct <= 0.35) AND (bottom_gap_pct <= 0.35)) THEN 'ON_RULE'::text
            ELSE 'OFF_RULE'::text
        END AS edge_verdict,
        CASE
            WHEN ((scanned IS NULL) OR (page_grade = 'FAILED'::text) OR (top_kind = 'unclassified'::text) OR (bottom_kind = 'unclassified'::text) OR (top_kind IS NULL) OR (bottom_kind IS NULL)) THEN 'UNKNOWN'::text
            WHEN ((top_kind = 'boundary'::text) AND (bottom_kind = 'boundary'::text) AND (inner_boundaries = (expected_slots - 1)) AND (inner_dividers = expected_slots)) THEN 'ONE_CLIENT'::text
            WHEN (inner_boundaries > (expected_slots - 1)) THEN 'SPANS_MULTIPLE'::text
            WHEN ((top_kind = 'boundary'::text) AND (bottom_kind = 'boundary'::text)) THEN 'ODD_SLOT'::text
            ELSE 'PART_SLOT'::text
        END AS slot_verdict
   FROM m;

COMMENT ON VIEW derm.v_band_edge_check IS
  'Two verdicts per served band, and SAFE IS THE CONJUNCTION. edge_verdict asks whether a line of '
  'TEXT is bisected; slot_verdict asks whether the band covers exactly the printed rows belonging '
  'to THIS CLIENT. ONE_CLIENT, not ONE_SLOT: a generated sheet prints one row per ACTIVE GDO '
  'permit, so a multi-permit client legitimately spans several slots. expected_slots is that count '
  'for this band''s page, from derm.v_sheet_printed_rows, and falls back to 1 for a handwritten '
  'sheet with no generated layout. '
  'See docs/migrations/2026-08-24_1620_slot_verdict_permit_grain.sql.';

CREATE VIEW derm.v_band_edges_off_rule AS
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
    edge_verdict,
    slot_verdict,
        CASE
            WHEN (slot_verdict = 'SPANS_MULTIPLE'::text) THEN 1
            WHEN (slot_verdict = ANY (ARRAY['PART_SLOT'::text, 'ODD_SLOT'::text])) THEN 2
            WHEN (edge_verdict = ANY (ARRAY['STALE'::text, 'UNSCANNED'::text])) THEN 3
            WHEN (edge_verdict = 'OFF_RULE'::text) THEN 4
            ELSE 5
        END AS severity
   FROM derm.v_band_edge_check v
  WHERE ((NOT ((edge_verdict = 'ON_RULE'::text) AND (slot_verdict = 'ONE_CLIENT'::text))) AND (NOT (EXISTS ( SELECT 1
           FROM derm.band_review br
          WHERE ((br.row_id = v.row_id) AND (br.verdict = 'accepted'::text) AND (br.band_y0_pct = round(v.band_y0_pct, 3)) AND (br.band_y1_pct = round(v.band_y1_pct, 3)))))));

COMMENT ON VIEW derm.v_band_edges_off_rule IS
  'The band-geometry worklist. EMPTY IS HEALTHY. A band passes only when edge_verdict=ON_RULE AND '
  'slot_verdict=ONE_CLIENT, or when a person has accepted its exact geometry in derm.band_review. '
  'Ordered by severity: 1 spans more slots than the client owns, 2 an edge inside a slot, '
  '3 unscanned or stale, 4 an edge off the printed rules.';

REVOKE ALL ON derm.v_band_edge_check FROM PUBLIC;
REVOKE ALL ON derm.v_band_edges_off_rule FROM PUBLIC;
DO $g$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON derm.v_band_edge_check FROM anon';
    EXECUTE 'REVOKE ALL ON derm.v_band_edges_off_rule FROM anon';
  END IF;
END $g$;
GRANT SELECT ON derm.v_band_edge_check, derm.v_band_edges_off_rule TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- PART 5.  Withdraw the acceptance the check no longer needs
-- ---------------------------------------------------------------------------

DELETE FROM derm.band_review WHERE reviewed_by = 'claude-permit-grain-2026-08-24';

-- ---------------------------------------------------------------------------
-- PART 6.  VERIFY
-- ---------------------------------------------------------------------------

DO $verify$
DECLARE v_txt text; v_n int; v_exp int;
BEGIN
  ------------------------------------------------------------------------
  -- 6.1  The whole distribution, so a change anywhere else is caught.
  ------------------------------------------------------------------------
  SELECT string_agg(slot_verdict || '=' || n, ' ' ORDER BY slot_verdict) INTO v_txt
    FROM (SELECT slot_verdict, count(*) n FROM derm.v_band_edge_check GROUP BY 1) q;
  IF v_txt IS DISTINCT FROM 'ONE_CLIENT=584 PART_SLOT=25 SPANS_MULTIPLE=22 UNKNOWN=7' THEN
    RAISE EXCEPTION 'verdict distribution is not the measured one: %', v_txt;
  END IF;

  IF EXISTS (SELECT 1 FROM derm.v_band_edge_check WHERE slot_verdict = 'ONE_SLOT') THEN
    RAISE EXCEPTION 'the retired ONE_SLOT label is still being produced';
  END IF;

  ------------------------------------------------------------------------
  -- 6.2  The band this was for, and the evidence behind it.
  ------------------------------------------------------------------------
  SELECT expected_slots, slot_verdict INTO v_exp, v_txt
    FROM derm.v_band_edge_check
   WHERE dump_folder = 'ticket-833395' AND client_code = '242-WYN';
  IF v_exp <> 3 OR v_txt IS DISTINCT FROM 'ONE_CLIENT' THEN
    RAISE EXCEPTION '242-WYN grades % with expected_slots=%, wanted ONE_CLIENT/3', v_txt, v_exp;
  END IF;

  ------------------------------------------------------------------------
  -- 6.3  CONTROL for PART 1: 043-MIL holds TWO permits but they straddle a page,
  --      so it must expect ONE slot on its band's page and keep passing. If this
  --      reads 2, the implementation used the permit count instead of the page
  --      count and has just flagged a correct band.
  ------------------------------------------------------------------------
  SELECT expected_slots, slot_verdict INTO v_exp, v_txt
    FROM derm.v_band_edge_check
   WHERE dump_folder = 'ticket-832194' AND client_code = '043-MIL';
  IF v_exp <> 1 OR v_txt IS DISTINCT FROM 'ONE_CLIENT' THEN
    RAISE EXCEPTION 'CONTROL FAILED: 043-MIL expects % slots and grades % -- N is not per page', v_exp, v_txt;
  END IF;

  ------------------------------------------------------------------------
  -- 6.4  CONTROL: the check has not gone blind. 22 bands must still be
  --      SPANS_MULTIPLE, and none of them may be a multi-permit client on its
  --      own rows. A rule that passes everything would satisfy 6.1 to 6.3.
  ------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM derm.v_band_edge_check WHERE slot_verdict = 'SPANS_MULTIPLE';
  IF v_n <> 22 THEN RAISE EXCEPTION 'expected 22 remaining SPANS_MULTIPLE, found %', v_n; END IF;

  SELECT count(*) INTO v_n FROM derm.v_band_edge_check
   WHERE slot_verdict = 'SPANS_MULTIPLE' AND inner_boundaries <= expected_slots - 1;
  IF v_n <> 0 THEN
    RAISE EXCEPTION '% bands are called SPANS_MULTIPLE while within their own slot count', v_n;
  END IF;

  ------------------------------------------------------------------------
  -- 6.5  THE REAL PROOF: the manual acceptance is gone, and 833395 stays off the
  --      worklist on the check's own merits.
  ------------------------------------------------------------------------
  IF EXISTS (SELECT 1 FROM derm.band_review WHERE reviewed_by = 'claude-permit-grain-2026-08-24') THEN
    RAISE EXCEPTION 'the manual acceptance was not withdrawn';
  END IF;
  SELECT count(*) INTO v_n FROM derm.v_band_edges_off_rule WHERE dump_folder = 'ticket-833395';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'ticket-833395 is back on the worklist with % bands, so the check still cannot express a multi-permit band', v_n;
  END IF;

  ------------------------------------------------------------------------
  -- 6.6  The other 47 acceptances still apply, and the worklist is unchanged.
  ------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM derm.band_review WHERE verdict = 'accepted';
  IF v_n <> 47 THEN RAISE EXCEPTION 'expected the 47 earlier acceptances, found %', v_n; END IF;

  SELECT count(*) INTO v_n FROM derm.v_band_edges_off_rule;
  IF v_n <> 33 THEN RAISE EXCEPTION 'worklist moved to % rows, expected the same 33', v_n; END IF;

  ------------------------------------------------------------------------
  -- 6.7  Grants survived the drop and rebuild.
  ------------------------------------------------------------------------
  IF NOT has_table_privilege('authenticated', 'derm.v_band_edge_check', 'SELECT')
     OR NOT has_table_privilege('service_role', 'derm.v_band_edges_off_rule', 'SELECT') THEN
    RAISE EXCEPTION 'a rebuilt view lost a grant';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
     AND has_table_privilege('anon', 'derm.v_band_edge_check', 'SELECT') THEN
    RAISE EXCEPTION 'anon can read the rebuilt check';
  END IF;

  RAISE NOTICE 'OK: 1 of 638 bands moved (242-WYN -> ONE_CLIENT), 043-MIL still expects 1, 22 SPANS_MULTIPLE remain, acceptance withdrawn';
END $verify$;

COMMIT;
