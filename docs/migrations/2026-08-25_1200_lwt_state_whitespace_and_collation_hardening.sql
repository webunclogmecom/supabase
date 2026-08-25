-- 2026-08-25_1200_lwt_state_whitespace_and_collation_hardening.sql
-- ---------------------------------------------------------------------------
-- Close two LATENT holes in the state mapping shipped this morning (2026-08-25_0400).
-- Found by the adversarial audit Fred asked for before the change was announced.
--
-- 🛑 NOTHING ABOUT THE INTENDED OUTCOME CHANGES, AND THAT IS THE POINT.
--
-- ⚠ CORRECTION 2026-08-25, found by the iteration-2 audit: THAT SENTENCE IS FALSE AS WRITTEN,
--   and only the audit's regression SKEPTIC caught it -- no dimension report named it.
--   Folding chr(201)/chr(233) to 'E'/'e' BEFORE upper() applies to the WHOLE value, not just
--   to the Quebec arm. So an accented NEW YORK now maps to 'NY' where it previously passed
--   through verbatim. That is a WIDENING of the mapping.
--   It is latent (0 of 921 rows) and safe in DIRECTION -- FLORIDA and CALIFORNIA contain no E,
--   so nothing can be falsely coerced to FL or CA, and the only reachable effect is that a
--   correctly-spelled accented state name is now recognised instead of printed raw.
--   Kept deliberately. But "nothing changes" was the wrong claim to make, and the honest
--   version is: no CURRENT value moves, and the recognised set is slightly wider.
--    Every value in the table today maps to exactly what it mapped to before:
--    690 rows / 589 in_scope / 126 tickets, state FL 676 + null 14, curly 0,
--    name_nonascii 2, addr_nonascii 10. Measured before and after. This migration
--    only makes the SAME rule survive inputs it would previously have fallen through.
--
-- ---------------------------------------------------------------------------
-- HOLE 1: `btrim()` STRIPS ASCII SPACE ONLY.
--
-- A TAB, NEWLINE, CR, NBSP or ZERO-WIDTH SPACE in `properties.state` defeated EVERY
-- branch of the CASE and landed on the county form verbatim. Measured through the live
-- view: `'Florida'` + NBSP came back as `466c6f72696461c2a0`, i.e. **the full state NAME
-- printed on a Miami-Dade compliance filing**, which is the exact outcome the explicit
-- mapping exists to prevent.
--
-- ⚠ IT IS REACHABLE, NOT THEORETICAL. `webhook-jobber` writes
--   `state: addr.province ?? 'FL'` (index.ts:607 and :1383) straight from Jobber free
--   text with no trim, and `??` does not catch an empty string.
-- ⚠ Latent TODAY: 0 of 921 property rows carry padding, NBSP, TAB, CR, NL or ZWSP.
--   That is why no value moves. It is a tripwire, not a repair.
--
-- 🛑 THIS IS THE SAME TRAP ALREADY RECORDED FOR `fn_requeue_derm_portal` (2026-08-24,
--    where a TAB/NEWLINE/NBSP reason defeated the required-reason guard entirely) --
--    recurring ONE MIGRATION LATER, written by the same session that documented it.
--    `btrim(x)` looks like "trim whitespace" and is not.
--
-- FIX: translate the five invisible characters to spaces, then btrim. `chr()` throughout
-- because backslash escapes get eaten in transit (this file's predecessor had `U&'\2019'`
-- arrive as `U&'9'`).
--
-- ---------------------------------------------------------------------------
-- HOLE 2: THE QUEBEC ARM RESTED ON AN UNPINNED COLLATION AND WOULD HAVE DIED SILENTLY.
--
-- The old arm compared `upper(btrim(p.state)) = 'QU' || chr(201) || 'BEC'`, which only
-- matches if `upper()` folds `é` to `É`. Under `en_US.UTF-8` (today, PG 17.6) it does.
-- Under `COLLATE "C"` it does not: `upper(<stored Québec> COLLATE "C")` is `'QUéBEC'`
-- and the comparison returns FALSE. The arm would stop working with no error, and
-- `2026-08-25_0400`'s VERIFY could not have seen it -- that check only asserted the
-- strings 'CALIFORNIA' and 'ELSE btrim' appear in `pg_get_viewdef`, both of which stay
-- TRUE with the accented arm deleted outright.
--
-- FIX: `translate(..., chr(201)||chr(233), 'Ee')` folds the accent explicitly, so the
-- comparison is plain ASCII under any collation.
--
-- 🛑 ORDER MATTERS AND THE OBVIOUS ORDER IS WRONG. translate() must run BEFORE upper(),
--    not after. `translate(upper(x), ...)` still depends on upper() having folded the
--    accent -- it re-introduces the very assumption being removed. `upper(translate(x))`
--    turns `Québec` into `Quebec` into `QUEBEC` under any collation.
--
-- ⚠ The stored value really is `Québec`, bytes 5175c3a9626563, on properties 234 and 882.
--   Neither has ever had a visit, so this arm has never fired on real data.
--
-- ---------------------------------------------------------------------------
-- ⚠ WHAT THIS DELIBERATELY DOES NOT DO:
--   - No new "empty string -> NULL" branch. A whitespace-only value now trims to '' and
--     falls to ELSE emitting '', which is what a literal '' already did. Adding a branch
--     would change an outcome for a case that does not exist, and `st_null` is asserted.
--   - The two-letter branch still has no USPS allow-list, so 'Zz' -> 'ZZ'. Unchanged and
--     accepted: the view cannot tell a real code from any two letters, and coercing an
--     unknown to 'FL' is the failure this whole design exists to avoid.
--   - `client_name` is not touched at all.
--
-- ⚠ The body is `pg_get_viewdef` output with ONE block substituted (scratchpad genlwt2.js),
--   diffed against the live body line by line with a positive control: the ONLY difference
--   is the six state lines. Never retyped -- CREATE OR REPLACE takes the whole body.
--
-- Audit (Rule 8): one view body. No table, column or grant on any audited table changes.
-- Column list and types unchanged, so CREATE OR REPLACE preserves grants.
--
-- @Building Apps. Claimed in WORKING-NOW.md.

BEGIN;

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
            WHEN upper(translate(btrim(translate(p.state, chr(9)||chr(10)||chr(13)||chr(160)||chr(8203), '     ')), chr(201)||chr(233), 'Ee')) = ANY (ARRAY['FL'::text, 'FLORIDA'::text]) THEN 'FL'::text
            WHEN upper(translate(btrim(translate(p.state, chr(9)||chr(10)||chr(13)||chr(160)||chr(8203), '     ')), chr(201)||chr(233), 'Ee')) = ANY (ARRAY['CA'::text, 'CALIFORNIA'::text]) THEN 'CA'::text
            WHEN upper(translate(btrim(translate(p.state, chr(9)||chr(10)||chr(13)||chr(160)||chr(8203), '     ')), chr(201)||chr(233), 'Ee')) = ANY (ARRAY['NY'::text, 'NEW YORK'::text]) THEN 'NY'::text
            WHEN upper(translate(btrim(translate(p.state, chr(9)||chr(10)||chr(13)||chr(160)||chr(8203), '     ')), chr(201)||chr(233), 'Ee')) = ANY (ARRAY['QC'::text, 'QUEBEC'::text]) THEN 'QC'::text
            WHEN btrim(translate(p.state, chr(9)||chr(10)||chr(13)||chr(160)||chr(8203), '     ')) ~ '^[A-Za-z]{2}$'::text THEN upper(btrim(translate(p.state, chr(9)||chr(10)||chr(13)||chr(160)||chr(8203), '     ')))
            ELSE btrim(translate(p.state, chr(9)||chr(10)||chr(13)||chr(160)||chr(8203), '     '))
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
-- 🛑 SUPERSEDED. DO NOT RUN THIS BLOCK. IT GOES RED ON A HEALTHY DATABASE.
--
--    It pins `all_rows <> 690 OR in_scope <> 589 OR tickets <> 126` and `st_fl <> 676`, which
--    were the true values on 2026-08-25 and stopped being true the same morning, when Diego
--    filed ticket 833813 and ten legitimate rows appeared. Running it now reports
--    "[TOTALS MOVED: 700/599/127, expected 690/589/126]" -- a green database described as broken.
--
--    ⇒ **THE CANONICAL, GROWTH-PROOF BLOCK IS IN
--      `docs/migrations/2026-08-25_1500_lwt_normalizer_grant_and_category_close.sql`.**
--      It compares the view against an INDEPENDENT BASE-TABLE RECOMPUTATION at the same instant
--      instead of against a remembered number, asserts state structurally, names the accent
--      CARRIERS rather than counting them, and SET ROLEs to pg_read_all_data for the privilege
--      check. Mutation-tested; it RAISES its own check count on success, which is why no
--      number is quoted here -- the count is data-dependent and a pinned one goes stale.
--
--    The pinned assertions below are LEFT AS WRITTEN on purpose: this file is a dated record of
--    what was asserted when it was applied, and rewriting it would falsify that. But the
--    "run it any time" promise underneath was wrong within hours, so it is withdrawn here.
--
--    🛑 THE LESSON, which this estate had already written down one day earlier in
--       2026-08-25_0110 and which I then did the opposite of:
--       **do not hard-code an expected breakdown against live data.** Compare two live reads of
--       the same instant. A re-runnable check that fails on normal business activity is worse
--       than no check -- it trains whoever runs it to ignore a red result.
-- ---------------------------------------------------------------------------

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
