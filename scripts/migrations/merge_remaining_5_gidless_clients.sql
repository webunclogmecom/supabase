-- =============================================================================
-- Merge the 5 remaining gidless clients (with DERM data) into their already-
-- known Jobber-linked siblings — found via fuzzy name match in Jobber.
-- =============================================================================
-- Pairs (loser → keeper):
--   394 "54 Warehouse LLC"            → 151 "146- 54 Warehouse LLC"
--   395 "Good Food - Merav Halperin"  → 312 "Merav Halperin - Good Food"
--   406 "Shaulson Lyft Station"       → 322 "057-BAY Bayshore executive Plaza"
--   418 "57 Ocean Residences"         → 138 "142- 57 Ocean Residences"
--   420 "Puya Cantina"                → 332 "127 -PC Puya Cantina"
--
-- Each loser has DERM manifests + properties/contacts/service_configs that
-- need to move onto the keeper. None of the keepers currently have an
-- Airtable ESL, so the AT ESL transfers cleanly.
-- =============================================================================

BEGIN;

CREATE TEMP TABLE merge_pairs (loser_id bigint, keeper_id bigint) ON COMMIT DROP;
INSERT INTO merge_pairs VALUES
  (394, 151),
  (395, 312),
  (406, 322),
  (418, 138),
  (420, 332);

-- Drop loser-side rows that would conflict on UNIQUE constraints with keeper
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

-- Move all child rows
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

-- Move Airtable ESL onto keeper (cross-system traceability)
UPDATE entity_source_links esl
SET entity_id = m.keeper_id
FROM merge_pairs m
WHERE esl.entity_type = 'client'
  AND esl.entity_id = m.loser_id
  AND esl.source_system = 'airtable';

-- Backfill keeper.client_code from the loser (orphans had codes Yan typed
-- in Airtable; the Jobber-side names sometimes lack the NNN-XX prefix).
UPDATE clients k
SET client_code = COALESCE(k.client_code, l.client_code)
FROM merge_pairs m
JOIN clients l ON l.id = m.loser_id
WHERE k.id = m.keeper_id AND k.client_code IS NULL;

-- Delete the loser clients
DELETE FROM clients WHERE id IN (SELECT loser_id FROM merge_pairs);

COMMIT;
