-- 2026-09-02_1420_rule_refusal_hints.sql
--
-- WHAT: adds derm.fn_rule_hint(text), an operator sentence for each way fn_validate_page_rules can
--       refuse a set of marked lines, and returns it from derm.record_page_rules as `hint`.
--
-- WHY:  Fred, repeatedly, and it is the same complaint every time: "I don't understand the error."
--       He is not describing a preference. The Studio has been showing him the DETECTOR's internal
--       language for a decision about lines he drew with his own hand:
--
--         only 2 rules inside the roster
--         only 1 slot boundaries
--         chain does not alternate at position 2
--         run-length split disagrees with the labels at chain position 4
--
--       None of those name an action. "Rules" are printed lines, "the roster" is Section B, "the
--       chain" is an internal array, and "slot boundaries" are the very lines he calls limit and
--       client bands. A person cannot act on any of it, so every refusal reads as the app being
--       broken rather than as the sheet being incompletely marked.
--
--       2026-09-02_0200 already did this for the eighteen geometry guards via derm.fn_geometry_hint.
--       This is the same mechanism for the other half of the save, and it is deliberately the SAME
--       mechanism: a second way of explaining a refusal would drift from the first.
--
-- THE HONEST WEAKNESS, STATED SO NOBODY TRUSTS IT FURTHER THAN IT DESERVES. This maps on MESSAGE
--       TEXT, and this estate's own lesson is that string matching is not measurement. The right
--       design is a code returned alongside the message, and that means editing every RETURN site
--       in fn_validate_page_rules, which is the last line of defence for a customer-facing
--       redaction and was already changed once today. So: text matching now, and the fall-through
--       returns the raw message rather than swallowing it, so the worst case is exactly today's
--       behaviour.
--       => What makes it acceptable is that VERIFY DRIVES THE REAL VALIDATOR to emit each message
--       and asserts a specific hint comes back. The mapping is tested against the function's actual
--       output, never against my memory of what it says. If a message is reworded, VERIFY fails.
--
-- VOCABULARY. The sentences use the words Fred uses, which are the words on the paper:
--       Section B is the region that gets blacked out, a LIMIT band is its top or bottom edge, and
--       a CLIENT band is the line between one client's row and the next. "Rule", "roster", "chain",
--       "slot" and "phase" do not appear in any operator-facing sentence.
--
-- RULE 8 (audit): no table or column changes. Functions only.
-- RULE 2/3: nothing derived, copied or stored.

BEGIN;

CREATE OR REPLACE FUNCTION derm.fn_rule_hint(p_msg text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT CASE
    WHEN p_msg IS NULL THEN NULL

    WHEN p_msg = 'no rules' OR p_msg LIKE 'rules is not a json array' THEN
      'No lines were marked on this page.'

    -- the two floors, and the one Fred hits by marking only the top and bottom of Section B
    WHEN p_msg LIKE 'only % rules inside the roster' THEN
      'Not enough lines yet. Mark the top and bottom of Section B and the line between every client row: a page needs at least five lines in total before it can be recorded.'

    WHEN p_msg LIKE 'only % slot boundaries' THEN
      'Not enough lines are marked as row edges. At least three are needed. If you marked lines as mid-row dividers, change them to row edges: a line between two clients is a row edge.'

    WHEN p_msg LIKE '% closer than the %pp merge distance' THEN
      'Two of your lines are almost on top of each other, closer than the sheet''s own rows can be. Delete one of them.'

    WHEN p_msg LIKE 'rules are not in strictly ascending order%' THEN
      'Two lines are at the same height, or out of order. Delete the duplicate and try again.'

    WHEN p_msg LIKE '% is out of range' THEN
      'A line is off the page. Every line must sit inside the scan.'

    WHEN p_msg LIKE '% is missing pct, run or kind' THEN
      'One line could not be measured on the image. Delete it and mark it again slightly higher or lower.'

    WHEN p_msg LIKE 'rule % has unknown kind %' THEN
      'A line has a type this page does not accept. Set each line to a row edge, a mid-row divider, or the form bar.'

    WHEN p_msg LIKE 'chain does not alternate at position %' THEN
      'The lines do not read as alternating row edges and mid-row dividers. If every line you marked separates one client from the next, set them all to row edges.'

    -- V4b. I wrote this one for a person this morning and it STILL says "slot boundary" and quotes
    -- a deviation percentage, neither of which names an action. Replaced, not passed through.
    WHEN p_msg LIKE 'every line is labelled a slot boundary, but they are not evenly pitched%' THEN
      'Your lines are not evenly spaced down the page, so at least one of them is probably the fainter line inside a client row rather than the edge between two clients. Look for the one that is out of step with the rest.'

    WHEN p_msg LIKE 'a chain with no mid-slot dividers needs at least three%' THEN
      'Mark at least three row edges so the spacing of the rows can be checked.'

    WHEN p_msg LIKE 'cannot measure the slot pitch%' THEN
      'The row spacing could not be measured from these lines. Check that they run down the page in order.'

    WHEN p_msg LIKE 'cannot split the run values%' THEN
      'Every line you marked inks the same width, so they cannot be told apart as row edges and mid-row dividers. If they are all row edges, set them all to row edges.'

    WHEN p_msg LIKE 'run-length split disagrees with the labels%' THEN
      'The widths measured on the image disagree with how the lines are labelled: a full-width line is marked as a mid-row divider, or a short one as a row edge. This is the mistake that can show one client another client''s row, so it is refused. Check the labels against the scan.'

    ELSE p_msg
  END;
$fn$;

COMMENT ON FUNCTION derm.fn_rule_hint(text) IS
  'Operator sentence for a derm.fn_validate_page_rules refusal, in the vocabulary of the paper (Section B, row edge, mid-row divider) rather than the detector''s (roster, chain, slot, phase). Sibling of derm.fn_geometry_hint, deliberately the same mechanism. Matches on message text, which is weaker than a returned code and is why the migration VERIFY drives the real validator to emit each message rather than asserting against a hand-typed list; the ELSE arm returns the raw message, so an unmapped refusal is no worse than before.';

REVOKE ALL ON FUNCTION derm.fn_rule_hint(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION derm.fn_rule_hint(text) FROM anon;

-- The writer hands the sentence to the app and keeps the raw text in the stored record.
-- Body COPIED from pg_get_functiondef (already carrying the 1330 edits), three anchors.

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
      -- the stored detail keeps the validator's exact words, because page_rule_scans.detail
      -- is the forensic record. The OPERATOR gets the plain sentence, returned separately.
      v_hint   := derm.fn_rule_hint(v_reject);
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
    'n_boundaries', v_n_bounds, 'pitch', v_pitch, 'detail', v_detail, 'hint', v_hint,
    'source_etag', v_etag);
END $function$;

DO $$
DECLARE
  v_msg text; v_hint text; v_bad text;
  v_jargon text[] := array['roster','chain','slot boundar','pct','jsonb','phase','run-length','alternate at position'];
  w text;
BEGIN
  -- case: no rules
  v_msg := derm.fn_validate_page_rules('[]'::jsonb);
  IF v_msg IS NULL THEN
    RAISE EXCEPTION 'VERIFY FAILED [no rules]: the validator ACCEPTED this payload, so the case tests nothing';
  END IF;
  v_hint := derm.fn_rule_hint(v_msg);
  IF v_hint IS NULL OR v_hint = v_msg THEN
    RAISE EXCEPTION 'VERIFY FAILED [no rules]: no operator sentence, raw message was %', v_msg;
  END IF;
  IF position('no lines' in lower(v_hint)) = 0 THEN
    RAISE EXCEPTION 'VERIFY FAILED [no rules]: wrong sentence for %; got %', v_msg, v_hint;
  END IF;
  FOREACH w IN ARRAY v_jargon LOOP
    IF position(w in lower(v_hint)) > 0 THEN
      RAISE EXCEPTION 'VERIFY FAILED [no rules]: operator sentence still contains %: %', w, v_hint;
    END IF;
  END LOOP;
  -- case: only 2 rules inside the roster
  v_msg := derm.fn_validate_page_rules('[{"pct":27.9,"run":0.35,"ink":0.5,"kind":"boundary"},{"pct":60.2,"run":0.35,"ink":0.5,"kind":"boundary"}]'::jsonb);
  IF v_msg IS NULL THEN
    RAISE EXCEPTION 'VERIFY FAILED [only 2 rules inside the roster]: the validator ACCEPTED this payload, so the case tests nothing';
  END IF;
  v_hint := derm.fn_rule_hint(v_msg);
  IF v_hint IS NULL OR v_hint = v_msg THEN
    RAISE EXCEPTION 'VERIFY FAILED [only 2 rules inside the roster]: no operator sentence, raw message was %', v_msg;
  END IF;
  IF position('not enough lines' in lower(v_hint)) = 0 THEN
    RAISE EXCEPTION 'VERIFY FAILED [only 2 rules inside the roster]: wrong sentence for %; got %', v_msg, v_hint;
  END IF;
  FOREACH w IN ARRAY v_jargon LOOP
    IF position(w in lower(v_hint)) > 0 THEN
      RAISE EXCEPTION 'VERIFY FAILED [only 2 rules inside the roster]: operator sentence still contains %: %', w, v_hint;
    END IF;
  END LOOP;
  -- case: only 1 slot boundaries
  v_msg := derm.fn_validate_page_rules('[{"pct":27.9,"run":0.35,"ink":0.5,"kind":"boundary"},{"pct":33.3,"run":0.35,"ink":0.5,"kind":"divider"},{"pct":38.7,"run":0.35,"ink":0.5,"kind":"divider"},{"pct":44.1,"run":0.35,"ink":0.5,"kind":"divider"},{"pct":49.5,"run":0.35,"ink":0.5,"kind":"divider"}]'::jsonb);
  IF v_msg IS NULL THEN
    RAISE EXCEPTION 'VERIFY FAILED [only 1 slot boundaries]: the validator ACCEPTED this payload, so the case tests nothing';
  END IF;
  v_hint := derm.fn_rule_hint(v_msg);
  IF v_hint IS NULL OR v_hint = v_msg THEN
    RAISE EXCEPTION 'VERIFY FAILED [only 1 slot boundaries]: no operator sentence, raw message was %', v_msg;
  END IF;
  IF position('row edges' in lower(v_hint)) = 0 THEN
    RAISE EXCEPTION 'VERIFY FAILED [only 1 slot boundaries]: wrong sentence for %; got %', v_msg, v_hint;
  END IF;
  FOREACH w IN ARRAY v_jargon LOOP
    IF position(w in lower(v_hint)) > 0 THEN
      RAISE EXCEPTION 'VERIFY FAILED [only 1 slot boundaries]: operator sentence still contains %: %', w, v_hint;
    END IF;
  END LOOP;
  -- case: merge distance
  v_msg := derm.fn_validate_page_rules('[{"pct":27.9,"run":0.35,"ink":0.5,"kind":"boundary"},{"pct":28.0,"run":0.35,"ink":0.5,"kind":"boundary"}]'::jsonb);
  IF v_msg IS NULL THEN
    RAISE EXCEPTION 'VERIFY FAILED [merge distance]: the validator ACCEPTED this payload, so the case tests nothing';
  END IF;
  v_hint := derm.fn_rule_hint(v_msg);
  IF v_hint IS NULL OR v_hint = v_msg THEN
    RAISE EXCEPTION 'VERIFY FAILED [merge distance]: no operator sentence, raw message was %', v_msg;
  END IF;
  IF position('on top of each other' in lower(v_hint)) = 0 THEN
    RAISE EXCEPTION 'VERIFY FAILED [merge distance]: wrong sentence for %; got %', v_msg, v_hint;
  END IF;
  FOREACH w IN ARRAY v_jargon LOOP
    IF position(w in lower(v_hint)) > 0 THEN
      RAISE EXCEPTION 'VERIFY FAILED [merge distance]: operator sentence still contains %: %', w, v_hint;
    END IF;
  END LOOP;
  -- case: ascending
  v_msg := derm.fn_validate_page_rules('[{"pct":30.0,"run":0.35,"ink":0.5,"kind":"boundary"},{"pct":30.0,"run":0.35,"ink":0.5,"kind":"boundary"}]'::jsonb);
  IF v_msg IS NULL THEN
    RAISE EXCEPTION 'VERIFY FAILED [ascending]: the validator ACCEPTED this payload, so the case tests nothing';
  END IF;
  v_hint := derm.fn_rule_hint(v_msg);
  IF v_hint IS NULL OR v_hint = v_msg THEN
    RAISE EXCEPTION 'VERIFY FAILED [ascending]: no operator sentence, raw message was %', v_msg;
  END IF;
  IF position('same height' in lower(v_hint)) = 0 THEN
    RAISE EXCEPTION 'VERIFY FAILED [ascending]: wrong sentence for %; got %', v_msg, v_hint;
  END IF;
  FOREACH w IN ARRAY v_jargon LOOP
    IF position(w in lower(v_hint)) > 0 THEN
      RAISE EXCEPTION 'VERIFY FAILED [ascending]: operator sentence still contains %: %', w, v_hint;
    END IF;
  END LOOP;
  -- case: out of range
  v_msg := derm.fn_validate_page_rules('[{"pct":150.0,"run":0.35,"ink":0.5,"kind":"boundary"}]'::jsonb);
  IF v_msg IS NULL THEN
    RAISE EXCEPTION 'VERIFY FAILED [out of range]: the validator ACCEPTED this payload, so the case tests nothing';
  END IF;
  v_hint := derm.fn_rule_hint(v_msg);
  IF v_hint IS NULL OR v_hint = v_msg THEN
    RAISE EXCEPTION 'VERIFY FAILED [out of range]: no operator sentence, raw message was %', v_msg;
  END IF;
  IF position('off the page' in lower(v_hint)) = 0 THEN
    RAISE EXCEPTION 'VERIFY FAILED [out of range]: wrong sentence for %; got %', v_msg, v_hint;
  END IF;
  FOREACH w IN ARRAY v_jargon LOOP
    IF position(w in lower(v_hint)) > 0 THEN
      RAISE EXCEPTION 'VERIFY FAILED [out of range]: operator sentence still contains %: %', w, v_hint;
    END IF;
  END LOOP;
  -- case: missing field
  v_msg := derm.fn_validate_page_rules('[{"pct":30.0,"ink":0.5,"kind":"boundary"}]'::jsonb);
  IF v_msg IS NULL THEN
    RAISE EXCEPTION 'VERIFY FAILED [missing field]: the validator ACCEPTED this payload, so the case tests nothing';
  END IF;
  v_hint := derm.fn_rule_hint(v_msg);
  IF v_hint IS NULL OR v_hint = v_msg THEN
    RAISE EXCEPTION 'VERIFY FAILED [missing field]: no operator sentence, raw message was %', v_msg;
  END IF;
  IF position('could not be measured' in lower(v_hint)) = 0 THEN
    RAISE EXCEPTION 'VERIFY FAILED [missing field]: wrong sentence for %; got %', v_msg, v_hint;
  END IF;
  FOREACH w IN ARRAY v_jargon LOOP
    IF position(w in lower(v_hint)) > 0 THEN
      RAISE EXCEPTION 'VERIFY FAILED [missing field]: operator sentence still contains %: %', w, v_hint;
    END IF;
  END LOOP;
  -- case: unknown kind
  v_msg := derm.fn_validate_page_rules('[{"pct":30.0,"run":0.35,"ink":0.5,"kind":"wibble"}]'::jsonb);
  IF v_msg IS NULL THEN
    RAISE EXCEPTION 'VERIFY FAILED [unknown kind]: the validator ACCEPTED this payload, so the case tests nothing';
  END IF;
  v_hint := derm.fn_rule_hint(v_msg);
  IF v_hint IS NULL OR v_hint = v_msg THEN
    RAISE EXCEPTION 'VERIFY FAILED [unknown kind]: no operator sentence, raw message was %', v_msg;
  END IF;
  IF position('type this page does not accept' in lower(v_hint)) = 0 THEN
    RAISE EXCEPTION 'VERIFY FAILED [unknown kind]: wrong sentence for %; got %', v_msg, v_hint;
  END IF;
  FOREACH w IN ARRAY v_jargon LOOP
    IF position(w in lower(v_hint)) > 0 THEN
      RAISE EXCEPTION 'VERIFY FAILED [unknown kind]: operator sentence still contains %: %', w, v_hint;
    END IF;
  END LOOP;
  -- case: alternation
  v_msg := derm.fn_validate_page_rules('[{"pct":27.9,"run":0.99,"ink":0.5,"kind":"boundary"},{"pct":33.3,"run":0.99,"ink":0.5,"kind":"boundary"},{"pct":38.7,"run":0.99,"ink":0.5,"kind":"boundary"},{"pct":44.1,"run":0.40,"ink":0.5,"kind":"divider"},{"pct":49.5,"run":0.99,"ink":0.5,"kind":"boundary"}]'::jsonb);
  IF v_msg IS NULL THEN
    RAISE EXCEPTION 'VERIFY FAILED [alternation]: the validator ACCEPTED this payload, so the case tests nothing';
  END IF;
  v_hint := derm.fn_rule_hint(v_msg);
  IF v_hint IS NULL OR v_hint = v_msg THEN
    RAISE EXCEPTION 'VERIFY FAILED [alternation]: no operator sentence, raw message was %', v_msg;
  END IF;
  IF position('alternating' in lower(v_hint)) = 0 THEN
    RAISE EXCEPTION 'VERIFY FAILED [alternation]: wrong sentence for %; got %', v_msg, v_hint;
  END IF;
  FOREACH w IN ARRAY v_jargon LOOP
    IF position(w in lower(v_hint)) > 0 THEN
      RAISE EXCEPTION 'VERIFY FAILED [alternation]: operator sentence still contains %: %', w, v_hint;
    END IF;
  END LOOP;
  -- case: uneven pitch
  v_msg := derm.fn_validate_page_rules('[{"pct":27.9,"run":0.35,"ink":0.5,"kind":"boundary"},{"pct":33.3,"run":0.35,"ink":0.5,"kind":"boundary"},{"pct":38.7,"run":0.35,"ink":0.5,"kind":"boundary"},{"pct":44.1,"run":0.35,"ink":0.5,"kind":"boundary"},{"pct":58.0,"run":0.35,"ink":0.5,"kind":"boundary"}]'::jsonb);
  IF v_msg IS NULL THEN
    RAISE EXCEPTION 'VERIFY FAILED [uneven pitch]: the validator ACCEPTED this payload, so the case tests nothing';
  END IF;
  v_hint := derm.fn_rule_hint(v_msg);
  IF v_hint IS NULL OR v_hint = v_msg THEN
    RAISE EXCEPTION 'VERIFY FAILED [uneven pitch]: no operator sentence, raw message was %', v_msg;
  END IF;
  IF position('evenly spaced' in lower(v_hint)) = 0 THEN
    RAISE EXCEPTION 'VERIFY FAILED [uneven pitch]: wrong sentence for %; got %', v_msg, v_hint;
  END IF;
  FOREACH w IN ARRAY v_jargon LOOP
    IF position(w in lower(v_hint)) > 0 THEN
      RAISE EXCEPTION 'VERIFY FAILED [uneven pitch]: operator sentence still contains %: %', w, v_hint;
    END IF;
  END LOOP;
  -- case: same run values
  v_msg := derm.fn_validate_page_rules('[{"pct":27.9,"run":0.35,"ink":0.5,"kind":"boundary"},{"pct":33.3,"run":0.35,"ink":0.5,"kind":"divider"},{"pct":38.7,"run":0.35,"ink":0.5,"kind":"boundary"},{"pct":44.1,"run":0.35,"ink":0.5,"kind":"divider"},{"pct":49.5,"run":0.35,"ink":0.5,"kind":"boundary"}]'::jsonb);
  IF v_msg IS NULL THEN
    RAISE EXCEPTION 'VERIFY FAILED [same run values]: the validator ACCEPTED this payload, so the case tests nothing';
  END IF;
  v_hint := derm.fn_rule_hint(v_msg);
  IF v_hint IS NULL OR v_hint = v_msg THEN
    RAISE EXCEPTION 'VERIFY FAILED [same run values]: no operator sentence, raw message was %', v_msg;
  END IF;
  IF position('same width' in lower(v_hint)) = 0 THEN
    RAISE EXCEPTION 'VERIFY FAILED [same run values]: wrong sentence for %; got %', v_msg, v_hint;
  END IF;
  FOREACH w IN ARRAY v_jargon LOOP
    IF position(w in lower(v_hint)) > 0 THEN
      RAISE EXCEPTION 'VERIFY FAILED [same run values]: operator sentence still contains %: %', w, v_hint;
    END IF;
  END LOOP;
  -- case: phase flip
  v_msg := derm.fn_validate_page_rules('[{"pct":27.9,"run":0.40,"ink":0.5,"kind":"boundary"},{"pct":33.3,"run":0.99,"ink":0.5,"kind":"divider"},{"pct":38.7,"run":0.40,"ink":0.5,"kind":"boundary"},{"pct":44.1,"run":0.99,"ink":0.5,"kind":"divider"},{"pct":49.5,"run":0.40,"ink":0.5,"kind":"boundary"}]'::jsonb);
  IF v_msg IS NULL THEN
    RAISE EXCEPTION 'VERIFY FAILED [phase flip]: the validator ACCEPTED this payload, so the case tests nothing';
  END IF;
  v_hint := derm.fn_rule_hint(v_msg);
  IF v_hint IS NULL OR v_hint = v_msg THEN
    RAISE EXCEPTION 'VERIFY FAILED [phase flip]: no operator sentence, raw message was %', v_msg;
  END IF;
  IF position('disagree with how the lines are labelled' in lower(v_hint)) = 0 THEN
    RAISE EXCEPTION 'VERIFY FAILED [phase flip]: wrong sentence for %; got %', v_msg, v_hint;
  END IF;
  FOREACH w IN ARRAY v_jargon LOOP
    IF position(w in lower(v_hint)) > 0 THEN
      RAISE EXCEPTION 'VERIFY FAILED [phase flip]: operator sentence still contains %: %', w, v_hint;
    END IF;
  END LOOP;

  -- CONTROL: an unmapped message must pass THROUGH unchanged, never be swallowed.
  IF derm.fn_rule_hint('a refusal nobody has written a sentence for yet')
     <> 'a refusal nobody has written a sentence for yet' THEN
    RAISE EXCEPTION 'VERIFY FAILED: the fall-through arm rewrote a message it does not know';
  END IF;
  IF derm.fn_rule_hint(NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY FAILED: a NULL refusal produced a sentence';
  END IF;

  -- record_page_rules must hand the sentence to the app, and keep the raw text stored.
  BEGIN
    v_msg := (derm.record_page_rules('ticket-834489', 1, 'human-v1-hintprobe',
               'https://example.invalid/p.jpg',
               '[{"pct":27.9,"run":0.35,"ink":0.5,"kind":"boundary"},
                 {"pct":60.2,"run":0.35,"ink":0.5,"kind":"boundary"}]'::jsonb,
               '{"grade":"OK"}'::jsonb))->>'hint';
    IF v_msg IS NULL OR position('not enough lines' in lower(v_msg)) = 0 THEN
      RAISE EXCEPTION 'VERIFY FAILED: record_page_rules did not return the operator sentence, got %', coalesce(v_msg,'<null>');
    END IF;
    SELECT detail INTO v_bad FROM derm.page_rule_scans
     WHERE dump_folder='ticket-834489' AND source='human-v1-hintprobe';
    IF v_bad IS NULL OR position('fn_validate_page_rules' in v_bad) = 0 THEN
      RAISE EXCEPTION 'VERIFY FAILED: the stored detail lost the validator raw text, got %', coalesce(v_bad,'<null>');
    END IF;
    RAISE EXCEPTION 'ROLLBACK_PROBE' USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;
  IF EXISTS (SELECT 1 FROM derm.page_rule_scans WHERE source='human-v1-hintprobe') THEN
    RAISE EXCEPTION 'VERIFY FAILED: the probe scan survived the rollback';
  END IF;

  RAISE NOTICE 'OK: 12 validator refusals carry a plain sentence, driven from the real validator.';
END $$;

COMMIT;
