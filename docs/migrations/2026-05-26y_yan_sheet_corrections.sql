-- 2026-05-26y_yan_sheet_corrections.sql
--
-- First batch of corrections from Yan's master Miami-Dade GDO sheet
-- cross-check (2026-05-25 → 2026-05-26). Viktor-blessed both actions
-- in #viktor-supabase thread ts 1779747271.192639.
--
-- ACTIONS
--   1. DEMOTE id=84 047-PAM Pamplemousse GDO-14294 — bot confirmed EXPIRED
--      2024-12-31. Address (910 West Ave) now has GDO-09736 issued to MR.
--      BAGUETTE — different tenant. Pamplemousse never renewed. Client
--      operating without a GDO — flag for ops/compliance.
--   2. REVERT id=99 171-CAF Ironside Cafe gdo_number GDO-10249 → GDO-10248.
--      Bot confirmed GDO-10249 does NOT exist in DERM. Only GDO-10248 at
--      7580 NE 4th Ct, issued to "THE OM CENTER LLC DBA LA GIULETTA".
--      Phase 2d rename was wrong. Restore the original number; flag for ops
--      to verify whether Ironside Cafe operates under the La Giuletta permit
--      (could be same location, different tenant/DBA).
--
-- DEFERRED to next batch (Viktor wants more bot lookups before deciding):
--   - Carrot Doral GDO-11170 (Yan suggests GDO-12209) — bot lookup pending
--   - Pummarola GDO-00951 — bot lookup pending
--   - Carrot Coral Gables GDO-09925 — direct GDO# re-verification
--   - Carrot Buena Vista GDO-13822 — direct GDO# re-verification
--   - 3 missing-from-Yan (Baoli, 41 Pizza, Marie Blachere) — bot lookup pending
--   - 4 stale-expiration candidates (Mozart, Bagel Boss, Kresy, Hubble) — bot lookup pending
--
-- IDEMPOTENT (Rule 5) · AUDIT (Rule 8) · NEVER HARD-DELETE (Rule 6)

BEGIN;

-- 1. Pamplemousse — demote expired GDO
UPDATE public.gdos
SET status = 'INACTIVE',
    permit_expiration = '2024-12-31',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-26 Yan-sheet correction] DEMOTED. @GDO bot confirms GDO-14294 expired 2024-12-31; address 910 West Ave now has active GDO-09736 issued to MR. BAGUETTE (different tenant). Pamplemousse never renewed. Client (047-PAM, status=RECURRING) is operating without a GDO — flag for ops/compliance. Permit_expiration reverted from Phase 2 bulk-set 2026-12-31 to real 2024-12-31. Viktor approved in #viktor-supabase thread 1779747271.192639.'
WHERE id = 84
  AND gdo_number = 'GDO-14294'
  AND status = 'ACTIVE';

-- 2. Ironside Cafe — revert rename to non-existent number
UPDATE public.gdos
SET gdo_number = 'GDO-10248',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-26 Yan-sheet correction] REVERTED gdo_number from GDO-10249 back to GDO-10248. @GDO bot confirms GDO-10249 does NOT exist in DERM. Only GDO-10248 at 7580 NE 4th Court, issued to "THE OM CENTER LLC DBA LA GIULETTA". Phase 2d rename (25q) was wrong. Note: the permit-holder name on GDO-10248 doesnt match Ironside Cafe — may be same location, different tenant/DBA. Flag for ops to verify. Viktor approved in #viktor-supabase thread 1779747271.192639.'
WHERE id = 99
  AND gdo_number = 'GDO-10249';

COMMIT;

-- VERIFY
--   SELECT id, gdo_number, status, permit_expiration::text FROM public.gdos
--   WHERE id IN (84, 99) ORDER BY id;
--   Expected:
--     84 GDO-14294 INACTIVE 2024-12-31
--     99 GDO-10248 ACTIVE   2026-12-31
