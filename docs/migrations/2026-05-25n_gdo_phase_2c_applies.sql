-- 2026-05-25n_gdo_phase_2c_applies.sql
--
-- Phase 2c bot-batch applies. Generated from
--   docs/gdo-phase-2-2026-05-25/probes/12_phase_2c_results.json
-- via
--   docs/gdo-phase-2-2026-05-25/probes/13_phase_2c_analyze.py
--
-- Auto-applies per Viktor 2026-05-25 PM standing rule:
--   "no need for me to pre-approve the migration pattern anymore.
--    Just flag anything that doesn't fit the established buckets."
--
-- Deferred buckets (NOT in this migration; surfaced to Viktor separately):
--   1 WRONG_GDO_NUMBER - bot name_match unreliable in this batch (e.g., Talmudic Univ -> IHOP)
--   1 WRONG_CLIENT SUSPECT_NAME_VARIATION - might be name-variation matches
--   0 DIFFERENT_TENANT with name similarity
--   0 AMBIGUOUS/ERROR
--
-- SCOPE (auto-applied)
--   12 CONFIRMED_MATCH UPDATEs
--   9 WRONG_CLIENT DEMOTEs (low name similarity)
--   3 DIFFERENT_TENANT DEMOTEs (low name similarity)
--   0 NO_PERMIT DEMOTEs
--
-- IDEMPOTENT (Rule 5) · AUDIT (Rule 8) · NEVER HARD-DELETE (Rule 6)

BEGIN;

-- ============================================================
-- 1. 12 CONFIRMED_MATCH UPDATEs
-- ============================================================

UPDATE public.gdos SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] CONFIRMED_MATCH via @GDO bot. issued_to="LA GRANJA ALLAPATTAH CORP DBA LA GRANJA CHICKEN STEAK AND SE", facility_name="LA CENIZA MINI MARKET", max_frequency_days=90.'
WHERE id = 76 AND gdo_number = 'GDO-09017'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

UPDATE public.gdos SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] CONFIRMED_MATCH via @GDO bot. issued_to="LA GRANJA FLAGLER CORPORATION DBA LA GRANJA CHICKEN STEAK AN", facility_name="CHICKEN KITCHEN", max_frequency_days=90.'
WHERE id = 78 AND gdo_number = 'GDO-09077'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

UPDATE public.gdos SET max_frequency_days = 30,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] CONFIRMED_MATCH via @GDO bot. issued_to="HIRO''S SUSHI EXPRESS", facility_name="SUSHI EXPRESS", max_frequency_days=30.'
WHERE id = 79 AND gdo_number = 'GDO-06989'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 30);

UPDATE public.gdos SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] CONFIRMED_MATCH via @GDO bot. issued_to="INTERNATIONAL FOODS BY NONI LLC", facility_name="INTERNATIONAL FOODS BY NONI LLC", max_frequency_days=90.'
WHERE id = 81 AND gdo_number = 'GDO-15359'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

UPDATE public.gdos SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] CONFIRMED_MATCH via @GDO bot. issued_to="BET SHIRA CONGREGATION", facility_name="BET SHIRA CONGREGATION", max_frequency_days=90.'
WHERE id = 85 AND gdo_number = 'GDO-05180'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

UPDATE public.gdos SET max_frequency_days = 30,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] CONFIRMED_MATCH via @GDO bot. issued_to="ZTB I, LLC DBA ZAK THE BAKER", facility_name="ZAK THE BAKER 2", max_frequency_days=30.'
WHERE id = 91 AND gdo_number = 'GDO-11186'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 30);

UPDATE public.gdos SET max_frequency_days = 60,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] CONFIRMED_MATCH via @GDO bot. issued_to="CORNER ESPANOLA LLC. DBA. THE JOYCE", facility_name="TAPAS & TINTOS RESTAURANT", max_frequency_days=60.'
WHERE id = 93 AND gdo_number = 'GDO-03917'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 60);

UPDATE public.gdos SET max_frequency_days = 30,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] CONFIRMED_MATCH via @GDO bot. issued_to="CHOW DOWN GRILL, INC. DBA JOSH''S DELI", facility_name="ARTICHAUX GOURMET GALLERIE", max_frequency_days=30.'
WHERE id = 96 AND gdo_number = 'GDO-00992'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 30);

UPDATE public.gdos SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] CONFIRMED_MATCH via @GDO bot. issued_to="LETTUCE & TOMATO RESTAURANT, LLC", facility_name="LUNA CREPESSE GOURMET DELI & BISTRO", max_frequency_days=90.'
WHERE id = 102 AND gdo_number = 'GDO-08912'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

UPDATE public.gdos SET max_frequency_days = 60,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] CONFIRMED_MATCH via @GDO bot. issued_to="PURA VIDA MIAMI, LLC DBA PURA VIDA CAFETERIA", facility_name="PURA VIDA SMOOTHIE BAR", max_frequency_days=60.'
WHERE id = 107 AND gdo_number = 'GDO-07696'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 60);

UPDATE public.gdos SET max_frequency_days = 30,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] CONFIRMED_MATCH via @GDO bot. issued_to="SANTA TERESA GROUP LLC DBA 100 MONTADITOS", facility_name="SANTA TERESA GROUP LLC DBA 100 MONTADITOS", max_frequency_days=30.'
WHERE id = 112 AND gdo_number = 'GDO-13822'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 30);

UPDATE public.gdos SET max_frequency_days = 60,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] CONFIRMED_MATCH via @GDO bot. issued_to="PURA VIDA BRICKELL LLC DBA PURA VIDA MIAMI", facility_name="SUMI YAKTORI AT MILICENTO", max_frequency_days=60.'
WHERE id = 117 AND gdo_number = 'GDO-11228'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 60);

-- ============================================================
-- 2. 9 WRONG_CLIENT DEMOTEs
-- ============================================================

-- id=75 GDO-00548 (200-PALO Palomar)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] DEMOTED. GDO-00548 actually belongs to "SOBE ALTON LLC DBA OSTERIA MORINI" per @GDO bot. Palomar has no DERM permit at its address.'
WHERE id = 75 AND gdo_number = 'GDO-00548' AND status = 'ACTIVE';

-- id=82 GDO-04127 (042-MT Miami twist LLC)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] DEMOTED. GDO-04127 actually belongs to "PESKARA, LLC DBA DENNY''S #7134" per @GDO bot. Miami twist LLC has no DERM permit at its address.'
WHERE id = 82 AND gdo_number = 'GDO-04127' AND status = 'ACTIVE';

-- id=97 GDO-14934 (180-PV Pura Vida Kendall)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] DEMOTED. GDO-14934 actually belongs to "JEN''S CHICKEN PEN, INC. DBA CHICK-FIL-A EAST DORAL DTO" per @GDO bot. Pura Vida Kendall has no DERM permit at its address.'
WHERE id = 97 AND gdo_number = 'GDO-14934' AND status = 'ACTIVE';

-- id=104 GDO-11433 (176-SOU What Soup)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] DEMOTED. GDO-11433 actually belongs to "TIGER LIGHT, LLC DBA TAULA FRESH MEDITERRANEAN FOOD" per @GDO bot. What Soup has no DERM permit at its address.'
WHERE id = 104 AND gdo_number = 'GDO-11433' AND status = 'ACTIVE';

-- id=105 GDO-13175 (130-RL Richard Lonnie)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] DEMOTED. GDO-13175 actually belongs to "OUTBACK STEAKHOUSE OF FLORIDA LLC DBA: OUTBACK STEAKHOUSE" per @GDO bot. Richard Lonnie has no DERM permit at its address.'
WHERE id = 105 AND gdo_number = 'GDO-13175' AND status = 'ACTIVE';

-- id=108 GDO-04400 (038-LR Le rond)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] DEMOTED. GDO-04400 actually belongs to "3500 HOTEL LLC. DBA CAMPO" per @GDO bot. Le rond has no DERM permit at its address.'
WHERE id = 108 AND gdo_number = 'GDO-04400' AND status = 'ACTIVE';

-- id=109 GDO-05395 (153-LTC LTC Rentals)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] DEMOTED. GDO-05395 actually belongs to "VIVARIA FLORIDA, LLC DBA LANDSHARK BAR & GRILL BY MARGARITAV" per @GDO bot. LTC Rentals has no DERM permit at its address.'
WHERE id = 109 AND gdo_number = 'GDO-05395' AND status = 'ACTIVE';

-- id=111 GDO-07564 (118-MRJ Mr Jones)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] DEMOTED. GDO-07564 actually belongs to "VENTURA CAPITAL ONE, LLC DBA CAVALIER HOTEL & RESTAURANT" per @GDO bot. Mr Jones has no DERM permit at its address.'
WHERE id = 111 AND gdo_number = 'GDO-07564' AND status = 'ACTIVE';

-- id=116 GDO-03620 (000-DH Homestead Dump)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] DEMOTED. GDO-03620 actually belongs to "MDCPS-HORACE MANN MIDDLE SCHOOL" per @GDO bot. Homestead Dump has no DERM permit at its address.'
WHERE id = 116 AND gdo_number = 'GDO-03620' AND status = 'ACTIVE';

-- ============================================================
-- 3. 3 DIFFERENT_TENANT DEMOTEs
-- ============================================================

-- id=89 GDO-11230 (037-LB Le Basilic)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] DEMOTED. GDO-11230 does not appear at this address per @GDO bot. Address belongs to GDO-16296 "SHELBORNE HOTEL PARTNERS WC LP DBA PAULINE" - different tenant. Le Basilic has no DERM permit here.'
WHERE id = 89 AND gdo_number = 'GDO-11230' AND status = 'ACTIVE';

-- id=94 GDO-08682 (012-DKC Danziguer Kosher Catering)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] DEMOTED. GDO-08682 does not appear at this address per @GDO bot. Address belongs to GDO-03278 "FAIRFIELD INN & SUITES" - different tenant. Danziguer Kosher Catering has no DERM permit here.'
WHERE id = 94 AND gdo_number = 'GDO-08682' AND status = 'ACTIVE';

-- id=113 GDO-06550 (128-MF Meir Fellig)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2c] DEMOTED. GDO-06550 does not appear at this address per @GDO bot. Address belongs to GDO-03662 "MDCPS-PALM SPRINGS NORTH ELEMENTARY" - different tenant. Meir Fellig has no DERM permit here.'
WHERE id = 113 AND gdo_number = 'GDO-06550' AND status = 'ACTIVE';

COMMIT;

-- ============================================================
-- VERIFICATION
-- ============================================================
-- 1. ACTIVE count
--    SELECT COUNT(*) FILTER (WHERE status='ACTIVE')::int FROM public.gdos;
--    Expected: 111 - 12 = 99
-- 2. max_frequency_days non-NULL count
--    SELECT COUNT(*) FROM public.gdos WHERE max_frequency_days IS NOT NULL;
--    Expected: 34 + 12 + (in-place freq sets) = approx
-- 3. Audit rows
--    SELECT app_source, operation, COUNT(*) FROM audit.logs
--    WHERE table_name='gdos' AND changed_at > now() - interval '5 minutes'
--    GROUP BY app_source, operation;