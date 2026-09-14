-- ============================================================================================
-- 2026-09-14_0605_generated_page_matcher.sql
--
-- The layout-guided matcher for GENERATED DERM address sheets, as read-only functions, so it can be
-- replayed over every accepted page (Phase 0 of the finisher plan) before anything writes.
--
-- Design: docs/superpowers/specs/2026-09-14-generated-sheet-auto-measure-and-complete-design.md
-- Plan:   docs/superpowers/plans/2026-09-14-generated-sheet-finisher.md (Task 2)
--
-- WHY. A generated sheet (number 1000+) is printed by our own pdf-service on the fixed DERM_V4.00
-- form: five Section B slots on every page, six printed boundaries, at positions that differ between
-- photographs by a uniform shift of 0.3 to 2pp. The Studio's blind classifier failed 835076 page 2
-- because one boundary is printed half-width in that scan. A page we printed needs no classifier:
-- the layout is a PRIOR, the scan is the MEASUREMENT.
--
-- THREE FUNCTIONS, NONE OF WHICH WRITES:
--   derm.fn_generated_template_boundaries()  the stamp-midpoint template, derived from
--                                            fn_generated_row_geometry (never typed); the first-pass
--                                            prior for Phase 0, superseded by fn_generated_page_prior
--   derm.fn_match_generated_page(...)        IMMUTABLE: raw lines + stamps + prior -> six boundaries
--                                            or a plain-language refusal
--   derm.fn_generated_page_cards(folder, pg) STABLE: the stamped cards of one image position with
--                                            their PRINTED row, or the plain-language refusal
--
-- EVERY REFUSAL IS A SENTENCE A PERSON CAN ACT ON (CLAUDE.md, Fred 2026-09-14); the technical
-- particulars ride in `detail`, which no app displays.
--
-- RULE 8: no table changes. Grants: service_role only (Phase 0 runs as postgres over the
-- Management API; the Studio never calls these).
-- ============================================================================================
BEGIN;

-- --------------------------------------------------------------------------------------------
-- PART 1. The template: six boundaries implied by the five stamp positions we print at.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_generated_template_boundaries()
RETURNS numeric[]
LANGUAGE sql IMMUTABLE
SET search_path TO 'derm', 'public'
AS $function$
  -- The midpoint between neighbouring stamps, and the same half-gap beyond the first and the last.
  -- This is exactly what derm.v_stamp_row_bands derives for a fully stamped generated page
  -- (25.84 / 33.76 / 41.10 / 48.145 / 55.925 / 64.155). It is a PRIOR and is never written anywhere;
  -- the printed lines on a real scan sit 0.0 to 0.75pp from it (measured on 835076, both pages).
  SELECT ARRAY[
           s[1] - (s[2] - s[1]) / 2,
           (s[1] + s[2]) / 2, (s[2] + s[3]) / 2, (s[3] + s[4]) / 2, (s[4] + s[5]) / 2,
           s[5] + (s[5] - s[4]) / 2 ]
    FROM (SELECT ARRAY(SELECT g.o_y_pct
                         FROM generate_series(1, 5) i
                        CROSS JOIN LATERAL derm.fn_generated_row_geometry(i) g
                        ORDER BY i) AS s) t;
$function$;

-- --------------------------------------------------------------------------------------------
-- PART 2. The matcher. Pure: reads no table, so the same function serves Phase 0 and the writer.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_match_generated_page(
  p_lines   jsonb,               -- [{pct, run, ...}] the detector's raw lines; kind is ignored
  p_stamps  jsonb,               -- [{row, y}] one entry per stamped card, row = printed row 1..5
  p_prior   numeric[],           -- the six expected boundaries
  p_search  numeric DEFAULT 2.5, -- window around each prior boundary when finding the page shift
  p_match   numeric DEFAULT 0.75,-- window around prior + shift when matching a boundary
  p_gap     numeric DEFAULT 0.75,-- tolerance on each slot gap against the printed gap
  p_clear   numeric DEFAULT 0.5, -- a stamp must sit this far inside both lines of its slot
  p_min_run numeric DEFAULT 0.35)-- a line shorter than this fraction of the form width is noise
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $function$
DECLARE
  v_pct   numeric[];  v_run numeric[];  v_n int;
  v_off   numeric[] := '{}';
  v_shift numeric;
  v_found numeric[] := '{}';  v_runs numeric[] := '{}';  v_res numeric[] := '{}';
  v_best  numeric;  v_bestd numeric;  v_bestj int;
  v_row   int;  v_y numeric;
  i int;  j int;
BEGIN
  IF p_prior IS NULL OR array_length(p_prior, 1) <> 6 THEN
    RETURN jsonb_build_object('ok', false,
      'reason', 'The printed layout for this sheet is not available, so it cannot be measured automatically.',
      'detail', 'prior must hold exactly 6 boundaries');
  END IF;

  -- 1. the usable lines: any width at or above p_min_run, in page order
  SELECT array_agg(x.pct ORDER BY x.pct), array_agg(x.run ORDER BY x.pct)
    INTO v_pct, v_run
    FROM (SELECT (e->>'pct')::numeric AS pct, (e->>'run')::numeric AS run
            FROM jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e) x
   WHERE x.pct IS NOT NULL AND x.run IS NOT NULL AND x.run >= p_min_run;
  v_n := coalesce(array_length(v_pct, 1), 0);
  IF v_n < 5 THEN
    RETURN jsonb_build_object('ok', false,
      'reason', 'The printed rows could not be found on this scan.',
      'detail', format('%s usable lines (run >= %s), need at least 5', v_n, p_min_run));
  END IF;

  -- 2. the page's uniform shift: for each prior boundary the nearest line within p_search; the
  --    shift is the MEDIAN offset so one wrong candidate cannot drag it. At least 5 of 6 must exist.
  FOR i IN 1 .. 6 LOOP
    v_best := NULL; v_bestd := NULL;
    FOR j IN 1 .. v_n LOOP
      IF abs(v_pct[j] - p_prior[i]) <= p_search
         AND (v_bestd IS NULL OR abs(v_pct[j] - p_prior[i]) < v_bestd) THEN
        v_best := v_pct[j]; v_bestd := abs(v_pct[j] - p_prior[i]);
      END IF;
    END LOOP;
    IF v_best IS NOT NULL THEN v_off := v_off || (v_best - p_prior[i]); END IF;
  END LOOP;
  IF coalesce(array_length(v_off, 1), 0) < 5 THEN
    RETURN jsonb_build_object('ok', false,
      'reason', 'The printed rows could not be found on this scan.',
      'detail', format('only %s of 6 boundaries have a line within %spp of the layout',
                       coalesce(array_length(v_off, 1), 0), p_search));
  END IF;
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY o) INTO v_shift FROM unnest(v_off) o;

  -- 3. each boundary: the line nearest to prior + shift, within p_match, whatever its width.
  --    This is the step the blind classifier cannot do: a half-width boundary is still the boundary.
  FOR i IN 1 .. 6 LOOP
    v_best := NULL; v_bestd := NULL; v_bestj := NULL;
    FOR j IN 1 .. v_n LOOP
      IF abs(v_pct[j] - (p_prior[i] + v_shift)) <= p_match
         AND (v_bestd IS NULL OR abs(v_pct[j] - (p_prior[i] + v_shift)) < v_bestd) THEN
        v_best := v_pct[j]; v_bestd := abs(v_pct[j] - (p_prior[i] + v_shift)); v_bestj := j;
      END IF;
    END LOOP;
    IF v_best IS NULL THEN
      RETURN jsonb_build_object('ok', false,
        'reason', 'A printed line between two rows is not visible on this scan.',
        'detail', format('boundary %s expected near %s (shift %s), no line within %spp',
                         i, round(p_prior[i] + v_shift, 3), round(v_shift, 3), p_match));
    END IF;
    v_found := v_found || v_best;
    v_runs  := v_runs  || v_run[v_bestj];
    v_res   := v_res   || round(v_best - (p_prior[i] + v_shift), 3);
  END LOOP;

  -- 4. ascending, and every slot gap within p_gap of the printed gap
  FOR i IN 2 .. 6 LOOP
    IF v_found[i] <= v_found[i-1]
       OR abs((v_found[i] - v_found[i-1]) - (p_prior[i] - p_prior[i-1])) > p_gap THEN
      RETURN jsonb_build_object('ok', false,
        'reason', 'The rows on this scan are not spaced like the printed sheet.',
        'detail', format('gap %s is %s, printed %s', i - 1,
                         round(v_found[i] - v_found[i-1], 3), round(p_prior[i] - p_prior[i-1], 3)));
    END IF;
  END LOOP;

  -- 5. every stamp strictly inside its own slot, with clearance from both lines
  FOR v_row, v_y IN
    SELECT (e->>'row')::int, (e->>'y')::numeric
      FROM jsonb_array_elements(coalesce(p_stamps, '[]'::jsonb)) e
  LOOP
    IF v_row IS NULL OR v_row < 1 OR v_row > 5 OR v_y IS NULL THEN
      RETURN jsonb_build_object('ok', false,
        'reason', 'A stamp on this page is not on any printed row.',
        'detail', format('stamp row %s y %s', v_row, v_y));
    END IF;
    IF NOT (v_y > v_found[v_row] + p_clear AND v_y < v_found[v_row + 1] - p_clear) THEN
      RETURN jsonb_build_object('ok', false,
        'reason', 'A stamp sits on the line between two rows. Place it again.',
        'detail', format('row %s stamp at %s, slot %s to %s, clearance %s',
                         v_row, v_y, v_found[v_row], v_found[v_row + 1], p_clear));
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true,
    'boundaries', to_jsonb(v_found), 'runs', to_jsonb(v_runs),
    'shift', round(v_shift, 3), 'residuals', to_jsonb(v_res), 'usable_lines', v_n);
END $function$;

-- --------------------------------------------------------------------------------------------
-- PART 3. The page's cards with their PRINTED row. Refuses, in plain words, every shape the matcher
-- must not be handed: a card not on the printed list, a card printed on another page, a client
-- printed on several rows (the 834986 lesson: the insert trigger stacks its cards on one row), two
-- stamps on one row, a stamp with a position but no placement.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_generated_page_cards(p_dump_folder text, p_page integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_ticket text; v_refusal text; v_detail text; v_cards jsonb; v_n int;
BEGIN
  SELECT r.white_manifest_number INTO v_ticket
    FROM derm.address_row_map r
   WHERE r.dump_folder = p_dump_folder AND r.white_manifest_number IS NOT NULL
   LIMIT 1;
  IF v_ticket IS NULL OR NOT coalesce(derm.fn_sheet_is_generated(v_ticket), false) THEN
    RETURN jsonb_build_object(
      'refusal', 'This sheet was not printed by us, so it cannot be measured automatically. Measure it with Draw the bands.',
      'detail', 'no generated-sheet link for ' || coalesce(v_ticket, p_dump_folder),
      'ticket', v_ticket, 'cards', '[]'::jsonb);
  END IF;

  WITH c AS (
    SELECT r.id, r.matched_client_id, r.stamp_y_pct, r.stamp_placed_at, s.slot,
           CASE WHEN s.slot IS NULL THEN NULL ELSE ((s.slot - 1) / 5) + 1 END AS printed_page,
           CASE WHEN s.slot IS NULL THEN NULL ELSE ((s.slot - 1) % 5) + 1 END AS row_on_page,
           (SELECT max(sc.rows_printed)
              FROM derm.address_sheet_manifests l
              JOIN derm.address_sheet_clients sc ON sc.sheet_id = l.sheet_id AND sc.slot = l.slot
             WHERE l.manifest_id = r.matched_manifest_id) AS rows_printed
      FROM derm.address_row_map r
      CROSS JOIN LATERAL (SELECT derm.fn_generated_sheet_slot(r.matched_manifest_id) AS slot) s
     WHERE r.dump_folder = p_dump_folder
       AND coalesce(r.stamp_page, r.page) = p_page
       AND r.stamp_y_pct IS NOT NULL
  )
  SELECT count(*),
         CASE
           WHEN count(*) = 0 THEN
             'Nothing has been stamped on this page yet.'
           WHEN bool_or(stamp_placed_at IS NULL) THEN
             'A stamp on this page has a position but was never actually placed. Place it again.'
           WHEN bool_or(slot IS NULL) THEN
             'A client on this page is not on the printed list of this sheet, so its row cannot be found automatically. A person needs to check this page in Draw the bands.'
           WHEN bool_or(derm.fn_sheet_image_position(p_dump_folder, printed_page) IS DISTINCT FROM p_page) THEN
             'A client on this page is printed on a different page of this sheet. A person needs to check this page in Draw the bands.'
           WHEN bool_or(rows_printed > 1) OR count(*) > count(DISTINCT matched_client_id) THEN
             'A client on this page is printed on several rows. Give it one card per permit and place each stamp on its own row, then measure the page with Draw the bands.'
           WHEN count(*) > count(DISTINCT row_on_page) THEN
             'Two stamps on this page sit on the same printed row. Place them again.'
         END,
         format('%s stamped cards, %s clients, %s without a printed slot, %s multi-row',
                count(*), count(DISTINCT matched_client_id),
                count(*) FILTER (WHERE slot IS NULL), count(*) FILTER (WHERE rows_printed > 1)),
         jsonb_agg(jsonb_build_object('row_id', id, 'client_id', matched_client_id,
                                      'row', row_on_page, 'y', stamp_y_pct)
                   ORDER BY row_on_page, id)
    INTO v_n, v_refusal, v_detail, v_cards
    FROM c;

  RETURN jsonb_build_object('refusal', v_refusal, 'detail', v_detail, 'ticket', v_ticket,
                            'cards', coalesce(v_cards, '[]'::jsonb));
END $function$;

-- --------------------------------------------------------------------------------------------
-- PART 4. Grants: the default privileges hand EXECUTE to authenticated; take it back.
-- --------------------------------------------------------------------------------------------
REVOKE ALL ON FUNCTION derm.fn_generated_template_boundaries() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_generated_template_boundaries() TO service_role;
REVOKE ALL ON FUNCTION derm.fn_match_generated_page(jsonb, jsonb, numeric[], numeric, numeric, numeric, numeric, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_match_generated_page(jsonb, jsonb, numeric[], numeric, numeric, numeric, numeric, numeric) TO service_role;
REVOKE ALL ON FUNCTION derm.fn_generated_page_cards(text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_generated_page_cards(text, integer) TO service_role;

-- --------------------------------------------------------------------------------------------
-- VERIFY. PL/pgSQL is not parsed at creation: every arm is CALLED here.
-- --------------------------------------------------------------------------------------------
DO $verify$
DECLARE
  v_prior numeric[] := derm.fn_generated_template_boundaries();
  v_ok    jsonb;   -- lines exactly on the template, run 0.99
  v_m     jsonb;
  v_cards jsonb;
  v_lines_835076_p1 jsonb := '[{"pct":14.317,"run":0.990},{"pct":23.789,"run":0.404},{"pct":26.125,"run":0.990},{"pct":30.19,"run":0.404},{"pct":34.343,"run":0.989},{"pct":37.716,"run":0.404},{"pct":41.047,"run":0.987},{"pct":44.291,"run":0.403},{"pct":48.227,"run":0.987},{"pct":51.903,"run":0.403},{"pct":56.012,"run":0.988},{"pct":59.689,"run":0.404},{"pct":63.754,"run":0.989},{"pct":66.912,"run":0.987},{"pct":69.247,"run":0.698}]';
  -- ticket-833049 page 1: a handwritten SIX-slot pad linked to a generated sheet record. The one
  -- page in the estate that MUST be refused: the matcher has no business on a form we did not print.
  v_lines_833049_p1 jsonb := '[{"pct":13.118,"run":0.719},{"pct":15.865,"run":0.981},{"pct":26.992,"run":0.359},{"pct":29.396,"run":0.980},{"pct":32.349,"run":0.368},{"pct":35.096,"run":0.981},{"pct":37.981,"run":0.359},{"pct":40.728,"run":0.982},{"pct":43.613,"run":0.366},{"pct":46.36,"run":0.982},{"pct":49.245,"run":0.359},{"pct":51.992,"run":0.983},{"pct":54.876,"run":0.363},{"pct":57.624,"run":0.984},{"pct":60.508,"run":0.361},{"pct":63.324,"run":0.984},{"pct":65.385,"run":0.984},{"pct":67.995,"run":0.983}]';
  v_stamps jsonb := '[{"row":1,"y":29.80},{"row":2,"y":37.72},{"row":3,"y":44.48},{"row":4,"y":51.81},{"row":5,"y":60.04}]';
  v_tech  text := '(_|\[|\]|jsonb|numeric|null|prior|boundary [0-9])';
  v_b     numeric[];
BEGIN
  -- 0. the template is the derived one, not a typed one
  IF v_prior IS DISTINCT FROM ARRAY[25.84, 33.76, 41.10, 48.145, 55.925, 64.155]::numeric[] THEN
    RAISE EXCEPTION 'VERIFY 0 FAILED: template is %', v_prior;
  END IF;
  SELECT jsonb_agg(jsonb_build_object('pct', p, 'run', 0.99)) INTO v_ok FROM unnest(v_prior) p;

  -- a. lines exactly on the template: accepted, shift 0, residuals 0
  v_m := derm.fn_match_generated_page(v_ok, v_stamps, v_prior);
  IF NOT (v_m->>'ok')::boolean OR (v_m->>'shift')::numeric <> 0
     OR (SELECT bool_or(r::numeric <> 0) FROM jsonb_array_elements_text(v_m->'residuals') r) THEN
    RAISE EXCEPTION 'VERIFY a FAILED: %', v_m;
  END IF;

  -- b. the same lines shifted by +2.4 (inside the search window): accepted, shift 2.4;
  --    shifted by +2.6 (outside it): refused
  v_m := derm.fn_match_generated_page((SELECT jsonb_agg(jsonb_build_object('pct', p + 2.4, 'run', 0.99)) FROM unnest(v_prior) p),
                                      '[]'::jsonb, v_prior);
  IF NOT (v_m->>'ok')::boolean OR (v_m->>'shift')::numeric <> 2.4 THEN RAISE EXCEPTION 'VERIFY b1 FAILED: %', v_m; END IF;
  v_m := derm.fn_match_generated_page((SELECT jsonb_agg(jsonb_build_object('pct', p + 2.6, 'run', 0.99)) FROM unnest(v_prior) p),
                                      '[]'::jsonb, v_prior);
  IF (v_m->>'ok')::boolean OR v_m->>'reason' <> 'The printed rows could not be found on this scan.' THEN
    RAISE EXCEPTION 'VERIFY b2 FAILED: %', v_m;
  END IF;

  -- c. a real generated page (835076 p1, the Node detector's output): accepted, the six known lines
  v_m := derm.fn_match_generated_page(v_lines_835076_p1, v_stamps, v_prior);
  v_b := ARRAY(SELECT r::numeric FROM jsonb_array_elements_text(v_m->'boundaries') r);
  IF NOT (v_m->>'ok')::boolean OR v_b IS DISTINCT FROM ARRAY[26.125, 34.343, 41.047, 48.227, 56.012, 63.754]::numeric[] THEN
    RAISE EXCEPTION 'VERIFY c FAILED: %', v_m;
  END IF;
  -- and the header (14.317) and footer (66.912) bars never got picked
  IF 14.317 = ANY(v_b) OR 66.912 = ANY(v_b) THEN RAISE EXCEPTION 'VERIFY c FAILED: a form bar was taken as a boundary'; END IF;

  -- d. a six-slot pad (833049 p1): refused, whatever the reason, and the reason is plain
  v_m := derm.fn_match_generated_page(v_lines_833049_p1, '[]'::jsonb, v_prior);
  IF (v_m->>'ok')::boolean THEN RAISE EXCEPTION 'VERIFY d FAILED: a handwritten pad was accepted: %', v_m; END IF;
  IF v_m->>'reason' !~ '^(A printed line between two rows is not visible on this scan\.|The rows on this scan are not spaced like the printed sheet\.|The printed rows could not be found on this scan\.)$' THEN
    RAISE EXCEPTION 'VERIFY d FAILED: unexpected reason %', v_m;
  END IF;

  -- e. one boundary missing (the 4th): refused as "not visible"
  v_m := derm.fn_match_generated_page((SELECT jsonb_agg(jsonb_build_object('pct', p, 'run', 0.99)) FROM unnest(v_prior) WITH ORDINALITY u(p, n) WHERE n <> 4),
                                      '[]'::jsonb, v_prior);
  IF (v_m->>'ok')::boolean OR v_m->>'reason' <> 'A printed line between two rows is not visible on this scan.' THEN
    RAISE EXCEPTION 'VERIFY e FAILED: %', v_m;
  END IF;

  -- f. a stamp on a line: refused
  v_m := derm.fn_match_generated_page(v_ok, '[{"row":1,"y":33.9}]'::jsonb, v_prior);
  IF (v_m->>'ok')::boolean OR v_m->>'reason' <> 'A stamp sits on the line between two rows. Place it again.' THEN
    RAISE EXCEPTION 'VERIFY f FAILED: %', v_m;
  END IF;

  -- g. a short line (run 0.20) and a mid-slot divider (run 0.40) added: ignored / not picked
  v_m := derm.fn_match_generated_page(v_ok || '[{"pct":30.0,"run":0.20},{"pct":30.3,"run":0.40}]'::jsonb, v_stamps, v_prior);
  v_b := ARRAY(SELECT r::numeric FROM jsonb_array_elements_text(v_m->'boundaries') r);
  IF NOT (v_m->>'ok')::boolean OR v_b IS DISTINCT FROM v_prior THEN RAISE EXCEPTION 'VERIFY g FAILED: %', v_m; END IF;

  -- h. two boundaries pushed towards each other by 0.7 each (each still matches, the gap does not)
  v_m := derm.fn_match_generated_page(
           (SELECT jsonb_agg(jsonb_build_object('pct', CASE n WHEN 3 THEN p + 0.7 WHEN 4 THEN p - 0.7 ELSE p END, 'run', 0.99))
              FROM unnest(v_prior) WITH ORDINALITY u(p, n)),
           '[]'::jsonb, v_prior);
  IF (v_m->>'ok')::boolean OR v_m->>'reason' <> 'The rows on this scan are not spaced like the printed sheet.' THEN
    RAISE EXCEPTION 'VERIFY h FAILED: %', v_m;
  END IF;

  -- i. a 5-element prior is refused up front
  v_m := derm.fn_match_generated_page(v_ok, '[]'::jsonb, v_prior[1:5]);
  IF (v_m->>'ok')::boolean THEN RAISE EXCEPTION 'VERIFY i FAILED'; END IF;

  -- j. no refusal sentence carries a technical word
  FOR v_m IN
    SELECT derm.fn_match_generated_page(l, s, v_prior)
      FROM (VALUES (v_lines_833049_p1, '[]'::jsonb), (v_ok, '[{"row":1,"y":33.9}]'::jsonb),
                   ('[]'::jsonb, '[]'::jsonb), (v_ok, '[{"row":9,"y":50}]'::jsonb)) t(l, s)
  LOOP
    IF (v_m->>'ok')::boolean OR v_m->>'reason' ~ v_tech THEN RAISE EXCEPTION 'VERIFY j FAILED: %', v_m; END IF;
  END LOOP;

  -- k. the page-card reader on live data (read-only)
  v_cards := derm.fn_generated_page_cards('ticket-835076', 1);
  IF v_cards->>'refusal' IS NOT NULL OR jsonb_array_length(v_cards->'cards') <> 5
     OR (SELECT array_agg((c->>'row')::int ORDER BY (c->>'row')::int) FROM jsonb_array_elements(v_cards->'cards') c) IS DISTINCT FROM ARRAY[1,2,3,4,5] THEN
    RAISE EXCEPTION 'VERIFY k1 FAILED: %', v_cards;
  END IF;
  v_cards := derm.fn_generated_page_cards('ticket-833395', 1);        -- 242-WYN: 3 printed rows, 1 card
  IF v_cards->>'refusal' IS NULL OR v_cards->>'refusal' ~ v_tech THEN RAISE EXCEPTION 'VERIFY k2 FAILED: %', v_cards; END IF;
  v_cards := derm.fn_generated_page_cards('ticket-834986', 1);        -- a pad page on a folder with a generated link
  IF v_cards->>'refusal' IS NULL OR v_cards->>'refusal' ~ v_tech THEN RAISE EXCEPTION 'VERIFY k3 FAILED: %', v_cards; END IF;
  v_cards := derm.fn_generated_page_cards('window4-sheet1', 1);       -- handwritten, no link at all
  IF v_cards->>'refusal' NOT LIKE 'This sheet was not printed by us%' THEN RAISE EXCEPTION 'VERIFY k4 FAILED: %', v_cards; END IF;
  v_cards := derm.fn_generated_page_cards('ticket-835076', 9);        -- a page that does not exist
  IF v_cards->>'refusal' <> 'Nothing has been stamped on this page yet.' THEN RAISE EXCEPTION 'VERIFY k5 FAILED: %', v_cards; END IF;

  -- l. grants
  IF has_function_privilege('authenticated', 'derm.fn_match_generated_page(jsonb, jsonb, numeric[], numeric, numeric, numeric, numeric, numeric)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'derm.fn_generated_page_cards(text, integer)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'derm.fn_generated_page_cards(text, integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY l FAILED: grants';
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: template derived, matcher accepts the template and a real page, refuses a pad, a missing line, a bad gap, a stamp on a line, and every refusal is plain language; page-card reader agrees with the live corpus.';
END
$verify$;

COMMIT;
