-- 2026-05-25q_gdo_phase_2d_deferrals.sql
--
-- Phase 2d deferrals — 2 rows. Auto-applied per Viktor's standing rule:
-- both fit established buckets that were previously approved per case.
--
--   1. 171-CAF Ironside Cafe (id=99) — WRONG_GDO_NUMBER in-place rename.
--      Bot: issued_to "THE OM CENTER, LLC DBA PIZZA AT IRONSIDE" shares
--      "Ironside" with our client. Same pattern as Pummarola typo fix in
--      25o. Pre-flight: target GDO-10249 not present elsewhere.
--   2. 011-CCC Cine Citta Cafe (Franck Taieb) (id=86) — Reclassify
--      WRONG_CLIENT -> CONFIRMED_MATCH. Bot's issued_to "CINE CITTA, LLC"
--      matches client name (difflib sim=0.61, shared=cine+citta). Bot's
--      name_match=false was a false negative (likely tripped by "Franck
--      Taieb" suffix). Same pattern as Grove Kosher / Pura Vida Bay Harbor
--      in 25o.
--
-- IDEMPOTENT (Rule 5) · AUDIT (Rule 8) · NEVER HARD-DELETE (Rule 6)

BEGIN;

-- 171-CAF Ironside Cafe (id=99): GDO-10248 -> GDO-10249
UPDATE public.gdos
SET gdo_number = 'GDO-10249',
    max_frequency_days = 90,
    permit_expiration = '2026-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2d deferral] WRONG_GDO_NUMBER corrected from GDO-10248 to GDO-10249 per @GDO bot lookup. issued_to="THE OM CENTER, LLC DBA PIZZA AT IRONSIDE" — name overlap on "Ironside". max_frequency_days=90, expiration set to current cycle. Auto-applied per Viktor''s standing rule (same pattern as Pummarola/Talmudic in 25o).'
WHERE id = 99 AND gdo_number = 'GDO-10248';

-- 011-CCC Cine Citta Cafe (Franck Taieb) (id=86) — reclassify CONFIRMED_MATCH
UPDATE public.gdos
SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2d deferral] Reclassified WRONG_CLIENT -> CONFIRMED_MATCH per difflib (sim=0.61, shared=cine/citta). Bot issued_to="CINE CITTA, LLC" matches client; bot.name_match=false was a false negative (tripped by "Franck Taieb" suffix). Bot freq=90 trusted. Auto-applied per Viktor''s standing rule.'
WHERE id = 86 AND gdo_number = 'GDO-05625'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

COMMIT;

-- ============================================================
-- VERIFICATION
-- ============================================================
-- SELECT id, gdo_number, max_frequency_days, status FROM public.gdos WHERE id IN (86, 99);
-- Expected: 86 GDO-05625 90 ACTIVE, 99 GDO-10249 90 ACTIVE
