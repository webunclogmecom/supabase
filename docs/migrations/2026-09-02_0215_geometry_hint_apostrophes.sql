-- 2026-09-02_0215_geometry_hint_apostrophes.sql
--
-- WHAT: fixes three operator hints added minutes earlier by 2026-09-02_0200. They read
--       "A client' stamp" and "a client' own text" instead of "A client's ...".
--
-- WHY:  my own defect, caught by READING the served output rather than by the migration passing.
--       The builder script kept apostrophes out of the shell by writing a placeholder and
--       substituting it at assembly time, and the placeholder was mapped to the SQL escape for a
--       bare apostrophe ('') instead of apostrophe-plus-s (''s). So every possessive lost its s.
--       Nothing failed: the SQL was valid, the migration applied, all five VERIFY blocks passed,
--       and three sentences shown to a person were wrong.
--
--       Worth keeping as a lesson, because it is the shape this estate keeps meeting: a check that
--       asserts a value EXISTS cannot notice that the value is malformed. VERIFY 3 asserted every
--       code has a hint and that the fallback is loud. Neither question is "is the sentence
--       correct English", and no assertion of that kind is practical, which is exactly why the
--       output has to be looked at.
--
-- SCOPE: derm.fn_geometry_hint only. CREATE OR REPLACE with the full body, three sentences changed
--        and every other byte identical to what 2026-09-02_0200 installed. No other object, no
--        table, no grant. The function is IMMUTABLE and read-only, so this is a text correction.
--
-- RULE 8 (audit): no table change, nothing to opt in or out of.

BEGIN;

CREATE OR REPLACE FUNCTION derm.fn_geometry_hint(p_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT CASE p_code
    WHEN 'G1_NULL_KEY' THEN
      'Something went wrong identifying this page. Reload the sheet and try again.'
    WHEN 'G1_BANDS_SHAPE' THEN
      'Place the stamps first. Row boundaries describe where each client sits on the sheet, so there is nothing to save until at least one card is placed.'
    WHEN 'G1_BAND_NULL' THEN
      'One of the rows has no top or bottom edge yet. Drag both edges of every row before saving.'
    WHEN 'G1_DUP_ROW' THEN
      'The same client row was sent twice. Reload the sheet and set the boundaries again.'
    WHEN 'G1_HALF_EXTENT' THEN
      'Set both the top and the bottom page boundary, or neither. One on its own cannot be saved.'
    WHEN 'G2_EXTENT_RANGE' THEN
      'A page boundary is off the sheet. Both boundaries must sit inside the page.'
    WHEN 'G2_BAND_RANGE' THEN
      'A row edge is off the sheet. Every edge must sit inside the page.'
    WHEN 'G3_NO_SUCH_PAGE' THEN
      'No stamp has been placed on this page yet, so there is no geometry to save. Place the stamps first.'
    WHEN 'G6_MISSING_ROW' THEN
      'A client on this page was left out. Every client printed on the page needs its own row boundaries.'
    WHEN 'G6_FOREIGN_ROW' THEN
      'A row that does not belong to this page was included. Reload the sheet and try again.'
    WHEN 'G7_OVERLAP' THEN
      'Two clients overlap. Each client needs its own strip with no shared space, or one client would be shown part of another row.'
    WHEN 'G8_NOT_CONTAINED' THEN
      'A page boundary cuts through a client row. Move the boundary so every row sits fully inside it.'
    WHEN 'G9_NOT_MEASURED' THEN
      'This page has not been measured yet, so there are no printed lines to check the edges against. Press "Re-measure printed lines" first. If measuring keeps failing on this sheet, it needs a person to look at it.'
    WHEN 'G9_OFF_RULE' THEN
      'A row edge is not sitting on one of the printed lines on the sheet. Drag it onto the nearest printed line: an edge between the lines can cut a client''s own text in half.'
    WHEN 'G11_ROSTER_NOT_COVERED' THEN
      'The page boundaries do not cover the whole printed list. Any printed line left outside them would be shown to the client.'
    WHEN 'G13_STAMP_OUTSIDE_BAND' THEN
      'A client''s stamp is outside the strip you gave it. The stamp marks that client''s own row, so the strip must contain it.'
    WHEN 'G14_SPANS_EXTRA_SLOTS' THEN
      'A client''s strip covers more printed rows than that client owns. If the client really has several permits on this sheet, it needs one card per permit.'
    ELSE
      'Unrecognised geometry check (' || COALESCE(p_code, 'null') || '). This is a bug: the check has no operator message. Tell Fred.'
  END;
$fn$;

DO $$
DECLARE
  v_bad int; v_code text; v_hint text;
  v_codes text[] := ARRAY['G1_NULL_KEY','G1_BANDS_SHAPE','G1_BAND_NULL','G1_DUP_ROW','G1_HALF_EXTENT',
    'G2_EXTENT_RANGE','G2_BAND_RANGE','G3_NO_SUCH_PAGE','G6_MISSING_ROW','G6_FOREIGN_ROW','G7_OVERLAP',
    'G8_NOT_CONTAINED','G9_NOT_MEASURED','G9_OFF_RULE','G11_ROSTER_NOT_COVERED','G13_STAMP_OUTSIDE_BAND',
    'G14_SPANS_EXTRA_SLOTS'];
BEGIN
  -- 1. the three repaired sentences read correctly
  IF derm.fn_geometry_hint('G13_STAMP_OUTSIDE_BAND') NOT LIKE 'A client''s stamp%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: G13 hint is %', derm.fn_geometry_hint('G13_STAMP_OUTSIDE_BAND');
  END IF;
  IF derm.fn_geometry_hint('G14_SPANS_EXTRA_SLOTS') NOT LIKE 'A client''s strip%' THEN
    RAISE EXCEPTION 'VERIFY 1b FAILED: G14 hint is %', derm.fn_geometry_hint('G14_SPANS_EXTRA_SLOTS');
  END IF;
  IF derm.fn_geometry_hint('G9_OFF_RULE') NOT LIKE '%a client''s own text in half.' THEN
    RAISE EXCEPTION 'VERIFY 1c FAILED: G9_OFF_RULE hint is %', derm.fn_geometry_hint('G9_OFF_RULE');
  END IF;

  -- 2. CONTROL, and it is the one that would have caught the original defect: no hint anywhere may
  --    contain a possessive apostrophe that is not followed by an s. That is precisely the damage
  --    the placeholder substitution did, and it is mechanically checkable even though "is this
  --    good English" is not.
  SELECT count(*) INTO v_bad
    FROM unnest(v_codes) c
   WHERE derm.fn_geometry_hint(c) ~ '[A-Za-z]''([^s]|$)';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % hint(s) carry an apostrophe not followed by s', v_bad;
  END IF;

  -- 3. nothing else regressed: every code still has a hint and the fallback is still loud
  FOREACH v_code IN ARRAY v_codes LOOP
    v_hint := derm.fn_geometry_hint(v_code);
    IF v_hint IS NULL OR v_hint LIKE 'Unrecognised geometry check%' THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: code % lost its hint', v_code;
    END IF;
  END LOOP;
  IF derm.fn_geometry_hint('G99_MADE_UP') NOT LIKE 'Unrecognised geometry check%' THEN
    RAISE EXCEPTION 'VERIFY 3b FAILED: the ELSE arm is no longer loud';
  END IF;

  -- 4. anon still cannot execute it
  IF has_function_privilege('anon','derm.fn_geometry_hint(text)','EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: anon can execute fn_geometry_hint';
  END IF;

  RAISE NOTICE 'OK: possessives repaired, 17 codes hinted, fallback loud, anon still revoked.';
END $$;

COMMIT;
