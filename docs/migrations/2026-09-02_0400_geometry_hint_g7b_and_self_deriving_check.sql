-- 2026-09-02_0400_geometry_hint_g7b_and_self_deriving_check.sql
--
-- WHAT: adds the missing operator hint for G7B_OVERLAPS_WITHHELD, and replaces the hand-typed code
--       list in the coverage check with one DERIVED from the function body, so a code can never
--       again be missing a hint without the check noticing.
--
-- WHY:  MY DEFECT, found by an adversarial audit hours after 2026-09-02_0200 shipped. That migration
--       claimed to give every guard an operator sentence and asserted it in VERIFY 3. It missed one,
--       and the reason is worth more than the fix:
--
--         I enumerated the codes with the regex  '(G\d+_[A-Z_]+)'
--         which requires an underscore immediately after the digits.
--         G7B_OVERLAPS_WITHHELD has a LETTER there, so it was invisible.
--         VERIFY 3 then asserted that every code IN MY LIST had a hint, and my list was the output
--         of the same broken regex. The check validated its own instrument and passed.
--
--       This is the estate's most-repeated failure shape: a sweep whose universe is defined by the
--       tool doing the sweeping. The lesson is not "write a better regex", it is "do not let the
--       check and the thing it checks share a source of truth".
--
-- WHAT IT COST. G7B refuses a band that overlaps a WITHHELD card (one with a stamp position but no
--       stamp_placed_at). That is a correct leak refusal: a withheld row must not be covered by a
--       neighbour's strip. With no hint, fn_geometry_hint fell to its ELSE arm and the operator was
--       told "Unrecognised geometry check (G7B_OVERLAPS_WITHHELD). This is a bug: the check has no
--       operator message. Tell Fred." So a guard doing its job read as an application fault.
--       Measured 2026-09-02: 6 folders / 7 pages / 10 withheld cards can trigger it, and the nearest
--       editable edge on window4-sheet1 p1 is 0.005pp away, so it is easy to hit.
--
-- ⚠ AND THE HINT HAS TO SAY THE HARD PART. Of those 10 withheld cards, SEVEN are not rendered in the
--       Studio at all: derm.v_stamp_rows filters them out. So an operator can be told their strip
--       overlaps a row they cannot see anywhere on screen. The sentence says so rather than implying
--       they have simply missed something.
--
-- RULE 8 (audit): no table or column changes. Functions only.
-- RULE 2/3: nothing derived, copied or stored.

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
    WHEN 'G7B_OVERLAPS_WITHHELD' THEN
      'This strip covers a row that is on hold. A card on this page has a stamp but was never confirmed, so nothing may be published over its row. Shrink this strip clear of it. Note that a held row is often NOT drawn on this sheet, so if you cannot see what you are overlapping, that is why: someone needs to finish or remove that card.'
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

COMMENT ON FUNCTION derm.fn_geometry_hint(text) IS
  'Operator-facing sentence for each derm._page_geometry_violations code. Lives beside the guards on purpose: the Stamp Studio previously mapped 1 of 16 codes and printed the rest raw. The ELSE arm is deliberately loud so a new code without a hint is visible. Coverage is asserted against codes DERIVED FROM THE FUNCTION BODY, never a hand-typed list: a typed list missed G7B_OVERLAPS_WITHHELD for hours because the regex that built it required a digit-then-underscore.';

REVOKE ALL ON FUNCTION derm.fn_geometry_hint(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION derm.fn_geometry_hint(text) FROM anon;

DO $$
DECLARE
  v_src text; v_code text; v_hint text; v_n int; v_missing text[] := '{}';
BEGIN
  -- Derive the codes FROM THE LIVE FUNCTION BODY. This is the whole point of this migration: the
  -- previous check compared hints against a list I typed, and that list was produced by the same
  -- flawed regex, so it could not see what it was missing.
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'derm' AND p.proname = '_page_geometry_violations';
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'VERIFY 0 FAILED: could not read _page_geometry_violations';
  END IF;

  FOR v_code IN
    SELECT DISTINCT (regexp_matches(v_src, '''(G\d+[A-Z]?_[A-Z0-9_]+)''', 'g'))[1]
  LOOP
    v_hint := derm.fn_geometry_hint(v_code);
    IF v_hint IS NULL OR v_hint LIKE 'Unrecognised geometry check%' THEN
      v_missing := v_missing || v_code;
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % code(s) emitted by the guard have no hint: %',
      array_length(v_missing,1), array_to_string(v_missing, ', ');
  END IF;

  -- 2. CONTROL: the derivation must actually find codes, and MORE than the old regex did.
  --    A pattern that matched nothing would make VERIFY 1 pass vacuously, which is precisely the
  --    failure being corrected here.
  SELECT count(*) INTO v_n FROM (
    SELECT DISTINCT (regexp_matches(v_src, '''(G\d+[A-Z]?_[A-Z0-9_]+)''', 'g'))[1] AS c) d;
  IF v_n < 18 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: derived only % codes from the body, expected at least 18', v_n;
  END IF;
  IF NOT EXISTS (SELECT 1 WHERE v_src LIKE '%G7B_OVERLAPS_WITHHELD%') THEN
    RAISE EXCEPTION 'VERIFY 2b FAILED: G7B_OVERLAPS_WITHHELD is not in the body, so this fix targets nothing';
  END IF;

  -- 3. the specific hint reads correctly and mentions the invisible-row problem
  v_hint := derm.fn_geometry_hint('G7B_OVERLAPS_WITHHELD');
  IF v_hint LIKE 'Unrecognised%' OR v_hint NOT LIKE '%on hold%' OR v_hint NOT LIKE '%NOT drawn%' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: G7B hint is %', v_hint;
  END IF;

  -- 4. the ELSE arm is still loud, and no possessive lost its s (the 2026-09-02_0215 regression)
  IF derm.fn_geometry_hint('G99_MADE_UP') NOT LIKE 'Unrecognised geometry check%' THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: the ELSE arm is no longer loud';
  END IF;
  SELECT count(*) INTO v_n
    FROM (SELECT DISTINCT (regexp_matches(v_src, '''(G\d+[A-Z]?_[A-Z0-9_]+)''', 'g'))[1] AS c) x
   WHERE derm.fn_geometry_hint(x.c) ~ '[A-Za-z]''([^s]|$)';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4b FAILED: % hint(s) carry an apostrophe not followed by s', v_n;
  END IF;

  -- 5. anon still cannot execute it
  IF has_function_privilege('anon','derm.fn_geometry_hint(text)','EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: anon can execute fn_geometry_hint';
  END IF;

  RAISE NOTICE 'OK: every code the guard can emit has a hint, derived from the body, not a typed list.';
END $$;

COMMIT;
