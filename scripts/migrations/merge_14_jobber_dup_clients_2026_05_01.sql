-- =============================================================================
-- Merge 14 duplicate-Jobber-client groups — 2026-05-01
-- =============================================================================
-- Each pair represents the SAME Jobber client stored twice in our DB:
--   - 13 pairs: keeper has base64 GID, loser has same client as raw numeric
--     (legacy webhook bug stored numericId in entity_source_links).
--   - 140-TYO: keeper is 302 (real Jobber GID for "140-TCY Tacos yoyo");
--     loser is 140 (stale GID that no longer exists in Jobber).
--
-- For each pair: move all child rows + ESL from loser → keeper, then
-- hard-delete the loser client and its bad ESL.
-- =============================================================================

BEGIN;

CREATE TEMP TABLE merge_pairs (loser_id bigint, keeper_id bigint) ON COMMIT DROP;
INSERT INTO merge_pairs VALUES
  (445, 369),  -- 009-CN
  (426, 378),  -- 027-HER
  (428, 361),  -- 034-LG
  (427, 379),  -- 062-TCE
  (440, 380),  -- 070-TCE
  (140, 302),  -- 140-TYO (stale GID → real 140-TCY)
  (430, 385),  -- 148-MOR
  (442, 334),  -- 152-DAV
  (432, 204),  -- 154-PV
  (438, 382),  -- 170-PV
  (439, 375),  -- 186-PV
  (433, 383),  -- 191-TEN
  (434, 307),  -- 196-PV
  (435, 259);  -- 197-BGT

-- Drop conflicting child rows that would violate UNIQUE constraints
DELETE FROM client_contacts cc
USING merge_pairs m
WHERE cc.client_id = m.loser_id
  AND cc.contact_role IN (SELECT contact_role FROM client_contacts WHERE client_id = m.keeper_id);

DELETE FROM service_configs sc
USING merge_pairs m
WHERE sc.client_id = m.loser_id
  AND sc.service_type IN (SELECT service_type FROM service_configs WHERE client_id = m.keeper_id);

DELETE FROM properties p
USING merge_pairs m
WHERE p.client_id = m.loser_id
  AND p.address IN (SELECT address FROM properties WHERE client_id = m.keeper_id);

-- Move all child rows from loser → keeper
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

-- Delete the bad ESLs on losers (raw-numeric Jobber GIDs and stale Jobber GIDs)
DELETE FROM entity_source_links
WHERE entity_type='client' AND source_system='jobber'
  AND entity_id IN (SELECT loser_id FROM merge_pairs);

-- Move losers' Airtable ESL onto keepers (only if keeper doesn't already have one)
UPDATE entity_source_links esl
SET entity_id = m.keeper_id
FROM merge_pairs m
WHERE esl.entity_type='client' AND esl.source_system='airtable'
  AND esl.entity_id = m.loser_id
  AND NOT EXISTS (
    SELECT 1 FROM entity_source_links other
    WHERE other.entity_type='client' AND other.source_system='airtable'
      AND other.entity_id = m.keeper_id
  );
-- Any remaining (conflict) losers' AT ESLs — delete (keeper already has one)
DELETE FROM entity_source_links
WHERE entity_type='client' AND source_system='airtable'
  AND entity_id IN (SELECT loser_id FROM merge_pairs);

-- Same for samsara
UPDATE entity_source_links esl
SET entity_id = m.keeper_id
FROM merge_pairs m
WHERE esl.entity_type='client' AND esl.source_system='samsara'
  AND esl.entity_id = m.loser_id
  AND NOT EXISTS (SELECT 1 FROM entity_source_links other
    WHERE other.entity_type='client' AND other.source_system='samsara' AND other.entity_id = m.keeper_id);
DELETE FROM entity_source_links
WHERE entity_type='client' AND source_system='samsara'
  AND entity_id IN (SELECT loser_id FROM merge_pairs);

-- Hard-delete the loser clients
DELETE FROM clients WHERE id IN (SELECT loser_id FROM merge_pairs);

COMMIT;
