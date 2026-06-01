-- 2026-06-01b_seed_casa_neos_wynd_client_locations.sql
--
-- Seed the two CLEAN multi-location clients into public.client_locations:
--   A. Casa Neos (client_id=369) -> 3 service-area locations, each LINKED to its
--      existing GDO (the proof case: schema already holds 3 GDOs on property 42).
--   B. Wynd 28   (client_id=233) -> 5 tenant locations, names lifted from Airtable
--      (216-220-WYN) THIS WEEK before AT sunset. NO GDO link yet (Wynd has 0 GDOs
--      ingested; the D-track ingests + links them once Q1's per-tenant GDOs arrive).
--
-- The other 10 multi-GDO clients are NOT seeded here: their GDO data is dirty
-- (typo-dups "GDO-000951"/"GDO-00951", merge artifacts "...-DUPMERGE-147",
-- placeholders "Needs review"/"Not available"). They are a triaged Phase-2 backfill
-- AFTER a GDO-dedup cleanup. See scripts/probes/find_multi_location_candidates.sql.
--
-- DEPENDS ON: 2026-06-01_client_locations.sql (table + gdos.client_location_id).
-- Idempotent (Rule 5): ON CONFLICT (client_id, name) DO NOTHING; the GDO link
--   UPDATE is guarded by IS DISTINCT FROM. property_id resolved by sub-select
--   (is_primary) -> stays correct across envs, never hardcoded.
-- Source-agnostic (Rule 1): location names are native canonical text; provenance of
--   the Wynd names is recorded in notes, NOT as an Airtable column or source link
--   (Fred 2026-06-01: tenants leave Airtable entirely; Wynd becomes ONE client).

BEGIN;

-- A. Casa Neos (009-CN, id=369): 3 service-area locations -----------------
WITH casa_bldg AS (
  SELECT id FROM public.properties
  WHERE client_id = 369
  ORDER BY is_primary DESC NULLS LAST, id ASC
  LIMIT 1
)
INSERT INTO public.client_locations (client_id, name, property_id, status, notes)
SELECT 369, t.name, casa_bldg.id, 'active', t.note
FROM (VALUES
  ('Kitchens', 'Casa Neos service area. Maps to GDO-10877 (label KITCHENS).'),
  ('Bars',     'Casa Neos service area. Maps to GDO-15062 (label BARS).'),
  ('Lounge',   'Casa Neos service area. Maps to GDO-16389 (label LOUNGE).')
) AS t(name, note)
CROSS JOIN casa_bldg
ON CONFLICT (client_id, name) DO NOTHING;

-- A2. Link Casa Neos's 3 GDOs to the new locations (match on location_label) --
UPDATE public.gdos g
SET client_location_id = cl.id
FROM public.client_locations cl
WHERE cl.client_id = 369
  AND g.client_id  = 369
  AND upper(btrim(cl.name)) = upper(btrim(g.location_label))
  AND g.client_location_id IS DISTINCT FROM cl.id;

-- B. Wynd 28 (id=233): 5 tenant locations, names from AT before sunset -----
--    NO GDO link (0 GDOs ingested). Wynd's single client_code (e.g. 228-WYN)
--    is set by Fred in Jobber and flows in via webhook-jobber; not set here.
WITH wynd_bldg AS (
  SELECT id FROM public.properties
  WHERE client_id = 233
  ORDER BY is_primary DESC NULLS LAST, id ASC
  LIMIT 1
)
INSERT INTO public.client_locations (client_id, name, property_id, status, notes)
SELECT 233, t.name, wynd_bldg.id, 'active', t.note
FROM (VALUES
  ('Pasta',      'Wynd 28 tenant. Name lifted from Airtable 216-WYN before AT sunset 2026-06. GDO pending ingestion.'),
  ('Presidente', 'Wynd 28 tenant. Name lifted from Airtable 217-WYN before AT sunset 2026-06. GDO pending ingestion.'),
  ('CU4',        'Wynd 28 tenant. Name lifted from Airtable 218-WYN before AT sunset 2026-06. GDO pending ingestion.'),
  ('Nino Gordo', 'Wynd 28 tenant. Name lifted from Airtable 219-WYN before AT sunset 2026-06. GDO pending ingestion.'),
  ('Pari Pari',  'Wynd 28 tenant. Name lifted from Airtable 220-WYN before AT sunset 2026-06. GDO pending ingestion.')
) AS t(name, note)
CROSS JOIN wynd_bldg
ON CONFLICT (client_id, name) DO NOTHING;

COMMIT;

-- POST-SEED VERIFICATION ---------------------------------------------------
-- 1. 8 rows total (3 Casa Neos + 5 Wynd):
--    SELECT c.client_code, c.name AS client, cl.name AS location, cl.property_id, cl.status
--    FROM public.client_locations cl JOIN public.clients c ON c.id=cl.client_id
--    WHERE cl.client_id IN (233,369) ORDER BY c.client_code, cl.name;
-- 2. Casa Neos GDOs linked (3 rows, each client_location_id set):
--    SELECT g.gdo_number, g.location_label, cl.name AS location
--    FROM public.gdos g JOIN public.client_locations cl ON cl.id=g.client_location_id
--    WHERE g.client_id=369 ORDER BY g.gdo_number;
-- 3. Wynd locations have NO gdo link yet (expected 5, all unlinked):
--    SELECT count(*) FROM public.client_locations cl
--    LEFT JOIN public.gdos g ON g.client_location_id=cl.id
--    WHERE cl.client_id=233 AND g.id IS NULL;          -- expect 5
