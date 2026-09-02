-- 2026-09-02_1030_allow_all_boundary_chain.sql
--
-- WHAT: derm.fn_validate_page_rules now accepts a chain whose lines are ALL slot boundaries, with a
--       new pitch-uniformity guard (V4b) standing in for the alternation check it skips.
--
-- WHY:  Fred drew every printed line on ticket-834489 and could not save any labelling of them.
--       That is not him choosing wrongly. Measured against the live validator, EVERY option fails:
--
--         all seven as slot boundaries      -> "chain does not alternate at position 2"      (V4)
--         outer two boundary, inner five divider -> "only 2 slot boundaries"                 (V3)
--         strict alternation                -> "run-length split disagrees ... a phase flip" (V5)
--
--       The sheet is real and its geometry is ordinary: seven lines at a 5.4pp pitch bounding six
--       client rows. The validator simply could not express it.
--
--       Fred's own words, and he is right: *"the limit bands should also count as client bands
--       because the limit also touches the first and last client rows."* The outermost lines are
--       both the roster's outer limit AND the top of the first client row and the bottom of the
--       last. Every one of those seven lines separates one client from the next.
--
-- 🛑 WHY ALTERNATION WAS WRONG TO REQUIRE UNCONDITIONALLY. It encodes an assumption about the
--    SCAN, not about the geometry: that a form's fainter mid-slot dividers are always detectable.
--    On a washed-out scan they are not. ticket-834489's seven lines all run 0.345 to 0.367 with no
--    long/short split anywhere, because only the boundaries inked strongly enough to be found. A
--    pure-boundary chain is coherent: N+1 lines, N slots, and nothing claimed about dividers.
--
-- 🛑 WHY THIS IS SAFE, WHICH IS THE PART THAT MATTERS. The dangerous mistake in this estate is a
--    PHASE FLIP: boundaries labelled dividers and back. It makes a band span two clients and shows
--    one client another client's row, which is exactly the 2026-08-19 leak. **With no dividers
--    claimed there is no phase to flip.**
--    The residual risk runs the other way and is milder: marking a real mid-slot divider as a
--    boundary halves a band into part of the client's OWN row. Self-only degradation, never a
--    cross-client leak. G13 still binds each strip to the one client whose stamp is inside it.
--
-- V4b, THE SUBSTITUTE GUARD. That residual mistake is detectable, because taking every second line
--    as a boundary makes the gaps alternate long/short while a genuine boundary run is evenly
--    pitched. Measured 2026-09-02, max gap deviation from the median:
--         ticket-834489, six real boundaries                       3.1%
--         ticket-834433, six real boundaries                      14.3%
--         ticket-834433, whole chain mislabelled all-boundary     38.6%
--    The threshold is 20%, which sits cleanly between the honest cases and the mislabelling
--    signature. It also demands at least three boundaries so a pitch can be measured at all.
--
-- 🛑 THE BODY WAS COPIED FROM pg_get_functiondef AND EDITED BY ANCHOR, NEVER RETYPED. This function
--    is the last line of defence for a customer-facing redaction; CREATE OR REPLACE takes the whole
--    body and silently deletes anything not reproduced. Before/after copies are committed under
--    scripts/probes/geom/. The diff is exactly two insertions plus the re-indent of the V4 loop.
--
-- ⚠ V5 also stands down for a pure-boundary chain, because there is no phase to check and no split
--    to demand. Its "every rule has the same run length" refusal is kept for every mixed chain.
--
-- RULE 8 (audit): no table or column changes. A function only.
-- RULE 2/3: nothing derived, copied or stored.

BEGIN;

CREATE OR REPLACE FUNCTION derm.fn_validate_page_rules(p_rules jsonb)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'derm', 'public', 'pg_temp'
AS $function$
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
  -- 2026-09-02: SKIPPED when the chain claims NO DIVIDERS AT ALL. Alternation assumes every
  -- sheet's mid-slot dividers are detectable, and on a faint scan they are not: ticket-834489
  -- yields seven lines all running 0.345-0.367, which ARE its slot boundaries. Every possible
  -- labelling of them was refused (all-boundary hit V4, mixed hit the boundary count, alternating
  -- hit V5), so a correct sheet was unrepresentable. A pure-boundary chain is coherent geometry:
  -- N+1 lines, N slots, nothing claimed about dividers.
  IF EXISTS (SELECT 1 FROM unnest(v_isb) b WHERE NOT b) THEN
    FOR i IN 2 .. array_length(v_isb,1) LOOP
      IF v_isb[i] = v_isb[i-1] THEN
        RETURN format('chain does not alternate at position %s', i);
      END IF;
    END LOOP;
  ELSE
    -- V4b: THE SUBSTITUTE GUARD, and the reason skipping V4 is safe rather than merely
    -- convenient. The dangerous error is a PHASE FLIP: boundaries labelled dividers and back,
    -- which makes a band span two clients and shows one client another's row. With no dividers
    -- claimed there is no phase to flip. The residual risk is the opposite and milder: marking a
    -- real mid-slot divider as a boundary, which halves a client's band into part of THEIR OWN
    -- row. That is a self-only degradation, never a cross-client leak.
    -- It is also detectable, because that mistake makes the gaps alternate long/short while a
    -- genuine boundary run is evenly pitched. Measured 2026-09-02:
    --   ticket-834489, six real boundaries          max gap deviation  3.1%
    --   ticket-834433, six real boundaries          max gap deviation 14.3%
    --   ticket-834433, whole chain mislabelled all-boundary       38.6%
    -- 20% sits cleanly between the honest cases and the mislabelling signature.
    DECLARE
      v_med numeric;
      v_dev numeric;
    BEGIN
      FOR i IN 2 .. array_length(v_bounds,1) LOOP
        v_gaps := v_gaps || (v_bounds[i] - v_bounds[i-1]);
      END LOOP;
      IF array_length(v_gaps,1) IS NULL OR array_length(v_gaps,1) < 2 THEN
        RETURN 'a chain with no mid-slot dividers needs at least three slot boundaries to check its pitch';
      END IF;
      SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY g) INTO v_med FROM unnest(v_gaps) g;
      IF v_med IS NULL OR v_med <= 0 THEN
        RETURN 'cannot measure the slot pitch of a chain with no mid-slot dividers';
      END IF;
      SELECT max(abs(g - v_med) / v_med) INTO v_dev FROM unnest(v_gaps) g;
      IF v_dev > 0.20 THEN
        RETURN format('every line is labelled a slot boundary, but they are not evenly pitched (worst gap is %s%% off the %s pp median). If some of these are mid-slot dividers inside a client row, label them as such.', round(v_dev*100,1), round(v_med,3));
      END IF;
    END;
  END IF;

  -- V5: ðŸ›‘ THE PHASE CHECK, AND THE REASON THIS FUNCTION EXISTS.
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
  -- 2026-09-02: with no dividers claimed there is no phase to check, and no split to demand.
  IF NOT EXISTS (SELECT 1 FROM unnest(v_isb) b WHERE NOT b) THEN
    RETURN NULL;   -- pure-boundary chain, already checked by V4b
  END IF;
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

  -- ðŸ›‘ SPACING IS DELIBERATELY NOT CHECKED HERE. classify.js grades SPARSE when a gap looks like a
  -- whole MISSING boundary and IRREGULAR when gaps wander off the pitch, and in both cases it still
  -- emits the rules, because a missing boundary does not make the boundaries that WERE found fake.
  -- Measured 2026-08-28: 12 of the 168 measured pages are graded non-OK and carry rules today, and
  -- they work. Rejecting them here would leave those pages permanently unmeasurable while removing
  -- no risk: an edge that finds no rule still fails G9 on its own.
  RETURN NULL;   -- acceptable
END $function$;

DO $$
DECLARE
  v_all   jsonb; v_alt jsonb; v_flip jsonb; v_fred jsonb; v_two jsonb;
  v_r     text;
BEGIN
  -- Fred's six lines on ticket-834489, all labelled slot boundaries. Must now be ACCEPTED.
  v_fred := '[{"pct":27.892,"run":0.356,"ink":0.5,"kind":"boundary"},
              {"pct":33.374,"run":0.351,"ink":0.5,"kind":"boundary"},
              {"pct":38.789,"run":0.351,"ink":0.5,"kind":"boundary"},
              {"pct":44.102,"run":0.347,"ink":0.5,"kind":"boundary"},
              {"pct":49.619,"run":0.347,"ink":0.5,"kind":"boundary"},
              {"pct":55.136,"run":0.367,"ink":0.5,"kind":"boundary"}]'::jsonb;
  v_r := derm.fn_validate_page_rules(v_fred);
  IF v_r IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: the 834489 all-boundary set is still refused: %', v_r;
  END IF;

  -- ticket-834433's REAL recorded rules, unchanged. Must still be ACCEPTED (no regression).
  SELECT jsonb_agg(jsonb_build_object('pct', rule_pct, 'run', run_frac, 'ink',
                                      coalesce(ink_frac, 0.5), 'kind', kind) ORDER BY rule_pct)
    INTO v_alt
    FROM derm.page_row_rules
   WHERE dump_folder = 'ticket-834433' AND effective_page = 1;
  IF v_alt IS NULL THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: no rules on ticket-834433, so the regression test proves nothing';
  END IF;
  v_r := derm.fn_validate_page_rules(v_alt);
  IF v_r IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: 834433 real rules now refused: %', v_r;
  END IF;

  -- CONTROL A: the same page's whole chain mislabelled as all-boundary. V4b must REFUSE it,
  -- otherwise the new arm is a hole rather than a guard.
  SELECT jsonb_agg(jsonb_build_object('pct', rule_pct, 'run', run_frac, 'ink',
                                      coalesce(ink_frac, 0.5), 'kind', 'boundary') ORDER BY rule_pct)
    INTO v_all
    FROM derm.page_row_rules
   WHERE dump_folder = 'ticket-834433' AND effective_page = 1 AND kind IN ('boundary','divider');
  v_r := derm.fn_validate_page_rules(v_all);
  IF v_r IS NULL THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: a chain of real boundaries AND dividers all labelled boundary was ACCEPTED. V4b is not biting.';
  END IF;
  IF v_r NOT LIKE '%evenly pitched%' THEN
    RAISE EXCEPTION 'VERIFY 3b FAILED: refused, but not by the pitch guard: %', v_r;
  END IF;

  -- CONTROL B: V5 is intact. Flip every label on the real 834433 chain; it must still be caught.
  SELECT jsonb_agg(jsonb_build_object('pct', rule_pct, 'run', run_frac, 'ink',
                                      coalesce(ink_frac, 0.5),
                                      'kind', CASE kind WHEN 'boundary' THEN 'divider'
                                                        WHEN 'divider' THEN 'boundary'
                                                        ELSE kind END) ORDER BY rule_pct)
    INTO v_flip
    FROM derm.page_row_rules
   WHERE dump_folder = 'ticket-834433' AND effective_page = 1;
  v_r := derm.fn_validate_page_rules(v_flip);
  IF v_r IS NULL THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: a PHASE FLIP was accepted. This is the leak case and must never pass.';
  END IF;

  -- CONTROL C: the boundary-count floor still applies, so two lines cannot be a page.
  v_two := '[{"pct":27.892,"run":0.356,"ink":0.5,"kind":"boundary"},
             {"pct":33.374,"run":0.351,"ink":0.5,"kind":"divider"},
             {"pct":38.789,"run":0.351,"ink":0.5,"kind":"divider"},
             {"pct":44.102,"run":0.347,"ink":0.5,"kind":"divider"},
             {"pct":49.619,"run":0.347,"ink":0.5,"kind":"divider"},
             {"pct":60.244,"run":0.052,"ink":0.5,"kind":"boundary"}]'::jsonb;
  IF derm.fn_validate_page_rules(v_two) IS NULL THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: a two-boundary chain was accepted';
  END IF;

  RAISE NOTICE 'OK: pure-boundary chains accepted, mislabelled chains refused by pitch, phase flip still caught.';
END $$;

COMMIT;
