-- 2026-08-06_1448_fee_lines_are_derm_neutral.sql
--
-- Client App fee lines, SC step 1 of 3: MAKE A FEE LINE DERM-NEUTRAL.
-- 🛑 THIS MUST SHIP BEFORE fee lines are ever mirrored onto Service Call jobs.
--
-- WHY, AND WHY IT IS A COMPLIANCE ISSUE RATHER THAN A TIDY-UP
-- ----------------------------------------------------------
-- `fn_line_item_requires_derm` currently answers FALSE for codes 25/26/27, because the
-- catalogue's `requires_derm` column is NOT NULL and those rows carry false.
--
-- On code 05 (Main Line Cleaning) FALSE is a genuine statement: a cleaning service really
-- does not require DERM. On a CREDIT CARD FEE it is not a statement at all — a payment fee
-- says NOTHING about whether the work needed a manifest. Storing "no" where the truth is
-- "this line does not say" is what makes the next step dangerous:
--
--   `fn_visit_requires_derm` folds the reachable lines with bool_or. A Service Call visit
--   today reaches NO job-scoped line, so it derives NULL — "unknown", which every consumer
--   treats as REQUIRED (`customer.work_orders` ends `COALESCE(v.derm_required, true) = true`).
--   The moment a fee line is mirrored onto that job, the visit reaches exactly one line, that
--   line answers FALSE, and the visit derives FALSE — "definitively not required". The nightly
--   `derm-required-rederive` writes precisely that NULL->FALSE fill, and the monotonic guard
--   only blocks demoting a known TRUE, so nothing stops it.
--
--   ⇒ 33 live visits across 22 non-SA jobs sit in exactly that shape. Without this migration,
--     enabling SC fees silently EVICTS them from the client's DERM compliance surface — the
--     view Fred ruled on 2026-08-05 is the compliance record by design.
--
-- MEASURED IMPACT TODAY: **ZERO**, and the zero is instrumented.
--   visits reaching a fee line ............. 826   <- POSITIVE CONTROL, must be non-zero
--   visits with any reachable line ........ 1741
--   visits whose derive CHANGES ............... 0
-- On every visit that reaches a fee today, a real service line already decides the outcome
-- through bool_or, so nothing moves. This is a guard being installed before the hazard, not a
-- repair.
--
-- ⚠ THE FIRST VERSION OF THAT MEASUREMENT WAS VACUOUS AND SAID "0 of 1741" TOO.
-- The regex was written `'^\\s*2[567]\\s*-'` from a JS string, and a DOUBLED backslash in SQL
-- is a LITERAL backslash, so it matched nothing: the control returned 0 visits reaching a fee
-- line, which is impossible with 166 fee rows live. This is the exact inversion documented in
-- CLAUDE.md. Rewritten with the escape-free POSIX class `[[:space:]]`, the control returned
-- 826 and the real answer was still 0 — but only the second one means anything.
-- ⇒ Never accept a 0 here without the control printed beside it.
--
-- WHY THE FUNCTION AND NOT THE CATALOGUE COLUMN: `service_line_items.requires_derm` is
-- NOT NULL, so "this line does not say" cannot be expressed there without widening the column
-- for all 28 rows. The function is the semantic layer and the right place for the distinction.
--
-- SCOPE, DELIBERATELY NARROW: only the AUTHORITATIVE taxonomy branch (a) is changed, which is
-- what a mirrored line always hits ("25 - Credit card fee (3.53%)" carries its code prefix).
-- The free-text branch (c) still answers FALSE for a fee-ish string, because that same regex
-- also covers cleaning/camera/labour where FALSE genuinely IS evidence. Splitting it is a
-- separate change with its own blast radius.
--
-- CONSUMERS (generated, not assumed): public.edit_calendar_visit, public.fn_generate_sa_visits,
-- public.fn_visit_requires_derm. All three use it for the same derivation, so the semantics
-- stay consistent across them.
--
-- AUDIT (rule 8): no table touched, no new object. Pure function replacement.
--
-- ROLLBACK: re-apply the previous body (drop the `reason IN ('fee','other')` CASE arm).

CREATE OR REPLACE FUNCTION public.fn_line_item_requires_derm(p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT CASE
    WHEN p_name IS NULL OR btrim(p_name) = '' THEN NULL
    -- (a) taxonomy-formatted "NN - ..." -> authoritative flag by code.
    --     ⚠ A fee/admin line answers NULL, not FALSE: it does not say whether the work
    --     needed a manifest, and FALSE would be read as "definitively not required".
    WHEN substring(btrim(p_name) from '^([0-9]{1,2})\s*-\s') IS NOT NULL THEN
      (SELECT CASE WHEN s.reason IN ('fee', 'other') THEN NULL ELSE s.requires_derm END
         FROM public.service_line_items s
        WHERE s.code = lpad(substring(btrim(p_name) from '^([0-9]{1,2})\s*-\s'), 2, '0'))
    -- (b) free-text PUMPING: a regulated vessel (grease trap/interceptor, grey water, lift station)
    --     near a pump word (either order), or an explicit pump-out (any word-form).
    WHEN btrim(p_name) ~* '(grease\s*tr?ap|grease\s*interceptor|interceptor|grey\s*water|greywater|(lift|lyft)\s*station)[^,]*pump'
      OR btrim(p_name) ~* 'pump[a-z]*[^,]*(grease\s*tr?ap|grease\s*interceptor|interceptor|grey\s*water|greywater|(lift|lyft)\s*station)'
      OR btrim(p_name) ~* 'pump(ed|ing|s)?\s*[- ]?out'
      THEN true
    -- (c) free-text recognized NON-pumping services / parts / fees
    --     ⚠ Left answering FALSE on purpose: this same branch covers clean/hydrojet/camera/
    --     labour, where FALSE is real evidence. Narrowing it is a separate change.
    WHEN btrim(p_name) ~* '(clean|hydrojet|unclog|camera|dye|assess|inspect|labou?r|\mpart|warrant|fee|tax|gdo|manifest|report|faucet|toilet|pipe|drain|install|repair|replace|locator|leak|smell|pictur|material|supply|\mdig|concret|cover|barrier|discount|credit|tip|commissary|ceiling|sump|plumb|cancel|removal|sample|mop|connection|brass|tapcon|union|p-?trap|reconnect|reinstal|drill|valve|emergency\s*visit|manhole|driver)'
      THEN false
    ELSE NULL
  END
$function$;

COMMENT ON FUNCTION public.fn_line_item_requires_derm(text) IS
  'Does this line item NAME indicate DERM was required? TRUE = yes, FALSE = it says no, '
  'NULL = it does not say. Fee/admin catalogue lines (reason fee/other, codes 25/26/27) answer '
  'NULL by design: a payment fee is not evidence that no manifest was needed, and FALSE would '
  'evict the visit from customer.work_orders. See 2026-08-06_1448_fee_lines_are_derm_neutral.sql.';
