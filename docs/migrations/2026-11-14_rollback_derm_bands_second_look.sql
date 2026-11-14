-- 2026-11-14_rollback_derm_bands_second_look.sql
-- Undoes 2026-11-14_1240_derm_bands_second_look.sql: DROPs the two-argument validator, re-creates the one-argument
-- body byte for byte with its grants (authenticated + service_role) and comment, and restores record_page_rules byte
-- for byte. VERIFY checks both md5 values (5904327d5c4c775f87c2f61fdf0c26b4, 57022cc11610982ec906309ebdc53ede).
-- Rehearsed in the migration's rolled-back rehearsal and again after apply (rolled back).
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP FUNCTION derm.fn_validate_page_rules(jsonb, numeric);
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
REVOKE ALL ON FUNCTION derm.fn_validate_page_rules(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION derm.fn_validate_page_rules(jsonb) TO authenticated, service_role;
COMMENT ON FUNCTION derm.fn_validate_page_rules(jsonb) IS $cmt$Independent check on a classified rule set proposed by the Stamp Studio. Returns NULL when it is acceptable, else the reason. The load-bearing test is V5: a phase flip (boundary/divider swapped) passes an alternation check because both phases alternate, but it cannot survive a split of the run values, since a slot boundary spans the whole form and a mid-slot divider does not.$cmt$;
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
  v_hint       text;
BEGIN
  -- 2026-09-02: 'human-v1-%' admitted alongside 'runlen-v2-%'. The READER was widened by
  -- 2026-09-02_0330 and this WRITER was not, so an operator-marked page raised
  -- "source must match runlen-v2-%" and nothing could ever be recorded. Measured before this
  -- migration: 176 scans exist and every one is runlen-v2, i.e. the widened view had never
  -- admitted a single row and was inert from the hour it shipped.
  IF NOT derm._is_rule_source(p_source) THEN
    RAISE EXCEPTION 'source must match runlen-v2-%%, human-v1-%% or template-v1-%%, got %',
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
                    AND coalesce(r.stamp_page, r.page) = p_effective_page)
     -- 2026-10-05: a page with a scan but no card on it yet is a real page. Draw the bands now comes
     -- BEFORE any stamp, and an unplaced card carries page = 1, so page 2 of a two-page sheet has no
     -- card until the first stamp lands on it. The page must be in the ticket's image list.
     AND NOT EXISTS (SELECT 1
                       FROM (SELECT DISTINCT r.white_manifest_number AS wm
                               FROM derm.address_row_map r
                              WHERE r.dump_folder = p_dump_folder
                                AND r.white_manifest_number IS NOT NULL) f
                      WHERE p_effective_page BETWEEN 1
                            AND coalesce(array_length(derm.ticket_page_images(f.wm), 1), 0)) THEN
    RAISE EXCEPTION 'no cards on %/% : refusing to record rules for a page that does not exist',
      p_dump_folder, p_effective_page USING ERRCODE = '22023';
  END IF;

  -- 2026-09-02_1520: THE VALIDATOR RUNS BEFORE THE SUPERSESSION GUARD, and the order is the whole
  -- point of this migration. v_grade starts as the grade the CALLER CLAIMED. The guard below
  -- compares that value, so while validation ran AFTER it the guard could only ever see a caller
  -- that SAID 'FAILED'. The detector never does: it claims OK and lets the server judge. So a
  -- re-measure whose rules the validator rejects sailed past the guard, was written as the newest
  -- scan for the page, and v_page_printed_rules -- which joins rules on the newest scan's OWN
  -- source -- then served ZERO rules. The operator's hand-marked geometry vanished from every
  -- reader while still sitting in page_row_rules.
  -- Measured on ticket-834489 before the fix, replaying that page's real rejected detector
  -- payload: rules served went 7 -> 0, and the RPC reported wrote:false as if it had done nothing.
  IF v_grade <> 'FAILED' THEN
    v_reject := derm.fn_validate_page_rules(p_rules);
    IF v_reject IS NOT NULL THEN
      v_grade  := 'FAILED';
      v_detail := 'rejected by fn_validate_page_rules: ' || v_reject;
      -- the stored detail keeps the validator's exact words, because page_rule_scans.detail
      -- is the forensic record. The OPERATOR gets the plain sentence, returned separately.
      v_hint   := derm.fn_rule_hint(v_reject);
    END IF;
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
      -- 2026-10-05: the validator's reason travels with the refusal, so a redraw on a page with a
      -- good earlier scan gets the specific sentence, not a generic one (save_page_bands shows it)
      'hint', v_hint, 'reject', v_detail,
      -- 2026-09-02: the article is chosen from the grade rather than hardcoded 'a'. The grade
      -- vocabulary is OK / IRREGULAR / SPARSE / FAILED, so two of the four take 'an' and the
      -- message read "already has a OK scan" on the commonest one.
      'detail', format('this page already has %s %s scan (%s) and the image has not changed; '
                       || 'refusing to replace it with a %s result',
                       CASE WHEN left(v_prev.grade, 1) IN ('A','E','I','O','U')
                            THEN 'an' ELSE 'a' END,
                       v_prev.grade, v_prev.source, v_grade));
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
    'n_boundaries', v_n_bounds, 'pitch', v_pitch, 'detail', v_detail, 'hint', v_hint,
    'source_etag', v_etag);
END $function$;
DO $v$
BEGIN
  IF md5(replace(pg_get_functiondef('derm.fn_validate_page_rules(jsonb)'::regprocedure), chr(13), '')) <> '5904327d5c4c775f87c2f61fdf0c26b4'
    THEN RAISE EXCEPTION 'VERIFY: derm.fn_validate_page_rules(jsonb) is not back byte for byte'; END IF;
  IF md5(replace(pg_get_functiondef('derm.record_page_rules(text,integer,text,text,jsonb,jsonb,boolean)'::regprocedure), chr(13), '')) <> '57022cc11610982ec906309ebdc53ede'
    THEN RAISE EXCEPTION 'VERIFY: record_page_rules is not back byte for byte'; END IF;
  IF (SELECT array_agg(x ORDER BY x) FROM (SELECT coalesce(nullif(a.grantee, 0)::regrole::text, 'PUBLIC') || ':' || a.privilege_type AS x
       FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a WHERE p.oid = 'derm.fn_validate_page_rules(jsonb)'::regprocedure) acl)
     IS DISTINCT FROM ARRAY['authenticated:EXECUTE','postgres:EXECUTE','service_role:EXECUTE']
    THEN RAISE EXCEPTION 'VERIFY: grants on derm.fn_validate_page_rules(jsonb) are not as before'; END IF;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'fn_validate_page_rules' AND pronamespace = 'derm'::regnamespace) <> 1
    THEN RAISE EXCEPTION 'VERIFY: expected exactly one derm.fn_validate_page_rules'; END IF;
END $v$;
COMMIT;
