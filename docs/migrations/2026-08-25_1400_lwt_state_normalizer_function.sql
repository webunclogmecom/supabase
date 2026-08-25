-- 2026-08-25_1400_lwt_state_normalizer_function.sql
-- ---------------------------------------------------------------------------
-- Finish the job 2026-08-25_1200 started: move the invisible-whitespace handling out of the
-- view and into derm.fn_normalize_state_input(), and cover the 24 characters 1200 missed.
--
-- Zero-runs iteration 3. Outcome unchanged again, and asserted:
--   690 rows / 589 in_scope / 126 tickets, state FL 676 + null 14, curly 0,
--   name_nonascii 2, addr_nonascii 10. Identical before and after.
--
-- ---------------------------------------------------------------------------
-- 🛑 WHY: 1200 CLOSED FIVE CHARACTERS AND THE HOLE HAS TWENTY-NINE.
--
-- 1200 handled TAB, LF, CR, NBSP and ZWSP. The iteration-2 audit drove hex-encoded inputs
-- through the LIVE view, 72 probes across three positions, and found **24 more invisible
-- characters that still defeated every arm and printed the full state NAME on a county
-- filing** -- the exact outcome the mapping exists to prevent. Two of them (VERTICAL TAB and
-- FORM FEED) are ASCII controls every bit as plausible as the TAB and CR that WERE handled;
-- U+FEFF arrives from an Excel/CSV paste and U+202F from Word.
--
-- ⇒ The lesson is not "we missed some". It is that **1200 fixed the characters somebody
--   happened to think of, and called the class closed.** A hand-picked list is not a class.
--
-- ---------------------------------------------------------------------------
-- 🛑 TWO CLASSES, AND THEY MUST BEHAVE DIFFERENTLY. Mapping both to a space is wrong.
--
--   SPACE-LIKE (23)  -> become a real space, so an NBSP inside 'NEW YORK' still matches.
--   ZERO-WIDTH (6)   -> are DELETED, so 'F<ZWSP>L' recovers to 'FL'.
--
-- Mapping a zero-width character to a space turns invisible corruption into visible
-- wrongness: 'F<ZWSP>L' would become 'F L', which matches nothing and prints garbage. A
-- zero-width character has no width by definition, so deletion is the only reading that can
-- recover the intended value. Conversely, DELETING a real NBSP would weld 'NEW YORK' into
-- 'NEWYORK' and lose a genuine word boundary.
--
-- ⚠ The consequence, asserted rather than hidden: 'New<ZWSP>York' emits **'NewYork'**, which
--   is not a state name and not two letters, so it falls to ELSE and passes through VERBATIM.
--   That is correct by design -- somebody typed 'NewYork' with junk in it, and this estate's
--   rule is to show an unrecognised value rather than guess at it.
--
-- 🛑 THE MECHANISM IS translate()'s LENGTH ASYMMETRY, WHICH IS EASY TO GET SILENTLY WRONG.
--    translate(src, from, to) DELETES any character of `from` with no counterpart in `to`.
--    So `to` must be EXACTLY as long as the space-like run (23). One space short and the
--    23rd space-like character is silently DELETED instead of spaced -- a whitespace bug
--    hidden inside a whitespace fix, invisible to any diff that normalises whitespace.
--    The VERIFY block asserts length('...') = 23 by COUNT, never by eye.
--
-- ---------------------------------------------------------------------------
-- WHY A FUNCTION RATHER THAN MORE INLINE SQL:
--   - 1200 repeated its expression SEVEN times in the CASE. At 29 characters that is
--     unreadable and unmaintainable, and seven copies is seven chances to edit six of them.
--   - It is independently testable. The VERIFY exercises all 29 characters x 3 positions.
--   - ⚠ But testing the FUNCTION is not testing the VIEW -- the view could stop calling it
--     and every function-level test would still pass. So the VERIFY drives every character
--     through the LIVE VIEW on a real row, and reads the real output column.
--
-- ⚠ SAFE TO CALL FROM AN OWNER-RIGHTS VIEW: it is IMMUTABLE, PARALLEL SAFE, touches NO table,
--   and has a pinned search_path. The CLAUDE.md warning about SECURITY INVOKER functions
--   inside owner-rights views applies to functions that READ TABLES; this one is pure.
--   Grants are explicit because Supabase's ALTER DEFAULT PRIVILEGES hands out EXECUTE on new
--   public functions unasked -- this one lives in `derm`, and is granted deliberately.
--
-- ⚠ The view body is pg_get_viewdef output with ONE block substituted (scratchpad genlwt3.js),
--   diffed line by line against the live body with a positive control: only the six state-CASE
--   arms differ. Never retyped.
--
-- Audit (Rule 8): one new pure function + one view body. No table, column or grant on any
-- audited table changes. View column list and types unchanged, so grants are preserved.
--
-- @Building Apps. Claimed in WORKING-NOW.md.

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
  -- 🛑 TWO CLASSES, HANDLED DIFFERENTLY ON PURPOSE.
  --   SPACE-LIKE characters are mapped to a real space, so an NBSP *inside* a name still
  --     leaves 'NEW YORK' matchable.
  --   ZERO-WIDTH / FORMAT characters are DELETED, not spaced. translate() drops any source
  --     character with no counterpart in the `to` string, which is what the length asymmetry
  --     below is doing. Mapping them to a space would turn an invisibly-corrupt 'F<ZWSP>L'
  --     into a visibly-wrong 'F L' -- neither is usable, but a zero-width character carries
  --     no width by definition, so deleting it is the only reading that can recover 'FL'.
  --
  -- ⚠ THE `to` STRING MUST BE EXACTLY AS LONG AS THE SPACE-LIKE RUN (23). If it is shorter,
  --   translate SILENTLY DELETES the overhang instead of spacing it, and a whitespace bug
  --   hides inside a whitespace fix. Asserted in the VERIFY block by character count, not by eye.
  SELECT btrim(translate(
    p_state,
    -- 23 SPACE-LIKE -> space
       chr(9)    || chr(10)   || chr(11)   || chr(12)   || chr(13)      -- TAB LF VT FF CR
    || chr(133)  || chr(160)                                           -- NEL, NBSP
    || chr(8192) || chr(8193) || chr(8194) || chr(8195) || chr(8196)    -- U+2000..2004
    || chr(8197) || chr(8198) || chr(8199) || chr(8200) || chr(8201)    -- U+2005..2009
    || chr(8202)                                                       -- U+200A hair space
    || chr(8232) || chr(8233)                                          -- LINE SEP, PARA SEP
    || chr(8239) || chr(8287) || chr(12288)                            -- narrow NBSP, medium math, ideographic
    -- 6 ZERO-WIDTH / FORMAT -> deleted (no counterpart)
    || chr(173)  || chr(8203) || chr(8204) || chr(8205)                 -- soft hyphen, ZWSP, ZWNJ, ZWJ
    || chr(8288) || chr(65279),                                         -- word joiner, BOM
    '                       '   -- exactly 23 spaces
  ))
$fn$;

COMMENT ON FUNCTION derm.fn_normalize_state_input(text) IS
  'Normalise invisible whitespace in a state value before matching. Space-like characters become a space; zero-width and format characters are DELETED via translate() length asymmetry. Exists because btrim() strips ASCII SPACE ONLY, so a TAB/NBSP/ZWSP/BOM defeated every arm of the derm.v_lwt_monthly_rows state CASE and printed the full state NAME on a Miami-Dade filing. Pure, IMMUTABLE, touches no table.';

REVOKE ALL ON FUNCTION derm.fn_normalize_state_input(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION derm.fn_normalize_state_input(text) TO authenticated, service_role;

CREATE OR REPLACE VIEW derm.v_lwt_monthly_rows AS
 SELECT COALESCE(m.white_manifest_number, m.yellow_ticket_number) AS ticket_number,
        CASE
            WHEN m.white_manifest_number IS NOT NULL THEN 'white'::text
            ELSE 'yellow'::text
        END AS ticket_kind,
    m.white_manifest_number IS NOT NULL AS offload_in_dade,
    m.dump_ticket_date AS offload_date,
    df.name AS disposal_facility,
    v.visit_date AS pickup_date,
    c.client_code,
    replace(replace(replace(replace(replace(replace(replace(c.name, chr(8217), ''''::text), chr(8216), ''''::text), chr(8220), '"'::text), chr(8221), '"'::text), chr(8211), '-'::text), chr(8212), '-'::text), chr(160), ' '::text) AS client_name,
    p.address,
    p.city,
        CASE
            WHEN p.state IS NULL THEN NULL::text
            WHEN upper(translate(derm.fn_normalize_state_input(p.state), chr(201)||chr(233), 'Ee')) = ANY (ARRAY['FL'::text, 'FLORIDA'::text]) THEN 'FL'::text
            WHEN upper(translate(derm.fn_normalize_state_input(p.state), chr(201)||chr(233), 'Ee')) = ANY (ARRAY['CA'::text, 'CALIFORNIA'::text]) THEN 'CA'::text
            WHEN upper(translate(derm.fn_normalize_state_input(p.state), chr(201)||chr(233), 'Ee')) = ANY (ARRAY['NY'::text, 'NEW YORK'::text]) THEN 'NY'::text
            WHEN upper(translate(derm.fn_normalize_state_input(p.state), chr(201)||chr(233), 'Ee')) = ANY (ARRAY['QC'::text, 'QUEBEC'::text]) THEN 'QC'::text
            WHEN derm.fn_normalize_state_input(p.state) ~ '^[A-Za-z]{2}$'::text THEN upper(derm.fn_normalize_state_input(p.state))
            ELSE derm.fn_normalize_state_input(p.state)
        END AS state,
    p.zip,
    p.county,
    COALESCE(p.county = 'Dade'::text, false) AS pickup_in_dade,
    COALESCE(p.county = 'Dade'::text, false) OR m.white_manifest_number IS NOT NULL AS in_scope,
    ve.name AS truck,
    ve.grease_tank_capacity_gallons AS truck_capacity_gallons,
    NULL::integer AS gallons,
    m.id AS manifest_id,
    v.id AS visit_id
   FROM derm_manifests m
     JOIN manifest_visits mv ON mv.manifest_id = m.id
     JOIN visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL
     JOIN clients c ON c.id = m.client_id
     LEFT JOIN properties p ON p.id = v.property_id
     LEFT JOIN vehicles ve ON ve.id = v.vehicle_id
     LEFT JOIN disposal_facilities df ON df.id = m.disposal_facility_id
  WHERE m.deleted_at IS NULL;

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

  -- 1. the totals must not move. A presentation change that alters these means a JOIN or the
  --    WHERE was damaged while the body was regenerated -- the CREATE OR REPLACE failure mode.
  v_checks := v_checks + 1;
  IF r.all_rows <> 690 OR r.in_scope <> 589 OR r.tickets <> 126 THEN
    v_fail := v_fail || format(' [TOTALS MOVED: %s/%s/%s, expected 690/589/126]',
                               r.all_rows, r.in_scope, r.tickets);
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
  v_checks := v_checks + 1;
  IF r.name_nonascii <> 2 OR r.addr_nonascii <> 10 THEN
    v_fail := v_fail || format(' [ACCENTS: name=%s (want 2), addr=%s (want 10) -- if either is 0 a real business name and a real street are now misspelled on a county form]',
                               r.name_nonascii, r.addr_nonascii);
  END IF;

  -- 4. state is uniform, and nothing was invented
  v_checks := v_checks + 1;
  IF r.st_fl <> 676 OR r.st_null <> 14 THEN
    v_fail := v_fail || format(' [STATE: FL=%s (want 676), null=%s (want 14)]', r.st_fl, r.st_null);
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
        v_cps  int[]  := ARRAY[9,10,11,12,13,133,160,8192,8193,8194,8195,8196,8197,8198,8199,
                               8200,8201,8202,8232,8233,8239,8287,12288,
                               173,8203,8204,8205,8288,65279];
        v_zero int[]  := ARRAY[173,8203,8204,8205,8288,65279];
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

  IF v_fail <> '' THEN
    RAISE EXCEPTION 'LWT VERIFY FAILED (% checks):%', v_checks, v_fail;
  END IF;
  RAISE NOTICE 'LWT VERIFY: % checks passed', v_checks;
END $verify$;
