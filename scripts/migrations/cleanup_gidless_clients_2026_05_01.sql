-- =============================================================================
-- Cleanup gidless clients — 2026-05-01
-- =============================================================================
-- Per Fred's "no clients without Jobber" directive (same as visits):
--   B) Merge 27 mergeable gidless clients into their Jobber-linked siblings
--      (same client_code). Move properties/service_configs/client_contacts/
--      derm_manifests onto the keeper, then delete the gidless duplicate.
--   C) Hard-delete 8 empty-shell orphans (no FK data anywhere).
--
-- Phase D (5 orphans with DERM compliance data) is NOT in this migration —
-- handled separately after Fred decides delete-vs-INACTIVE.
-- =============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- B. Merge 27 gidless duplicates into Jobber-linked siblings
-- ----------------------------------------------------------------------------

-- Build the merge map: every gidless client_id mapped to its Jobber-linked
-- sibling (same client_code), only when sibling exists. None of the keepers
-- already have an Airtable ESL (verified zero conflicts in audit).
CREATE TEMP TABLE merge_map AS
SELECT
  gl.id AS loser_id,
  jl.id AS keeper_id,
  gl.client_code,
  (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=gl.id AND source_system='airtable' LIMIT 1) AS at_id_to_transfer
FROM clients gl
JOIN LATERAL (
  SELECT c.id FROM clients c
  WHERE c.client_code = gl.client_code AND c.id <> gl.id
    AND EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='jobber')
  ORDER BY c.id LIMIT 1
) jl ON true
WHERE NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='client' AND entity_id=gl.id AND source_system='jobber');

-- B.1: For child tables with UNIQUE(client_id, ...) constraints — drop loser
--      rows that conflict with keeper rows on the constraint key. Then move
--      the survivors.
DELETE FROM client_contacts cc
USING merge_map m
WHERE cc.client_id = m.loser_id
  AND cc.contact_role IN (SELECT contact_role FROM client_contacts WHERE client_id = m.keeper_id);

DELETE FROM service_configs sc
USING merge_map m
WHERE sc.client_id = m.loser_id
  AND sc.service_type IN (SELECT service_type FROM service_configs WHERE client_id = m.keeper_id);

DELETE FROM properties p
USING merge_map m
WHERE p.client_id = m.loser_id
  AND p.address IN (SELECT address FROM properties WHERE client_id = m.keeper_id);

-- B.2: Move all child rows from loser → keeper (no-op for tables that don't
-- have any rows on losers).
UPDATE properties      SET client_id = m.keeper_id FROM merge_map m WHERE properties.client_id      = m.loser_id;
UPDATE client_contacts SET client_id = m.keeper_id FROM merge_map m WHERE client_contacts.client_id = m.loser_id;
UPDATE service_configs SET client_id = m.keeper_id FROM merge_map m WHERE service_configs.client_id = m.loser_id;
UPDATE derm_manifests  SET client_id = m.keeper_id FROM merge_map m WHERE derm_manifests.client_id  = m.loser_id;
-- visits/jobs/invoices/notes/quotes/jobber_oversized_attachments: no data on losers per audit, but defensive:
UPDATE visits          SET client_id = m.keeper_id FROM merge_map m WHERE visits.client_id          = m.loser_id;
UPDATE jobs            SET client_id = m.keeper_id FROM merge_map m WHERE jobs.client_id            = m.loser_id;
UPDATE invoices        SET client_id = m.keeper_id FROM merge_map m WHERE invoices.client_id        = m.loser_id;
UPDATE notes           SET client_id = m.keeper_id FROM merge_map m WHERE notes.client_id           = m.loser_id;
UPDATE quotes          SET client_id = m.keeper_id FROM merge_map m WHERE quotes.client_id          = m.loser_id;
UPDATE jobber_oversized_attachments SET client_id = m.keeper_id FROM merge_map m WHERE jobber_oversized_attachments.client_id = m.loser_id;

-- B.3: Move the Airtable ESL onto the keeper (preserve cross-system traceability).
UPDATE entity_source_links esl
SET entity_id = m.keeper_id
FROM merge_map m
WHERE esl.entity_type = 'client'
  AND esl.entity_id = m.loser_id
  AND esl.source_system = 'airtable';

-- B.4: Delete the gidless duplicate clients (visit_assignments + manifest_visits
-- cascade automatically if any).
DELETE FROM clients
WHERE id IN (SELECT loser_id FROM merge_map);

-- ----------------------------------------------------------------------------
-- C. Hard-delete the 8 empty-shell orphans (no FK data, no merge target)
-- ----------------------------------------------------------------------------
-- Explicit list (verified empty in audit):
--   405 UNKNOWN_AT, 408 Casa Neos BAR, 409 Massimo & Umberto Inc,
--   413 ZZZ__Zohars (test), 419 aziz test,
--   436 Le Specialita, 437 YASU, 444 Tower 41 (already-soft-deleted tombstones)

-- Their Airtable ESL (if any)
DELETE FROM entity_source_links
WHERE entity_type='client' AND source_system='airtable'
  AND entity_id IN (405, 408, 409, 413, 419, 436, 437, 444);

-- The clients themselves
DELETE FROM clients
WHERE id IN (405, 408, 409, 413, 419, 436, 437, 444);

DROP TABLE merge_map;

COMMIT;
