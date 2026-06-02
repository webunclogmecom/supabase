-- 2026-05-25l_gdo_phase_2a_sample_applies.sql
--
-- Phase 2a sample-batch applies, based on Viktor's review of the 10-GDO
-- sample run on 2026-05-25 PM.
--
-- SOURCES
--   - Sample results : docs/gdo-phase-2-2026-05-25/02-phase-2a-sample-results.md
--   - Viktor approval: #viktor-supabase ts 1779725868.955249
--   - PDF verification: C:\Users\FRED\AppData\Local\Temp\gdo-pdfs\
--                       (casa_neos_kitchens.pdf, casa_neos_bars.pdf,
--                        casa_neos_lounge.pdf)
--
-- WHAT THIS DOES
--   1. Casa Neos (ids 63, 64, 65) — location_label + max_frequency_days +
--      permit_expiration. PDFs confirm: KITCHENS/60d, BARS/90d, LOUNGE/30d.
--   2. 3 simple matches:
--        165-LPB GDO-15328 → max_frequency_days=90
--        077-TCE GDO-10822 → max_frequency_days=30
--        032-LG  GDO-11532 → max_frequency_days=30 + permit_expiration fix
--   3. 4 mismatches DEMOTED to INACTIVE (DB had wrong client↔GDO link):
--        058-SOH GDO-01179 (Apache Landing actually owns it)
--        021-GRA GDO-00376 (McDonald's #11333 actually owns it)
--        124-SAF GDO-14336 (Tasty Dough Enterprise actually owns it)
--        122-BMN GDO-01759 (Cotrina USA / La Vida de Don Pollo owns it)
--   4. Blanket renewal expiration fix (FAST PATH per Viktor): every ACTIVE
--      row with permit_expiration < 2026-01-01 gets bumped to 2026-12-31.
--      GDOs renew annually on Dec 31 and prior sync hadn't pulled the new
--      date.
--
-- DEFERRED PER VIKTOR
--   - GDO-15199 SARPINOS PIZZERIA insertion. Premature without ops
--     confirmation that we actually service this neighbor of Casa Neos.
--
-- ARCHITECTURAL STANDING (CLAUDE.md, the 8 rules)
--   - Rule 1 (source-agnostic): no source-prefixed columns touched. ✓
--   - Rule 2 (3NF): all 4 columns touched (status, location_label,
--     max_frequency_days, permit_expiration, notes) are intrinsic to the
--     permit row, not derivable from a join. ✓
--   - Rule 3 (reference all data): no copies. ✓
--   - Rule 4 (trust hierarchy): DERM via @GDO bot + PDF verification is
--     canonical for permit fields. ✓
--   - Rule 5 (idempotent): every UPDATE filters on current state. Re-run is
--     a no-op (e.g. `WHERE max_frequency_days IS NULL`,
--     `WHERE status = 'ACTIVE'`,
--     `WHERE permit_expiration < '2026-01-01'`). ✓
--   - Rule 6 (never hard-delete): the 4 mismatches go to status='INACTIVE'
--     with explanatory notes; no rows removed. ✓
--   - Rule 7 (timestamps UTC, money NUMERIC): N/A (date column). ✓
--   - Rule 8 (audit): public.gdos already opts in to audit.log_change()
--     (per 25k header). Every UPDATE here generates an audit row with
--     app_source='sql' (Management API has no PostgREST context). ✓
--
-- HOW TO APPLY
--   node docs/gdo-phase-2-2026-05-25/probes/06_apply_2026_05_25l.js
--
-- HOW TO VERIFY
--   node docs/gdo-phase-2-2026-05-25/probes/07_verify_2026_05_25l.js

BEGIN;

-- ============================================================
-- 1. Casa Neos (property 42 — ids 63 / 64 / 65)
-- ============================================================
-- PDF-verified disambiguation. Each row gets the DERM-issued facility label
-- (KITCHENS / BARS / LOUNGE), the city-mandated max frequency from the
-- permit cleaning schedule, and the current annual expiration date.

UPDATE public.gdos
SET location_label    = 'KITCHENS',
    max_frequency_days = 60,
    permit_expiration  = '2026-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2a] location_label=KITCHENS (DERM PDF: ' ||
            '"CASA NEOS MIAMI, LLC D/B/A CASA NEOS (KITCHENS)"), ' ||
            'max_frequency_days=60 (Full Service Restaurant cleaning ' ||
            'schedule, 4x100 GPM units), permit_expiration renewed to ' ||
            'current annual cycle.'
WHERE id = 63
  AND gdo_number = 'GDO-10877'
  AND (location_label IS NULL
       OR max_frequency_days IS NULL
       OR permit_expiration < '2026-12-31');

UPDATE public.gdos
SET location_label    = 'BARS',
    max_frequency_days = 90,
    permit_expiration  = '2026-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2a] location_label=BARS (DERM PDF: ' ||
            '"CASA NEOS MIAMI, LLC D/B/A CASA NEOS (BARS)" at FAC. B, ' ||
            '1x75 GPM), max_frequency_days=90, permit_expiration ' ||
            'renewed.'
WHERE id = 64
  AND gdo_number = 'GDO-15062'
  AND (location_label IS NULL
       OR max_frequency_days IS NULL
       OR permit_expiration < '2026-12-31');

UPDATE public.gdos
SET location_label    = 'LOUNGE',
    max_frequency_days = 30,
    permit_expiration  = '2026-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2a] location_label=LOUNGE (DERM PDF: ' ||
            '"CN LOUNGE LLC DBA CASA NEOS LOUNGE" at Suite 301 — note ' ||
            'this is a SEPARATE LLC from the kitchen/bar permits, but ' ||
            'co-located at the Casa Neos address), max_frequency_days=30, ' ||
            'permit_expiration renewed.'
WHERE id = 65
  AND gdo_number = 'GDO-16389'
  AND (location_label IS NULL
       OR max_frequency_days IS NULL
       OR permit_expiration < '2026-12-31');

-- ============================================================
-- 2. Simple matches (3 confident UPDATEs)
-- ============================================================
-- These rows have correct client↔GDO mapping; only missing
-- max_frequency_days (and in La Granja's case, also a stale expiration).

-- 165-LPB La Plaza Coffee And Bakery
UPDATE public.gdos
SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2a] max_frequency_days=90 from DERM permit ' ||
            '(GDO Bot lookup confirmed against active permit).'
WHERE gdo_number = 'GDO-15328'
  AND max_frequency_days IS NULL;

-- 077-TCE Carrot Love Dadeland DBA Carrot Express
UPDATE public.gdos
SET max_frequency_days = 30,
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2a] max_frequency_days=30 from DERM permit ' ||
            '(GDO Bot lookup confirmed against active permit).'
WHERE gdo_number = 'GDO-10822'
  AND max_frequency_days IS NULL;

-- 032-LG La Granja Miami Corp (also needs expiration fix)
UPDATE public.gdos
SET max_frequency_days = 30,
    permit_expiration  = '2026-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2a] max_frequency_days=30 from DERM permit; ' ||
            'permit_expiration corrected from prior-year date (2026-01-07) ' ||
            'to current annual cycle (2026-12-31).'
WHERE gdo_number = 'GDO-11532'
  AND (max_frequency_days IS NULL OR permit_expiration < '2026-12-31');

-- ============================================================
-- 3. Demote 4 mismatched gdos rows
-- ============================================================
-- The DB associates these GDO numbers with the wrong client. The bot
-- confirmed each GDO actually belongs to a different business — often at
-- the same multi-tenant address. Per Viktor: demote to INACTIVE (not
-- delete), document the actual owner in notes for future re-assignment if
-- ops later confirms a real link.

-- 058-SOH Soho Asian Bar ↔ GDO-01179 (actually APACHE LANDING BAR & GRILL)
UPDATE public.gdos
SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2a] DEMOTED. GDO-01179 actually belongs to ' ||
            'APACHE LANDING BAR & GRILL per DERM lookup (already noted in ' ||
            'Viktor''s 2026-05-22 backfill). Soho Asian Bar has no DERM ' ||
            'permit at its address per @GDO bot.'
WHERE gdo_number = 'GDO-01179'
  AND status = 'ACTIVE';

-- 021-GRA Granada Condo ↔ GDO-00376 (actually McDonald's #11333)
UPDATE public.gdos
SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2a] DEMOTED. GDO-00376 actually belongs to ' ||
            'McDonald''s #11333 (multi-tenant @ 9341 E Bay Harbor Dr). ' ||
            'Granada Condo has no DERM permit at its address per @GDO bot.'
WHERE gdo_number = 'GDO-00376'
  AND status = 'ACTIVE';

-- 124-SAF Jonny Safar ↔ GDO-14336 (actually TASTY DOUGH ENTERPRISE LLC)
UPDATE public.gdos
SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2a] DEMOTED. GDO-14336 actually belongs to ' ||
            'TASTY DOUGH ENTERPRISE LLC (multi-tenant @ 3150 Sheridan Ave). ' ||
            'Jonny Safar has no DERM permit at its address per @GDO bot.'
WHERE gdo_number = 'GDO-14336'
  AND status = 'ACTIVE';

-- 122-BMN BMN Normandy ↔ GDO-01759 (actually COTRINA USA DBA LA VIDA DE DON POLLO)
UPDATE public.gdos
SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2a] DEMOTED. GDO-01759 actually belongs to ' ||
            'COTRINA USA DBA LA VIDA DE DON POLLO (multi-tenant @ 1936 ' ||
            'Normandy Dr). BMN Normandy has no DERM permit at its address ' ||
            'per @GDO bot.'
WHERE gdo_number = 'GDO-01759'
  AND status = 'ACTIVE';

-- ============================================================
-- 4. Blanket renewal expiration fix (FAST PATH per Viktor)
-- ============================================================
-- All GDO permits renew annually on Dec 31. Sample run showed every
-- bot-verified DERM record has 2026-12-31, but the DB has prior-year dates.
-- Likely all 135 rows are stale.
--
-- Idempotent: re-runs only affect rows still showing a past year. The
-- individual UPDATEs above already moved Casa Neos + La Granja to
-- 2026-12-31, so this bulk pass picks up everyone else.
--
-- Viktor noted: "spot-check 10-15 random rows after this" — that's a SELECT
-- in the verify probe, not a mutation here.

UPDATE public.gdos
SET permit_expiration = '2026-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2a bulk] permit_expiration bumped to ' ||
            'current annual cycle (2026-12-31). GDOs renew annually on ' ||
            'Dec 31; prior sync had not pulled the new date.'
WHERE status = 'ACTIVE'
  AND permit_expiration < '2026-01-01';

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION (see probes/07_verify_2026_05_25l.js)
-- ============================================================
-- 1. Casa Neos all 3 set correctly
--      SELECT id, gdo_number, location_label, max_frequency_days,
--             permit_expiration::text
--      FROM gdos WHERE property_id = 42 ORDER BY id;
--      Expected:
--        63 GDO-10877 KITCHENS 60 2026-12-31
--        64 GDO-15062 BARS     90 2026-12-31
--        65 GDO-16389 LOUNGE   30 2026-12-31
--
-- 2. Simple matches set
--      SELECT gdo_number, max_frequency_days, permit_expiration::text
--      FROM gdos
--      WHERE gdo_number IN ('GDO-15328', 'GDO-10822', 'GDO-11532');
--      Expected: 90, 30, 30; all expirations 2026-12-31.
--
-- 3. 4 mismatched rows demoted
--      SELECT gdo_number, status FROM gdos
--      WHERE gdo_number IN ('GDO-01179', 'GDO-00376',
--                           'GDO-14336', 'GDO-01759');
--      Expected: all INACTIVE.
--
-- 4. ACTIVE count
--      SELECT COUNT(*) FILTER (WHERE status = 'ACTIVE')::int FROM gdos;
--      Expected: 131 (was 135 before the 4 demotions).
--
-- 5. No ACTIVE rows still showing a stale expiration
--      SELECT COUNT(*)::int FROM gdos
--      WHERE status = 'ACTIVE' AND permit_expiration < '2026-01-01';
--      Expected: 0.
--
-- 6. Spot-check: 15 random ACTIVE rows
--      SELECT gdo_number, permit_expiration::text, max_frequency_days
--      FROM gdos WHERE status = 'ACTIVE' ORDER BY random() LIMIT 15;
--      Expected: every expiration is 2026-12-31. max_frequency_days mostly
--      still NULL (Phase 2a only covered 6 of 135) — that's expected.
--
-- 7. Audit rows generated
--      SELECT COUNT(*)::int FROM audit.logs
--      WHERE table_name = 'gdos'
--        AND occurred_at > now() - interval '5 minutes'
--        AND app_source = 'sql';
--      Expected: at least 10 (3 Casa Neos + 3 simple + 4 demotes) plus the
--      bulk-expiration count (likely 120+).
