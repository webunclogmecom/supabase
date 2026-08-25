-- 2026-08-25_1500_lwt_normalizer_grant_and_category_close.sql
-- ---------------------------------------------------------------------------
-- Zero-runs iteration 4. Fixes the LIVE PRIVILEGE REGRESSION that 2026-08-25_1400 introduced,
-- and closes the invisible-character set by CATEGORY instead of by enumeration.
--
-- Outcome unchanged for the fourth time.
-- ⚠ **THE VERIFY PINS NO ROW COUNTS.** An earlier version of this line listed 690 / 589 / 126,
-- FL 676 + null 14, name_nonascii 2, addr_nonascii 10 and said they were asserted. They were,
-- until iteration 5 removed them; the sentence outlived the assertions, and then a later edit
-- deleted the list and left "those numbers" pointing at nothing. It asserts, in this order: the view's counts
-- EQUAL an independent base-table recomputation at the same instant; a `< 690` floor so a
-- catastrophic emptying is still loud; `curly = 0`; the accent CARRIERS by name (167-FEN,
-- 014-JOY, 179-CIG) rather than a count; state accounted for structurally (FL + NULL = every
-- row) AND FL actually present AND a null state only ever beside a null address.
-- Pinning live counts is what broke the previous block the morning after it shipped, and
-- naming a pin this block does not make is the very defect §(2) below indicts 1400 for.
--
-- ---------------------------------------------------------------------------
-- 🛑 (1) THE PRIVILEGE REGRESSION. THIS IS THE IMPORTANT HALF.
--
-- 1400 moved inlined built-ins into derm.fn_normalize_state_input(), a SECURITY INVOKER
-- function. **That adds an invoker-side EXECUTE check to the view's read path.** A role holding
-- SELECT on the view but not EXECUTE on the function can read every column EXCEPT the one that
-- routes through it.
--
-- Measured, column-isolated:
--   set local role pg_read_all_data;
--   select count(ticket_number) from derm.v_lwt_monthly_rows;  -> 690
--   select count(state)         from derm.v_lwt_monthly_rows;  -> 42501 permission denied
--                                                                 for function fn_normalize_state_input
-- Affected: pg_read_all_data, plus supabase_read_only_user and supabase_etl_admin which inherit
-- it -- read-only dashboard sessions and ETL. Production was unaffected: the edge function holds
-- the service-role key, which had EXECUTE from the start.
--
-- 🛑 THE 1400 HEADER ARGUED THIS COULD NOT HAPPEN, AND THE ARGUMENT WAS AIMED AT THE WRONG AXIS.
--    It said the function is safe inside an owner-rights view because it is IMMUTABLE and
--    "touches NO table", and that CLAUDE.md's warning "applies to functions that READ TABLES;
--    this one is pure." **Purity disposes of data LEAKAGE. It is irrelevant to the EXECUTE
--    check.** CLAUDE.md's own table lists this asymmetry as having bitten three times; this is
--    the fourth, committed by someone who had just re-read that section to justify the design.
--
-- 🛑 AND 1400's VERIFY WAS STRUCTURALLY INCAPABLE OF CATCHING IT. It runs over the Management
--    API as `postgres`, which holds EXECUTE. A privilege assertion executed as a role that
--    already has the privilege asserts nothing.
--    ⇒ **A privilege check must SET ROLE to the affected role**, and must isolate the affected
--      COLUMN -- `select *` would have failed for both roles and told you nothing about which
--      column, while `count(ticket_number)` vs `count(state)` names the mechanism exactly.
--
-- ⚠ The catalogue is not sufficient on its own either: after the grant,
--   has_function_privilege() returned true for all three roles while a `SET LOCAL ROLE
--   supabase_read_only_user` probe still raised 42501 -- because `postgres` is not a member of
--   that role and could not assume it. That 42501 was the HARNESS failing, not the fix. Probe
--   with a role you can actually assume (pg_read_all_data), and read the error text rather than
--   the SQLSTATE alone: "permission denied to set role" is not "permission denied for function".
--
-- ---------------------------------------------------------------------------
-- 🛑 (2) THE CHARACTER SET, CLOSED BY CATEGORY THIS TIME.
--
-- Three versions in one day, each hand-picked, each stale within hours:
--   1200:  5 characters. An audit found 24 more.
--   1400: 29 characters. An audit found **14** more, including U+1680 OGHAM SPACE MARK and the
--         bidi controls U+202A-U+202E / U+2066-U+2069.
--        (29 + 14 = 43. An earlier version of this line said "9 more", which does not reach 43 --
--         and its own 'including' list already named 10. Verified from the two bodies: 1400 is
--         23 space-like + 6 zero-width with a 23-space to-string; 1500 is 24 + 19 with 24.)
--   1500: 43 characters, chosen by UNICODE CATEGORY -- all Zs, Zl, Zp, the whitespace Cc, and
--         the Cf that plausibly reaches a state field from a Western editor or web form.
--
-- ⇒ The lesson is not "we missed some again". It is that **a hand-picked list is not a class**,
--   and each version was declared complete on the strength of the characters its author
--   happened to imagine. Enumerate the category.
--
-- ⚠ BIDI CONTROLS ARE THE ONE THAT MATTERS MOST HERE, and they are new in this migration. They
--   can make a string RENDER differently from its bytes -- on a compliance form that is worse
--   than a stray space, because the printed page and the stored value disagree while both look
--   correct in isolation.
--
-- ⚠ DELIBERATELY EXCLUDED, and this is a boundary rather than an oversight: U+2800 BRAILLE
--   PATTERN BLANK (So) and U+FFA0 HALFWIDTH HANGUL FILLER (Lo) render blank but are NOT
--   whitespace. Treating every glyph that looks empty as whitespace has no principled stopping
--   point. They pass through to ELSE and print verbatim -- the designed behaviour for anything
--   unrecognised. The VERIFY ASSERTS that they still pass through, so a future widening past
--   this boundary fails loudly.
--
-- ⚠ 24 space-like -> a real space; 19 zero-width/format -> DELETED. translate() drops any source
--   character with no counterpart in `to`, which is the mechanism. The `to` string must be
--   EXACTLY 24 characters, and the VERIFY now asserts that by COUNT **against
--   pg_get_functiondef**, so it cannot drift from the deployed object. 1400's header claimed
--   this assertion existed; it did not.
--
-- Audit (Rule 8): one function body + one grant. No table, column or grant on any audited table
-- changes. The view itself is NOT touched by this migration.
--
-- @Building Apps.

BEGIN;

CREATE OR REPLACE FUNCTION derm.fn_normalize_state_input(p_state text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $fn$
  -- Strip the whitespace btrim() cannot see, then trim.
  --
  -- 🛑 THE SET IS CHOSEN BY UNICODE CATEGORY, NOT BY WHAT ANYONE THOUGHT OF.
  --    The first version handled 5 characters, the second 29, and an audit found more each
  --    time -- because both were hand-picked lists. This one closes the CATEGORIES:
  --      Zs (space separator)      -- ALL of them
  --      Zl / Zp (line/para sep)   -- both
  --      Cc that are whitespace    -- TAB LF VT FF CR NEL
  --      Cf (format) that plausibly reaches a state field from Western text editors and web
  --                                   forms -- see the exclusion note below
  --
  -- 🛑 TWO CLASSES, DIFFERENT TREATMENT, AND THE DIFFERENCE IS LOAD-BEARING.
  --    SPACE-LIKE (24) -> mapped to a real space, so an NBSP inside 'NEW YORK' still matches.
  --    ZERO-WIDTH (19) -> DELETED, so 'F<ZWSP>L' recovers to 'FL'. Mapping these to a space
  --      would turn invisible corruption into visible garbage that matches nothing.
  --    translate() deletes any source character with no counterpart in `to`, which is what the
  --    length asymmetry below does.
  --
  -- ⚠ THE `to` STRING MUST BE EXACTLY 24 CHARACTERS. One short and the 24th space-like
  --   character is silently DELETED instead of spaced -- a whitespace bug hiding inside a
  --   whitespace fix, invisible to any diff that normalises whitespace. The VERIFY block
  --   asserts this by COUNT against the live function body.
  --
  -- ⚠ DELIBERATELY NOT HANDLED, and this is a boundary not an oversight:
  --   U+2800 BRAILLE PATTERN BLANK and U+FFA0 HALFWIDTH HANGUL FILLER render blank but are
  --   NOT whitespace -- they are So and Lo. Treating every glyph that happens to look empty
  --   as whitespace has no principled stopping point. They pass through to ELSE and print
  --   verbatim, which is the designed behaviour for anything unrecognised: visible, not guessed.
  --   The Arabic/Syriac Cf range (U+0600-0605, U+06DD, U+070F, U+08E2) is likewise out: it
  --   cannot reach a Florida property address through Jobber, and an unbounded list is how the
  --   previous two versions of this function went stale.
  SELECT btrim(translate(
    p_state,
    -- ---- 24 SPACE-LIKE -> space -------------------------------------------------
    -- Cc whitespace (6)
       chr(9)     || chr(10)    || chr(11)    || chr(12)    || chr(13)    || chr(133)
    -- Zs (16): NBSP, OGHAM SPACE MARK, U+2000..U+200A, NARROW NBSP, MEDIUM MATH, IDEOGRAPHIC
    || chr(160)   || chr(5760)
    || chr(8192)  || chr(8193)  || chr(8194)  || chr(8195)  || chr(8196)  || chr(8197)
    || chr(8198)  || chr(8199)  || chr(8200)  || chr(8201)  || chr(8202)
    || chr(8239)  || chr(8287)  || chr(12288)
    -- Zl, Zp (2)
    || chr(8232)  || chr(8233)
    -- ---- 19 ZERO-WIDTH / FORMAT -> DELETED (no counterpart) ----------------------
    -- soft hyphen, ARABIC LETTER MARK, MONGOLIAN VOWEL SEPARATOR
    || chr(173)   || chr(1564)  || chr(6158)
    -- ZWSP, ZWNJ, ZWJ, LRM, RLM
    || chr(8203)  || chr(8204)  || chr(8205)  || chr(8206)  || chr(8207)
    -- bidi embedding / override: LRE RLE PDF LRO RLO
    || chr(8234)  || chr(8235)  || chr(8236)  || chr(8237)  || chr(8238)
    -- word joiner, and the bidi isolates LRI RLI FSI PDI
    || chr(8288)  || chr(8294)  || chr(8295)  || chr(8296)  || chr(8297)
    -- BOM / zero-width no-break space
    || chr(65279),
    '                        '   -- exactly 24 spaces
  ))
$fn$;

COMMENT ON FUNCTION derm.fn_normalize_state_input(text) IS
  'Normalise invisible whitespace in a state value before matching. 24 space-like characters (all Zs, Zl, Zp and whitespace Cc) become a space; 19 zero-width/format characters (Cf) are DELETED via translate() length asymmetry. Exists because btrim() strips ASCII SPACE ONLY, so a TAB/NBSP/ZWSP/BOM defeated every arm of the derm.v_lwt_monthly_rows state CASE and printed the full state NAME on a Miami-Dade filing. Chosen by Unicode CATEGORY rather than by enumeration, because the two previous hand-picked versions (5 chars, then 29) both went stale. U+2800 and U+FFA0 are deliberately excluded: they render blank but are not whitespace. Pure, IMMUTABLE, touches no table. ⚠ It is SECURITY INVOKER, so every role that can SELECT the view must also hold EXECUTE here -- that includes pg_read_all_data, which supabase_read_only_user and supabase_etl_admin inherit.';

REVOKE ALL ON FUNCTION derm.fn_normalize_state_input(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION derm.fn_normalize_state_input(text) TO authenticated, service_role, pg_read_all_data;

COMMIT;

-- ---------------------------------------------------------------------------
-- VERIFY -- RE-RUNNABLE AND IT ACTUALLY ASSERTS.
--
-- 🛑 The first version of this block was entirely `--` comments saying "expect 690".
--    Nothing would have failed if the totals HAD moved, despite the header above insisting
--    THE TOTALS MUST NOT MOVE. An audit caught it. A comment is not a control -- this estate
--    has now been bitten by that exact shape three times (a caveat in a view comment while 39
--    wrong bands passed the check; a `RAISE`-less expectation here). If you add an expectation,
--    make it raise.
--
-- Run it any time. It is read-only and takes no arguments.
-- ---------------------------------------------------------------------------
DO $verify$
DECLARE
  r         record;
  b         record;
  v_fail    text := '';
  v_checks  int  := 0;
BEGIN
  SELECT count(*)                                                     AS all_rows,
         count(*) FILTER (WHERE in_scope)                             AS in_scope,
         count(DISTINCT ticket_number)                                AS tickets,
         count(*) FILTER (WHERE client_name LIKE '%'||chr(8217)||'%') AS curly,
         count(*) FILTER (WHERE client_name ~ '[^\x20-\x7E]')         AS name_nonascii,
         count(*) FILTER (WHERE address ~ '[^\x20-\x7E]')             AS addr_nonascii,
         count(*) FILTER (WHERE state IS NOT NULL
                            AND state !~ '^[A-Z]{2}$')                AS state_not_2letter,
         count(*) FILTER (WHERE state = 'FL')                         AS st_fl,
         count(*) FILTER (WHERE state IS NULL)                        AS st_null
    INTO r
    FROM derm.v_lwt_monthly_rows;

  -- 1. 🛑 THE TOTALS ARE COMPARED AGAINST AN INDEPENDENT RECOMPUTATION, NOT AGAINST A
  --    REMEMBERED NUMBER. The first version of this asserted all_rows = 690 and it FAILED the
  --    next morning -- not because anything broke, but because Diego filed ticket 833813 and
  --    ten legitimate rows appeared. A re-runnable check that breaks on normal business is
  --    worse than no check: it trains whoever runs it to ignore a red result.
  --
  --    ⚠ THIS ESTATE ALREADY LEARNED THIS, one day earlier, in 2026-08-25_0110:
  --      "DO NOT hard-code an expected breakdown against live data. Mine went stale between
  --       writing the migration and running it. Assert mirror == queue instead, which compares
  --       two live reads of the same instant rather than a live read against a remembered number."
  --    I wrote that note and then did the opposite. So: recompute from the BASE TABLES and
  --    compare two reads of the SAME INSTANT. That is stable under growth by construction, and
  --    it is a STRONGER check -- it catches a damaged JOIN or WHERE, which is the actual
  --    CREATE OR REPLACE failure mode, where a frozen count only catches a change in volume.
  SELECT count(*) AS all_rows,
         count(*) FILTER (WHERE COALESCE(p.county = 'Dade', false)
                             OR m.white_manifest_number IS NOT NULL) AS in_scope,
         count(DISTINCT COALESCE(m.white_manifest_number, m.yellow_ticket_number)) AS tickets
    INTO b
    FROM public.derm_manifests m
    JOIN public.manifest_visits mv ON mv.manifest_id = m.id
    JOIN public.visits v          ON v.id = mv.visit_id AND v.deleted_at IS NULL
    JOIN public.clients c         ON c.id = m.client_id
    LEFT JOIN public.properties p ON p.id = v.property_id
   WHERE m.deleted_at IS NULL;

  v_checks := v_checks + 1;
  IF r.all_rows <> b.all_rows OR r.in_scope <> b.in_scope OR r.tickets <> b.tickets THEN
    v_fail := v_fail || format(' [VIEW DISAGREES WITH THE BASE TABLES: view %s/%s/%s vs recomputed %s/%s/%s -- a JOIN or the WHERE was damaged]',
                               r.all_rows, r.in_scope, r.tickets, b.all_rows, b.in_scope, b.tickets);
  END IF;

  -- and a floor, so a catastrophic emptying is still loud. Deliberately a FLOOR, not equality:
  -- it cannot go stale upward, and 690 was the measured size on 2026-08-25.
  v_checks := v_checks + 1;
  IF r.all_rows < 690 THEN
    v_fail := v_fail || format(' [ROWS WENT DOWN: %s, was 690 on 2026-08-25 and this view only grows]', r.all_rows);
  END IF;

  -- 2. the fold did its job
  v_checks := v_checks + 1;
  IF r.curly <> 0 THEN
    v_fail := v_fail || format(' [%s curly apostrophes still served]', r.curly);
  END IF;

  -- 3. 🛑 THE ACCENTS MUST SURVIVE. This is the assertion that would catch someone
  --    "improving" the fold into unaccent() or a [^\x20-\x7E] strip. A result of ZERO here is
  --    a REGRESSION, not a cleaner one: it means "Fendi Château Residences" and "Española Way"
  --    are now MISSPELLED on a Miami-Dade compliance form.
  --    ⚠ Asserted on the CARRIERS, not on a count. The count grows with the business; the fact
  --      that Fendi Chateau keeps its a-circumflex does not.
  --    ⚠ This is the COARSE net. It cannot tell "the fold was widened into an unaccent()" from
  --      "every carrier retired", so it says so and defers to the per-carrier check below, which
  --      distinguishes them. An earlier version asserted MISSPELLED outright and would have
  --      shouted that at a clean database the day 167-FEN's two rows went away.
  v_checks := v_checks + 1;
  IF r.name_nonascii < 1 OR r.addr_nonascii < 1 THEN
    v_fail := v_fail || format(' [NO ACCENTED CHARACTERS LEFT AT ALL: name_nonascii=%s addr_nonascii=%s -- either the fold was widened into an unaccent(), or every carrier retired. The per-carrier check reports which]',
                               r.name_nonascii, r.addr_nonascii);
  END IF;
  -- 🛑 EXACT CHARACTERS, PER CARRIER, CONJUNCTIVELY. Two holes were found here and both are
  --    the same shape: the assertion PARAPHRASED the rule instead of MIRRORING it.
  --
  --    (1) `~ '[^ -~]'` asks "is SOME non-ASCII byte still present", not "is the RIGHT
  --        character still present". Measured: mapping the n-tilde to an o-grave leaves this
  --        green while the view serves **'448 Espaoola Way'** to a county filing. Likewise
  --        a-circumflex -> a-diaeresis leaves 'Fendi Chateau Residences' misspelled and green.
  --        So the whole point of the check -- do not misspell a real street on a regulatory
  --        document -- was not being tested at all.
  --
  --    (2) `client_code IN ('014-JOY','179-CIG') AND ...` inside one EXISTS is an OR: EITHER
  --        carrier satisfies it. Measured: stripping the n-tilde from 014-JOY ALONE left the
  --        block fully green. Each carrier is exactly one property, so the single-carrier
  --        regression is the REALISTIC shape and it was the invisible one.
  --
  --    The Postman suite already did this correctly (exact strings, iterated per carrier), so
  --    the DB-side check was strictly WEAKER than the HTTP-side one on the same claim.
  DECLARE
    v_carrier text;
    v_missing text := '';
    v_gone    text := '';
    -- carrier, the column to read, and the EXACT substring that must be present
    v_acc text[][] := ARRAY[
      ['167-FEN', 'name', 'Fendi Ch' || chr(226) || 'teau Residences'],
      ['014-JOY', 'addr', 'Espa'     || chr(241) || 'ola Way'],
      ['179-CIG', 'addr', 'Espa'     || chr(241) || 'ola Way']
    ];
  BEGIN
    FOR i IN 1 .. array_length(v_acc,1) LOOP
      v_checks := v_checks + 1;
      -- 🛑 TWO DIFFERENT REASONS THIS CAN GO RED, AND THE MESSAGE MUST SAY WHICH.
      --    A carrier that has been RETIRED has no rows at all -- nothing is misspelled, the
      --    accent path simply is not exercised any more and someone should pick a new carrier.
      --    167-FEN carries only 2 rows, so ONE client retiring trips this, and shouting
      --    "MISSPELLED ON A COUNTY FILING" at a clean database is exactly the thing this block's
      --    own governing rule warns about: a check that cries wolf trains people to ignore red.
      IF NOT EXISTS (SELECT 1 FROM derm.v_lwt_monthly_rows WHERE client_code = v_acc[i][1]) THEN
        v_gone := v_gone || format(' %s', v_acc[i][1]);
      ELSIF NOT EXISTS (
        SELECT 1 FROM derm.v_lwt_monthly_rows
         WHERE client_code = v_acc[i][1]
           AND CASE WHEN v_acc[i][2] = 'name' THEN client_name ELSE address END
               LIKE '%' || v_acc[i][3] || '%'
      ) THEN
        v_missing := v_missing || format(' %s(%s)', v_acc[i][1], v_acc[i][3]);
      END IF;
    END LOOP;
    IF v_missing <> '' THEN
      v_fail := v_fail || format(' [ACCENT CARRIER(S) NO LONGER CARRY THE EXACT SPELLING:%s -- a real Miami Beach street and/or a registered business name are now MISSPELLED on a county filing]', v_missing);
    END IF;
    IF v_gone <> '' THEN
      v_fail := v_fail || format(' [ACCENT CARRIER(S) HAVE NO ROWS AT ALL:%s -- nothing is misspelled; the client retired, so the accent path is no longer exercised. Pick a new carrier that still carries a non-ASCII LETTER and update this list]', v_gone);
    END IF;
  END;

  -- 4. state is uniform, and nothing was invented. STRUCTURAL, not a pinned count: every
  --    non-null value must be a two-letter code, and FL + NULL must account for every row.
  --    A pinned FL=676 broke the morning after it shipped; this cannot.
  v_checks := v_checks + 1;
  IF r.st_fl + r.st_null <> r.all_rows THEN
    v_fail := v_fail || format(' [STATE: FL=%s + NULL=%s does not account for all %s rows -- a third value has appeared, look at it]',
                               r.st_fl, r.st_null, r.all_rows);
  END IF;

  -- 🛑 AND FL MUST ACTUALLY BE PRESENT. The accounting check above is SATISFIED by
  --    st_fl = 0, st_null = all_rows -- i.e. by the State column going blank on every row of a
  --    county filing. That is the shape a broken property join produces, and nothing else here
  --    would see it: check 6 drives values through the view and catches a VIEW-LOGIC collapse,
  --    but this is the DATA side.
  --    Measured every month of 2026: FL is 54..90 per month, minimum 74 of 87 in-scope. It has
  --    never been 0 and cannot legitimately be.
  v_checks := v_checks + 1;
  IF r.st_fl = 0 THEN
    v_fail := v_fail || ' [STATE IS NULL ON EVERY ROW -- the State column would print blank on the whole filing. This is what a broken property join looks like, not a normalisation problem]';
  END IF;

  -- 🛑 AND A NULL STATE MUST MEAN "NO PROPERTY AT ALL", NOT "STATE WENT MISSING".
  --    Measured: the null crosstab is an EXACT DIAGONAL -- 686 rows with none of
  --    state/address/city/zip/county null, 14 with ALL FIVE null, and no third combination.
  --    So a row with a null state but a present address is a new and different defect.
  v_checks := v_checks + 1;
  IF EXISTS (SELECT 1 FROM derm.v_lwt_monthly_rows
              WHERE state IS NULL AND (address IS NOT NULL OR city IS NOT NULL)) THEN
    v_fail := v_fail || ' [a row has a NULL state but a present address/city -- state is going missing on its own, which has never happened; the 14 known nulls are rows whose visit has no property at all]';
  END IF;

  -- 5. 🛑 THE PASS-THROUGH TRIPWIRE. Verbatim pass-through is deliberate and is the reason a
  --    non-Florida property can never be silently relabelled -- but a value reaching the form
  --    that is not a 2-letter code is something a HUMAN must see before it is filed.
  v_checks := v_checks + 1;
  IF r.state_not_2letter <> 0 THEN
    v_fail := v_fail || format(' [%s rows carry a non-2-letter state -- an unrecognised value is passing through to a county filing; look at it, do not coerce it]',
                               r.state_not_2letter);
  END IF;

  -- 6. the mapping is a MAPPING, not a constant. Asserted by OUTCOME against the LIVE view,
  --    because `pg_get_viewdef(...) ~ 'CALIFORNIA'` stays TRUE even with the arm deleted.
  --
  -- 🛑 THE PROBE WRITES, SO IT MUST ROLL BACK, AND A BARE `DO` BLOCK COMMITS ON SUCCESS.
  --    The first version of this restored the value by hand and called itself read-only. It was
  --    not: the updated_at trigger still fired and it left 8 UPDATE rows in audit.logs
  --    (app_source='sql') on the carrier property. Restoring a VALUE is not the same as not
  --    having written. A BEGIN..EXCEPTION block is an implicit SAVEPOINT, so raising a sentinel
  --    at the end of it rolls the writes back -- while PL/pgSQL LOCAL VARIABLES keep the values
  --    they had when the error was raised, which is what lets the results survive the rollback.
  DECLARE
    v_prop bigint; v_vis bigint; v_orig text; v_got text; v_qc text;
    v_cases text[][] := ARRAY[
      -- the plain cases: the mapping is a MAPPING, and the last two prove it is not a constant
      ['Florida','FL'],  ['fl','FL'],  ['California','CA'],  ['New York','NY'],
      ['tx','TX'],       ['Ontario','Ontario'],              ['XYZZY','XYZZY'],
      -- 🛑 THE INVISIBLE WHITESPACE CASES. btrim() strips ASCII SPACE ONLY, so before
      --    2026-08-25_1200 every one of these fell through EVERY branch and printed the full
      --    state NAME on a county filing. 0 of 921 rows carry them today, so these are the
      --    only place this hardening is exercised at all.
      ['Florida' || chr(160), 'FL'],          -- trailing NBSP
      [chr(9) || 'Florida',   'FL'],          -- leading TAB
      ['Florida' || chr(8203),'FL'],          -- trailing ZERO-WIDTH SPACE
      [chr(10) || 'fl' || chr(13), 'FL'],     -- newline + CR around a lowercase code
      ['New' || chr(160) || 'York', 'NY'],    -- NBSP *inside* the name
      ['Ontario' || chr(160), 'Ontario'],     -- unrecognised still passes through, now trimmed
      -- and the accented province, spelled out, which must not depend on upper() folding it
      ['Qu' || chr(233) || 'bec', 'QC'],      -- lowercase e-acute
      ['QU' || chr(201) || 'BEC', 'QC']       -- uppercase E-acute
    ];
  BEGIN
    SELECT x.visit_id, v.property_id INTO v_vis, v_prop
      FROM derm.v_lwt_monthly_rows x JOIN public.visits v ON v.id = x.visit_id
     WHERE v.property_id IS NOT NULL ORDER BY x.visit_id LIMIT 1;
    SELECT state INTO v_orig FROM public.properties WHERE id = v_prop;
    SELECT state INTO v_qc   FROM public.properties WHERE state ILIKE 'qu%bec%' LIMIT 1;

    BEGIN
      FOR i IN 1 .. array_length(v_cases,1) LOOP
        UPDATE public.properties SET state = v_cases[i][1] WHERE id = v_prop;
        SELECT state INTO v_got FROM derm.v_lwt_monthly_rows WHERE visit_id = v_vis LIMIT 1;
        v_checks := v_checks + 1;
        IF v_got IS DISTINCT FROM v_cases[i][2] THEN
          v_fail := v_fail || format(' [MAP %L -> %L, wanted %L]', v_cases[i][1], v_got, v_cases[i][2]);
        END IF;
      END LOOP;

      -- the STORED accented Québec (U+00E9), whose arm depends on upper() under the db collation.
      -- Read from the table, never retyped: a retyped copy tests your editor, not the data.
      IF v_qc IS NOT NULL THEN
        UPDATE public.properties SET state = v_qc WHERE id = v_prop;
        SELECT state INTO v_got FROM derm.v_lwt_monthly_rows WHERE visit_id = v_vis LIMIT 1;
        v_checks := v_checks + 1;
        IF v_got IS DISTINCT FROM 'QC' THEN
          v_fail := v_fail || format(' [the STORED accented Quebec mapped to %L, not QC -- the chr(201) arm is dead under this collation]', v_got);
        END IF;
      END IF;

      -- 🛑 EVERY INVISIBLE CHARACTER, DRIVEN THROUGH THE LIVE VIEW.
      --    Testing derm.fn_normalize_state_input() directly is NOT testing this view -- the
      --    view could stop calling it and every function-level test would still pass. These
      --    go through the real object, on a real row, and read the real output column.
      DECLARE
        v_cp   int;
        v_kind text;
        v_want text;
        -- 43 characters: 24 space-like (all Zs + Zl + Zp + whitespace Cc) and 19 zero-width Cf.
        -- Chosen by CATEGORY. The two earlier hand-picked versions (5 chars, then 29) both went
        -- stale within hours of shipping, each time to an audit that simply tried more characters.
        v_cps  int[]  := ARRAY[9,10,11,12,13,133,160,5760,8192,8193,8194,8195,8196,8197,8198,
                               8199,8200,8201,8202,8239,8287,12288,8232,8233,
                               173,1564,6158,8203,8204,8205,8206,8207,8234,8235,8236,8237,8238,
                               8288,8294,8295,8296,8297,65279];
        v_zero int[]  := ARRAY[173,1564,6158,8203,8204,8205,8206,8207,8234,8235,8236,8237,8238,
                               8288,8294,8295,8296,8297,65279];
      BEGIN
        FOREACH v_cp IN ARRAY v_cps LOOP
          v_kind := CASE WHEN v_cp = ANY (v_zero) THEN 'zero' ELSE 'space' END;

          -- trailing and leading must both normalise away entirely
          UPDATE public.properties SET state = 'Florida' || chr(v_cp) WHERE id = v_prop;
          SELECT state INTO v_got FROM derm.v_lwt_monthly_rows WHERE visit_id = v_vis LIMIT 1;
          v_checks := v_checks + 1;
          IF v_got IS DISTINCT FROM 'FL' THEN
            v_fail := v_fail || format(' [WS trailing U+%s -> %L, wanted FL]', upper(to_hex(v_cp)), v_got);
          END IF;

          UPDATE public.properties SET state = chr(v_cp) || 'Florida' WHERE id = v_prop;
          SELECT state INTO v_got FROM derm.v_lwt_monthly_rows WHERE visit_id = v_vis LIMIT 1;
          v_checks := v_checks + 1;
          IF v_got IS DISTINCT FROM 'FL' THEN
            v_fail := v_fail || format(' [WS leading U+%s -> %L, wanted FL]', upper(to_hex(v_cp)), v_got);
          END IF;

          -- INTERNAL is where the two classes must behave DIFFERENTLY: a space-like character
          -- becomes a space so 'NEW YORK' still matches; a zero-width one is deleted so
          -- 'F<ZWSP>L' recovers to 'FL' rather than becoming an unusable 'F L'.
          -- 🛑 THE TWO CLASSES MUST DIVERGE HERE, and the expected values differ accordingly.
          --    'New<c>York':  a SPACE-LIKE c becomes a real space -> 'New York' -> NY.
          --                   a ZERO-WIDTH c is DELETED -> 'NewYork', which is not a state
          --                   name and not two letters, so it falls to ELSE and passes
          --                   through VERBATIM. That is correct: a zero-width character
          --                   represents no space, so the honest reading of 'New<ZWSP>York'
          --                   is that somebody typed 'NewYork' with junk in it, and the
          --                   design says show it rather than guess.
          --    Asserting 'NY' for BOTH would be a paraphrase of the rule, not a mirror of it.
          v_want := CASE WHEN v_kind = 'zero' THEN 'NewYork' ELSE 'NY' END;
          UPDATE public.properties SET state = 'New' || chr(v_cp) || 'York' WHERE id = v_prop;
          SELECT state INTO v_got FROM derm.v_lwt_monthly_rows WHERE visit_id = v_vis LIMIT 1;
          v_checks := v_checks + 1;
          IF v_got IS DISTINCT FROM v_want THEN
            v_fail := v_fail || format(' [WS internal U+%s (%s) -> %L, wanted %L]', upper(to_hex(v_cp)), v_kind, v_got, v_want);
          END IF;
        END LOOP;

        -- and the zero-width class specifically, mid-token: F<zw>L must recover to FL
        FOREACH v_cp IN ARRAY v_zero LOOP
          UPDATE public.properties SET state = 'F' || chr(v_cp) || 'L' WHERE id = v_prop;
          SELECT state INTO v_got FROM derm.v_lwt_monthly_rows WHERE visit_id = v_vis LIMIT 1;
          v_checks := v_checks + 1;
          IF v_got IS DISTINCT FROM 'FL' THEN
            v_fail := v_fail || format(' [ZW mid-token U+%s -> %L, wanted FL -- a zero-width char must be DELETED, not spaced]', upper(to_hex(v_cp)), v_got);
          END IF;
        END LOOP;

        -- 🛑 THE LENGTH ASSERTION, READ FROM THE LIVE FUNCTION BODY.
        --    translate() DELETES any source character with no counterpart in `to`, so a `to`
        --    string one short silently deletes the last space-like character instead of spacing
        --    it. The 1400 header claimed this was "asserted by COUNT, never by eye" -- it was
        --    not, it was only a comment. This is the assertion. It reads pg_get_functiondef so
        --    it cannot drift from the deployed object the way a source-file check would.
        DECLARE v_to_len int;
        BEGIN
          SELECT length((regexp_match(pg_get_functiondef(pr.oid),
                                      '''( +)''\s*-- exactly 24 spaces'))[1])
            INTO v_to_len
            FROM pg_proc pr
           -- ⚠ by SIGNATURE, not by name: a second overload would make a name-only lookup
           --   ambiguous and could silently read the wrong body.
           WHERE pr.oid = 'derm.fn_normalize_state_input(text)'::regprocedure;
          v_checks := v_checks + 1;
          IF v_to_len IS DISTINCT FROM 24 THEN
            v_fail := v_fail || format(' [translate to-string is %s chars, MUST be 24 -- a short to-string silently DELETES space-like characters instead of spacing them]', coalesce(v_to_len::text,'unreadable'));
          END IF;
        END;

        -- the two DELIBERATE exclusions must still pass through: they render blank but are not
        -- whitespace (U+2800 BRAILLE BLANK is So, U+FFA0 HANGUL FILLER is Lo). If these ever
        -- start normalising, somebody has widened the set past its stated boundary.
        UPDATE public.properties SET state = 'F' || chr(10240) || 'L' WHERE id = v_prop;
        SELECT state INTO v_got FROM derm.v_lwt_monthly_rows WHERE visit_id = v_vis LIMIT 1;
        v_checks := v_checks + 1;
        IF v_got IS NOT DISTINCT FROM 'FL' THEN
          v_fail := v_fail || ' [U+2800 BRAILLE BLANK was normalised -- it is NOT whitespace and the set has been widened past its boundary]';
        END IF;

        UPDATE public.properties SET state = 'F' || chr(65440) || 'L' WHERE id = v_prop;
        SELECT state INTO v_got FROM derm.v_lwt_monthly_rows WHERE visit_id = v_vis LIMIT 1;
        v_checks := v_checks + 1;
        IF v_got IS NOT DISTINCT FROM 'FL' THEN
          v_fail := v_fail || ' [U+FFA0 HALFWIDTH HANGUL FILLER was normalised -- it is Lo, not whitespace, and the set has been widened past its stated boundary]';
        END IF;

        -- NEGATIVE CONTROL: an ordinary character must NOT be stripped, or the normaliser is
        -- eating real data and every pass above is meaningless.
        UPDATE public.properties SET state = 'Flo' || chr(120) || 'rida' WHERE id = v_prop;
        SELECT state INTO v_got FROM derm.v_lwt_monthly_rows WHERE visit_id = v_vis LIMIT 1;
        v_checks := v_checks + 1;
        IF v_got IS DISTINCT FROM 'Floxrida' THEN
          v_fail := v_fail || format(' [CONTROL FAILED: Flo-x-rida came back %L, so the normaliser is stripping ordinary characters]', v_got);
        END IF;
      END;

      RAISE EXCEPTION 'LWT_PROBE_ROLLBACK';       -- undo every write above
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'LWT_PROBE_ROLLBACK' THEN RAISE; END IF;   -- a real error still propagates
    END;

    -- prove the rollback actually happened rather than assuming it
    v_checks := v_checks + 1;
    IF (SELECT state FROM public.properties WHERE id = v_prop) IS DISTINCT FROM v_orig THEN
      v_fail := v_fail || format(' [ROLLBACK FAILED: properties.id=%s is not %L]', v_prop, v_orig);
    END IF;
  END;

  -- 🛑 THE PRIVILEGE ASSERTION, RUN AS THE AFFECTED ROLE.
  --    2026-08-25_1400 narrowed the view's effective read privilege by routing one column
  --    through a SECURITY INVOKER function, and the FIRST version of 1500 -- whose entire
  --    subject was that regression -- shipped a VERIFY with no privilege check at all. The
  --    check below closed that, added by baac702 alongside this very sentence.
  --    ⚠ As first written this read "1500 shipped a VERIFY with no privilege check at all",
  --      present tense, eight lines above the check itself -- the doc denying the code beside
  --      it. This file uses "an earlier version of" correctly twice elsewhere; this sentence
  --      was simply never re-tensed after the thing it describes was fixed in the same commit.
  --    Worse, this block runs
  --    as `postgres`, which OWNS the function, so any naive check passes with the grant
  --    present OR absent. It has to SET ROLE, and it has to isolate the COLUMN: `select *`
  --    fails for both roles and names nothing.
  --    ⚠ Use pg_read_all_data, a role postgres can actually assume. A probe against
  --      supabase_read_only_user raises 42501 "permission denied TO SET ROLE" -- same SQLSTATE
  --      as the defect, opposite meaning, and it was misread as a failure once already.
  DECLARE v_tick bigint; v_st bigint;
  BEGIN
    BEGIN
      SET LOCAL ROLE pg_read_all_data;
      SELECT count(ticket_number), count(state) INTO v_tick, v_st FROM derm.v_lwt_monthly_rows;
      v_checks := v_checks + 1;
      IF v_st <> v_tick - (SELECT count(*) FROM derm.v_lwt_monthly_rows WHERE state IS NULL) THEN
        v_fail := v_fail || format(' [PRIV: as pg_read_all_data, count(state)=%s does not match count(ticket_number)=%s less the nulls]', v_st, v_tick);
      END IF;
    EXCEPTION WHEN insufficient_privilege THEN
      v_checks := v_checks + 1;
      v_fail := v_fail || ' [PRIV REGRESSION: pg_read_all_data got 42501 reading the state column -- a function on the view read path is missing EXECUTE. supabase_read_only_user and supabase_etl_admin inherit this role, so read-only dashboards and ETL are broken]';
    END;
    RESET ROLE;
  END;

  -- 🛑 PIN THE FUNCTION'S ATTRIBUTES. Nothing else here reads them, so a CREATE OR REPLACE
  --    could quietly drop IMMUTABLE, flip it to SECURITY DEFINER, or lose the pinned
  --    search_path, and every other check would stay green. SECDEF in particular would change
  --    the privilege model this migration exists to get right.
  DECLARE r2 record;
  BEGIN
    SELECT p.provolatile, p.prosecdef, p.proparallel, p.proconfig::text
      INTO r2
      FROM pg_proc p
     -- ⚠ by SIGNATURE, not by name -- see the note above.
     WHERE p.oid = 'derm.fn_normalize_state_input(text)'::regprocedure;
    v_checks := v_checks + 1;
    IF r2.provolatile <> 'i' OR r2.prosecdef OR r2.proparallel <> 's'
       OR r2.proconfig IS DISTINCT FROM '{search_path=pg_catalog}' THEN
      v_fail := v_fail || format(' [FUNCTION ATTRIBUTES CHANGED: volatile=%s secdef=%s parallel=%s config=%s -- expected i/false/s/{search_path=pg_catalog}]',
                                 r2.provolatile, r2.prosecdef, r2.proparallel, r2.proconfig);
    END IF;
  END;

  IF v_fail <> '' THEN
    RAISE EXCEPTION 'LWT VERIFY FAILED (% checks):%', v_checks, v_fail;
  END IF;
  RAISE NOTICE 'LWT VERIFY: % checks passed', v_checks;
END $verify$;

-- ---------------------------------------------------------------------------
-- Mutation-tested, every assertion fires.
-- 🛑 THE CHECK COUNT IS DELIBERATELY NOT WRITTEN DOWN, and it used to say "180" while the
--    block ran 182. It is DATA-DEPENDENT: the Quebec arm only executes because properties 234
--    and 882 exist today, and the accent loop scales with the carrier list. A pinned count is
--    the same defect as the pinned row counts this block was rebuilt to remove -- it goes
--    stale on ordinary data movement and trains whoever reads it to ignore the mismatch.
--    The block RAISES its own count on success; read that, do not quote one here.
--
-- 🛑 THE ACCENT ASSERTIONS WERE REBUILT 2026-08-25 (iteration 9) BECAUSE THEY DID NOT TEST WHAT
--    THEIR OWN PROSE PROMISED. Two holes, both the paraphrase-instead-of-mirror shape:
--
--    (1) They asked `~ '[^ -~]'` -- "is SOME non-ASCII byte still present" -- not "is the
--        RIGHT character still present". Measured through the live view, rolled back: mapping the
--        n-tilde to an o-grave left the block GREEN while the view served **'448 Espaoola Way'**,
--        and a-circumflex -> a-diaeresis left 'Fendi Chateau Residences' misspelled and green.
--        A misspelled Miami Beach street and a misspelled registered business name could reach a
--        county filing at 180/180 checks passed.
--
--    (2) `client_code IN ('014-JOY','179-CIG') AND ...` inside ONE `EXISTS` is an OR: either
--        carrier satisfied it. Stripping the n-tilde from 014-JOY ALONE left the block green.
--        Each carrier is ONE property row, so the single-carrier regression is the realistic
--        shape -- and it was the invisible one.
--
--    Both now assert the EXACT substring, per carrier, conjunctively. Proven by driving all three
--    real regressions through the live view in rolled-back savepoints: each is CAUGHT, and the old
--    form is shown to have PASSED two of them. Rollback verified (10 n-tilde rows, 2 a-circumflex).
--
--    ⚠ The Postman suite had ALREADY done this correctly (exact strings, iterated per carrier), so
--      for a while the DB-side check was strictly WEAKER than the HTTP-side one on the same claim.
--      When two layers assert "the same thing", diff the assertions, not the intentions.
