-- 2026-09-02_1330_record_page_rules_admits_operator_marked.sql
--
-- WHAT: derm.record_page_rules now accepts a 'human-v1-%' source, looks for a previous scan across
--       BOTH admitted prefixes, and protects any non-FAILED previous grade rather than only 'OK'.
--       Adds derm._is_rule_source(text) so the admitted set is written down once.
--
-- WHY:  MY DEFECT, and Fred hit it head-on. He drew the limit bands on ticket-834489, placed a
--       stamp, pressed save, and got:
--
--         source must match runlen-v2-%, got human-v1-2026-09-02
--
--       2026-09-02_0330 widened the READER (derm.v_page_printed_rules) to admit operator-marked
--       scans and never touched the WRITER. So the feature could read a kind of row that nothing
--       was permitted to create.
--
-- THE MEASUREMENT THAT SHOULD HAVE BEEN IN THAT MIGRATION, AND IS THE REASON THIS ONE EXISTS.
--       Live corpus today: 176 scans, and the prefix census is {"runlen-v2": 176}. Not one
--       human-v1 row has ever existed. So the widened view had admitted NOTHING from the hour it
--       shipped, and its VERIFY passed anyway, because every assertion in it was about the rows
--       that were ALREADY there: "the same pages still serve the same number of rules", "no
--       claude-% leaked", "one source per page". Every one true, none of them about the new arm.
--       => A migration that widens an accepting set MUST assert that a value from the NEW arm is
--       actually accepted end to end. A regression suite over the old arm cannot fail. VERIFY 3
--       below is that assertion: it records real rules under a human-v1 source and reads them back
--       out of the view.
--
-- AND THE SECOND HALF: an accepting set has a READER and a WRITER, and widening one is half a
--       change. The pairing here is (v_page_printed_rules, record_page_rules). If a third consumer
--       of these prefixes is ever added, it goes through derm._is_rule_source too.
--
-- WHY THE SUPERSESSION LOOKUP HAD TO MOVE WITH IT. The guard read the newest 'runlen-v2-%' scan.
--       Leave it that way and an operator-marked page is INVISIBLE to it, so the next automatic
--       re-measure that grades FAILED becomes the newest scan for the page. It does not delete the
--       human rules (the DELETE is scoped to its own source and only runs on a non-FAILED grade),
--       it HIDES them: v_page_printed_rules takes DISTINCT ON newest and joins rules on that
--       scan's own source, so the page serves zero rules and every band on it grades UNSCANNED.
--       Fred would have measured the sheet by hand, pressed "Re-measure printed lines" once, and
--       watched his work silently stop counting.
--
-- WHY 'OK' BECAME 'ANY NON-FAILED'. Rules are written on OK, SPARSE and IRREGULAR alike, so all
--       three can be hidden the same way. The corpus holds 8 SPARSE and 2 IRREGULAR scans that
--       were exposed to exactly that, and 0 pages are shadowed right now, so this refuses nothing
--       that happens today. Purely protective.
--
-- 'claude-%' IS STILL REFUSED, on both sides. Those are stale positions from old repair
--       migrations, not a person reading the sheet. That distinction is the whole basis on which
--       operator marks were admitted, so it is asserted here rather than assumed.
--
-- THE BODY WAS COPIED FROM pg_get_functiondef AND EDITED BY ANCHOR, NEVER RETYPED. Before and
--    after copies are committed under scripts/probes/geom/. The diff is four edits, nothing else.
--
-- RULE 8 (audit): no table or column changes. Functions only. derm.page_row_rules and
--    derm.page_rule_scans remain deliberately unaudited (regenerable detector output).
-- RULE 2/3: nothing derived, copied or stored.

BEGIN;

-- The admitted set, written down ONCE. IMMUTABLE and NULL-safe: a NULL source is not admissible,
-- and returning NULL there would make a caller's IF evaluate to NULL and fall open.
CREATE OR REPLACE FUNCTION derm._is_rule_source(p_source text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT p_source IS NOT NULL
     AND (p_source LIKE 'runlen-v2-%' OR p_source LIKE 'human-v1-%');
$fn$;

COMMENT ON FUNCTION derm._is_rule_source(text) IS
  'Which page_rule_scans sources are admissible: the runlen-v2 detector, and human-v1 operator marks. Deliberately excludes claude-%, which are stale positions written by old repair migrations rather than by a person reading the sheet. Kept as a function so the reader (v_page_printed_rules) and the writer (record_page_rules) cannot drift apart; the view keeps literal patterns on purpose, because a SECURITY INVOKER function in a view adds an invoker-side EXECUTE check to the read path and that regressed pg_read_all_data once already (2026-08-25_1400). VERIFY 2 asserts the two stay in step.';

REVOKE ALL ON FUNCTION derm._is_rule_source(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION derm._is_rule_source(text) FROM anon;

CREATE OR REPLACE FUNCTION derm.record_page_rules(p_dump_folder text, p_effective_page integer, p_source text, p_source_url text, p_rules jsonb, p_meta jsonb DEFAULT '{}'::jsonb, p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public', 'pg_temp'
AS $function$
DECLARE
  v_grade      text := coalesce(p_meta->>'grade', 'FAILED');
  v_detail     text := p_meta->>'detail';
  -- 🛑 COMPUTE THE ETAG WHEN THE CALLER OMITS IT. A NULL here makes every band on the page read
  -- STALE in v_band_edge_check, because that check compares the etag BEFORE it compares any edge
  -- and NULL is DISTINCT FROM everything. The app does not send one; this is why it must not matter.
  v_etag       text := coalesce(p_meta->>'source_etag', derm._img_etag(p_source_url));
  v_reject     text;
  v_prev       record;
  v_n_rules    integer := 0;
  v_n_bounds   integer := 0;
  v_pitch      numeric;
  v_wrote      boolean := false;
BEGIN
  -- 2026-09-02: 'human-v1-%' admitted alongside 'runlen-v2-%'. The READER was widened by
  -- 2026-09-02_0330 and this WRITER was not, so an operator-marked page raised
  -- "source must match runlen-v2-%" and nothing could ever be recorded. Measured before this
  -- migration: 176 scans exist and every one is runlen-v2, i.e. the widened view had never
  -- admitted a single row and was inert from the hour it shipped.
  IF NOT derm._is_rule_source(p_source) THEN
    RAISE EXCEPTION 'source must match runlen-v2-%% or human-v1-%%, got %',
      coalesce(p_source,'<null>') USING ERRCODE = '22023';
  END IF;
  IF p_dump_folder IS NULL OR p_effective_page IS NULL THEN
    RAISE EXCEPTION 'dump_folder and effective_page are required' USING ERRCODE = '22023';
  END IF;
  IF v_grade NOT IN ('OK','IRREGULAR','SPARSE','FAILED') THEN
    RAISE EXCEPTION 'grade % is outside the allowed vocabulary', v_grade USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                  WHERE r.dump_folder = p_dump_folder
                    AND coalesce(r.stamp_page, r.page) = p_effective_page) THEN
    RAISE EXCEPTION 'no cards on %/% : refusing to record rules for a page that does not exist',
      p_dump_folder, p_effective_page USING ERRCODE = '22023';
  END IF;

  SELECT s.grade, s.source, s.source_etag, s.scanned_at
    INTO v_prev
    FROM derm.page_rule_scans s
   WHERE s.dump_folder = p_dump_folder AND s.effective_page = p_effective_page
     AND derm._is_rule_source(s.source)
   ORDER BY s.scanned_at DESC
   LIMIT 1;

  -- 2026-09-02: was v_prev.grade = 'OK'. Widened to any non-FAILED grade because rules are
  -- WRITTEN on OK, SPARSE and IRREGULAR alike, and the view joins rules on the NEWEST scan's
  -- own source. So a later FAILED scan does not delete the old rules, it HIDES them: the page
  -- silently serves zero rules and every band on it grades UNSCANNED. Live corpus: 8 SPARSE
  -- and 2 IRREGULAR scans were exposed to that, and 0 pages are shadowed today, so this
  -- changes no existing row and is purely protective.
  IF FOUND AND v_prev.grade <> 'FAILED' AND v_grade = 'FAILED' AND NOT p_force
     AND (v_etag IS NULL OR v_prev.source_etag IS NULL OR v_etag = v_prev.source_etag) THEN
    RETURN jsonb_build_object(
      'wrote', false, 'grade', v_grade, 'rules_written', 0,
      'skipped', 'would_supersede_ok',
      'detail', format('this page already has a %s scan (%s) and the image has not changed; '
                       || 'refusing to replace it with a %s result',
                       v_prev.grade, v_prev.source, v_grade));
  END IF;

  IF v_grade <> 'FAILED' THEN
    v_reject := derm.fn_validate_page_rules(p_rules);
    IF v_reject IS NOT NULL THEN
      v_grade  := 'FAILED';
      v_detail := 'rejected by fn_validate_page_rules: ' || v_reject;
    END IF;
  END IF;

  SELECT count(*), count(*) FILTER (WHERE e->>'kind' = 'boundary')
    INTO v_n_rules, v_n_bounds
    FROM jsonb_array_elements(coalesce(p_rules,'[]'::jsonb)) e;

  IF v_grade <> 'FAILED' THEN
    WITH b AS (
      SELECT (e->>'pct')::numeric AS pct
        FROM jsonb_array_elements(p_rules) e
       WHERE e->>'kind' = 'boundary'
       ORDER BY 1
    ), g AS (
      SELECT pct - lag(pct) OVER (ORDER BY pct) AS gap FROM b
    )
    SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY gap) INTO v_pitch FROM g WHERE gap IS NOT NULL;
  END IF;

  INSERT INTO derm.page_rule_scans
    (dump_folder, effective_page, source_url, image_w, image_h, skew,
     n_rules, n_boundaries, pitch_pct, grade, detail, source, scanned_at, source_etag, skew_saturated)
  VALUES
    (p_dump_folder, p_effective_page, coalesce(p_source_url,'(unknown)'),
     (p_meta->>'image_w')::int, (p_meta->>'image_h')::int, (p_meta->>'skew')::numeric,
     v_n_rules, v_n_bounds, v_pitch, v_grade, v_detail, p_source, now(), v_etag,
     coalesce((p_meta->>'skew_saturated')::boolean, false))
  ON CONFLICT (dump_folder, effective_page, source) DO UPDATE
    SET source_url = EXCLUDED.source_url, image_w = EXCLUDED.image_w, image_h = EXCLUDED.image_h,
        skew = EXCLUDED.skew, n_rules = EXCLUDED.n_rules, n_boundaries = EXCLUDED.n_boundaries,
        pitch_pct = EXCLUDED.pitch_pct, grade = EXCLUDED.grade, detail = EXCLUDED.detail,
        scanned_at = EXCLUDED.scanned_at, source_etag = EXCLUDED.source_etag,
        skew_saturated = EXCLUDED.skew_saturated;

  IF v_grade <> 'FAILED' THEN
    DELETE FROM derm.page_row_rules
     WHERE dump_folder = p_dump_folder AND effective_page = p_effective_page AND source = p_source;
    INSERT INTO derm.page_row_rules
      (dump_folder, effective_page, rule_pct, ink_frac, source, detected_at, run_frac, kind, kind_confirmed)
    SELECT p_dump_folder, p_effective_page,
           (e->>'pct')::numeric, coalesce((e->>'ink')::numeric, 0), p_source, now(),
           (e->>'run')::numeric, e->>'kind', false
      FROM jsonb_array_elements(p_rules) e;
    v_wrote := true;
  END IF;

  RETURN jsonb_build_object(
    'wrote', v_wrote, 'grade', v_grade,
    'rules_written', CASE WHEN v_wrote THEN v_n_rules ELSE 0 END,
    'n_boundaries', v_n_bounds, 'pitch', v_pitch, 'detail', v_detail,
    'source_etag', v_etag);
END $function$;

DO $$
DECLARE
  v_viewdef text;
  v_res     jsonb;
  v_report  text := '';
  v_n       int;
  v_ok      boolean;
BEGIN
  ----------------------------------------------------------------------------
  -- 1. the admitted set, with both arms and the refusals
  ----------------------------------------------------------------------------
  IF NOT derm._is_rule_source('runlen-v2-2026-09-02') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: the detector prefix is not admitted';
  END IF;
  IF NOT derm._is_rule_source('human-v1-2026-09-02') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: the operator prefix is not admitted';
  END IF;
  -- CONTROL: the set must still REFUSE, or admitting things proves nothing
  IF derm._is_rule_source('claude-vision-v1')
     OR derm._is_rule_source(NULL)
     OR derm._is_rule_source('runlen-v2')      -- no trailing dash: not a dated run
     OR derm._is_rule_source('human-v1')
     OR derm._is_rule_source('anything-else') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: the source gate admits something it must refuse';
  END IF;

  ----------------------------------------------------------------------------
  -- 2. reader and writer agree. The view holds literal patterns by design (see the COMMENT),
  --    so the check is that both arms are present there and claude is not.
  ----------------------------------------------------------------------------
  SELECT pg_get_viewdef('derm.v_page_printed_rules'::regclass, true) INTO v_viewdef;
  IF v_viewdef NOT LIKE '%runlen-v2-%' OR v_viewdef NOT LIKE '%human-v1-%' THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: the view does not admit both arms the writer does';
  END IF;
  IF v_viewdef LIKE '%claude-%' THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: the view mentions claude, which must stay excluded';
  END IF;

  ----------------------------------------------------------------------------
  -- 3. THE ASSERTION THE PREVIOUS MIGRATION LACKED: drive the NEW arm end to end, on a real
  --    page, and read it back OUT OF THE VIEW. Rolled back via a subtransaction.
  --    ticket-834489 is chosen deliberately: 0 extents, 0 published documents, 0 rules, so a
  --    write there cannot reach a customer even for the instant it exists.
  ----------------------------------------------------------------------------
  BEGIN
    v_res := derm.record_page_rules(
      'ticket-834489', 1, 'human-v1-verify', 'https://example.invalid/probe.jpg',
      '[{"pct":27.960,"run":0.356,"ink":0.5,"kind":"boundary"},
        {"pct":33.340,"run":0.351,"ink":0.5,"kind":"boundary"},
        {"pct":38.720,"run":0.351,"ink":0.5,"kind":"boundary"},
        {"pct":44.100,"run":0.347,"ink":0.5,"kind":"boundary"},
        {"pct":49.480,"run":0.347,"ink":0.5,"kind":"boundary"},
        {"pct":54.860,"run":0.352,"ink":0.5,"kind":"boundary"},
        {"pct":60.240,"run":0.367,"ink":0.5,"kind":"boundary"}]'::jsonb,
      '{"grade":"OK","source_etag":"probe-etag"}'::jsonb);

    IF NOT (v_res->>'wrote')::boolean THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: human-v1 record refused: %', v_res::text;
    END IF;
    IF (v_res->>'rules_written')::int <> 7 THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: wrote % rules, expected 7', v_res->>'rules_written';
    END IF;

    -- it must be VISIBLE through the reader, not merely present in the table
    SELECT count(*) INTO v_n FROM derm.v_page_printed_rules
     WHERE dump_folder = 'ticket-834489' AND effective_page = 1 AND source = 'human-v1-verify';
    IF v_n <> 7 THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: the view serves % of 7 operator-marked rules', v_n;
    END IF;

    -- 3b. the supersession guard now SEES that human scan: a later FAILED detector run must be
    --     refused rather than silently hiding it.
    v_res := derm.record_page_rules(
      'ticket-834489', 1, 'runlen-v2-verify', 'https://example.invalid/probe.jpg',
      '[]'::jsonb, '{"grade":"FAILED","source_etag":"probe-etag"}'::jsonb);
    IF v_res->>'skipped' IS DISTINCT FROM 'would_supersede_ok' THEN
      RAISE EXCEPTION 'VERIFY 3b FAILED: a FAILED detector run was allowed to shadow the operator marks: %', v_res::text;
    END IF;
    SELECT count(*) INTO v_n FROM derm.v_page_printed_rules
     WHERE dump_folder = 'ticket-834489' AND effective_page = 1;
    IF v_n <> 7 THEN
      RAISE EXCEPTION 'VERIFY 3b FAILED: the operator marks stopped being served (% rows)', v_n;
    END IF;

    -- 3c. CONTROL for 3b: p_force must still get through, or the guard is a wall not a gate
    v_res := derm.record_page_rules(
      'ticket-834489', 1, 'runlen-v2-verify', 'https://example.invalid/probe.jpg',
      '[]'::jsonb, '{"grade":"FAILED","source_etag":"probe-etag"}'::jsonb, true);
    IF v_res->>'skipped' IS NOT NULL THEN
      RAISE EXCEPTION 'VERIFY 3c FAILED: p_force did not override the supersession guard: %', v_res::text;
    END IF;

    -- 3d. THE SPARSE ARM. This is what makes the "any non-FAILED" widening a tested change rather
    --     than an asserted one: with the old `v_prev.grade = 'OK'` condition every assertion above
    --     still passes, because they all use an OK scan. A SPARSE scan writes rules exactly like an
    --     OK one and can be hidden exactly like one, and the corpus holds 8 of them.
    v_res := derm.record_page_rules(
      'ticket-834489', 1, 'human-v1-verify-sparse', 'https://example.invalid/probe.jpg',
      '[{"pct":27.960,"run":0.356,"ink":0.5,"kind":"boundary"},
        {"pct":33.340,"run":0.351,"ink":0.5,"kind":"boundary"},
        {"pct":38.720,"run":0.351,"ink":0.5,"kind":"boundary"},
        {"pct":44.100,"run":0.347,"ink":0.5,"kind":"boundary"},
        {"pct":49.480,"run":0.347,"ink":0.5,"kind":"boundary"},
        {"pct":54.860,"run":0.352,"ink":0.5,"kind":"boundary"},
        {"pct":60.240,"run":0.367,"ink":0.5,"kind":"boundary"}]'::jsonb,
      '{"grade":"SPARSE","source_etag":"probe-etag"}'::jsonb);
    IF NOT (v_res->>'wrote')::boolean OR v_res->>'grade' <> 'SPARSE' THEN
      RAISE EXCEPTION 'VERIFY 3d FAILED: a SPARSE operator scan did not write: %', v_res::text;
    END IF;

    -- now() is the TRANSACTION timestamp, so every scan written in this probe ties on scanned_at
    -- and "newest" is arbitrary among them. That tie made an earlier draft of this block pass
    -- against a mutant carrying the old `grade = OK` condition, because the lookup could return
    -- the OK scan instead of the SPARSE one. Leave exactly one scan standing so the assertion is
    -- about the grade and nothing else. (Live, each RPC is its own transaction and cannot tie.)
    DELETE FROM derm.page_rule_scans
     WHERE dump_folder = 'ticket-834489' AND source <> 'human-v1-verify-sparse';

    v_res := derm.record_page_rules(
      'ticket-834489', 1, 'runlen-v2-verify-2', 'https://example.invalid/probe.jpg',
      '[]'::jsonb, '{"grade":"FAILED","source_etag":"probe-etag"}'::jsonb);
    IF v_res->>'skipped' IS DISTINCT FROM 'would_supersede_ok' THEN
      RAISE EXCEPTION 'VERIFY 3d FAILED: a FAILED detector run was allowed to shadow a SPARSE operator scan: %', v_res::text;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_PROBE' USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN
      v_report := 'probe rolled back';
  END;
  IF v_report <> 'probe rolled back' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: the probe subtransaction did not run';
  END IF;

  -- and it really did roll back
  SELECT count(*) INTO v_n FROM derm.page_rule_scans
   WHERE dump_folder = 'ticket-834489' AND source IN ('human-v1-verify','runlen-v2-verify');
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: % probe scan(s) survived the rollback', v_n;
  END IF;

  ----------------------------------------------------------------------------
  -- 4. CONTROL: the gate still bites. A source outside the admitted set must RAISE, and
  --    claude-% specifically must still be refused by the writer.
  ----------------------------------------------------------------------------
  v_ok := false;
  BEGIN
    PERFORM derm.record_page_rules('ticket-834489', 1, 'claude-vision-v1', NULL,
                                   '[]'::jsonb, '{"grade":"FAILED"}'::jsonb);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: a claude source was accepted by the writer';
  END IF;

  v_ok := false;
  BEGIN
    PERFORM derm.record_page_rules('ticket-834489', 1, 'runlen-v3-future', NULL,
                                   '[]'::jsonb, '{"grade":"FAILED"}'::jsonb);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: an unrecognised source was accepted';
  END IF;

  ----------------------------------------------------------------------------
  -- 5. no existing page changed. The whole live corpus is runlen-v2, so the view must serve
  --    exactly what it served before this migration.
  ----------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM derm.v_page_printed_rules;
  IF v_n <> 2331 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: the view serves % rules, expected the pre-migration count', v_n;
  END IF;

  RAISE NOTICE 'OK: operator marks are writable and readable end to end; detector arm unchanged; claude still refused.';
END $$;

COMMIT;
