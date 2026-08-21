// Emit the fleet-wide rule-detection migration from classified.json.
// Usage: node gen-migration.js <classified.json> <stamp> <outfile.sql>
const fs = require('fs');
const C = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const STAMP = process.argv[3];
const OUT = process.argv[4];
const REPLACE = process.argv.includes('--replace');
const SOURCE = 'runlen-v2-' + STAMP.slice(0, 10);

const q = s => "'" + String(s).replace(/'/g, "''") + "'";

const scanRows = [];
const ruleRows = [];
for (const p of C) {
  scanRows.push('  (' + [
    q(p.dump_folder), p.pg, q(p.src || ''), p.W || 'null', p.H || 'null',
    p.skew == null ? 'null' : p.skew,
    p.n_rules == null ? 0 : p.n_rules,
    p.n_bounds == null ? 'null' : p.n_bounds,
    p.pitch == null ? 'null' : p.pitch,
    q(p.grade), q(p.why || ''), q(SOURCE),
  ].join(', ') + ')');
  // Belt and braces: two refined positions can still round to the same rule_pct, which is the
  // primary key. Keep the longer run, because a boundary matters more than a divider.
  const seen = new Map();
  for (const r of (p.rules || [])) {
    const prev = seen.get(r.pct);
    if (prev && prev.run >= r.run) continue;
    seen.set(r.pct, r);
  }
  for (const r of seen.values()) {
    const kind = r.kind || 'unclassified';
    const confirmed = (p.grade === 'FAILED' || kind === 'header-footer' || p.split_cut == null)
      ? 'null' : ((r.run >= p.split_cut) === !!r.b);
    ruleRows.push('  (' + [
      q(p.dump_folder), p.pg, r.pct, r.ink, r.run, q(kind), confirmed, q(SOURCE),
    ].join(', ') + ')');
  }
}

const g = {}; C.forEach(p => g[p.grade] = (g[p.grade] || 0) + 1);

const sql = `-- ============================================================================
-- ${STAMP}  Fleet-wide printed-rule detection for the DERM blackout
-- ============================================================================
--
-- Fred: "prioritise building the fleet-wide printed-rule detection pass."
--
-- 🛑 WHAT THIS BUYS, IN ONE SENTENCE: a band edge that sits on a printed rule cannot be inside a
-- line of text, because a printed rule is not text. That is the defect that put Wynd 28's street
-- address into 226-JER's Field Portal document (docs/migrations/2026-08-21_0651), and until now
-- there was no way to check for it except by looking at every page.
--
-- The test existed in principle and was unusable in practice: rules had only ever been recorded by
-- hand, for 30 of 160 pages, so **515 of 626 served bands sat on pages with ZERO detected rules**
-- and the check's silence was absence of data rather than an all-clear.
--
-- MEASURED RESULT: 1,179 of 1,276 served band edges (92.4%) sit on a detected printed rule.
-- **97 edges across 26 pages do not**, and those are the population that can bisect a line of text.
-- That is the whole visual sweep reduced to a worklist.
--
-- ============================================================================================
-- HOW THE DETECTOR WORKS, AND WHY IT IS NOT THE FIFTH FAILED SCORER
-- ============================================================================================
-- Four scorers have already been measured against known truth and rejected (see the 2026-08-21_0651
-- header). Every one of them reasoned about GEOMETRY: how far an edge sits from something. This one
-- measures a physical property of the paper instead.
--
-- Score each scanline by the LONGEST CONTIGUOUS HORIZONTAL RUN of dark pixels across the FULL form
-- width. A printed rule is one unbroken run; a line of text inks a comparable total but only in
-- many short pieces. Over the 30 hand-recorded pages the result is sharply bimodal:
--
--     run 0.40-0.50   108 detections        run 0.80-1.05   171 detections
--     run 0.50-0.80    28 detections   <- the gap between two different printed objects
--
--   run ~1.00  a SLOT BOUNDARY, spanning the whole form including the empty FOG / Hydro / Gravity
--              columns on the right where no text is ever written
--   run ~0.41  a MID-SLOT DIVIDER, between a client's Facility Name row and its Address row,
--              stopping at the first vertical column line
--
-- 🛑 THAT SETTLES THE AMBIGUITY THAT BLOCKED SNAPPING SINCE 2026-08-20. Rules sit ~3.5pp apart
-- while a slot is ~7.8pp, so "snap to the nearest rule" was a coin flip: on ticket-310607 one edge
-- had candidates 1.82 and 2.34 away. Run length tells the two kinds apart directly.
--
-- Three further things the older detector got wrong, each found by a measurement, not by taste:
--   * it scored INK FRACTION over x in [2%,45%] - the text column, the worst possible window for
--     telling a rule from text, and the reason its margin was thin enough to fail on a light scan
--   * it discarded any detection group thicker than 0.8pp, which DELETED the strongest rules
--     whenever their shoulders merged with nearby ink: on ticket-832487 p2 it reported six mid-slot
--     dividers and none of the six slot boundaries
--   * a scan rotated by a fraction of a degree breaks a horizontal run, so v2 shears the sampling
--     across a range of slopes and keeps the best; skew is recorded per page
--
-- CLASSIFICATION is by ALTERNATION, not by a run threshold. Down the roster the two kinds strictly
-- alternate, so the boundaries are one PHASE of the sorted rule list, whichever has the longer runs
-- on average. A fixed threshold fails on four measured shapes: ticket-310607 p1 (clusters at 0.37
-- and 0.56, nothing reaches 0.80), ticket-832996 p1 (a cropped sixth boundary at 0.72),
-- ticket-831938 p2 (four at 0.99, two at 0.51) and derm/1236 p1 (all fourteen at 0.35).
-- The threshold split is still computed and stored per rule as \`kind_confirmed\`, so where the two
-- methods disagree that is visible rather than averaged away. They disagree on 58 of 157 pages,
-- almost always about a single rule, which is why the alternation is primary and the threshold is
-- a cross-check rather than the other way round.
--
-- ============================================================================================
-- CONTROLS. Every one ran before this file was written, and each had to come out a specific way.
-- ============================================================================================
--   REGRESSION      194 rules recorded by hand across 30 pages. In-roster recall 99.5% (185/186),
--                   mean distance 0.062pp, worst 0.274pp. The single miss is ticket-309661 p2 at
--                   41.301, found 0.411pp away. The other 8 hand-recorded rules are the form's
--                   header and footer bars, which sit outside the roster and are deliberately
--                   trimmed; both numbers are reported by classify.js so the flattering one cannot
--                   be quoted alone.
--   MUST FLAG       all 7 band-edge values from the four CONFIRMED leaks, in their pre-repair
--                   state, come back OFF RULE: 226-JER 32.571 (1.585 away), 032-LG 24.190/36.190,
--                   214-MYK 31.830/43.830, 025-GRO 34.340/41.100.
--   MUST PASS       all 6 repaired values come back ON RULE, worst 0.208pp.
--   MUST PASS       ticket-832996 p1, verified clean by eye on 2026-08-21, is ON RULE on every
--                   edge, worst 0.069pp.
--   NEGATIVE        the header/footer trim was added because leaving those bars in graded 81 of
--                   160 pages IRREGULAR. Without the trim the fleet looks broken; with it, 147
--                   pages grade OK. The trim is checked by the regression above, which would drop
--                   if it were cutting real roster rules.
--
-- ⚠ ONE THING THIS FOUND ABOUT MY OWN REPAIR, AND IT IS RECORDED RATHER THAN QUIETLY FIXED.
-- 2026-08-21_0651 moved 226-JER's top edge to 33.500, a value I read off a ruler render by eye and
-- described as "the printed rule at 33.30". The detector puts that rule at 34.156. My reading was
-- 0.66pp out. The repair is still SAFE - 33.500 lands in the whitespace between 242-WYN's address
-- line and the rule, so nothing is bisected - but it is not ON the rule, and this migration snaps
-- it there so the page satisfies the invariant it is introducing. **Eyes were right about which
-- edges were broken and wrong about the exact value by more than half a text line.** That is the
-- argument for this pass in one sentence.
--
-- ============================================================================================
-- WHAT THIS DOES NOT DO
-- ============================================================================================
--   * It does not move any band except the one noted above. The 97 off-rule edges are REPORTED,
--     not repaired: several are on handwritten sheets where the right answer needs a person.
--   * ON_RULE is necessary, not sufficient. It proves no line of text is bisected. It does NOT
--     prove the edge is on the RIGHT rule: a band whose edges are two rules too far apart still
--     swallows a neighbour whole, which is the ticket-831047 shape. Band height and the stamp
--     position are the checks for that, and they already exist.
--   * A printed-but-unrowed slot is still invisible to all of this (CLAUDE.md, 2026-08-19).
--   * Detection is per IMAGE. \`page_rule_scans.source_url\` records which image was scanned so a
--     changed page shows as STALE rather than silently keeping an old verdict.
--
-- ADR 010 rule 8 (audit): both tables hold machine-detected geometry with no human-editable
-- business fields, so audit OPT-OUT, consistent with derm.page_row_rules and derm.page_block_extents
-- as created by 2026-08-03_0340. The one band change lands on derm.address_row_map, whose old value
-- is recorded above.
--
-- ⚠ The 194 rules recorded by earlier migrations are NOT deleted. They stay as historical evidence
-- for the snapping decisions that cite them, and the new views scope to this run's source, so the
-- two generations cannot be mixed. page_row_rules carries no audit trigger, which is exactly why a
-- delete there would be unrecoverable.

BEGIN;

-- ---------------------------------------------------------------------------------------------
-- PART 1  schema
-- ---------------------------------------------------------------------------------------------

ALTER TABLE derm.page_row_rules
  ADD COLUMN IF NOT EXISTS run_frac       numeric(4,3),
  ADD COLUMN IF NOT EXISTS kind           text,
  ADD COLUMN IF NOT EXISTS kind_confirmed boolean;

COMMENT ON COLUMN derm.page_row_rules.run_frac IS
  'Longest contiguous horizontal run of dark pixels on this scanline, as a fraction of the form '
  'width. ~1.00 = a slot boundary spanning the whole form; ~0.41 = a mid-slot divider stopping at '
  'the first vertical column line. This is what separates a printed rule from a line of text; '
  'ink_frac cannot, because dense text inks as much of the column as a rule does.';
COMMENT ON COLUMN derm.page_row_rules.kind IS
  'boundary | divider | unclassified. From the ALTERNATION of the two kinds down the roster, not '
  'from a run threshold: see the 2026-08-21 migration header for the four page shapes where a '
  'fixed threshold gives the wrong answer.';
COMMENT ON COLUMN derm.page_row_rules.kind_confirmed IS
  'TRUE when a plain run-length split of this page agrees with the alternation about this rule. '
  'NULL where the page could not be classified. The two methods disagree on 58 of 157 pages, '
  'almost always about one rule; disagreement is kept visible rather than averaged away.';

CREATE TABLE IF NOT EXISTS derm.page_rule_scans (
  dump_folder    text        NOT NULL,
  effective_page integer     NOT NULL,
  source_url     text        NOT NULL,
  image_w        integer,
  image_h        integer,
  skew           numeric(6,4),
  n_rules        integer     NOT NULL,
  n_boundaries   integer,
  pitch_pct      numeric(7,3),
  grade          text        NOT NULL,
  detail         text,
  source         text        NOT NULL,
  scanned_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dump_folder, effective_page, source),
  CONSTRAINT page_rule_scans_grade_chk CHECK (grade IN ('OK','IRREGULAR','SPARSE','FAILED'))
);

COMMENT ON TABLE derm.page_rule_scans IS
  'One row per DERM address-sheet page that the printed-rule detector has RUN on, whatever the '
  'outcome. 🛑 THIS TABLE EXISTS SO THAT ABSENCE OF DATA CANNOT BE READ AS AN ALL-CLEAR. A page '
  'with a row here graded FAILED is known to be undetectable; a page with NO row here has never '
  'been scanned, and those are different states that a rules table alone cannot tell apart. That '
  'confusion is what made the band-edge check unusable before 2026-08-21: 515 of 626 served bands '
  'sat on pages with zero detected rules and nobody could tell whether that meant clean or unread.';
COMMENT ON COLUMN derm.page_rule_scans.source_url IS
  'The exact image scanned. A page whose served document now uses a different image reads as '
  'STALE in derm.v_band_edge_check rather than silently keeping the old verdict.';
COMMENT ON COLUMN derm.page_rule_scans.grade IS
  'OK = boundaries alternate cleanly and the spacing fits one pitch. IRREGULAR = boundaries found '
  'but the spacing does not fit one pitch. SPARSE = a gap looks like a whole missing boundary. '
  'FAILED = too few rules, or the two phases are indistinguishable. Only OK supports an argument '
  'about which slot a band covers; ALL grades still support the band-edge-on-a-rule check, which '
  'needs the rule positions and not their classification.';
COMMENT ON COLUMN derm.page_rule_scans.skew IS
  'Shear applied before detection, as rise over run across the page. A scan rotated by a fraction '
  'of a degree breaks a horizontal run into pieces, and the run is the whole basis of detection: '
  'v1 found 4 of 12 rules on ticket-311780 p2 for this reason alone.';

-- ---------------------------------------------------------------------------------------------
-- PART 2  the scan record and the detected rules
-- ---------------------------------------------------------------------------------------------

${REPLACE ? `-- 🛑 REPLACE, NOT APPEND. This re-runs the same source label, so the previous generation is
-- removed first. That is a DELETE from two tables that carry no audit trigger, which by the
-- 2026-08-14 rule needs a restore path named before the fact: every deleted row exists as literal
-- SQL in docs/migrations/2026-08-21_0736_fleet_printed_rule_detection.sql, committed and pushed,
-- and the whole set is reproducible from scripts/probes/derm_band_review/ against the same images.
DELETE FROM derm.page_row_rules  WHERE source = ${q(SOURCE)};
DELETE FROM derm.page_rule_scans WHERE source = ${q(SOURCE)};

` : ''}INSERT INTO derm.page_rule_scans
  (dump_folder, effective_page, source_url, image_w, image_h, skew,
   n_rules, n_boundaries, pitch_pct, grade, detail, source)
VALUES
${scanRows.join(',\n')}
ON CONFLICT (dump_folder, effective_page, source) DO UPDATE
  SET source_url = EXCLUDED.source_url, image_w = EXCLUDED.image_w, image_h = EXCLUDED.image_h,
      skew = EXCLUDED.skew, n_rules = EXCLUDED.n_rules, n_boundaries = EXCLUDED.n_boundaries,
      pitch_pct = EXCLUDED.pitch_pct, grade = EXCLUDED.grade, detail = EXCLUDED.detail,
      scanned_at = now();

INSERT INTO derm.page_row_rules
  (dump_folder, effective_page, rule_pct, ink_frac, run_frac, kind, kind_confirmed, source)
VALUES
${ruleRows.join(',\n')}
ON CONFLICT (dump_folder, effective_page, rule_pct) DO UPDATE
  SET ink_frac = EXCLUDED.ink_frac, run_frac = EXCLUDED.run_frac, kind = EXCLUDED.kind,
      kind_confirmed = EXCLUDED.kind_confirmed, source = EXCLUDED.source;

-- ---------------------------------------------------------------------------------------------
-- PART 3  snap the one band edge this pass proved my own eyes got wrong
-- ---------------------------------------------------------------------------------------------
-- 2026-08-21_0651 set this boundary to 33.500 from a ruler render. The rule is at 34.156.
-- 33.500 is safe (whitespace, nothing bisected) but off the rule, so the page would report an
-- OFF_RULE edge against an invariant introduced in the same breath.

${REPLACE ? '-- Already applied by the first run of this pass; both rows are at 34.156 and idempotent.' : ''}
UPDATE derm.address_row_map SET band_y1_pct = 34.156, band_source = 'runlen-snap-${STAMP.slice(0, 10)}', band_set_at = now() WHERE id = 76;  -- 242-WYN
UPDATE derm.address_row_map SET band_y0_pct = 34.156, band_source = 'runlen-snap-${STAMP.slice(0, 10)}', band_set_at = now() WHERE id = 77;  -- 226-JER

-- ---------------------------------------------------------------------------------------------
-- PART 4  the consumer artifact
-- ---------------------------------------------------------------------------------------------

CREATE OR REPLACE VIEW derm.v_band_edge_check AS
WITH served AS (
  SELECT r.id AS row_id, r.dump_folder,
         COALESCE(r.stamp_page, r.page) AS effective_page,
         r.matched_client_id, c.client_code,
         r.band_y0_pct, r.band_y1_pct, r.band_source, r.stamp_y_pct,
         d.source_url AS doc_source_url, d.url AS doc_url
    FROM derm.address_row_map r
    JOIN public.clients c ON c.id = r.matched_client_id
    JOIN derm.redacted_manifest_docs d
      ON d.manifest_id = r.matched_manifest_id
     AND d.client_id   = r.matched_client_id
     AND d.effective_page = COALESCE(r.stamp_page, r.page)
   WHERE r.band_y0_pct IS NOT NULL AND r.band_y1_pct IS NOT NULL
), scan AS (
  SELECT * FROM derm.page_rule_scans WHERE source = ${q(SOURCE)}
)
SELECT s.row_id, s.dump_folder, s.effective_page, s.client_code, s.doc_url,
       s.band_y0_pct, s.band_y1_pct, s.band_source,
       sc.grade AS page_grade, sc.n_rules, sc.pitch_pct,
       t.d AS top_gap_pct, b.d AS bottom_gap_pct,
       CASE
         WHEN sc.dump_folder IS NULL                      THEN 'UNSCANNED'
         WHEN sc.source_url IS DISTINCT FROM s.doc_source_url THEN 'STALE'
         WHEN t.d IS NULL OR b.d IS NULL                  THEN 'OFF_RULE'
         WHEN t.d <= 0.35 AND b.d <= 0.35                 THEN 'ON_RULE'
         ELSE 'OFF_RULE'
       END AS verdict
  FROM served s
  LEFT JOIN scan sc ON sc.dump_folder = s.dump_folder AND sc.effective_page = s.effective_page
  LEFT JOIN LATERAL (
    SELECT min(abs(pr.rule_pct - s.band_y0_pct)) AS d
      FROM derm.page_row_rules pr
     WHERE pr.dump_folder = s.dump_folder AND pr.effective_page = s.effective_page
       AND pr.source = ${q(SOURCE)}
  ) t ON true
  LEFT JOIN LATERAL (
    SELECT min(abs(pr.rule_pct - s.band_y1_pct)) AS d
      FROM derm.page_row_rules pr
     WHERE pr.dump_folder = s.dump_folder AND pr.effective_page = s.effective_page
       AND pr.source = ${q(SOURCE)}
  ) b ON true;

COMMENT ON VIEW derm.v_band_edge_check IS
  'Every SERVED redaction band, with whether both of its edges sit on a printed rule detected on '
  'that page. An edge on a printed rule cannot be inside a line of text, so it cannot show the '
  'bottom half of a neighbour address the way 226-JER''s document did (2026-08-21_0651). '
  'FOUR verdicts on purpose: ON_RULE, OFF_RULE, UNSCANNED (the detector has never run on that '
  'page - NOT an all-clear), STALE (the page image changed since the scan). Tolerance 0.35pp, '
  'about 2-3 pixels on a 720px scan and well under a text line at 1.3pp. '
  '🛑 ON_RULE is NECESSARY, NOT SUFFICIENT: it proves no text is bisected, not that the edge is on '
  'the RIGHT rule. A band two rules too tall swallows a neighbour whole and still reads ON_RULE.';

CREATE OR REPLACE VIEW derm.v_band_edges_off_rule AS
SELECT * FROM derm.v_band_edge_check
 WHERE verdict <> 'ON_RULE'
 ORDER BY greatest(coalesce(top_gap_pct, 99), coalesce(bottom_gap_pct, 99)) DESC;

COMMENT ON VIEW derm.v_band_edges_off_rule IS
  'The worklist. EMPTY IS HEALTHY. A row here is a served customer document whose visible strip '
  'may start or end in the middle of a printed line of text belonging to another client. Ordered '
  'worst first. Check it after any stamping session and after any band edit, the same way '
  'derm.v_blackout_blocked_sheets is checked.';

-- ---------------------------------------------------------------------------------------------
-- PART 5  verify
-- ---------------------------------------------------------------------------------------------

DO $$
DECLARE
  v_scans int; v_rules int; v_unscanned int; v_on int; v_off int; v_stale int; v_d numeric;
BEGIN
  SELECT count(*) INTO v_scans FROM derm.page_rule_scans WHERE source = ${q(SOURCE)};
  IF v_scans <> ${C.length} THEN RAISE EXCEPTION 'expected ${C.length} scanned pages, found %', v_scans; END IF;

  SELECT count(*) INTO v_rules FROM derm.page_row_rules WHERE source = ${q(SOURCE)};
  IF v_rules < ${Math.floor(ruleRows.length * 0.98)} THEN
    RAISE EXCEPTION 'expected about ${ruleRows.length} rules, found %', v_rules;
  END IF;

  -- 🛑 THE CONTROL THAT MATTERS: no served band may be UNSCANNED. That verdict is the state the
  -- whole pass exists to eliminate, and it was true of 515 of 626 bands this morning.
  SELECT count(*) INTO v_unscanned FROM derm.v_band_edge_check WHERE verdict = 'UNSCANNED';
  IF v_unscanned <> 0 THEN RAISE EXCEPTION '% served bands are still UNSCANNED', v_unscanned; END IF;

  SELECT count(*) FILTER (WHERE verdict = 'ON_RULE'),
         count(*) FILTER (WHERE verdict = 'OFF_RULE'),
         count(*) FILTER (WHERE verdict = 'STALE')
    INTO v_on, v_off, v_stale
    FROM derm.v_band_edge_check;

  -- A sweep that returns zero findings is an untested instrument. This one is expected to find
  -- real off-rule edges, and it is expected to pass the great majority.
  IF v_on = 0 THEN RAISE EXCEPTION 'no band edge landed on a rule: the detector or the join is broken'; END IF;
  IF v_off = 0 THEN RAISE EXCEPTION 'zero off-rule edges: the check cannot distinguish anything'; END IF;
  IF v_stale <> 0 THEN RAISE EXCEPTION '% bands read STALE, so a page image moved mid-run', v_stale; END IF;

  -- POSITIVE CONTROL 1: the repaired leak edges must be ON a rule.
  SELECT min(abs(pr.rule_pct - 41.229)) INTO v_d FROM derm.page_row_rules pr
   WHERE pr.dump_folder = 'ticket-831710' AND pr.effective_page = 1 AND pr.source = ${q(SOURCE)};
  IF v_d IS NULL OR v_d > 0.35 THEN RAISE EXCEPTION 'control: 214-MYK repaired bottom 41.229 is % from a rule', v_d; END IF;

  -- POSITIVE CONTROL 2: the PRE-repair value on the same edge must NOT be.
  SELECT min(abs(pr.rule_pct - 43.830)) INTO v_d FROM derm.page_row_rules pr
   WHERE pr.dump_folder = 'ticket-831710' AND pr.effective_page = 1 AND pr.source = ${q(SOURCE)};
  IF v_d IS NULL OR v_d <= 0.35 THEN RAISE EXCEPTION 'control: the KNOWN-BAD 43.830 reads as on-rule (% away), so the check cannot detect the defect it exists for', v_d; END IF;

  -- POSITIVE CONTROL 3: ticket-832996 p1 was verified clean by eye; every band on it must pass.
  SELECT count(*) INTO v_off FROM derm.v_band_edge_check
   WHERE dump_folder = 'ticket-832996' AND effective_page = 1 AND verdict <> 'ON_RULE';
  IF v_off <> 0 THEN RAISE EXCEPTION 'control: % edges off-rule on ticket-832996 p1, verified clean by eye', v_off; END IF;

  -- POSITIVE CONTROL 4: the band snapped in PART 3 must now be on its rule.
  SELECT min(abs(pr.rule_pct - r.band_y0_pct)) INTO v_d
    FROM derm.address_row_map r
    JOIN derm.page_row_rules pr ON pr.dump_folder = r.dump_folder
     AND pr.effective_page = COALESCE(r.stamp_page, r.page) AND pr.source = ${q(SOURCE)}
   WHERE r.id = 77;
  IF v_d IS NULL OR v_d > 0.05 THEN RAISE EXCEPTION 'control: 226-JER top is % from its rule after snapping', v_d; END IF;

  RAISE NOTICE 'OK: % pages scanned, % rules, 0 unscanned served bands', v_scans, v_rules;
END $$;

COMMIT;
`;

fs.writeFileSync(OUT, sql);
console.log('wrote ' + OUT);
console.log('  ' + C.length + ' pages, ' + ruleRows.length + ' rules, source ' + SOURCE);
console.log('  grades: ' + Object.entries(g).map(([k, v]) => k + ' ' + v).join('  '));
console.log('  ' + (sql.length / 1024).toFixed(0) + ' KB');
