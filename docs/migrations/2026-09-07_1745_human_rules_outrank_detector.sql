-- ============================================================================================
-- 2026-09-07_1745_human_rules_outrank_detector.sql
--
-- Make "human lines are authoritative" TRUE. Today it is only true by accident of timing.
--
-- WHY (Fred, 2026-09-07): "no separate approve step, human lines are authoritative."
--
-- 🛑 THE DEFECT THAT DECISION EXPOSES. derm.v_page_printed_rules picks ONE scan per page with
--      ORDER BY s.dump_folder, s.effective_page, s.scanned_at DESC
-- which is recency alone. A person draws lines by hand precisely when the detector is wrong, and
-- the very next detector run on that page then displaces them SILENTLY, because it is newer.
-- With an approve step a human would have been in the loop to notice. Fred has removed that step,
-- so the precedence has to be structural instead.
--
-- ⚠ It is reachable today, not hypothetical. derm.record_page_rules is called by the Studio's
-- re-measure button, which runs the detector in the operator's browser. Pressing it on a page that
-- was measured by hand overwrites the hand measurement, and the existing supersession guard does
-- not stop it: that guard only refuses a FAILED scan replacing an OK one, and a detector run on
-- these pages grades OK. ticket-833049 p1 is exactly this shape right now (human-v1-2026-09-07
-- with 7 lines, sitting on top of runlen-v2-2026-09-04 with 16), and Fred is about to work in it.
--
-- WHAT IT WOULD COST: v_page_printed_rules is the single scan-selection point for the whole
-- geometry lane, so a flip changes what _page_geometry_violations G9 checks band edges against and
-- what v_band_edge_check grades. A page measured by hand BECAUSE the detector was wrong would
-- revert to the wrong geometry, and correct serving bands would start reporting OFF_RULE.
--
-- THE CHANGE: one line. Human sets sort first, then by recency within each class, so a NEWER hand
-- measurement still replaces an older one. A detector run is still RECORDED (evidence is worth
-- keeping and page_rule_scans is the audit of what was seen), it just never wins.
--
-- ⚠ To get the detector back on a page, measure it by hand again. There is deliberately no
-- "unpin" verb: an operator-visible switch that silently hands a serving page's geometry back to
-- the detector is the thing this migration exists to prevent.
--
-- BODY PROVENANCE: pulled with pg_get_viewdef and patched by anchored replacement
-- (scripts/probes/g6/, one anchor, asserted to match exactly once). Never retyped.
--
-- 🛑 PROVABLE NO-OP AT INSTALL, WHICH IS WHY THE FIXTURE BELOW IS NOT OPTIONAL. All 5 human-
-- measured pages currently have zero newer scans, so the new arm changes nothing on live data and
-- a clean install would prove only that the old behaviour still works. VERIFY 2 builds the
-- displacing scan in a rolled-back savepoint and carries a MUTATION CONTROL proving the OLD
-- ordering would have flipped that page to the detector.
--
-- RULE 8: no schema change, view only. derm.page_rule_scans and derm.page_row_rules are unchanged.
-- ============================================================================================

BEGIN;

-- Snapshot what every page resolves to BEFORE the change, so the no-op claim is measured and not
-- asserted. Temp table, dropped with the session.
CREATE TEMP TABLE _before_active ON COMMIT DROP AS
  SELECT DISTINCT dump_folder, effective_page, source
    FROM derm.v_page_printed_rules;

CREATE OR REPLACE VIEW derm.v_page_printed_rules AS
WITH scan AS (
         SELECT DISTINCT ON (s.dump_folder, s.effective_page) s.dump_folder,
            s.effective_page,
            s.source,
            s.scanned_at,
            s.grade,
            s.source_etag,
            s.source_url
           FROM derm.page_rule_scans s
          WHERE s.source ~~ 'runlen-v2-%'::text OR s.source ~~ 'human-v1-%'::text
          ORDER BY s.dump_folder, s.effective_page, (s.source ~~ 'human-v1-%'::text) DESC, s.scanned_at DESC
        )
 SELECT sc.dump_folder,
    sc.effective_page,
    pr.rule_pct,
    pr.kind,
    pr.kind_confirmed,
    pr.run_frac,
    pr.ink_frac,
    sc.source,
    sc.scanned_at,
    sc.grade,
    sc.source_etag,
    sc.source_url
   FROM scan sc
     JOIN derm.page_row_rules pr ON pr.dump_folder = sc.dump_folder AND pr.effective_page = sc.effective_page AND pr.source = sc.source;;

COMMENT ON VIEW derm.v_page_printed_rules IS
  'The ONE scan-selection point for page geometry: one scan per (dump_folder, effective_page), '
  'with its own rules joined on its own source. A HUMAN set (source human-v1-%) outranks a '
  'detector set (runlen-v2-%) regardless of which is newer, because Fred removed the approve step '
  'on 2026-09-07 and made hand-drawn lines authoritative; within a class the newest wins, so a '
  'fresh hand measurement still replaces an older one. A detector run on a hand-measured page is '
  'still recorded in derm.page_rule_scans, it just never wins. Do not re-implement this DISTINCT '
  'ON anywhere else.';

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  v_n        int;
  v_src      text;
  v_old_src  text;
  v_folder   text := 'ticket-833049';
  v_page     int  := 1;
BEGIN
  ------------------------------------------------------------------------------------------
  -- 1. NO-OP ON LIVE DATA. Every page must resolve to exactly the scan it resolved to before.
  --    CONTROL: the snapshot must be non-empty, or this compares nothing to nothing.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM _before_active;
  IF v_n < 100 THEN
    RAISE EXCEPTION 'VERIFY 1 CONTROL FAILED: the before-snapshot holds only % pages, so the '
                    'comparison below is vacuous', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM (
    SELECT dump_folder, effective_page, source FROM _before_active
    EXCEPT
    SELECT DISTINCT dump_folder, effective_page, source FROM derm.v_page_printed_rules
    UNION ALL
    SELECT DISTINCT dump_folder, effective_page, source FROM derm.v_page_printed_rules
    EXCEPT
    SELECT dump_folder, effective_page, source FROM _before_active) x;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % page(s) changed which scan they resolve to. This was '
                    'meant to be a no-op on today''s data.', v_n;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 2. THE NEW ARM, EXERCISED. Live data cannot reach it (no human page has a newer detector
  --    scan), so build one. A detector scan is inserted on ticket-833049 p1 dated AFTER the
  --    human set, with one rule at a position the human set does not carry.
  --    Rolled back at the end of this block; nothing survives.
  ------------------------------------------------------------------------------------------
  SELECT source INTO v_src FROM derm.v_page_printed_rules
   WHERE dump_folder = v_folder AND effective_page = v_page LIMIT 1;
  IF v_src NOT LIKE 'human-v1-%' THEN
    RAISE EXCEPTION 'VERIFY 2 SETUP FAILED: % p% does not currently resolve to a human scan (it '
                    'resolves to %), so it is the wrong fixture', v_folder, v_page, v_src;
  END IF;

  BEGIN
    INSERT INTO derm.page_rule_scans
      (dump_folder, effective_page, source_url, n_rules, n_boundaries, pitch_pct, grade, detail,
       source, scanned_at, source_etag, skew_saturated)
    SELECT s.dump_folder, s.effective_page, s.source_url, 1, 1, s.pitch_pct, 'OK',
           'VERIFY FIXTURE, rolled back', 'runlen-v2-9999-01-01', now(), s.source_etag, false
      FROM derm.page_rule_scans s
     WHERE s.dump_folder = v_folder AND s.effective_page = v_page AND s.source = v_src;

    INSERT INTO derm.page_row_rules
      (dump_folder, effective_page, rule_pct, kind, run_frac, ink_frac, source)
    VALUES (v_folder, v_page, 11.111, 'boundary', 0.99, 0.9, 'runlen-v2-9999-01-01');

    -- 2a. The human set must STILL win, even though the detector scan is newer.
    SELECT source INTO v_src FROM derm.v_page_printed_rules
     WHERE dump_folder = v_folder AND effective_page = v_page LIMIT 1;
    IF v_src NOT LIKE 'human-v1-%' THEN
      RAISE EXCEPTION 'VERIFY 2 FAILED: a newer detector scan displaced the human set (now %). '
                      'Human lines are not authoritative.', v_src;
    END IF;

    -- 2b. And the fixture rule must be absent from what the guards read.
    SELECT count(*) INTO v_n FROM derm.v_page_printed_rules
     WHERE dump_folder = v_folder AND effective_page = v_page AND rule_pct = 11.111;
    IF v_n <> 0 THEN
      RAISE EXCEPTION 'VERIFY 2b FAILED: the fixture detector rule is visible to the guards';
    END IF;

    -- 2c. MUTATION CONTROL. Evaluate the OLD ordering (recency alone) over the SAME rows. It
    --     must pick the detector. Without this, 2a passes just as well against a view that
    --     ignores the fixture for some unrelated reason, and proves nothing.
    SELECT source INTO v_old_src FROM (
      SELECT DISTINCT ON (s.dump_folder, s.effective_page) s.source
        FROM derm.page_rule_scans s
       WHERE (s.source LIKE 'runlen-v2-%' OR s.source LIKE 'human-v1-%')
         AND s.dump_folder = v_folder AND s.effective_page = v_page
       ORDER BY s.dump_folder, s.effective_page, s.scanned_at DESC) o;
    IF v_old_src <> 'runlen-v2-9999-01-01' THEN
      RAISE EXCEPTION 'VERIFY 2c CONTROL FAILED: the OLD ordering picks % rather than the fixture, '
                      'so the fixture does not reproduce the defect and 2a proves nothing.',
        v_old_src;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_FIXTURE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_FIXTURE' THEN RAISE; END IF;
  END;

  -- 2d. The fixture is gone.
  SELECT count(*) INTO v_n FROM derm.page_rule_scans WHERE source = 'runlen-v2-9999-01-01';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2d FAILED: % fixture scan row(s) survived', v_n;
  END IF;
  SELECT count(*) INTO v_n FROM derm.page_row_rules WHERE source = 'runlen-v2-9999-01-01';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2d FAILED: % fixture rule row(s) survived', v_n;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 3. WITHIN A CLASS, RECENCY STILL DECIDES. A newer HUMAN set must replace an older one, or
  --    an operator could never correct their own measurement.
  ------------------------------------------------------------------------------------------
  BEGIN
    INSERT INTO derm.page_rule_scans
      (dump_folder, effective_page, source_url, n_rules, n_boundaries, pitch_pct, grade, detail,
       source, scanned_at, source_etag, skew_saturated)
    SELECT s.dump_folder, s.effective_page, s.source_url, 1, 1, s.pitch_pct, 'OK',
           'VERIFY FIXTURE, rolled back', 'human-v1-9999-01-01', now(), s.source_etag, false
      FROM derm.page_rule_scans s
     WHERE s.dump_folder = v_folder AND s.effective_page = v_page AND s.source LIKE 'human-v1-%'
     LIMIT 1;

    INSERT INTO derm.page_row_rules
      (dump_folder, effective_page, rule_pct, kind, run_frac, ink_frac, source)
    VALUES (v_folder, v_page, 22.222, 'boundary', 0.99, 0.9, 'human-v1-9999-01-01');

    SELECT source INTO v_src FROM derm.v_page_printed_rules
     WHERE dump_folder = v_folder AND effective_page = v_page LIMIT 1;
    IF v_src <> 'human-v1-9999-01-01' THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: a NEWER human set did not replace the older one (got %), '
                      'so an operator cannot correct their own measurement.', v_src;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_FIXTURE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_FIXTURE' THEN RAISE; END IF;
  END;

  SELECT count(*) INTO v_n FROM derm.page_rule_scans WHERE source = 'human-v1-9999-01-01';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 CLEANUP FAILED: % fixture row(s) survived', v_n;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 4. This is still the ONLY scan-selection point. If a second DISTINCT ON over
  --    page_rule_scans exists somewhere, fixing the view fixes half the lane.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('derm','public')
     AND p.prosrc LIKE '%page_rule_scans%'
     AND p.prosrc LIKE '%DISTINCT ON%'
     AND p.proname <> 'record_page_rules';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: % function(s) select a scan themselves rather than reading '
                    'v_page_printed_rules, so this fix is only half applied', v_n;
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: no live page moved, a newer detector scan can no longer '
               'displace a human set (mutation control confirms the old ordering would have), '
               'a newer human set still wins, fixtures cleaned up.';
END
$verify$;

COMMIT;
