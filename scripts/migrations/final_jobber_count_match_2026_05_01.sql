-- =============================================================================
-- Final Jobber/DB count alignment — 2026-05-01
-- =============================================================================
-- Pre: 393 clients in DB, 388 in Jobber (5 too many).
-- Diff: 6 stale-GID rows in DB + 1 missing Jobber client.
--
-- Merges (loser → keeper):
--   429 Bibi Shamin       → 327 (real Bibi Shamin)
--   431 1265 NBP, LLC     → 387 (real 1265 NBP, LLC)
--   446 199-STK JZ Steak  → 363 (real, has code 199-JZ)
--   447 Cacio e Pepe      → 364 (real, has code 206-CAC)
--
-- Hard-delete (empty + raw-numeric ESL = old webhook bug residue):
--   441 (no name, numeric ESL '133721540')
--   443 (no name, numeric ESL '123017289')
--
-- Carne en Vara (new in Jobber today) imported separately via webhook replay.
-- After this migration: DB 388 = Jobber 388.
-- =============================================================================

BEGIN;

CREATE TEMP TABLE merge_pairs (loser_id bigint, keeper_id bigint) ON COMMIT DROP;
INSERT INTO merge_pairs VALUES
  (429, 327),  -- Bibi Shamin
  (431, 387),  -- 1265 NBP, LLC
  (446, 363),  -- 199-STK JZ Steak House
  (447, 364);  -- Cacio e Pepe

-- 1. Drop conflicts on UNIQUE (client_id, ...) tables
DELETE FROM client_contacts cc USING merge_pairs m
WHERE cc.client_id = m.loser_id
  AND cc.contact_role IN (SELECT contact_role FROM client_contacts WHERE client_id = m.keeper_id);

DELETE FROM service_configs sc USING merge_pairs m
WHERE sc.client_id = m.loser_id
  AND sc.service_type IN (SELECT service_type FROM service_configs WHERE client_id = m.keeper_id);

DELETE FROM properties p USING merge_pairs m
WHERE p.client_id = m.loser_id
  AND p.address IN (SELECT address FROM properties WHERE client_id = m.keeper_id);

-- 2. Move all child rows from loser → keeper
UPDATE properties      SET client_id = m.keeper_id FROM merge_pairs m WHERE properties.client_id      = m.loser_id;
UPDATE client_contacts SET client_id = m.keeper_id FROM merge_pairs m WHERE client_contacts.client_id = m.loser_id;
UPDATE service_configs SET client_id = m.keeper_id FROM merge_pairs m WHERE service_configs.client_id = m.loser_id;
UPDATE derm_manifests  SET client_id = m.keeper_id FROM merge_pairs m WHERE derm_manifests.client_id  = m.loser_id;
UPDATE visits          SET client_id = m.keeper_id FROM merge_pairs m WHERE visits.client_id          = m.loser_id;
UPDATE jobs            SET client_id = m.keeper_id FROM merge_pairs m WHERE jobs.client_id            = m.loser_id;
UPDATE invoices        SET client_id = m.keeper_id FROM merge_pairs m WHERE invoices.client_id        = m.loser_id;
UPDATE notes           SET client_id = m.keeper_id FROM merge_pairs m WHERE notes.client_id           = m.loser_id;
UPDATE quotes          SET client_id = m.keeper_id FROM merge_pairs m WHERE quotes.client_id          = m.loser_id;
UPDATE jobber_oversized_attachments SET client_id = m.keeper_id FROM merge_pairs m WHERE jobber_oversized_attachments.client_id = m.loser_id;

-- 3. Drop the stale Jobber ESL on losers (the keepers already have the real GID)
DELETE FROM entity_source_links
WHERE entity_type='client' AND source_system='jobber'
  AND entity_id IN (SELECT loser_id FROM merge_pairs);

-- 4. Move losers' Airtable/Samsara ESLs onto keepers (if no conflict)
DELETE FROM entity_source_links del
USING merge_pairs m, entity_source_links keep
WHERE del.entity_type = 'client' AND del.entity_id = m.loser_id
  AND del.source_system IN ('airtable','samsara')
  AND keep.entity_type = 'client' AND keep.entity_id = m.keeper_id
  AND keep.source_system = del.source_system;

UPDATE entity_source_links esl SET entity_id = m.keeper_id
FROM merge_pairs m
WHERE esl.entity_type='client' AND esl.entity_id = m.loser_id;

-- 5. Delete the loser clients
DELETE FROM clients WHERE id IN (SELECT loser_id FROM merge_pairs);

-- 6. Hard-delete the 2 empty-name stale ones (no useful data, raw-numeric ESL bugs)
DELETE FROM entity_source_links
WHERE entity_type='client' AND entity_id IN (441, 443);

DELETE FROM clients WHERE id IN (441, 443);

COMMIT;
