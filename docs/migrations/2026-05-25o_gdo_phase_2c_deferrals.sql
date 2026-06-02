-- 2026-05-25o_gdo_phase_2c_deferrals.sql
--
-- Phase 2c deferrals applied per Viktor 2026-05-25 PM approval on each.
-- All 9 deferrals from the 2026-05-25n analyzer's "needs human" buckets.
--
-- SCOPE
--   1. 2 in-place gdo_number UPDATEs (Pummarola typo, Talmudic Univ -> Talmudic College)
--   2. 3 DEMOTEs (Pura Vida Brickell 701 conflict, Roast + Street Bar bot false-positives)
--   3. 4 CONFIRMED_MATCH UPDATEs reclassified from WRONG_CLIENT (bot misclassified —
--      issued_to and difflib name similarity both confirm match):
--        - 017-FIA Florida Food Eats Fialkoff's (Surfside)
--        - 072-TCE The carrot express Sunset Harbor
--        - 049-PV  Pura Vida (Bay Harbor)
--        - 025-GRO Grove Kosher LLC (Harding Ave)
--
-- PRE-FLIGHT CONFLICT CHECK (Viktor's standing rule, applied before writing):
--   - GDO-00951 (Pummarola target): NOT present in DB → safe in-place
--   - GDO-00313 (Talmudic target):  NOT present in DB → safe in-place
--   - GDO-11228 (Pura Vida Brickell 701 target): EXISTS at id=117 (050-PV
--     Pura Vida Brickell, same address 1104 S Miami Ave) → DEMOTE id=27,
--     don't UPDATE. id=117 already has the correct GDO-11228.
--
-- TODO FOR FRED/YAN/OPS — third duplicate-client pair surfaced:
--   175-PV "Pura Vida Brickell 701" (id=27)  vs  050-PV "Pura Vida Brickell" (id=117)
--   Same address: 1104 South Miami Avenue. Add to the cleanup list alongside
--   Kosh/Grove Kosher and Nu Real x2.
--
-- IDEMPOTENT (Rule 5) · AUDIT (Rule 8) · NEVER HARD-DELETE (Rule 6)

BEGIN;

-- ============================================================
-- 1. 2 in-place gdo_number UPDATEs
-- ============================================================

-- 132-PUM Pummarola (id=62): GDO-000951 -> GDO-00951 (extra-zero typo fix)
UPDATE public.gdos
SET gdo_number = 'GDO-00951',
    max_frequency_days = 30,
    permit_expiration = '2026-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2c deferral] WRONG_GDO_NUMBER corrected from GDO-000951 to GDO-00951 (typo fix — leading-zero error) per @GDO bot lookup. issued_to="SOUTH BEACH EXPRESS LLC DBA PUMMAROLA", max_frequency_days=30. Viktor approved 2026-05-25 PM.'
WHERE id = 62 AND gdo_number = 'GDO-000951';

-- 060-TU Talmudic University (id=57): GDO-13076 -> GDO-00313
UPDATE public.gdos
SET gdo_number = 'GDO-00313',
    max_frequency_days = 90,
    permit_expiration = '2026-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2c deferral] WRONG_GDO_NUMBER corrected from GDO-13076 to GDO-00313 per @GDO bot lookup. issued_to="TALMUDIC COLLEGE 4000 ALTON ROAD INC." — same institution as Talmudic University, two names. max_frequency_days=90, expiration set to current cycle. Viktor approved 2026-05-25 PM.'
WHERE id = 57 AND gdo_number = 'GDO-13076';

-- ============================================================
-- 2. 3 DEMOTEs (1 conflict + 2 bot false-positives)
-- ============================================================

-- 175-PV Pura Vida Brickell 701 (id=27): bot recommended GDO-11228 but
-- id=117 (050-PV Pura Vida Brickell) already holds it at same address.
-- Demote per conflict-handling standing rule.
UPDATE public.gdos
SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2c deferral] DEMOTED. Bot recommended GDO-11228 for this row but id=117 (050-PV Pura Vida Brickell, same address 1104 S Miami Ave) already holds it. Third duplicate-client pair surfaced in Phase 2 — flag for ops cleanup alongside Kosh/Grove Kosher and Nu Real x2. Demoting wrong row, id=117 has the correct linkage. Viktor approved 2026-05-25 PM.'
WHERE id = 27 AND gdo_number = 'GDO-02560' AND status = 'ACTIVE';

-- 108-ROA Roast (id=26): bot returned GDO-11202 with name_match=true but
-- issued_to is "LR SUSHI LLC DBA TYO SUSHI" — bot false-positive. Reclassify
-- as WRONG_CLIENT and demote (Roast has no permit at the address).
UPDATE public.gdos
SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2c deferral] DEMOTED. Bot initially flagged WRONG_GDO_NUMBER but bot.name_match was a false positive — issued_to "LR SUSHI LLC DBA TYO SUSHI" has no relation to Roast (difflib similarity = 0.26). Roast has no DERM permit at its address. Viktor approved 2026-05-25 PM.'
WHERE id = 26 AND gdo_number = 'GDO-11779' AND status = 'ACTIVE';

-- 091-SB Street Bar (id=73): bot returned GDO-03271 with name_match=true but
-- issued_to is "ISLAND'S PARADISE RESTAURANT & ROTI SHOP" — bot false-positive.
-- Demote.
UPDATE public.gdos
SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2c deferral] DEMOTED. Bot initially flagged WRONG_GDO_NUMBER but bot.name_match was a false positive — issued_to "ISLAND''S PARADISE RESTAURANT & ROTI SHOP" has no relation to Street Bar (difflib similarity = 0.15). Street Bar has no DERM permit at its address. Viktor approved 2026-05-25 PM.'
WHERE id = 73 AND gdo_number = 'GDO-08940' AND status = 'ACTIVE';

-- ============================================================
-- 3. 4 CONFIRMED_MATCH UPDATEs (reclassified from WRONG_CLIENT)
-- ============================================================
-- Bot returned name_match=false for these (false negative — usually due to
-- parens or extra words in our client_name), but issued_to and difflib
-- name similarity both confirm match. UPDATE max_frequency_days normally.

-- 017-FIA Florida Food Eats Fialkoff's (Surfside) (id=4)
UPDATE public.gdos
SET max_frequency_days = 30,
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2c deferral] Reclassified WRONG_CLIENT -> CONFIRMED_MATCH per difflib (sim=0.65, shared=fialkoff/surfside). Bot issued_to="FIALKOFF''S EXPRESS SURFSIDE LLC" matches client name. Bot freq=30 trusted. Viktor approved 2026-05-25 PM.'
WHERE id = 4 AND gdo_number = 'GDO-13962'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 30);

-- 072-TCE The carrot express Sunset Harbor (id=39)
UPDATE public.gdos
SET max_frequency_days = 60,
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2c deferral] Reclassified WRONG_CLIENT -> CONFIRMED_MATCH per difflib (sim=0.4, shared=carrot/express). Bot issued_to="CARROT LOVE SOUTH FLORIDA OPERATING C LL" — same Carrot Love chain DBA. Bot freq=60 trusted. Viktor approved 2026-05-25 PM.'
WHERE id = 39 AND gdo_number = 'GDO-10440'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 60);

-- 049-PV Pura Vida (Bay Harbor) (id=46)
UPDATE public.gdos
SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2c deferral] Reclassified WRONG_CLIENT -> CONFIRMED_MATCH per difflib (sim=1.0, shared=bay/harbor/pura/vida — exact match). Bot issued_to="PURA VIDA BAY HARBOR LLC". Bot freq=90 trusted. Viktor approved 2026-05-25 PM. (Bot misclassified due to parens in our client_name "Pura Vida (Bay Harbor)".)'
WHERE id = 46 AND gdo_number = 'GDO-11852'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

-- 025-GRO Grove Kosher LLC (Harding Ave) (id=68)
UPDATE public.gdos
SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2c deferral] Reclassified WRONG_CLIENT -> CONFIRMED_MATCH per difflib (sim=0.67, shared=grove/kosher). Bot issued_to="GROVE KOSHER LLC" — exact match minus our "(Harding Ave)" suffix that broke bot.name_match. Bot freq=90 trusted. Viktor approved 2026-05-25 PM.'
WHERE id = 68 AND gdo_number = 'GDO-13447'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

COMMIT;

-- ============================================================
-- VERIFICATION
-- ============================================================
-- 1. The 2 gdo_number renames
--    SELECT id, gdo_number FROM public.gdos WHERE id IN (57, 62);
--    Expected: 57=GDO-00313, 62=GDO-00951
-- 2. The 3 demotes
--    SELECT id, gdo_number, status FROM public.gdos WHERE id IN (27, 26, 73);
--    Expected: all INACTIVE
-- 3. The 4 reclass UPDATEs landed
--    SELECT id, max_frequency_days FROM public.gdos WHERE id IN (4, 39, 46, 68);
--    Expected: 4=30, 39=60, 46=90, 68=90
-- 4. ACTIVE / INACTIVE counts
--    SELECT COUNT(*) FILTER (WHERE status='ACTIVE')::int FROM public.gdos;
--    Expected: 97 - 3 = 94
--    SELECT COUNT(*) FILTER (WHERE status='INACTIVE')::int FROM public.gdos;
--    Expected: 38 + 3 = 41
-- 5. max_frequency_days non-NULL count
--    Expected: 60 + 6 (2 in-place + 4 reclass) = 66
-- 6. Audit row count
--    Expected: 9 UPDATE rows
