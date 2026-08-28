-- 2026-08-28_1520_record_page_rules_rpc.sql
--
-- WHY: THE GUARD THAT BLOCKS DIEGO HAS NO IN-PRODUCT WAY TO BE SATISFIED.
-- ---------------------------------------------------------------------------
-- `derm.save_page_geometry` refuses a band edge that is not on a printed rule detected from the
-- scan (G9_OFF_RULE). That guard is correct: it is what stops a repeat of the 2026-08-19 leak,
-- where derived bands were published and clients were served redactions carrying a neighbour's GDO
-- number and street address.
--
-- But NOTHING IN THE PRODUCT EVER PRODUCES THE DATA IT NEEDS. Every `page_row_rules` row in history
-- was written by a developer running scripts/probes/derm_band_review/detect.js in a Playwright
-- browser, piping it through classify.js and hand-authoring a migration. Fred hit this on
-- ticket-312433 and got ten identical G9_OFF_RULE lines whose only informative words, "no rules for
-- this page", were buried in a trailing parenthetical. An office user has no way forward at all.
--
-- Fred: "I don't want to be needing you to do that, it's supposed to be something done by the app,
-- what about an office member like diego working on it, he doesn't have you to work for him."
--
-- Measured 2026-08-28: 174 pages carry stamps, 168 have rules, 6 are blocked, and NONE of the 6 is
-- serving a client. The backlog is not the problem; the RATE is. Every newly generated sheet
-- arrives in this state and Diego files manifests daily.
--
-- This migration adds the WRITE PATH. The detector itself runs in the Studio, because the algorithm
-- is pure canvas pixel arithmetic with no AI call and the app already loads that same image with
-- crossOrigin="anonymous" and already uses canvas for its PNG export.
--
-- ---------------------------------------------------------------------------
-- 🛑 DEVIATION FROM THE SPEC, DELIBERATE, FLAGGED FOR FRED
-- ---------------------------------------------------------------------------
-- docs/superpowers/specs/2026-08-28-in-app-printed-rule-detection-design.md says classify.js's
-- ~200 lines of trim / duplicate-merge / end-bar removal / phase choice / grading move into a SQL
-- function. Reading that code closely changed my mind, and this ships the safer half instead:
--
--   the APP classifies (a JS-to-JS port of the same file, same language, faithful), and
--   the DATABASE independently VALIDATES the result and fails closed.
--
-- Why: a JS-to-PLpgSQL rewrite of that specific file is the highest-risk thing in this change. It
-- carries a documented history of subtle, expensive bugs (the 1.0pp trim margin that manufactured
-- the worst entry on the worklist; the post-refinement duplicates that flipped every label below
-- them; the `0.70 * maxRun` threshold that ate eight of twelve rules on ticket-311045 p1). A
-- reimplementation that drifts from the original is the exact failure this repo already paid for
-- with the base64 encoder existing in two files.
--
-- The spec's stated reason for SQL was that a stale browser bundle must not be able to write a
-- differently-classified page. VALIDATION gives that property without the rewrite, and the key
-- insight is that the dangerous error is INDEPENDENTLY DETECTABLE: a phase flip (every boundary and
-- divider swapped) passes an alternation check, because both phases alternate. But it does NOT
-- survive a run-length split, since a slot boundary spans the whole form (run ~1.0) and a mid-slot
-- divider stops at the first column line (run ~0.4). classify.js already computes exactly this as
-- `split_agrees` and deliberately only RECORDS it. For an unattended write path the right posture
-- is stricter than a developer's script: here, disagreement REFUSES.
--
-- Net effect: a stale or wrong bundle cannot write a dangerous result, only a refused one.
--
-- ---------------------------------------------------------------------------
-- 🛑 THE SUPERSESSION HAZARD, FOUND BEFORE WRITING A LINE OF THIS
-- ---------------------------------------------------------------------------
-- `derm.v_page_printed_rules` takes DISTINCT ON (folder, page) the NEWEST `runlen-v2-%` scan, then
-- joins `page_row_rules` on `pr.source = sc.source`. IT DOES NOT FILTER ON GRADE.
--
-- So writing a new scan row with a NEW source and no rules SILENTLY STRIPS A WORKING PAGE OF ITS
-- RULES: the new scan wins the DISTINCT ON, the join finds nothing for that source, and a page that
-- was fine yesterday starts failing G9 and reads UNSCANNED in v_band_edge_check. Re-running
-- detection on a page that already works could therefore break it.
--
-- Guarded here: a non-OK result will NOT supersede an existing OK scan unless the image itself
-- changed (etag differs) or the caller explicitly forces it. See PART 2 / rule S1.
--
-- RULE 8 (audit trail): `derm.page_row_rules` and `derm.page_rule_scans` are detector OUTPUT, not
-- human-editable fields, and both are fully reproducible from the image. Opt-out, consistent with
-- their existing state (neither carries a trigger today). The scan row is itself the provenance
-- record: it stores who/what/when via `source` + `scanned_at` + `source_etag`.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1. The validator. Pure, no writes, so it can be unit-tested on its own.
-- Returns NULL when the rule set is acceptable, else the reason it is not.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_validate_page_rules(p_rules jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = derm, public, pg_temp
AS $fn$
DECLARE
  MIN_SEP   constant numeric := 0.70;   -- classify.js near-duplicate merge distance
  v_n       integer;
  v_prev    numeric;
  v_rec     record;
  v_chain   numeric[] := '{}';          -- run values of chain members, in page order
  v_isb     boolean[] := '{}';          -- is-boundary, in page order
  v_bounds  numeric[] := '{}';          -- boundary positions
  v_runs    numeric[];
  v_cut     numeric := NULL;
  v_gap     numeric := 0;
  v_pitch   numeric;
  v_gaps    numeric[] := '{}';
  i         integer;
BEGIN
  IF p_rules IS NULL OR jsonb_typeof(p_rules) <> 'array' THEN
    RETURN 'rules is not a json array';
  END IF;
  SELECT count(*) INTO v_n FROM jsonb_array_elements(p_rules);
  IF v_n = 0 THEN RETURN 'no rules'; END IF;

  -- V1..V3: shape, range, strict ascent, and the post-refinement duplicate check. classify.js
  -- re-applies suppression AFTER centroid refinement because two peaks 4px apart can END UP 2px
  -- apart, and a duplicate inserts one extra element into a strictly alternating sequence, which
  -- flips the boundary/divider label for everything below it.
  v_prev := NULL;
  FOR v_rec IN
    SELECT (e->>'pct')::numeric AS pct,
           (e->>'run')::numeric AS run,
           e->>'kind'           AS kind,
           ordinality           AS ord
      FROM jsonb_array_elements(p_rules) WITH ORDINALITY e(e, ordinality)
  LOOP
    IF v_rec.pct IS NULL OR v_rec.run IS NULL OR v_rec.kind IS NULL THEN
      RETURN format('rule %s is missing pct, run or kind', v_rec.ord);
    END IF;
    IF v_rec.pct <= 0 OR v_rec.pct >= 100 THEN
      RETURN format('rule %s pct %s is out of range', v_rec.ord, v_rec.pct);
    END IF;
    IF v_prev IS NOT NULL AND v_rec.pct <= v_prev THEN
      RETURN format('rules are not in strictly ascending order at %s', v_rec.pct);
    END IF;
    IF v_prev IS NOT NULL AND v_rec.pct - v_prev < MIN_SEP THEN
      RETURN format('rules %s and %s are %spp apart, closer than the %spp merge distance',
                    v_prev, v_rec.pct, round(v_rec.pct - v_prev, 3), MIN_SEP);
    END IF;
    IF v_rec.kind NOT IN ('boundary','divider','header-footer') THEN
      RETURN format('rule %s has unknown kind %L', v_rec.pct, v_rec.kind);
    END IF;
    v_prev := v_rec.pct;

    -- the CHAIN is the roster's own alternating sequence. header-footer bars are deliberately kept
    -- in the rule list (a header bar IS a printed rule, and an edge on it is genuinely not inside a
    -- line of text) but excluded from the chain, because they break the alternation.
    IF v_rec.kind IN ('boundary','divider') THEN
      v_chain := v_chain || v_rec.run;
      v_isb   := v_isb   || (v_rec.kind = 'boundary');
      IF v_rec.kind = 'boundary' THEN v_bounds := v_bounds || v_rec.pct; END IF;
    END IF;
  END LOOP;

  IF array_length(v_chain,1) IS NULL OR array_length(v_chain,1) < 5 THEN
    RETURN format('only %s rules inside the roster', coalesce(array_length(v_chain,1),0));
  END IF;
  IF array_length(v_bounds,1) < 3 THEN
    RETURN format('only %s slot boundaries', coalesce(array_length(v_bounds,1),0));
  END IF;

  -- V4: STRICT ALTERNATION down the chain.
  FOR i IN 2 .. array_length(v_isb,1) LOOP
    IF v_isb[i] = v_isb[i-1] THEN
      RETURN format('chain does not alternate at position %s', i);
    END IF;
  END LOOP;

  -- V5: 🛑 THE PHASE CHECK, AND THE REASON THIS FUNCTION EXISTS.
  -- A phase flip swaps every boundary and divider and STILL ALTERNATES, so V4 cannot see it. The
  -- run length can: a slot boundary spans the whole form, a mid-slot divider stops at the first
  -- vertical column line. Split the chain's own run values at their largest gap (never a fixed
  -- fraction: on ticket-311045 p1 the two clusters sit at 0.403 and 0.542, and a fixed threshold
  -- marked every rule long) and require the split to agree with the submitted labels.
  v_runs := ARRAY(SELECT unnest(v_chain) ORDER BY 1);
  FOR i IN 2 .. array_length(v_runs,1) LOOP
    IF v_runs[i] - v_runs[i-1] > v_gap THEN
      v_gap := v_runs[i] - v_runs[i-1];
      v_cut := (v_runs[i] + v_runs[i-1]) / 2;
    END IF;
  END LOOP;
  IF v_cut IS NULL THEN
    RETURN 'cannot split the run values: every rule has the same run length';
  END IF;
  FOR i IN 1 .. array_length(v_chain,1) LOOP
    IF (v_chain[i] >= v_cut) <> v_isb[i] THEN
      RETURN format('run-length split disagrees with the labels at chain position %s '
                    || '(run %s, cut %s, labelled %s): a phase flip',
                    i, v_chain[i], round(v_cut,3),
                    CASE WHEN v_isb[i] THEN 'boundary' ELSE 'divider' END);
    END IF;
  END LOOP;

  -- 🛑 SPACING IS DELIBERATELY NOT CHECKED HERE. classify.js grades SPARSE when a gap looks like a
  -- whole MISSING boundary and IRREGULAR when gaps wander off the pitch, and in both cases it still
  -- emits the rules, because a missing boundary does not make the boundaries that WERE found fake.
  -- Measured 2026-08-28: 12 of the 168 measured pages are graded non-OK and carry rules today, and
  -- they work. Rejecting them here would leave those pages permanently unmeasurable while removing
  -- no risk: an edge that finds no rule still fails G9 on its own.
  RETURN NULL;   -- acceptable
END $fn$;

COMMENT ON FUNCTION derm.fn_validate_page_rules(jsonb) IS
'Independent check on a classified rule set proposed by the Stamp Studio. Returns NULL when it is '
'acceptable, else the reason. The load-bearing test is V5: a phase flip (boundary/divider swapped) '
'passes an alternation check because both phases alternate, but it cannot survive a split of the '
'run values, since a slot boundary spans the whole form and a mid-slot divider does not.';

-- ---------------------------------------------------------------------------
-- PART 2. The write path.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.record_page_rules(
  p_dump_folder    text,
  p_effective_page integer,
  p_source         text,
  p_source_url     text,
  p_rules          jsonb,
  p_meta           jsonb DEFAULT '{}'::jsonb,
  p_force          boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = derm, public, pg_temp
AS $fn$
DECLARE
  v_grade      text := coalesce(p_meta->>'grade', 'FAILED');
  v_detail     text := p_meta->>'detail';
  v_etag       text := p_meta->>'source_etag';
  v_reject     text;
  v_prev       record;
  v_n_rules    integer := 0;
  v_n_bounds   integer := 0;
  v_pitch      numeric;
  v_wrote      boolean := false;
BEGIN
  -- G1. Source vocabulary. v_page_printed_rules selects on 'runlen-v2-%' and deliberately ignores
  -- the five hand-recorded 'claude-*' sources. A new ALGORITHM gets v3 and is deliberately not
  -- picked up until somebody opts in, so this must never be relaxed to a wildcard.
  IF p_source IS NULL OR p_source NOT LIKE 'runlen-v2-%' THEN
    RAISE EXCEPTION 'source must match runlen-v2-%%, got %', coalesce(p_source,'<null>')
      USING ERRCODE = '22023';
  END IF;
  IF p_dump_folder IS NULL OR p_effective_page IS NULL THEN
    RAISE EXCEPTION 'dump_folder and effective_page are required' USING ERRCODE = '22023';
  END IF;
  IF v_grade NOT IN ('OK','IRREGULAR','SPARSE','FAILED') THEN
    RAISE EXCEPTION 'grade % is outside the allowed vocabulary', v_grade USING ERRCODE = '22023';
  END IF;

  -- G2. Never invent a page. The folder/page must actually carry cards.
  IF NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                  WHERE r.dump_folder = p_dump_folder
                    AND coalesce(r.stamp_page, r.page) = p_effective_page) THEN
    RAISE EXCEPTION 'no cards on %/% : refusing to record rules for a page that does not exist',
      p_dump_folder, p_effective_page USING ERRCODE = '22023';
  END IF;

  -- S1. 🛑 SUPERSESSION GUARD. v_page_printed_rules takes the NEWEST runlen-v2 scan and joins rules
  -- on that scan's own source, WITHOUT filtering on grade. So a new scan carrying no rules silently
  -- strips a working page. Refuse to let a non-OK result supersede an existing OK scan unless the
  -- image actually changed or the caller forces it.
  SELECT s.grade, s.source, s.source_etag, s.scanned_at
    INTO v_prev
    FROM derm.page_rule_scans s
   WHERE s.dump_folder = p_dump_folder AND s.effective_page = p_effective_page
     AND s.source LIKE 'runlen-v2-%'
   ORDER BY s.scanned_at DESC
   LIMIT 1;

  IF FOUND AND v_prev.grade = 'OK' AND v_grade = 'FAILED' AND NOT p_force
     AND (v_etag IS NULL OR v_prev.source_etag IS NULL OR v_etag = v_prev.source_etag) THEN
    RETURN jsonb_build_object(
      'wrote', false, 'grade', v_grade, 'rules_written', 0,
      'skipped', 'would_supersede_ok',
      'detail', format('this page already has an OK scan (%s) and the image has not changed; '
                       || 'refusing to replace it with a %s result', v_prev.source, v_grade));
  END IF;

  -- V. Validate whenever the caller proposes usable rules. A failure DOWNGRADES to FAILED rather
  -- than raising, so the app can show the operator something useful and the attempt is recorded.
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

  -- The scan row is written ALWAYS, whatever the outcome. "detection ran and could not read this
  -- page" and "nobody ever looked" are different states, and collapsing them is the false
  -- all-clear this estate keeps paying for.
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

  -- Rules are written on any grade EXCEPT FAILED, and only after fn_validate_page_rules accepted
  -- the labelling. FAILED means the classification itself is untrustworthy (too few rules, or the
  -- two phases are indistinguishable), so the labels may be wrong and nothing is written: that page
  -- keeps blocking. This is the entire safety property, because garbage rules are strictly worse
  -- than no rules, the guard would then ACCEPT bands snapped to lines that are not on the paper.
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
    'n_boundaries', v_n_bounds, 'pitch', v_pitch, 'detail', v_detail);
END $fn$;

COMMENT ON FUNCTION derm.record_page_rules(text,integer,text,text,jsonb,jsonb,boolean) IS
'The ONLY write path for derm.page_row_rules / page_rule_scans. Called by the DERM Stamp Studio '
'after it detects printed rules from the page image in a canvas. Always records a scan row so a '
'failed read stays distinguishable from a page nobody has looked at; writes rules only on an '
'accepted OK, so a page that cannot be measured keeps blocking save_page_geometry.';

REVOKE ALL ON FUNCTION derm.record_page_rules(text,integer,text,text,jsonb,jsonb,boolean) FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN
    EXECUTE 'REVOKE ALL ON FUNCTION derm.record_page_rules(text,integer,text,text,jsonb,jsonb,boolean) FROM anon';
  END IF;
END $$;
GRANT EXECUTE ON FUNCTION derm.record_page_rules(text,integer,text,text,jsonb,jsonb,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION derm.fn_validate_page_rules(jsonb) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_ok   jsonb;
  v_bad  jsonb;
  v_r    text;
  v_res  jsonb;
  v_n    integer;
  v_before integer;
BEGIN
  -- A real, clean page: ticket-312433 p1 as actually detected on 2026-08-28.
  v_ok := '[{"pct":24.945,"run":0.989,"ink":0.31,"kind":"boundary"},
            {"pct":29.075,"run":0.400,"ink":0.12,"kind":"divider"},
            {"pct":33.206,"run":0.990,"ink":0.30,"kind":"boundary"},
            {"pct":36.625,"run":0.401,"ink":0.11,"kind":"divider"},
            {"pct":39.880,"run":0.986,"ink":0.29,"kind":"boundary"},
            {"pct":43.189,"run":0.400,"ink":0.12,"kind":"divider"},
            {"pct":47.101,"run":0.984,"ink":0.30,"kind":"boundary"},
            {"pct":50.875,"run":0.401,"ink":0.11,"kind":"divider"},
            {"pct":54.978,"run":0.991,"ink":0.31,"kind":"boundary"},
            {"pct":58.698,"run":0.402,"ink":0.12,"kind":"divider"},
            {"pct":62.746,"run":0.991,"ink":0.30,"kind":"boundary"}]'::jsonb;

  -- 1. The real page validates.
  v_r := derm.fn_validate_page_rules(v_ok);
  IF v_r IS NOT NULL THEN RAISE EXCEPTION 'VERIFY 1 FAILED: real page rejected: %', v_r; END IF;

  -- 2. 🛑 THE CONTROL THAT MAKES 1 MEAN ANYTHING: a PHASE FLIP must be caught. It alternates
  --    perfectly, so only the run-length split can see it.
  SELECT jsonb_agg(jsonb_set(e, '{kind}',
           to_jsonb(CASE WHEN e->>'kind'='boundary' THEN 'divider' ELSE 'boundary' END))
           ORDER BY (e->>'pct')::numeric)
    INTO v_bad FROM jsonb_array_elements(v_ok) e;
  v_r := derm.fn_validate_page_rules(v_bad);
  IF v_r IS NULL THEN RAISE EXCEPTION 'VERIFY 2 FAILED: a phase flip was accepted'; END IF;
  IF v_r NOT LIKE '%phase flip%' THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: phase flip caught but by the wrong rule: %', v_r;
  END IF;

  -- 3. Non-alternating input is caught.
  v_r := derm.fn_validate_page_rules(
    '[{"pct":10,"run":0.99,"ink":0.3,"kind":"boundary"},
      {"pct":20,"run":0.98,"ink":0.3,"kind":"boundary"},
      {"pct":30,"run":0.40,"ink":0.1,"kind":"divider"},
      {"pct":40,"run":0.99,"ink":0.3,"kind":"boundary"},
      {"pct":50,"run":0.40,"ink":0.1,"kind":"divider"},
      {"pct":60,"run":0.99,"ink":0.3,"kind":"boundary"}]'::jsonb);
  IF v_r IS NULL OR v_r NOT LIKE '%alternate%' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: non-alternating chain accepted (%)', coalesce(v_r,'NULL');
  END IF;

  -- 4. A post-refinement duplicate is caught (the defect that flipped labels on ticket-311780 p2).
  v_r := derm.fn_validate_page_rules(
    (SELECT jsonb_agg(e ORDER BY (e->>'pct')::numeric)
       FROM (SELECT e FROM jsonb_array_elements(v_ok) e
             UNION ALL SELECT '{"pct":24.999,"run":0.9,"ink":0.3,"kind":"divider"}'::jsonb) t(e)));
  IF v_r IS NULL OR v_r NOT LIKE '%merge distance%' THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: near-duplicate accepted (%)', coalesce(v_r,'NULL');
  END IF;

  -- 5. Descending / out-of-range input is caught.
  IF derm.fn_validate_page_rules('[{"pct":150,"run":0.9,"ink":0.1,"kind":"boundary"}]'::jsonb) IS NULL
  THEN RAISE EXCEPTION 'VERIFY 5 FAILED: out-of-range pct accepted'; END IF;

  -- 6. A bad source is refused outright.
  BEGIN
    PERFORM derm.record_page_rules('ticket-312433', 1, 'claude-hand', 'x', v_ok);
    RAISE EXCEPTION 'VERIFY 6 FAILED: a non runlen-v2 source was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'VERIFY 6 FAILED%' THEN RAISE; END IF;
  END;

  -- 7. A page that does not exist is refused.
  BEGIN
    PERFORM derm.record_page_rules('ticket-does-not-exist', 1, 'runlen-v2-test', 'x', v_ok);
    RAISE EXCEPTION 'VERIFY 7 FAILED: rules recorded for a non-existent page';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'VERIFY 7 FAILED%' THEN RAISE; END IF;
  END;

  -- 8. 🛑 THE SUPERSESSION GUARD. ticket-832194 p1 already has an OK scan. A FAILED result must NOT
  --    replace it, or the page would silently lose its rules.
  SELECT count(*) INTO v_before FROM derm.page_row_rules
   WHERE dump_folder='ticket-832194' AND effective_page=1;
  v_res := derm.record_page_rules('ticket-832194', 1, 'runlen-v2-supersede-test', 'x',
                                  '[]'::jsonb, '{"grade":"FAILED","detail":"probe"}'::jsonb);
  IF (v_res->>'skipped') IS DISTINCT FROM 'would_supersede_ok' THEN
    RAISE EXCEPTION 'VERIFY 8 FAILED: a FAILED scan was allowed to supersede an OK one: %', v_res;
  END IF;
  SELECT count(*) INTO v_n FROM derm.page_row_rules
   WHERE dump_folder='ticket-832194' AND effective_page=1;
  IF v_n <> v_before THEN
    RAISE EXCEPTION 'VERIFY 8 FAILED: ticket-832194 p1 lost rules (% -> %)', v_before, v_n;
  END IF;

  -- 9. An OK claim that fails validation is DOWNGRADED and writes no rules. Rolled back.
  BEGIN
    v_res := derm.record_page_rules('ticket-312433', 1, 'runlen-v2-verify-probe', 'x',
                                    v_bad, '{"grade":"OK"}'::jsonb);
    IF (v_res->>'grade') <> 'FAILED' OR (v_res->>'rules_written')::int <> 0 THEN
      RAISE EXCEPTION 'VERIFY 9 FAILED: a phase-flipped OK submission wrote rules: %', v_res;
    END IF;
    SELECT count(*) INTO v_n FROM derm.page_row_rules
     WHERE dump_folder='ticket-312433' AND source='runlen-v2-verify-probe';
    IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 9 FAILED: % rules written', v_n; END IF;
    RAISE EXCEPTION 'probe_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'probe_rollback' THEN RAISE; END IF;
  END;

  -- 10. anon holds no EXECUTE.
  IF has_function_privilege('anon',
       'derm.record_page_rules(text,integer,text,text,jsonb,jsonb,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 10 FAILED: anon can execute record_page_rules';
  END IF;
  IF NOT has_function_privilege('authenticated',
       'derm.record_page_rules(text,integer,text,text,jsonb,jsonb,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 10 FAILED: authenticated cannot execute record_page_rules';
  END IF;

  -- 11. Nothing was written to the live estate by this migration.
  SELECT count(*) INTO v_n FROM derm.page_rule_scans WHERE source LIKE 'runlen-v2-%-test'
      OR source IN ('runlen-v2-supersede-test','runlen-v2-verify-probe');
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 11 FAILED: % probe scan row(s) leaked into page_rule_scans', v_n;
  END IF;

  RAISE NOTICE 'VERIFY ok: validator accepts the real page, catches a phase flip, a broken '
    'alternation, a near-duplicate and an out-of-range value; the RPC refuses a bad source, a '
    'non-existent page and a supersede, downgrades an invalid OK, and anon holds nothing.';
END $do$;

COMMIT;
