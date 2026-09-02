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