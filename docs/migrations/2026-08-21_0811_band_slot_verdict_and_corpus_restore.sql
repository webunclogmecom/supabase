-- ============================================================================
-- 2026-08-21_0811  Rule detection: what the adversarial review found in this morning's own work
-- ============================================================================
--
-- Three defects in 2026-08-21_0736 / _0741, all shipped by me a few hours earlier, all found by an
-- adversarial design panel briefed to attack the CONCLUSION rather than the numbers, and all
-- re-measured against live Prod here before anything was changed. The briefing is why they were
-- found: every measurement in those two files was correct, and every one of these defects lives in
-- the sentence wrapped around a measurement. Compare "instrument the inference" in CLAUDE.md.
--
-- ============================================================================================
-- DEFECT 1 - THE CHECK PASSED 39 BANDS THAT ARE STRUCTURALLY WRONG
-- ============================================================================================
-- v_band_edge_check shipped with ONE verdict, and its own comment said the right thing:
-- "ON_RULE is NECESSARY, NOT SUFFICIENT ... a band two rules too tall swallows a neighbour whole
-- and still reads ON_RULE." A caveat in a comment is not a control. Measured live:
--
--     29 bands read ON_RULE while an edge sits on a MID-SLOT DIVIDER or a HEADER/FOOTER BAR
--        -> the band begins or ends inside a slot. Where that edge is the divider of the slot
--           ABOVE, the band contains that client's whole address line.
--     10 bands read ON_RULE while CONTAINING a slot boundary
--        -> the band spans more than one printed slot. The ticket-831047 shape: 032-LG, 12pp tall,
--           containing the whole of Marie Blachere.
--
-- Both are the leak the pass was built to find, and both were passing it.
--
-- => TWO VERDICTS, because there are two properties and one column cannot carry both:
--     edge_verdict  ON_RULE / OFF_RULE / UNSCANNED / STALE
--                   is a line of text bisected? An edge on ANY printed rule is safe from that.
--     slot_verdict  ONE_SLOT / PART_SLOT / SPANS_MULTIPLE / ODD_SLOT / UNKNOWN
--                   does the band cover exactly one client's printed slot?
--   Safe is the CONJUNCTION. Measured: 534 of 626 served bands are ON_RULE and ONE_SLOT; 92 need
--   eyes, and the pair says which of the two things is wrong with each.
--
-- slot_verdict reads the kind of the NEAREST rule to each edge, whatever the distance. That is
-- deliberate: it answers "are these the right two boundaries", which stays useful when the edge is
-- a few tenths off. Whether the edge is ON that rule is edge_verdict's job. The 23 bands that come
-- out ONE_SLOT + OFF_RULE are the lowest-risk group precisely because the two answers disagree
-- in that direction.
--
-- ============================================================================================
-- DEFECT 2 - STALE COULD NEVER HAVE FIRED
-- ============================================================================================
-- page_rule_scans recorded source_url, and the view compared it against the served document's
-- source_url to catch a page image that had moved. But storage writes in this repo use
-- x-upsert:true, so a re-uploaded scan keeps its path: THE URL NEVER CHANGES. The branch was
-- structurally unable to fire, which is the same fail-silent shape as a sweep returning 0 rows and
-- being read as an all-clear.
--
-- derm._img_etag(text) already exists (SECURITY DEFINER, reads storage.objects.metadata) and is
-- what redacted_manifest_docs.fingerprint is built from. Verified live against both buckets. The
-- scan now stores source_etag and STALE compares on that.
--
-- ============================================================================================
-- DEFECT 3 - MY OWN UPSERT RELABELLED 61 HAND-RECORDED GROUND-TRUTH RULES
-- ============================================================================================
-- page_row_rules had primary key (dump_folder, effective_page, rule_pct), with no source. So
-- ON CONFLICT ... DO UPDATE SET ... source = EXCLUDED.source did not add a second row where a
-- machine detection matched a hand-recorded position: it OVERWROTE that row's provenance. 61 of
-- the 198 rules recorded by the five earlier migrations began claiming to be machine output, and
-- 2026-08-21_0741 then ran DELETE ... WHERE source = 'runlen-v2-2026-08-21' across exactly those.
--
-- NOTHING WAS LOST, AND THE HONEST VERSION MATTERS. All 198 positions are still present, because
-- the detector re-found every one of them, which is WHY they collided. What was destroyed is the
-- distinction between "a human measured this" and "the detector found this". That makes the next
-- generation's regression CIRCULAR: it would score the detector against 61 of its own outputs and
-- report a number that keeps improving for the wrong reason.
--
-- AND THE NEXT RUN WOULD NOT BE SO LUCKY. A v3 whose position for one of those rows moves by a
-- single rounding step deletes a hand-recorded rule outright, from a table with NO audit trigger.
--
-- Fixed both ways: source joins the primary key so two generations can never collide again, and
-- the 61 rows are restored from the committed migrations that created them (5 from 2026-08-03_0340,
-- 22 from 2026-08-19_2355, 30 from 2026-08-20_1538, 3 from 2026-08-20_1610, 1 from
-- 2026-08-21_0140). That is the restore path the 2026-08-14 rule asks for, named before the fact
-- and in git.
--
-- ALSO: skew_saturated. The skew ladder is +/-0.008 and 3 of 160 pages sit at its edge, meaning the
-- search returned the best of a bad set with nothing recording that it had run out of room. 49
-- pages carry a non-zero skew, so the mechanism is live and not decorative.
--
-- ADR 010 rule 8 (audit): unchanged. Both tables hold machine-detected geometry with no
-- human-editable business fields, so audit OPT-OUT.

BEGIN;

-- ---------------------------------------------------------------------------------------------
-- PART 1  generations can no longer collide, and the ground-truth corpus comes back
-- ---------------------------------------------------------------------------------------------

ALTER TABLE derm.page_row_rules DROP CONSTRAINT page_row_rules_pkey;
ALTER TABLE derm.page_row_rules
  ADD CONSTRAINT page_row_rules_pkey PRIMARY KEY (dump_folder, effective_page, rule_pct, source);

COMMENT ON CONSTRAINT page_row_rules_pkey ON derm.page_row_rules IS
  'source IS PART OF THE KEY ON PURPOSE. Without it an upsert from a new detector generation '
  'overwrites the provenance of any hand-recorded rule sitting at the same position, and a later '
  'DELETE-by-source removes it outright. That happened on 2026-08-21 to 61 of the 198 rules '
  'recorded by hand between 08-03 and 08-21, which are the corpus every detector is scored against.';

INSERT INTO derm.page_row_rules (dump_folder, effective_page, rule_pct, ink_frac, source) VALUES
  ('ticket-310429', 1, 30.295, 0.84, 'claude-rulesnap-2026-08-03'),
  ('ticket-310429', 1, 44.504, 0.84, 'claude-rulesnap-2026-08-03'),
  ('ticket-310429', 1, 48.525, 0.97, 'claude-rulesnap-2026-08-03'),
  ('ticket-310429', 1, 56.434, 0.97, 'claude-rulesnap-2026-08-03'),
  ('ticket-310429', 1, 64.209, 0.97, 'claude-rulesnap-2026-08-03'),
  ('ticket-311780', 1, 37.419, 0.86, 'claude-rulesnap-2026-08-19'),
  ('ticket-311780', 1, 43.952, 0.86, 'claude-rulesnap-2026-08-19'),
  ('ticket-311780', 1, 51.532, 0.86, 'claude-rulesnap-2026-08-19'),
  ('ticket-311780', 1, 55.726, 0.94, 'claude-rulesnap-2026-08-19'),
  ('ticket-311780', 2, 37.419, 0.86, 'claude-rulesnap-2026-08-19'),
  ('ticket-311780', 2, 43.912, 0.86, 'claude-rulesnap-2026-08-19'),
  ('ticket-311780', 2, 47.971, 0.98, 'claude-rulesnap-2026-08-19'),
  ('ticket-311780', 2, 55.763, 0.98, 'claude-rulesnap-2026-08-19'),
  ('ticket-311780', 2, 63.555, 0.98, 'claude-rulesnap-2026-08-19'),
  ('ticket-832487', 1, 28.548, 0.86, 'claude-rulesnap-2026-08-19'),
  ('ticket-832487', 1, 32.984, 1, 'claude-rulesnap-2026-08-19'),
  ('ticket-832487', 1, 36.452, 0.86, 'claude-rulesnap-2026-08-19'),
  ('ticket-832487', 1, 39.919, 1, 'claude-rulesnap-2026-08-19'),
  ('ticket-832487', 1, 43.306, 0.85, 'claude-rulesnap-2026-08-19'),
  ('ticket-832487', 2, 42.823, 0.85, 'claude-rulesnap-2026-08-19'),
  ('ticket-832487', 2, 50.726, 0.85, 'claude-rulesnap-2026-08-19'),
  ('ticket-832487', 2, 55.081, 1, 'claude-rulesnap-2026-08-19'),
  ('ticket-832487', 2, 58.79, 0.85, 'claude-rulesnap-2026-08-19'),
  ('ticket-310590', 1, 25.318, 0.99, 'claude-rulesnap-2026-08-19'),
  ('ticket-310590', 2, 25.517, 0.99, 'claude-rulesnap-2026-08-19'),
  ('ticket-310590', 2, 40.496, 0.99, 'claude-rulesnap-2026-08-19'),
  ('ticket-310590', 2, 51.395, 0.84, 'claude-rulesnap-2026-08-19'),
  ('ticket-309661', 1, 29.902, 0.959, 'claude-rulesnap-2026-08-20'),
  ('ticket-309661', 1, 41.667, 0.957, 'claude-rulesnap-2026-08-20'),
  ('ticket-309661', 1, 47.549, 0.957, 'claude-rulesnap-2026-08-20'),
  ('ticket-309661', 1, 53.431, 0.959, 'claude-rulesnap-2026-08-20'),
  ('ticket-309661', 1, 65.336, 0.959, 'claude-rulesnap-2026-08-20'),
  ('ticket-309898', 1, 40.165, 0.939, 'claude-rulesnap-2026-08-20'),
  ('ticket-309898', 1, 64.15, 0.939, 'claude-rulesnap-2026-08-20'),
  ('ticket-820714', 1, 27.742, 0.936, 'claude-rulesnap-2026-08-20'),
  ('ticket-820714', 1, 33.227, 0.968, 'claude-rulesnap-2026-08-20'),
  ('ticket-820714', 1, 38.712, 0.968, 'claude-rulesnap-2026-08-20'),
  ('ticket-820714', 1, 49.681, 0.968, 'claude-rulesnap-2026-08-20'),
  ('ticket-820714', 1, 55.166, 0.968, 'claude-rulesnap-2026-08-20'),
  ('ticket-829788', 1, 28.042, 0.961, 'claude-rulesnap-2026-08-20'),
  ('ticket-829788', 1, 44.303, 0.959, 'claude-rulesnap-2026-08-20'),
  ('ticket-830088', 1, 32.818, 0.955, 'claude-rulesnap-2026-08-20'),
  ('ticket-830088', 1, 38.26, 0.959, 'claude-rulesnap-2026-08-20'),
  ('ticket-830088', 1, 59.712, 0.813, 'claude-rulesnap-2026-08-20'),
  ('ticket-830310', 1, 26.907, 0.804, 'claude-rulesnap-2026-08-20'),
  ('ticket-830310', 1, 38.206, 0.765, 'claude-rulesnap-2026-08-20'),
  ('ticket-830413', 1, 32.83, 0.963, 'claude-rulesnap-2026-08-20'),
  ('ticket-830574', 1, 33.495, 0.895, 'claude-rulesnap-2026-08-20'),
  ('ticket-830574', 1, 44.322, 0.965, 'claude-rulesnap-2026-08-20'),
  ('ticket-830673', 1, 63.566, 0.981, 'claude-rulesnap-2026-08-20'),
  ('ticket-831938', 1, 25.205, 0.985, 'claude-rulesnap-2026-08-20'),
  ('ticket-831938', 2, 25.351, 0.983, 'claude-rulesnap-2026-08-20'),
  ('ticket-831938', 2, 33.638, 0.983, 'claude-rulesnap-2026-08-20'),
  ('ticket-832194', 1, 63.489, 1, 'claude-rulesnap-2026-08-20'),
  ('ticket-830714', 1, 38.712, 0.968, 'claude-rulesnap-2026-08-20'),
  ('ticket-830714', 1, 49.681, 0.968, 'claude-rulesnap-2026-08-20'),
  ('ticket-830714', 1, 55.166, 0.968, 'claude-rulesnap-2026-08-20'),
  ('ticket-310607', 1, 55.17, 0.843, 'claude-tilingfit-2026-08-20'),
  ('ticket-832996', 1, 33.771, 1, 'claude-tilingfit-2026-08-20'),
  ('ticket-832996', 1, 41.229, 1, 'claude-tilingfit-2026-08-20'),
  ('ticket-831710', 1, 41.229, 0.995, 'claude-leakfix-2026-08-21')
ON CONFLICT (dump_folder, effective_page, rule_pct, source) DO NOTHING;

-- ---------------------------------------------------------------------------------------------
-- PART 2  bind the scan to the image BYTES, not to its path
-- ---------------------------------------------------------------------------------------------

ALTER TABLE derm.page_rule_scans
  ADD COLUMN IF NOT EXISTS source_etag    text,
  ADD COLUMN IF NOT EXISTS skew_saturated boolean;

COMMENT ON COLUMN derm.page_rule_scans.source_etag IS
  'The storage etag of the image actually scanned. THE URL IS NOT ENOUGH: storage writes here use '
  'x-upsert:true, so a re-uploaded scan keeps its path and the URL never changes. Comparing URLs '
  'made the STALE verdict structurally unable to fire.';
COMMENT ON COLUMN derm.page_rule_scans.skew_saturated IS
  'TRUE when the chosen skew sits at the edge of the search ladder, so the page may be more rotated '
  'than the detector can correct and the result is the best of a bad set. 3 of 160 on 2026-08-21.';

UPDATE derm.page_rule_scans
   SET source_etag    = derm._img_etag(source_url),
       skew_saturated = (abs(skew) >= 0.008)
 WHERE source = 'runlen-v2-2026-08-21';

-- ---------------------------------------------------------------------------------------------
-- PART 3  two verdicts
-- ---------------------------------------------------------------------------------------------

DROP VIEW IF EXISTS derm.v_band_edges_off_rule;
DROP VIEW IF EXISTS derm.v_band_edge_check;

CREATE VIEW derm.v_band_edge_check AS
WITH served AS (
  SELECT r.id AS row_id, r.dump_folder,
         COALESCE(r.stamp_page, r.page) AS effective_page,
         c.client_code, r.band_y0_pct, r.band_y1_pct, r.band_source, r.stamp_y_pct,
         d.source_url AS doc_source_url, d.url AS doc_url
    FROM derm.address_row_map r
    JOIN public.clients c ON c.id = r.matched_client_id
    JOIN derm.redacted_manifest_docs d
      ON d.manifest_id = r.matched_manifest_id
     AND d.client_id   = r.matched_client_id
     AND d.effective_page = COALESCE(r.stamp_page, r.page)
   WHERE r.band_y0_pct IS NOT NULL AND r.band_y1_pct IS NOT NULL
), scan AS (
  SELECT * FROM derm.page_rule_scans WHERE source = 'runlen-v2-2026-08-21'
), m AS (
  SELECT s.*, sc.grade AS page_grade, sc.n_rules, sc.pitch_pct, sc.source_etag, sc.skew_saturated,
         sc.dump_folder AS scanned,
         t.d AS top_gap_pct, t.kind AS top_kind,
         b.d AS bottom_gap_pct, b.kind AS bottom_kind,
         ib.n AS inner_boundaries, idv.n AS inner_dividers
    FROM served s
    LEFT JOIN scan sc ON sc.dump_folder = s.dump_folder AND sc.effective_page = s.effective_page
    LEFT JOIN LATERAL (
      SELECT abs(pr.rule_pct - s.band_y0_pct) AS d, pr.kind
        FROM derm.page_row_rules pr
       WHERE pr.dump_folder = s.dump_folder AND pr.effective_page = s.effective_page
         AND pr.source = 'runlen-v2-2026-08-21'
       ORDER BY abs(pr.rule_pct - s.band_y0_pct) LIMIT 1
    ) t ON true
    LEFT JOIN LATERAL (
      SELECT abs(pr.rule_pct - s.band_y1_pct) AS d, pr.kind
        FROM derm.page_row_rules pr
       WHERE pr.dump_folder = s.dump_folder AND pr.effective_page = s.effective_page
         AND pr.source = 'runlen-v2-2026-08-21'
       ORDER BY abs(pr.rule_pct - s.band_y1_pct) LIMIT 1
    ) b ON true
    LEFT JOIN LATERAL (
      SELECT count(*) AS n FROM derm.page_row_rules pr
       WHERE pr.dump_folder = s.dump_folder AND pr.effective_page = s.effective_page
         AND pr.source = 'runlen-v2-2026-08-21' AND pr.kind = 'boundary'
         AND pr.rule_pct > s.band_y0_pct + 0.35 AND pr.rule_pct < s.band_y1_pct - 0.35
    ) ib ON true
    LEFT JOIN LATERAL (
      SELECT count(*) AS n FROM derm.page_row_rules pr
       WHERE pr.dump_folder = s.dump_folder AND pr.effective_page = s.effective_page
         AND pr.source = 'runlen-v2-2026-08-21' AND pr.kind = 'divider'
         AND pr.rule_pct > s.band_y0_pct + 0.35 AND pr.rule_pct < s.band_y1_pct - 0.35
    ) idv ON true
)
SELECT row_id, dump_folder, effective_page, client_code, doc_url,
       band_y0_pct, band_y1_pct, band_source, page_grade, n_rules, pitch_pct, skew_saturated,
       top_gap_pct, top_kind, bottom_gap_pct, bottom_kind, inner_boundaries, inner_dividers,
       CASE
         WHEN scanned IS NULL                                    THEN 'UNSCANNED'
         WHEN source_etag IS DISTINCT FROM derm._img_etag(doc_source_url) THEN 'STALE'
         WHEN top_gap_pct IS NULL OR bottom_gap_pct IS NULL       THEN 'OFF_RULE'
         WHEN top_gap_pct <= 0.35 AND bottom_gap_pct <= 0.35      THEN 'ON_RULE'
         ELSE 'OFF_RULE'
       END AS edge_verdict,
       CASE
         WHEN scanned IS NULL OR page_grade = 'FAILED'
           OR top_kind = 'unclassified' OR bottom_kind = 'unclassified'
           OR top_kind IS NULL OR bottom_kind IS NULL              THEN 'UNKNOWN'
         WHEN inner_boundaries > 0                                 THEN 'SPANS_MULTIPLE'
         WHEN top_kind = 'boundary' AND bottom_kind = 'boundary'
          AND inner_dividers = 1                                   THEN 'ONE_SLOT'
         WHEN top_kind = 'boundary' AND bottom_kind = 'boundary'    THEN 'ODD_SLOT'
         ELSE 'PART_SLOT'
       END AS slot_verdict
  FROM m;

COMMENT ON VIEW derm.v_band_edge_check IS
  'Every SERVED redaction band, against the printed rules detected on its page. TWO VERDICTS '
  'BECAUSE THERE ARE TWO PROPERTIES, and a band is safe only when BOTH hold. '
  'edge_verdict: is a line of TEXT bisected? An edge on any printed rule is not. ON_RULE / '
  'OFF_RULE / UNSCANNED (never scanned, NOT an all-clear) / STALE (the image bytes changed since '
  'the scan, compared by etag because x-upsert keeps the URL identical). '
  'slot_verdict: does the band cover exactly ONE client slot? ONE_SLOT / PART_SLOT (an edge on a '
  'mid-slot divider or a header bar, so it starts or ends inside somebody else''s slot) / '
  'SPANS_MULTIPLE (a slot boundary lies INSIDE the band, so it covers more than one client, the '
  'ticket-831047 shape) / ODD_SLOT / UNKNOWN. '
  'SHIPPED 2026-08-21 WITH edge_verdict ALONE AND 39 STRUCTURALLY WRONG BANDS PASSED IT: 29 '
  'PART_SLOT and 10 SPANS_MULTIPLE all read ON_RULE. slot_verdict uses the NEAREST rule''s kind '
  'whatever the distance, which is why a band can be ONE_SLOT and OFF_RULE: the right two '
  'boundaries with the edges a few tenths off them. Tolerance 0.35pp, about 2-3px on a 720px scan.';

CREATE VIEW derm.v_band_edges_off_rule AS
SELECT *,
       CASE WHEN slot_verdict = 'SPANS_MULTIPLE'            THEN 1
            WHEN slot_verdict IN ('PART_SLOT','ODD_SLOT')   THEN 2
            WHEN edge_verdict IN ('STALE','UNSCANNED')      THEN 3
            WHEN edge_verdict = 'OFF_RULE'                  THEN 4
            ELSE 5 END AS severity
  FROM derm.v_band_edge_check
 WHERE NOT (edge_verdict = 'ON_RULE' AND slot_verdict = 'ONE_SLOT');

COMMENT ON VIEW derm.v_band_edges_off_rule IS
  'The worklist. EMPTY IS HEALTHY. Everything that is not provably one whole slot with no line of '
  'text bisected. severity 1 the band covers more than one client, 2 it starts or ends inside a '
  'slot, 3 never scanned or the image moved, 4 the edges are off the rules but the slot is right. '
  'Check after any stamping session and after any band edit, the same way '
  'derm.v_blackout_blocked_sheets is checked.';

-- ---------------------------------------------------------------------------------------------
-- PART 4  verify
-- ---------------------------------------------------------------------------------------------

DO $$
DECLARE v_hand int; v_key text; v_etag int; v_span int; v_part int; v_ok int; v_work int; v_stale int;
BEGIN
  SELECT count(*) INTO v_hand FROM derm.page_row_rules WHERE source LIKE 'claude-%';
  IF v_hand <> 198 THEN RAISE EXCEPTION 'expected 198 hand-recorded rules, found %', v_hand; END IF;

  SELECT pg_get_constraintdef(oid) INTO v_key FROM pg_constraint
   WHERE conrelid = 'derm.page_row_rules'::regclass AND contype = 'p';
  IF v_key NOT LIKE '%source%' THEN RAISE EXCEPTION 'source is not in the primary key: %', v_key; END IF;

  SELECT count(*) INTO v_etag FROM derm.page_rule_scans
   WHERE source = 'runlen-v2-2026-08-21' AND (source_etag IS NULL OR source_etag = '');
  IF v_etag <> 0 THEN RAISE EXCEPTION '% scans have no source_etag, so STALE cannot fire for them', v_etag; END IF;

  SELECT count(*) INTO v_stale FROM derm.v_band_edge_check WHERE edge_verdict = 'STALE';
  IF v_stale <> 0 THEN RAISE EXCEPTION '% bands read STALE immediately after binding the etag', v_stale; END IF;

  -- THE CONTROL THAT MATTERS: the defect this file exists for must now be VISIBLE. Before, all 39
  -- of these read ON_RULE and were absent from the worklist entirely.
  SELECT count(*) INTO v_span FROM derm.v_band_edge_check WHERE slot_verdict = 'SPANS_MULTIPLE';
  SELECT count(*) INTO v_part FROM derm.v_band_edge_check WHERE slot_verdict = 'PART_SLOT';
  IF v_span = 0 THEN RAISE EXCEPTION 'no band covers more than one slot: the structural check is inert'; END IF;
  IF v_part = 0 THEN RAISE EXCEPTION 'no band is part-slot: the structural check is inert'; END IF;

  SELECT count(*) INTO v_ok FROM derm.v_band_edge_check
   WHERE edge_verdict = 'ON_RULE' AND slot_verdict = 'ONE_SLOT';
  IF v_ok < 400 THEN RAISE EXCEPTION 'only % bands are provably clean, too few to believe', v_ok; END IF;

  SELECT count(*) INTO v_work FROM derm.v_band_edges_off_rule;
  IF v_work = 0 THEN RAISE EXCEPTION 'the worklist is empty, so it cannot distinguish anything'; END IF;

  RAISE NOTICE 'OK: % hand rules, % clean bands, % on the worklist (% span multiple, % part slot)',
    v_hand, v_ok, v_work, v_span, v_part;
END $$;

COMMIT;
