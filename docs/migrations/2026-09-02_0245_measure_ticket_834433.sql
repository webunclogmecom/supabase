-- 2026-09-02_0245_measure_ticket_834433.sql
--
-- WHAT: records the printed rules for ticket-834433 page 1, so its bands can be checked and saved.
--       TWO `kind` labels are changed from the detector's output. Every position, run and ink value
--       is the detector's own, unedited.
--
-- WHY:  Fred, on the Stamp Studio: *"still errors on 834433. I don't understand why can't I just do
--       it manually as an option."* He is right that he was stuck, and the answer is that he should
--       never have had to: the detector read this sheet correctly and only mislabelled the last two
--       lines. This is the resolution the design intends for a page the algorithm refuses, and it
--       has a precedent five days old: 2026-08-28_2010 did exactly this for ticket-312024 p1.
--
-- WHAT THE DETECTOR ACTUALLY SAW. Captured from the live app by intercepting its own
-- record_page_rules call (the positions are not stored when the write is refused). Detection is
-- flawless: 14 rules, a textbook bimodal run split, boundaries 0.992-0.994 and dividers 0.403-0.407.
-- The CLASSIFIER mislabelled the trailing pair, and derm.fn_validate_page_rules correctly refused:
--   "run-length split disagrees with the labels at chain position 13 (run 0.994, cut 0.751,
--    labelled divider): a phase flip"
-- so zero rules were written, G9 had nothing to compare against, and the operator got one error per
-- band edge. The refusal was right. The labels were wrong.
--
-- THE TWO LINES THAT MOVE, and why they are not roster lines:
--     65.560  run 0.994  ink 0.971   labelled divider   -> header-footer
--     67.904  run 0.510  ink 0.953   labelled boundary  -> header-footer
--   * 65.560 runs 0.994, which is FULL WIDTH. No divider on this form does that: every real divider
--     here runs 0.403-0.407 and stops at the first vertical column line.
--   * Ink is the second, independent tell. The real dividers ink at 0.028-0.310. These two ink at
--     0.971 and 0.953, darker than most of the real boundaries. They are printed form bars.
--   * They sit BELOW the roster. The last real boundary is 62.370, and the five slots above it
--     measure 8.334, 6.640, 7.162, 7.812 and 7.748 pp, which is a clean 5-slot DERM form.
--   * 65.560 is the bar under "Attach Additional Sheets if more than 5 Grease Interceptors Pumped!";
--     67.904 is inside "E: Liquid Waste Transporter Certification".
--
-- 🛑 WHY THE CLASSIFIER FAILED, AND IT IS THE THIRD TIME. The end-bar trim drops a trailing rule
--    only when the outermost TWO are BOTH long and close. Here the outermost is 67.904 at run
--    0.510, which is SHORT, so the trim never fires and the long footer bar at 65.560 stays in the
--    alternating chain, inverting the labels at the end.
--    ⚠ ticket-312024 p1 failed on almost the same numbers: trailing 68.106 run 0.510, long footer
--    65.722. Same shape, same cause, five days apart. That is not a coincidence, it is a
--    reproducible limitation, and it is why the fix belongs in the trim rather than in more
--    migrations like this one. Spec:
--    docs/superpowers/specs/2026-09-02-printed-rule-phase-flip-design.md
--
-- 🛑 THE REFUSAL IS NOT THE BUG AND MUST NOT BE WEAKENED. fn_validate_page_rules did its job. The
--    rules drive band snapping, which drives which strip of a shared sheet each client is shown, so
--    a mislabelled phase is how one client sees another client's address line. Writing an unverified
--    phase would be the dangerous act. What is recorded below is validated by the SAME function
--    before it lands, and the migration aborts if it refuses.
--
-- WHY NOT JUST LET AN OPERATOR SAVE BANDS WITHOUT RULES, which is what Fred asked for. Because G9
--    is the check that stops one client's band edge sitting inside a neighbour's printed row, and
--    an edge 1.665pp off is exactly what leaked a client's address on 2026-08-19. The honest fix is
--    to give the page its rules, not to switch the check off. The lines are on the paper; only our
--    record of them was missing.
--
-- RULE 8 (audit): writes only through derm.record_page_rules, which is itself audited. No table or
--    column changes. derm.page_row_rules carries no audit trigger by design (it is detector output,
--    regenerable), and this migration does not alter that.
-- RULE 2/3: nothing derived or copied; these are measurements of a physical document.

BEGIN;

DO $do$
DECLARE
  v_rules jsonb;
  v_r     jsonb;
  v_bad   text;
BEGIN
  -- Detector output, VERBATIM, except the two trailing `kind` values reasoned about in the header.
  v_rules := '[
    {"pct":22.396,"run":0.403,"ink":0.310,"kind":"divider"},
    {"pct":24.674,"run":0.992,"ink":0.803,"kind":"boundary"},
    {"pct":28.776,"run":0.405,"ink":0.183,"kind":"divider"},
    {"pct":33.008,"run":0.994,"ink":0.943,"kind":"boundary"},
    {"pct":36.328,"run":0.407,"ink":0.057,"kind":"divider"},
    {"pct":39.648,"run":0.994,"ink":0.939,"kind":"boundary"},
    {"pct":42.969,"run":0.406,"ink":0.277,"kind":"divider"},
    {"pct":46.810,"run":0.994,"ink":0.728,"kind":"boundary"},
    {"pct":50.521,"run":0.407,"ink":0.028,"kind":"divider"},
    {"pct":54.622,"run":0.993,"ink":0.594,"kind":"boundary"},
    {"pct":58.333,"run":0.407,"ink":0.088,"kind":"divider"},
    {"pct":62.370,"run":0.994,"ink":0.993,"kind":"boundary"},
    {"pct":65.560,"run":0.994,"ink":0.971,"kind":"header-footer"},
    {"pct":67.904,"run":0.510,"ink":0.953,"kind":"header-footer"}
  ]'::jsonb;

  -- Validate BEFORE recording, so a bad hand-label fails loudly here rather than landing.
  v_bad := derm.fn_validate_page_rules(v_rules);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'ticket-834433 p1 rules rejected by the validator: %', v_bad;
  END IF;

  v_r := derm.record_page_rules(
    'ticket-834433', 1, 'runlen-v2-2026-09-02',
    'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1771/address_1.jpg',
    v_rules,
    '{"grade":"OK","detail":"6 boundaries, 5 slots 6.640-8.334pp; the two trailing form bars relabelled header-footer after reading the scan (run 0.994 full-width and ink 0.971/0.953, far above any real divider here)","image_w":964,"image_h":768,"skew":0}'::jsonb,
    true);
  IF (v_r->>'wrote')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'ticket-834433 p1 was not written: %', v_r;
  END IF;
END $do$;

DO $do$
DECLARE
  v_n int; v_b int; v_hf int; v_g9 int; v_notmeas int; v_bands jsonb;
BEGIN
  -- 1. the page now serves rules, with the right shape
  SELECT count(*) FILTER (WHERE kind IN ('boundary','divider')),
         count(*) FILTER (WHERE kind = 'boundary'),
         count(*) FILTER (WHERE kind = 'header-footer')
    INTO v_n, v_b, v_hf
    FROM derm.page_row_rules
   WHERE dump_folder = 'ticket-834433' AND effective_page = 1;
  IF v_n <> 12 OR v_b <> 6 OR v_hf <> 2 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % chain rules, % boundaries, % header-footer (want 12/6/2)', v_n, v_b, v_hf;
  END IF;

  -- 2. THE REPORTED SYMPTOM IS GONE. G9_NOT_MEASURED must no longer fire for this page.
  SELECT jsonb_agg(jsonb_build_object('row_id', r.id, 'y0', 24.674, 'y1', 33.008))
    INTO v_bands FROM derm.address_row_map r WHERE r.dump_folder = 'ticket-834433';

  SELECT count(*) INTO v_notmeas
    FROM derm._page_geometry_violations('ticket-834433', 1, v_bands)
   WHERE code = 'G9_NOT_MEASURED';
  IF v_notmeas <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: G9_NOT_MEASURED still fires on ticket-834433';
  END IF;

  -- 3. CONTROL, and it is the one that proves the rules are real rather than merely present:
  --    an edge deliberately BETWEEN two rules must now be caught as off-rule. If this does not
  --    fire, the rules landed but G9 is not actually consulting them.
  SELECT jsonb_agg(jsonb_build_object('row_id', r.id, 'y0', 26.900, 'y1', 31.100))
    INTO v_bands FROM derm.address_row_map r WHERE r.dump_folder = 'ticket-834433';
  SELECT count(*) INTO v_g9
    FROM derm._page_geometry_violations('ticket-834433', 1, v_bands)
   WHERE code = 'G9_OFF_RULE';
  IF v_g9 < 1 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: an edge between two rules was NOT reported off-rule, so G9 is not using the new rules';
  END IF;

  RAISE NOTICE 'OK: ticket-834433 p1 has 12 chain rules / 6 boundaries; G9_NOT_MEASURED gone; off-rule detection live.';
END $do$;

COMMIT;
