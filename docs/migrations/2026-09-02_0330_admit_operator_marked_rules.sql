-- 2026-09-02_0330_admit_operator_marked_rules.sql
--
-- WHAT: derm.v_page_printed_rules now admits scans whose source begins 'human-v1-' as well as
--       'runlen-v2-'. Nothing else changes: same columns, same newest-scan-per-page rule, same
--       join, and 'claude-%' stays excluded.
--
-- WHY:  Fred: "fix it, because i can't do it manually, which is what i want."
--       He is right, and the reason he cannot is sharper than it looked. It is not the guards and
--       it is not the labels. It is derm.fn_validate_page_rules V5, the phase check:
--
--         "cannot split the run values: every rule has the same run length"
--         ... and when a split does exist, the labels must agree with it.
--
--       On ticket-834489 the detector found SEVEN lines running 0.345, 0.356, 0.351, 0.351, 0.347,
--       0.347 and 0.367. There is no long/short split in that set, so V5 can never be satisfied by
--       ANY labelling of those seven. Relabelling is structurally incapable of rescuing that page.
--       Compare ticket-834433, where boundaries ran 0.99 full width against dividers at 0.40 and a
--       relabel was enough (2026-09-02_0245).
--
--       The full-width slot boundaries ARE on that sheet. The scan is too faint for the detector to
--       find them. A person looking at the paper can see them perfectly well. So the operator has to
--       be able to mark a line the detector missed, and those marks have to be admissible.
--
-- 🛑 THE RULE THAT KEEPS THIS HONEST: THE HUMAN SUPPLIES THE POSITION, THE MACHINE SUPPLIES THE
--    MEASUREMENT. When an operator marks a line, the app measures the actual run and ink at that
--    scanline with the same run-length method the detector uses, and records those. It must never
--    synthesise a run value. That is what keeps V5 meaningful: the phase check still compares real
--    measurements, it just gets to see lines the automatic pass could not pick out of the noise.
--    A marked position with a fabricated run would defeat the one check that catches a phase flip.
--
-- WHY A NEW PREFIX RATHER THAN REUSING 'runlen-v2-'. Provenance. A runlen-v2 scan means "a detector
--    chose these positions". An operator-marked page is a different claim and deserves a different
--    label, so that a later reader can tell them apart without guessing. 2026-09-02_0245 used the
--    runlen-v2 prefix legitimately because there only the LABELS were human and every position was
--    the detector's; here the positions themselves can be human, so the prefix must change.
--
-- ⚠ WHY 'claude-%' STAYS OUT, and this is the distinction that matters. page_row_rules holds five
--    hand-recorded claude-* sources from old repair migrations. Those are STALE rows written by a
--    process, not a person looking at the sheet, and CLAUDE.md is explicit that letting a band snap
--    to one would mean grading against a position no detector ever found. An operator marking a
--    line they can see on the scan in front of them is the opposite situation: it is the best
--    evidence available about that page, better than a detector that failed on a faint image.
--    Different provenance, different decision. The exclusion is deliberate and is preserved.
--
-- ⚠ SCAN SELECTION IS UNCHANGED AND STILL SINGLE-SOURCE. DISTINCT ON (dump_folder, effective_page)
--    ordered by scanned_at DESC, and the rules join on that scan's OWN source, so rules and grade
--    can never come from different runs. A later automatic runlen-v2 scan therefore SUPERSEDES an
--    operator-marked one, which is correct: if the detector later reads the page cleanly, its
--    measurement wins.
--
-- RULE 8 (audit): no table or column changes; a view definition only. derm.page_row_rules carries no
--    audit trigger by design (regenerable detector output) and that is not altered here.
-- RULE 2/3: nothing derived, copied or stored.

BEGIN;

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
          -- 2026-09-02: 'human-v1-%' admitted alongside 'runlen-v2-%' so an operator can mark a
          -- printed line the detector could not find on a faint scan. 'claude-%' remains excluded:
          -- those are stale positions from old repair migrations, not a person reading the sheet.
          WHERE s.source ~~ 'runlen-v2-%'::text
             OR s.source ~~ 'human-v1-%'::text
          ORDER BY s.dump_folder, s.effective_page, s.scanned_at DESC
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
     JOIN derm.page_row_rules pr ON pr.dump_folder = sc.dump_folder
       AND pr.effective_page = sc.effective_page
       AND pr.source = sc.source;

DO $$
DECLARE
  v_before int; v_after int; v_claude int; v_cols int; v_authn boolean; v_dupes int;
BEGIN
  -- 1. CONTROL: every page that served rules before must still serve exactly the same number.
  --    A widened filter that changed an existing page's answer would be a regression, not a feature.
  SELECT count(*) INTO v_after FROM derm.v_page_printed_rules;
  SELECT count(*) INTO v_before
    FROM derm.page_rule_scans s
    JOIN derm.page_row_rules pr
      ON pr.dump_folder = s.dump_folder AND pr.effective_page = s.effective_page
     AND pr.source = s.source
   WHERE s.source LIKE 'runlen-v2-%'
     AND s.scanned_at = (SELECT max(s2.scanned_at) FROM derm.page_rule_scans s2
                          WHERE s2.dump_folder = s.dump_folder
                            AND s2.effective_page = s.effective_page
                            AND (s2.source LIKE 'runlen-v2-%' OR s2.source LIKE 'human-v1-%'));
  IF v_after <> v_before THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: view serves % rows, recomputed baseline is %', v_after, v_before;
  END IF;

  -- 2. claude-% must STILL be excluded.
  --    ⚠ CORRECTED WHILE WRITING THIS: my first version asserted that a claude-% SCAN exists, so
  --    that the WHERE clause would be shown to bite. It does not exist, and the migration's own
  --    control caught the false premise. The 198 claude-% rows live in derm.page_row_rules; the
  --    derm.page_rule_scans table has NONE. So those rules are excluded by the JOIN (no scan row to
  --    match), and the WHERE clause is belt-and-braces against a claude scan ever being written.
  --    Asserting the truth instead of the thing I assumed.
  SELECT count(*) INTO v_claude FROM derm.v_page_printed_rules WHERE source LIKE 'claude-%';
  IF v_claude <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % claude-%% rows leaked into the view', v_claude;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM derm.page_row_rules WHERE source LIKE 'claude-%') THEN
    RAISE EXCEPTION 'VERIFY 2b FAILED: no claude-%% rule exists at all, so VERIFY 2 proved nothing';
  END IF;

  -- 3. still one scan per page, or rules and grade could come from different runs
  SELECT count(*) INTO v_dupes FROM (
    SELECT dump_folder, effective_page FROM derm.v_page_printed_rules
     GROUP BY 1,2 HAVING count(DISTINCT source) > 1) d;
  IF v_dupes <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: % page(s) serve rules from more than one source', v_dupes;
  END IF;

  -- 4. shape and grants survived CREATE OR REPLACE
  SELECT count(*) INTO v_cols FROM information_schema.columns
   WHERE table_schema='derm' AND table_name='v_page_printed_rules';
  IF v_cols <> 12 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: view has % columns, expected 12', v_cols;
  END IF;
  SELECT has_table_privilege('authenticated','derm.v_page_printed_rules','SELECT') INTO v_authn;
  IF NOT v_authn THEN
    RAISE EXCEPTION 'VERIFY 4b FAILED: authenticated lost SELECT on the view';
  END IF;

  RAISE NOTICE 'OK: human-v1 admitted, claude-%% still excluded (tested), % rows unchanged, one source per page.', v_after;
END $$;

COMMIT;
