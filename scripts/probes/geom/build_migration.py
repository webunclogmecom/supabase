# Assembles docs/migrations/2026-09-02_0200_geometry_violation_hints.sql
# The two function bodies are COPIED from pg_get_functiondef output and edited by anchor.
# They are never retyped. See CLAUDE.md "CREATE OR REPLACE: COPY THE WHOLE BODY".
import io

G = 'scripts/probes/geom/'
viol = io.open(G + '_page_geometry_violations.after.sql', encoding='utf-8').read().rstrip()
save = io.open(G + 'save.after.sql', encoding='utf-8').read().rstrip()
if not viol.endswith(';'):
    viol += ';'
if not save.endswith(';'):
    save += ';'

Q = chr(39)          # '
QQ = Q + Q           # '' (SQL-escaped apostrophe)

HEADER = '''-- 2026-09-02_0200_geometry_violation_hints.sql
--
-- WHAT: the page-geometry guards stop shouting developer codes at operators, and one missing
--       precondition stops multiplying into one error per band edge.
--         1. NEW derm.fn_geometry_hint(code) -> an operator sentence for every guard.
--         2. derm._page_geometry_violations gains a PRECONDITION arm: a page with no detected
--            printed rules yields ONE G9_NOT_MEASURED instead of one G9_OFF_RULE per edge.
--         3. derm.check_page_geometry returns (code, detail, HINT).
--         4. derm.save_page_geometry raises the HINT, with code and detail kept in brackets.
--
-- WHY:  Fred, 2026-09-02, on the DERM Stamp Studio: "why so many errors with the bands", and
--       "we need to solve the root cause, so it doesn t happen again". Two live examples:
--
--       ticket-834489 (handwritten pad sheet 344): both cards UNPLACED, so p_bands is empty and
--       the operator got "G1_BANDS_SHAPE: p_bands must be a non-empty JSON array". Nothing on a
--       pad sheet auto-places, so EVERY fresh pad sheet opens in exactly that state.
--
--       ticket-834433 (generated sheet 1106): 3 of 3 placed, bands set BY HAND, and six red lines,
--       every one "G9_OFF_RULE ... (nearest no rules for this page)". That page has ZERO rows in
--       derm.page_row_rules: the detector found 14 rules / 7 boundaries and
--       fn_validate_page_rules REJECTED the set ("a phase flip at chain position 13"), and a
--       rejected scan writes nothing. So G9 NOT EXISTS was true for every changed edge.
--       SIX ERRORS, ONE CAUSE, and none of them told the operator what to do.
--
-- ROOT CAUSE, both halves:
--   (a) the guards ran without checking their own preconditions, so one absent input became N
--       per-item failures that read like operator mistakes;
--   (b) there was no operator vocabulary. _page_geometry_violations returns (code, detail), both
--       written for a developer, and the Stamp Studio bundle maps exactly ONE of the 16 codes
--       (G9_OFF_RULE). Measured over the live bundle: 15 of 16 codes appear 0 times, so whatever
--       the server returns is printed verbatim to a person.
--
-- WHY THE HINT LIVES IN THE DATABASE AND NOT IN THE APP. That 1-of-16 is the whole argument. The
--   codes are raised here and the mapping lived over there, so every guard added since shipped
--   without operator text and nobody noticed. Putting the sentence next to the guard means a new
--   code cannot reach a person as a bare token: the ELSE arm of fn_geometry_hint is loud, and
--   VERIFY 3 fails this migration if any code the function can emit has no hint.
--
-- THE FUNCTION BODIES WERE COPIED, NOT RETYPED. _page_geometry_violations is 20,098 characters and
--   CREATE OR REPLACE takes the WHOLE body, so anything not reproduced is silently deleted. Both
--   bodies were extracted with pg_get_functiondef into scripts/probes/geom/*.before.sql, edited by
--   anchored replacement (each anchor asserted to match exactly once) in
--   scripts/probes/geom/build_migration.py, and diffed. The violations diff is TWO insertions and
--   nothing else; the save diff is one changed line plus a comment.
--
-- NOT IN SCOPE, deliberately:
--   * The CLASSIFIER phase flip that produced the FAILED scan on ticket-834433 is the upstream
--     cause and is NOT fixed here. It is a known, documented limitation (the end-bar trim strips
--     only LONG bars, so a page whose outermost rule at each end is SHORT inverts every label
--     below it; ticket-312024 p1 hit it first). Fixing the trim means re-validating all 168
--     already-measured pages, so it is its own piece of work with its own spec.
--   * Snap-to-rule while dragging in the Studio is an app change, not a database one. Today an
--     operator must land a freehand drag within 0.35pp of an invisible line, on every edge.
--
-- RULE 8 (audit): NO TABLE CHANGES AT ALL. Functions only, so no opt-in or opt-out arises.
-- RULE 2/3: no columns, no storage, nothing derived or copied.

BEGIN;

-- ============================================================================
-- 1. The operator vocabulary, next to the guards that raise it.
-- ============================================================================
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
      'A row edge is not sitting on one of the printed lines on the sheet. Drag it onto the nearest printed line: an edge between the lines can cut a client@S own text in half.'
    WHEN 'G11_ROSTER_NOT_COVERED' THEN
      'The page boundaries do not cover the whole printed list. Any printed line left outside them would be shown to the client.'
    WHEN 'G13_STAMP_OUTSIDE_BAND' THEN
      'A client@S stamp is outside the strip you gave it. The stamp marks that client@S own row, so the strip must contain it.'
    WHEN 'G14_SPANS_EXTRA_SLOTS' THEN
      'A client@S strip covers more printed rows than that client owns. If the client really has several permits on this sheet, it needs one card per permit.'
    ELSE
      'Unrecognised geometry check (' || COALESCE(p_code, 'null') || '). This is a bug: the check has no operator message. Tell Fred.'
  END;
$fn$;

COMMENT ON FUNCTION derm.fn_geometry_hint(text) IS
  'Operator-facing sentence for each derm._page_geometry_violations code. Lives beside the guards on purpose: the Stamp Studio previously mapped 1 of 16 codes and printed the rest raw, because the mapping was in the app while the codes were here. The ELSE arm is deliberately loud so a new code without a hint is visible rather than silent.';

REVOKE ALL ON FUNCTION derm.fn_geometry_hint(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION derm.fn_geometry_hint(text) FROM anon;
-- No grant is needed: every caller (check_page_geometry, save_page_geometry) is SECURITY DEFINER
-- and runs as the owner. Supabase default privileges hand new functions to anon and authenticated,
-- so the revokes above are the actual control, not the absence of a GRANT.

-- ============================================================================
-- 2. The precondition arm. Body copied from pg_get_functiondef, edited by anchor, diffed.
-- ============================================================================
'''

MID = '''
-- ============================================================================
-- 3. check_page_geometry gains the hint. The return type changes, so this is DROP + CREATE, which
--    DISCARDS GRANTS: they are restored immediately below and asserted in VERIFY 4.
-- ============================================================================
DROP FUNCTION IF EXISTS derm.check_page_geometry(text, integer, jsonb, numeric, numeric);

CREATE FUNCTION derm.check_page_geometry(
  p_dump_folder text, p_effective_page integer, p_bands jsonb,
  p_top_pct numeric DEFAULT NULL::numeric, p_bottom_pct numeric DEFAULT NULL::numeric)
RETURNS TABLE(code text, detail text, hint text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $function$
  SELECT v.code, v.detail, derm.fn_geometry_hint(v.code)
    FROM derm._page_geometry_violations($1,$2,$3,$4,$5) v;
$function$;

REVOKE ALL ON FUNCTION derm.check_page_geometry(text, integer, jsonb, numeric, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION derm.check_page_geometry(text, integer, jsonb, numeric, numeric) FROM anon;
GRANT EXECUTE ON FUNCTION derm.check_page_geometry(text, integer, jsonb, numeric, numeric)
  TO authenticated, service_role;

-- ============================================================================
-- 4. save_page_geometry raises the hint. Body copied, one line changed, diffed.
-- ============================================================================
'''

VERIFY = '''
DO $$
DECLARE
  v_n int; v_hint text; v_authn boolean; v_anon boolean; v_svc boolean; v_code text;
  v_bands433 jsonb; v_bands287 jsonb;
  v_codes text[] := ARRAY['G1_NULL_KEY','G1_BANDS_SHAPE','G1_BAND_NULL','G1_DUP_ROW','G1_HALF_EXTENT',
    'G2_EXTENT_RANGE','G2_BAND_RANGE','G3_NO_SUCH_PAGE','G6_MISSING_ROW','G6_FOREIGN_ROW','G7_OVERLAP',
    'G8_NOT_CONTAINED','G9_NOT_MEASURED','G9_OFF_RULE','G11_ROSTER_NOT_COVERED','G13_STAMP_OUTSIDE_BAND',
    'G14_SPANS_EXTRA_SLOTS'];
BEGIN
  SELECT jsonb_agg(jsonb_build_object('row_id', r.id, 'y0', 24.0, 'y1', 32.0))
    INTO v_bands433
    FROM derm.address_row_map r WHERE r.dump_folder = 'ticket-834433';

  SELECT jsonb_agg(jsonb_build_object('row_id', r.id, 'y0', 11.111, 'y1', 22.222))
    INTO v_bands287
    FROM derm.address_row_map r WHERE r.dump_folder = 'ticket-834287';

  -- 1. THE REPORTED DEFECT. ticket-834433 page 1 has NO detected rules and 3 placed cards, and it
  --    used to emit one G9_OFF_RULE per changed edge. It must now emit exactly one G9_NOT_MEASURED
  --    and no G9_OFF_RULE at all.
  SELECT count(*) INTO v_n
    FROM derm._page_geometry_violations('ticket-834433', 1, v_bands433)
   WHERE code = 'G9_OFF_RULE';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: ticket-834433 still emits % G9_OFF_RULE row(s) on an unmeasured page', v_n;
  END IF;

  SELECT count(*) INTO v_n
    FROM derm._page_geometry_violations('ticket-834433', 1, v_bands433)
   WHERE code = 'G9_NOT_MEASURED';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'VERIFY 1b FAILED: expected exactly 1 G9_NOT_MEASURED on ticket-834433, got %', v_n;
  END IF;

  -- 2. CONTROL, and it is the one that matters. A page that IS measured must STILL get the real
  --    per-edge check. A precondition arm that swallowed G9 entirely would sail through VERIFY 1
  --    while disabling the guard that stops a band cutting through a client row.
  --    ticket-834287 has detected rules; 11.111..22.222 is deliberately off every one of them.
  SELECT count(*) INTO v_n
    FROM derm._page_geometry_violations('ticket-834287', 1, v_bands287)
   WHERE code = 'G9_OFF_RULE';
  IF v_n < 1 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: a MEASURED page no longer reports G9_OFF_RULE for a deliberately off-rule edge. The guard has been disabled, which is worse than the bug being fixed.';
  END IF;

  -- 3. every code the function can emit has a real hint, and the fallback is still loud
  FOREACH v_code IN ARRAY v_codes LOOP
    v_hint := derm.fn_geometry_hint(v_code);
    IF v_hint IS NULL OR v_hint LIKE 'Unrecognised geometry check%' THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: code % has no operator hint', v_code;
    END IF;
  END LOOP;
  IF derm.fn_geometry_hint('G99_MADE_UP') NOT LIKE 'Unrecognised geometry check%' THEN
    RAISE EXCEPTION 'VERIFY 3b FAILED: the ELSE arm is not loud, so a new code would leak silently';
  END IF;

  -- 4. grants survived DROP + CREATE, and anon acquired nothing
  SELECT has_function_privilege('authenticated','derm.check_page_geometry(text,integer,jsonb,numeric,numeric)','EXECUTE'),
         has_function_privilege('anon','derm.check_page_geometry(text,integer,jsonb,numeric,numeric)','EXECUTE'),
         has_function_privilege('service_role','derm.check_page_geometry(text,integer,jsonb,numeric,numeric)','EXECUTE')
    INTO v_authn, v_anon, v_svc;
  IF NOT v_authn OR NOT v_svc OR v_anon THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: check_page_geometry grants are authn=% anon=% svc=%', v_authn, v_anon, v_svc;
  END IF;
  IF has_function_privilege('anon','derm.fn_geometry_hint(text)','EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 4b FAILED: anon can execute fn_geometry_hint';
  END IF;

  -- 5. the wrapper really returns three columns and the hint is the operator sentence
  SELECT hint INTO v_hint FROM derm.check_page_geometry('ticket-834489', 1, '[]'::jsonb) LIMIT 1;
  IF v_hint IS NULL OR v_hint NOT LIKE 'Place the stamps first%' THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: check_page_geometry hint for an empty payload was %', COALESCE(v_hint,'NULL');
  END IF;

  RAISE NOTICE 'OK: precondition arm live, 17 codes hinted, grants intact, wrapper serves the hint.';
END $$;

COMMIT;
'''

out = HEADER + viol + '\n' + MID + save + '\n' + VERIFY
out = out.replace('@S', QQ)          # SQL-escaped apostrophes, kept out of the shell entirely
assert '@S' not in out
assert chr(8212) not in out, 'em-dash present'
io.open('docs/migrations/2026-09-02_0200_geometry_violation_hints.sql', 'w',
        encoding='utf-8', newline='\n').write(out)
print('migration written:', len(out), 'chars')
