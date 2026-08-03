-- 2026-08-03b — Retitle line item 28 to match Jobber
--
-- WHY (Fred, 2026-08-03): "I changed the line 28 in the sheet and in jobber to be a SC line item,
-- it's now '28 - Service Call - Dump' and that's it, you can check Jobber for it."
--
-- Jobber is source of truth for the catalogue name. MEASURED via the Jobber GraphQL `products` root
-- field (version 2026-04-16), paginated to exhaustion (63 of 63):
--   name '28 - Service Call - Dump', gid://Jobber/ProductOrService/51248786, category SERVICE,
--   durationMinutes 60, defaultUnitCost 0.
--   Controls: names matching ^28 = 1; positive controls ^27/^01/^08 = 1 each; negative ^99 = 0.
--
-- ⚠ NOTHING SYNCS service_line_items FROM JOBBER. All 27 audit rows on the table are
-- app_source='sql' and every writer is a hand-written migration, so this row WILL drift again.
-- Same situation and same remedy as 2026-07-18g (code 02 typo). Code 13 is still drifted today by
-- deliberate decision ('Auxiliary Line Cleaning' vs Jobber's 'Aux Cleaning').
--
-- AUDIT: opt-out. Reference/catalogue table, one-column cosmetic correction.
--
-- ── WHY THIS IS SAFE (measured before applying) ────────────────────────────────────────────────
--   `title` participates in NO join. ops.client_service_options joins on
--     sli.code = lpad(substring(btrim(li.name),'^([0-9]+)'),2,'0')
--   and BOTH the old and the new name extract to '28':
--     '28 - Service Call - Dump'        -> '28'
--     '28 - Disposal - Dump Offload'    -> '28'
--     '  28 - Service Call - Dump'      -> '28'   (leading space)
--     negative control 'Service Call - Dump' -> NULL
--   0 DB objects compare service_line_items.title for equality.
--   0 of the 7 live app bundles hardcode any catalogue title (all read it from the DB at runtime);
--     each bundle walked to closure with a backtick-aware matcher, with per-bundle controls.
--   The 51 existing public.line_items rows still carrying the OLD name are deliberately left alone,
--     per the 2026-07-18g precedent: they are historical Jobber line text, not catalogue rows.
--
-- service_kind stays 'Dump Offload' on purpose: `reason` classifies SA/SC/fee, `service_kind`
-- describes the work, and ops.fn_service_group returns NULL for it either way, so the Visit
-- Calendar's SA chip colour system is untouched.

BEGIN;

UPDATE public.service_line_items
   SET title = '28 - Service Call - Dump'
 WHERE code = '28';

DO $$
DECLARE v_title text; v_sc int; v_joined int;
BEGIN
  SELECT title INTO v_title FROM public.service_line_items WHERE code = '28';
  SELECT count(*) INTO v_sc   FROM public.service_line_items
   WHERE reason = 'Service Call' AND active AND schedulable;
  SELECT count(*) INTO v_joined FROM public.line_items li
     JOIN public.service_line_items s
       ON s.code = lpad(substring(btrim(li.name), '^([0-9]+)'), 2, '0')
    WHERE s.code = '28';

  IF v_title <> '28 - Service Call - Dump' THEN
    RAISE EXCEPTION 'title not applied, got %', v_title;
  END IF;
  IF v_sc <> 17 THEN
    RAISE EXCEPTION 'expected 17 selectable SC codes, found % — the catalogue regressed', v_sc;
  END IF;
  IF v_joined <> 51 THEN
    RAISE EXCEPTION 'expected 51 line_items to still join to code 28, found % — extraction broke', v_joined;
  END IF;
  RAISE NOTICE 'OK: retitled, % SC codes, % line_items still joining', v_sc, v_joined;
END $$;

COMMIT;

-- APPLIED to Prod 2026-08-03. Verified after: title matches Jobber exactly, 17 selectable SC codes,
-- 51 line_items still joining to code 28.
