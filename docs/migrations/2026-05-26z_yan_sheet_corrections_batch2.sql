-- 2026-05-26z_yan_sheet_corrections_batch2.sql
--
-- Second batch of corrections from the Yan-sheet cross-check, applying the
-- 8 deferred bot-verified findings from #viktor-supabase thread ts
-- 1779747271.192639. All decisions confirmed by @GDO bot direct GDO# lookups
-- (8 lookups in #gdo-permit, all responded).
--
-- KEY FINDING from the bot batch: Phase 2's bulk "permit_expiration =
-- 2026-12-31 WHERE permit_expiration < 2026-01-01" was too aggressive on
-- 6 rows. Real DERM expirations (per direct GDO# lookup) are:
--
-- ACTIONS
--   1. Baoli Miami GDO-04840 — revert exp to 2024-12-31 (expired ~1.5 years)
--      Bot: issued_to "TRADEMARK MIAMI INC DBA BAOLI MIAMI" ✓ correct client,
--      but permit expired Dec 31 2024. Flag for ops compliance (renewal).
--   2. Marie Blachere GDO-14965 — revert exp to 2023-12-31 (expired ~2.5 years)
--      Bot: issued_to "MARIE BLACHERE HYDE MIAMI BAKERY, LLC" ✓ correct,
--      permit expired Dec 31 2023. Active client — urgent ops flag.
--   3. Mozart Cafe GDO-06762 — revert exp to 2025-12-31 (expired ~5 months)
--      Bot: issued_to "MOZART CAFE SUNNY ISLES INC DBA MOZART CAFFE" ✓.
--      Client is INACTIVE so low compliance urgency.
--   4. Bagel Boss Aventura GDO-11271 — revert exp to 2025-12-31
--      Bot: issued_to "TEAM FLORIDA BB LLC DBA BAGEL BOSS OF AVENTURA" ✓.
--      Active client, ops flag.
--   5. Kresy Kosher GDO-14528 — revert exp to 2025-12-31
--      Bot: issued_to "MEY ENTERPRISE LLC DBA KRESY FALAFEL AND PIZZA BAR" ✓.
--      PAUSED client.
--   6. Pummarola GDO-00951 — revert exp to 2023-12-31 (expired ~17 months)
--      Bot: issued_to "SOUTH BEACH EXPRESS LLC DBA PUMMAROLA" ✓ correct.
--      Already verified in first bot batch. Ops flag.
--   7. 41 Pizza GDO-09852 — DEMOTE (WRONG_CLIENT + expired 2022-12-31)
--      Bot: issued_to "PIZZA MISHPACHA, LLC DBA PIZZA DUDE" — NOT 41 Pizza.
--      Permit expired Dec 31 2022 (~3.5 years). Client (002-41 41 Pizza)
--      doesn't actually hold this permit. Demote + ops flag.
--   8. Carrot Buena Vista GDO-13822 — DEMOTE (WRONG_CLIENT + expired)
--      Already bot-verified in first batch: address belongs to 100 MONTADITOS,
--      permit expired Dec 31 2024. Carrot Express has no DERM permit here.
--      Sales lead per Viktor.
--
-- HUBBLE BUBBLE GDO-16086: bot confirmed our 2026-12-31 is CORRECT. No
-- action. Yan's sheet had stale info on this one.
--
-- CARROT DORAL: bot confirmed Yan's suggested GDO-12209 is SUVICHE DORAL LLC,
-- NOT Carrot Express. Our GDO-11170 (already Phase 2 verified as CARROT LOVE
-- CITY PLACE OPERATING LLC DBA CARROT EXPRESS) stays. No action.
--
-- AVA, Carrot Coral Gables, Fuego By Mana, Carrot Kendall — already confirmed
-- correct in first bot batch + Viktor approved. No action.
--
-- IDEMPOTENT (Rule 5) · AUDIT (Rule 8) · NEVER HARD-DELETE (Rule 6)

BEGIN;

-- 1. Baoli Miami — expired 2024
UPDATE public.gdos
SET permit_expiration = '2024-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-26 Yan-sheet batch2] permit_expiration reverted from Phase 2 bulk-set 2026-12-31 to real 2024-12-31 per @GDO bot direct lookup. issued_to=TRADEMARK MIAMI INC DBA BAOLI MIAMI (correct client). EXPIRED ~1.5 years. Flag for ops compliance — renewal needed.'
WHERE gdo_number = 'GDO-04840'
  AND permit_expiration <> '2024-12-31';

-- 2. Marie Blachere — expired 2023
UPDATE public.gdos
SET permit_expiration = '2023-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-26 Yan-sheet batch2] permit_expiration reverted from Phase 2 bulk-set 2026-12-31 to real 2023-12-31 per @GDO bot direct lookup. issued_to=MARIE BLACHERE HYDE MIAMI BAKERY LLC (correct client). EXPIRED ~2.5 years. URGENT ops compliance flag — active client operating without coverage.'
WHERE gdo_number = 'GDO-14965'
  AND permit_expiration <> '2023-12-31';

-- 3. Mozart Cafe — expired 2025
UPDATE public.gdos
SET permit_expiration = '2025-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-26 Yan-sheet batch2] permit_expiration reverted from 2026-12-31 to real 2025-12-31 per @GDO bot direct lookup. issued_to=MOZART CAFE SUNNY ISLES INC DBA MOZART CAFFE. Client INACTIVE so low urgency.'
WHERE gdo_number = 'GDO-06762'
  AND permit_expiration <> '2025-12-31';

-- 4. Bagel Boss Aventura — expired 2025
UPDATE public.gdos
SET permit_expiration = '2025-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-26 Yan-sheet batch2] permit_expiration reverted from 2026-12-31 to real 2025-12-31 per @GDO bot direct lookup. issued_to=TEAM FLORIDA BB LLC DBA BAGEL BOSS OF AVENTURA. Active client — ops compliance flag.'
WHERE gdo_number = 'GDO-11271'
  AND permit_expiration <> '2025-12-31';

-- 5. Kresy Kosher — expired 2025
UPDATE public.gdos
SET permit_expiration = '2025-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-26 Yan-sheet batch2] permit_expiration reverted from 2026-12-31 to real 2025-12-31 per @GDO bot direct lookup. issued_to=MEY ENTERPRISE LLC DBA KRESY FALAFEL AND PIZZA BAR. PAUSED client.'
WHERE gdo_number = 'GDO-14528'
  AND permit_expiration <> '2025-12-31';

-- 6. Pummarola — expired 2023 (also verified in first bot batch)
UPDATE public.gdos
SET permit_expiration = '2023-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-26 Yan-sheet batch2] permit_expiration reverted from 2026-12-31 to real 2023-12-31 per @GDO bot lookup. issued_to=SOUTH BEACH EXPRESS LLC DBA PUMMAROLA (correct client). EXPIRED ~17 months. Ops compliance flag — needs renewal.'
WHERE gdo_number = 'GDO-00951'
  AND permit_expiration <> '2023-12-31';

-- 7. 41 Pizza — DEMOTE (WRONG_CLIENT + expired 2022)
UPDATE public.gdos
SET status = 'INACTIVE',
    permit_expiration = '2022-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-26 Yan-sheet batch2] DEMOTED. @GDO bot direct lookup confirms GDO-09852 issued to PIZZA MISHPACHA LLC DBA PIZZA DUDE — NOT 41 Pizza and Bakery. Permit expired Dec 31 2022 (~3.5 years). Our client 002-41 (PAUSED) doesnt actually hold this permit. Flag for ops to find 41 Pizzas actual permit (if any) when reactivated.'
WHERE gdo_number = 'GDO-09852'
  AND status = 'ACTIVE';

-- 8. Carrot Buena Vista — DEMOTE (WRONG_CLIENT + expired, already bot-verified)
UPDATE public.gdos
SET status = 'INACTIVE',
    permit_expiration = '2024-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-26 Yan-sheet batch2] DEMOTED. @GDO bot confirms GDO-13822 belongs to SANTA TERESA GROUP LLC DBA 100 MONTADITOS — NOT Carrot Express Buena Vista. Permit expired Dec 31 2024. Carrot Express has no active DERM permit at 3252 Buena Vista Blvd. Sales lead per Viktor — they are operating without coverage.'
WHERE gdo_number = 'GDO-13822'
  AND status = 'ACTIVE';

COMMIT;

-- VERIFY
--   SELECT gdo_number, status, permit_expiration::text FROM public.gdos
--   WHERE gdo_number IN ('GDO-04840','GDO-14965','GDO-06762','GDO-11271',
--                        'GDO-14528','GDO-00951','GDO-09852','GDO-13822')
--   ORDER BY gdo_number;
--
--   Expected:
--     GDO-00951 ACTIVE   2023-12-31
--     GDO-04840 ACTIVE   2024-12-31
--     GDO-06762 ACTIVE   2025-12-31   (client INACTIVE so won't show in some views)
--     GDO-09852 INACTIVE 2022-12-31
--     GDO-11271 ACTIVE   2025-12-31
--     GDO-13822 INACTIVE 2024-12-31
--     GDO-14528 ACTIVE   2025-12-31
--     GDO-14965 ACTIVE   2023-12-31
--
--   ACTIVE count: 80 - 2 demotes = 78
--   ops.v_gdo_expiry should now show 5 newly-expired permits in "expired" status.
