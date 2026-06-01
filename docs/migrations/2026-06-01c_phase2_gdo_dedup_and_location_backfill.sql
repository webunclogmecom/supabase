-- 2026-06-01c_phase2_gdo_dedup_and_location_backfill.sql
--
-- Phase-2 batch 1 of the client_locations rollout (spec §10). Two parts:
--   A. Soft-delete 5 invalid / duplicate GDO rows on dirty multi-GDO clients
--      (status -> INACTIVE; NEVER hard-delete). Each had 0 manifests + no permit doc.
--   B. Backfill client_locations for the 3 CONFIRMED multi-facility clients
--      (different street addresses, each with its own GDO). Naming = location_label
--      else street address (Fred 2026-06-01). Link gdos.client_location_id.
--
-- HELD (deliberately NOT in this file, pending Diego/Yannick DERM verification):
--   the 3 "phantom" same-property 2nd GDOs — 060-TU GDO-13076, 155-PV GDO-12838,
--   170-PV GDO-11433 (valid numbers, but no permit doc + 0 manifests + added later).
--   See docs/phase2-gdo-verification-message.md.
--
-- Idempotent (Rule 5): soft-deletes guarded WHERE status='ACTIVE'; inserts
--   ON CONFLICT (client_id,name) DO NOTHING; links guarded IS DISTINCT FROM.
-- Soft-delete only (Rule 6): no hard deletes; notes record the reason + reversal.

BEGIN;

-- A. Soft-delete invalid GDO rows (typo-dups + non-permit placeholders) -----
UPDATE public.gdos SET status='INACTIVE',
  notes='Soft-deleted 2026-06-01 (Phase-2): typo-duplicate of GDO-00951 (id 62) — same DERM permit 951, property 45, 2023-12-31 expiration. 0 manifests, no doc. Reversible: status=ACTIVE.'
  WHERE id=144 AND status='ACTIVE';
UPDATE public.gdos SET status='INACTIVE',
  notes='Soft-deleted 2026-06-01 (Phase-2): non-permit placeholder ("Needs review"). Mila real permit is GDO-14117 (id 156). 0 manifests. Reversible.'
  WHERE id=155 AND status='ACTIVE';
UPDATE public.gdos SET status='INACTIVE',
  notes='Soft-deleted 2026-06-01 (Phase-2): malformed concatenation ("GDO-14117 / GDO-11024"). GDO-14117 exists (id 156); GDO-11024 may be a real 2nd permit — verify in DERM portal and add a clean row if real. 0 manifests. Reversible.'
  WHERE id=157 AND status='ACTIVE';
UPDATE public.gdos SET status='INACTIVE',
  notes='Soft-deleted 2026-06-01 (Phase-2): non-permit placeholder ("Not available") on Fresko 2nd/billing property 102. Real permit is GDO-08341 (id 129). 0 manifests. Reversible.'
  WHERE id=149 AND status='ACTIVE';
UPDATE public.gdos SET status='INACTIVE',
  notes='Soft-deleted 2026-06-01 (Phase-2): non-permit placeholder ("Not available"). Fresko Bakery real permit is GDO-01861 (id 130, currently INACTIVE). 0 manifests. Reversible.'
  WHERE id=159 AND status='ACTIVE';

-- B. Backfill client_locations for the 3 confirmed multi-facility clients ----
--    025-GRO Grove Kosher, 045-NU Nu Real Food, 175-PV Pura Vida Brickell.
INSERT INTO public.client_locations (client_id, name, property_id, status, notes)
VALUES
  (384, '9467 Harding Avenue',     24,  'active', 'Phase-2 backfill 2026-06-01 from GDO-13447 (id 68). Name = street address (no label).'),
  (384, 'Adriana',                 34,  'active', 'Phase-2 backfill 2026-06-01 from GDO-04943 (id 124, permit INACTIVE). Name = location_label.'),
  (371, '266 Miracle Mile',        200, 'active', 'Phase-2 backfill 2026-06-01 from GDO-07733 (id 88). Name = street address.'),
  (371, '3250 Northeast 1st Avenue',10, 'active', 'Phase-2 backfill 2026-06-01 from GDO-11540 (id 58). Name = street address.'),
  (343, '701 Brickell Avenue',     132, 'active', 'Phase-2 backfill 2026-06-01 from GDO-02560 (id 27). Name = street address.'),
  (343, '1104 South Miami Avenue', 353, 'active', 'Phase-2 backfill 2026-06-01 from GDO-11228 (id 117). Name = street address.')
ON CONFLICT (client_id, name) DO NOTHING;

-- Link each GDO to its new location.
UPDATE public.gdos g SET client_location_id = cl.id
  FROM public.client_locations cl
  WHERE cl.client_id = g.client_id
    AND ( (g.id = 68  AND cl.name = '9467 Harding Avenue')
       OR (g.id = 124 AND cl.name = 'Adriana')
       OR (g.id = 88  AND cl.name = '266 Miracle Mile')
       OR (g.id = 58  AND cl.name = '3250 Northeast 1st Avenue')
       OR (g.id = 27  AND cl.name = '701 Brickell Avenue')
       OR (g.id = 117 AND cl.name = '1104 South Miami Avenue') )
    AND g.client_location_id IS DISTINCT FROM cl.id;

COMMIT;

-- VERIFICATION -------------------------------------------------------------
-- SELECT c.client_code, cl.name, cl.property_id, g.gdo_number, g.status
-- FROM public.client_locations cl JOIN public.clients c ON c.id=cl.client_id
-- LEFT JOIN public.gdos g ON g.client_location_id=cl.id
-- WHERE cl.client_id IN (384,371,343) ORDER BY c.client_code, cl.name;   -- 6 rows, each linked
