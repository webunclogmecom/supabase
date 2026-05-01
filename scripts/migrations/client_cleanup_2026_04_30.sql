-- ============================================================================
-- Client cleanup 2026-04-30
-- ============================================================================
-- Three things in one transactional migration:
--   1. Backfill client_code from name where the name has the NNN-XX prefix
--      (44 ACTIVE clients Yan typed the prefix into Jobber but never put in
--      Airtable, so they had no code source).
--   2. Soft-delete 777-YA Yan's Restaurant (id=47) — duplicate test client
--      Yan made in Jobber separate from real 112-YA. Per Fred 2026-04-30.
--   3. Merge 3 duplicate-pair clients created by the OLD webhook GID bug
--      (raw-numeric ESL vs base64 GID ESL — webhook stored numeric, populate
--      stored GID, so webhook re-created on subsequent fires).
--      Pairs: 353/436 Le Specialita, 354/437 YASU, 376/444 Tower 41.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Backfill client_code from name (NNN-XX prefix)
-- ---------------------------------------------------------------------------
-- Match cases: '062-TCE The carrot express ...', '049-PV Pura Vida ...', etc.
-- Strict match only: requires at least one alphanumeric char after the dash.
-- Skip names like '128- Meir Fellig' (no XX) and '127 -PC ...' (space gap).

UPDATE clients
SET client_code = SUBSTRING(name FROM '^\s*(\d{3}-[A-Z0-9]+)')
WHERE client_code IS NULL
  AND name ~ '^\s*\d{3}-[A-Z0-9]+';

-- Report what just got backfilled
DO $$
DECLARE n_filled INT;
BEGIN
  SELECT COUNT(*) INTO n_filled
  FROM clients
  WHERE client_code IS NOT NULL AND status='ACTIVE';
  RAISE NOTICE 'After backfill: % ACTIVE clients now have client_code', n_filled;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Soft-delete duplicate 777-YA Yan's Restaurant (id=47)
-- ---------------------------------------------------------------------------
UPDATE clients
SET status='INACTIVE',
    notes = COALESCE(notes||E'\n', '')
            || '[2026-04-30] Soft-deleted per Fred — duplicate of 112-YA Yan''s '
            || 'Restaurant (id=381). Created in Jobber but no Airtable link.'
WHERE id=47;

-- ---------------------------------------------------------------------------
-- 3. Merge duplicate pairs (newer raw-numeric ESL row → older GID ESL row)
-- ---------------------------------------------------------------------------
-- Pattern for each pair (older=keeper, newer=dup):
--   a. Move all FK child rows from newer → older (visits/jobs/notes/etc.)
--   b. For invoices: DELETE the duplicate invoices outright (Tower 41 only —
--      same Jobber invoice IDs 153255291/154169394, stale totals)
--   c. Delete the duplicate populate-generated property on newer (same address
--      as older's, just an artifact of populate creating a primary property
--      for what looked like a brand-new client)
--   d. Delete bad raw-numeric ESL on newer
--   e. Soft-delete newer client row

-- Helper: for tables with UNIQUE(client_id, <role-ish>), we delete conflicting
-- newer rows first (where the same role/type already exists on older) then
-- move the remaining rows.

-- ----- Pair 1: Le Specialita 353 (keep) ← 436 (merge in) -----
DELETE FROM client_contacts WHERE client_id=436
  AND contact_role IN (SELECT contact_role FROM client_contacts WHERE client_id=353);
DELETE FROM service_configs WHERE client_id=436
  AND service_type IN (SELECT service_type FROM service_configs WHERE client_id=353);

UPDATE visits          SET client_id=353 WHERE client_id=436;
UPDATE jobs            SET client_id=353 WHERE client_id=436;
UPDATE invoices        SET client_id=353 WHERE client_id=436;
UPDATE notes           SET client_id=353 WHERE client_id=436;
UPDATE quotes          SET client_id=353 WHERE client_id=436;
UPDATE service_configs SET client_id=353 WHERE client_id=436;
UPDATE client_contacts SET client_id=353 WHERE client_id=436;
UPDATE derm_manifests  SET client_id=353 WHERE client_id=436;
UPDATE jobber_oversized_attachments SET client_id=353 WHERE client_id=436;

DELETE FROM properties WHERE client_id=436;  -- duplicate populate-gen primary
DELETE FROM entity_source_links WHERE entity_type='client' AND entity_id=436;
UPDATE clients SET status='INACTIVE',
  notes=COALESCE(notes||E'\n','')||'[2026-04-30] Merged into client #353. Old webhook GID-vs-numeric bug.'
  WHERE id=436;

-- ----- Pair 2: YASU 354 (keep) ← 437 (merge in) -----
DELETE FROM client_contacts WHERE client_id=437
  AND contact_role IN (SELECT contact_role FROM client_contacts WHERE client_id=354);
DELETE FROM service_configs WHERE client_id=437
  AND service_type IN (SELECT service_type FROM service_configs WHERE client_id=354);

UPDATE visits          SET client_id=354 WHERE client_id=437;
UPDATE jobs            SET client_id=354 WHERE client_id=437;
UPDATE invoices        SET client_id=354 WHERE client_id=437;
UPDATE notes           SET client_id=354 WHERE client_id=437;
UPDATE quotes          SET client_id=354 WHERE client_id=437;
UPDATE service_configs SET client_id=354 WHERE client_id=437;
UPDATE client_contacts SET client_id=354 WHERE client_id=437;
UPDATE derm_manifests  SET client_id=354 WHERE client_id=437;
UPDATE jobber_oversized_attachments SET client_id=354 WHERE client_id=437;

DELETE FROM properties WHERE client_id=437;
DELETE FROM entity_source_links WHERE entity_type='client' AND entity_id=437;
UPDATE clients SET status='INACTIVE',
  notes=COALESCE(notes||E'\n','')||'[2026-04-30] Merged into client #354. Old webhook GID-vs-numeric bug.'
  WHERE id=437;

-- ----- Pair 3: Tower 41 376 (keep) ← 444 (merge in) -----
-- Tower 41 invoices on 444 are STALE duplicates of 376's (same Jobber invoice
-- IDs, different totals). Delete them outright; don't move.
DELETE FROM entity_source_links
  WHERE entity_type='invoice' AND entity_id IN (1667, 1668);
DELETE FROM invoices WHERE id IN (1667, 1668);

DELETE FROM client_contacts WHERE client_id=444
  AND contact_role IN (SELECT contact_role FROM client_contacts WHERE client_id=376);
DELETE FROM service_configs WHERE client_id=444
  AND service_type IN (SELECT service_type FROM service_configs WHERE client_id=376);

UPDATE visits          SET client_id=376 WHERE client_id=444;
UPDATE jobs            SET client_id=376 WHERE client_id=444;
UPDATE notes           SET client_id=376 WHERE client_id=444;
UPDATE quotes          SET client_id=376 WHERE client_id=444;
UPDATE service_configs SET client_id=376 WHERE client_id=444;
UPDATE client_contacts SET client_id=376 WHERE client_id=444;
UPDATE derm_manifests  SET client_id=376 WHERE client_id=444;
UPDATE jobber_oversized_attachments SET client_id=376 WHERE client_id=444;

DELETE FROM properties WHERE client_id=444;
DELETE FROM entity_source_links WHERE entity_type='client' AND entity_id=444;
UPDATE clients SET status='INACTIVE',
  notes=COALESCE(notes||E'\n','')||'[2026-04-30] Merged into client #376. Old webhook GID-vs-numeric bug.'
  WHERE id=444;

COMMIT;
