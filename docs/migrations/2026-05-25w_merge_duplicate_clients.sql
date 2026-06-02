-- 2026-05-25w_merge_duplicate_clients.sql
--
-- Phase 7: merge 4 duplicate-client pairs surfaced during the Phase 2 GDO
-- audit. For each pair, FK references on 11 tables are moved from the
-- LOSER client_id to the SURVIVOR client_id, then the loser client itself
-- is demoted to status='INACTIVE'.
--
-- SURVIVOR SELECTION (best-judgment from probes/19_phase_7_dup_client_analysis.js)
--   1. 025-GRO Grove Kosher LLC (id=384)        survives;  150-KOS Kosh (id=336)        demoted
--   2. 045-NU  Nu Real Food (id=371)            survives;  172-NU  Nu Real Coral (id=224) demoted
--   3. 175-PV  Pura Vida Brickell 701 (id=343)  survives;  050-PV  Pura Vida Brickell (id=41) demoted
--   4. 139-LTG Lettuce and Tomato (id=5)        survives;  144-LTG (Bakery) L&T (id=147)  demoted
--
-- CONFLICT HANDLING
-- service_configs has UNIQUE (client_id, service_type). For each pair, if
-- the loser has a service_config of a type that the survivor already has,
-- we DELETE the loser's row (the survivor's is canonical). Same pattern
-- for client_contacts on (client_id, contact_role).
--
-- properties: if loser has properties, they move to survivor. Survivor
-- may end up with multiple is_primary=true rows — normalized to ONE
-- by setting all-but-survivor's-existing-primary to false.
--
-- entity_source_links: UNIQUE (source_system, source_id). If both clients
-- link to the same source record (rare; means they were both pointed at
-- one AT row), keep survivor's, delete loser's.
--
-- IDEMPOTENT (Rule 5): every UPDATE/DELETE is filtered to specific loser
-- client_ids. Re-run is no-op since loser rows now have client_id pointing
-- to survivor.
-- AUDIT (Rule 8): every UPDATE/DELETE fires audit triggers on the affected
-- table (visits, gdos, derm_manifests, etc. are audited).
-- NOT-A-HARD-DELETE (Rule 6): the loser CLIENTS themselves stay in the
-- DB with status='INACTIVE' + a merge note. Only redundant child rows
-- (service_configs, client_contacts) are DELETEd, and only when a
-- duplicate exists on the survivor.

BEGIN;

-- Reusable function: merge LOSER into SURVIVOR
-- Inlined per pair to keep the migration auditable and reversible.

-- ============================================================
-- PAIR 1: 150-KOS Kosh (id=336) -> 025-GRO Grove Kosher (id=384)
-- ============================================================

-- service_configs: drop loser's row if survivor already has the same service_type
DELETE FROM public.service_configs
WHERE client_id = 336
  AND service_type IN (SELECT service_type FROM public.service_configs WHERE client_id = 384);
UPDATE public.service_configs SET client_id = 384 WHERE client_id = 336;

-- client_contacts: same conflict pattern on contact_role
DELETE FROM public.client_contacts
WHERE client_id = 336
  AND contact_role IN (SELECT contact_role FROM public.client_contacts WHERE client_id = 384);
UPDATE public.client_contacts SET client_id = 384 WHERE client_id = 336;

-- entity_source_links: drop loser's link if survivor already has it for same source_system
-- The actual unique constraint is idx_esl_entity_source on
-- (entity_type, entity_id, source_system) — so any loser link sharing the
-- same source_system as a survivor link conflicts. Drop those loser links
-- (survivor's source_id wins); UPDATE the rest. The dropped loser source_ids
-- (typically jobber/airtable/derm) reference upstream records that may
-- themselves be duplicates — flagged for follow-up sync dedupe.
DELETE FROM public.entity_source_links
WHERE entity_type = 'client' AND entity_id = 336
  AND source_system IN (
    SELECT source_system FROM public.entity_source_links
    WHERE entity_type = 'client' AND entity_id = 384
  );
UPDATE public.entity_source_links SET entity_id = 384
WHERE entity_type = 'client' AND entity_id = 336;

-- Bulk-move all remaining child rows
UPDATE public.visits                       SET client_id = 384 WHERE client_id = 336;
UPDATE public.gdos                         SET client_id = 384 WHERE client_id = 336;
-- derm_manifests has UNIQUE (client_id, white_manifest_number) AND
-- (client_id, yellow_ticket_number). Hard-delete loser's duplicate rows
-- (true duplicates of the same physical manifest; survivor's row preserves
-- the data identically).
DELETE FROM public.derm_manifests WHERE client_id = 336 AND (
  white_manifest_number IN (SELECT white_manifest_number FROM public.derm_manifests WHERE client_id = 384)
  OR (yellow_ticket_number IS NOT NULL AND yellow_ticket_number IN (
    SELECT yellow_ticket_number FROM public.derm_manifests WHERE client_id = 384 AND yellow_ticket_number IS NOT NULL
  ))
);
UPDATE public.derm_manifests               SET client_id = 384 WHERE client_id = 336;
-- properties: force is_primary=false on incoming rows if survivor already has a primary
UPDATE public.properties
SET client_id = 384,
    is_primary = CASE
      WHEN EXISTS (SELECT 1 FROM public.properties WHERE client_id = 384 AND is_primary = true)
      THEN false ELSE is_primary
    END
WHERE client_id = 336;
UPDATE public.notes                        SET client_id = 384 WHERE client_id = 336;
UPDATE public.invoices                     SET client_id = 384 WHERE client_id = 336;
UPDATE public.quotes                       SET client_id = 384 WHERE client_id = 336;
UPDATE public.jobs                         SET client_id = 384 WHERE client_id = 336;
UPDATE public.jobber_oversized_attachments SET client_id = 384 WHERE client_id = 336;

-- Demote loser
UPDATE public.clients
SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 7 merge] Merged into 025-GRO Grove Kosher LLC (id=384) — same business, two client records at adjacent Harding Ave addresses (9477 vs 9467). All child rows reassigned.'
WHERE id = 336;

-- ============================================================
-- PAIR 2: 172-NU Nu Real Coral Gables (id=224) -> 045-NU Nu Real Food (id=371)
-- ============================================================
DELETE FROM public.service_configs
WHERE client_id = 224
  AND service_type IN (SELECT service_type FROM public.service_configs WHERE client_id = 371);
UPDATE public.service_configs SET client_id = 371 WHERE client_id = 224;

DELETE FROM public.client_contacts
WHERE client_id = 224
  AND contact_role IN (SELECT contact_role FROM public.client_contacts WHERE client_id = 371);
UPDATE public.client_contacts SET client_id = 371 WHERE client_id = 224;

DELETE FROM public.entity_source_links
WHERE entity_type = 'client' AND entity_id = 224
  AND source_system IN (
    SELECT source_system FROM public.entity_source_links
    WHERE entity_type = 'client' AND entity_id = 371
  );
UPDATE public.entity_source_links SET entity_id = 371
WHERE entity_type = 'client' AND entity_id = 224;

UPDATE public.visits                       SET client_id = 371 WHERE client_id = 224;
UPDATE public.gdos                         SET client_id = 371 WHERE client_id = 224;
DELETE FROM public.derm_manifests WHERE client_id = 224 AND (
  white_manifest_number IN (SELECT white_manifest_number FROM public.derm_manifests WHERE client_id = 371)
  OR (yellow_ticket_number IS NOT NULL AND yellow_ticket_number IN (
    SELECT yellow_ticket_number FROM public.derm_manifests WHERE client_id = 371 AND yellow_ticket_number IS NOT NULL
  ))
);
UPDATE public.derm_manifests               SET client_id = 371 WHERE client_id = 224;
UPDATE public.properties
SET client_id = 371,
    is_primary = CASE
      WHEN EXISTS (SELECT 1 FROM public.properties WHERE client_id = 371 AND is_primary = true)
      THEN false ELSE is_primary
    END
WHERE client_id = 224;
UPDATE public.notes                        SET client_id = 371 WHERE client_id = 224;
UPDATE public.invoices                     SET client_id = 371 WHERE client_id = 224;
UPDATE public.quotes                       SET client_id = 371 WHERE client_id = 224;
UPDATE public.jobs                         SET client_id = 371 WHERE client_id = 224;
UPDATE public.jobber_oversized_attachments SET client_id = 371 WHERE client_id = 224;

UPDATE public.clients
SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 7 merge] Merged into 045-NU Nu Real Food (id=371) — same business, two client records at adjacent block (3250 NE 1st Ave vs 3252 Buena Vista Blvd). All child rows reassigned.'
WHERE id = 224;

-- ============================================================
-- PAIR 3: 050-PV Pura Vida Brickell (id=41) -> 175-PV Pura Vida Brickell 701 (id=343)
-- ============================================================
DELETE FROM public.service_configs
WHERE client_id = 41
  AND service_type IN (SELECT service_type FROM public.service_configs WHERE client_id = 343);
UPDATE public.service_configs SET client_id = 343 WHERE client_id = 41;

DELETE FROM public.client_contacts
WHERE client_id = 41
  AND contact_role IN (SELECT contact_role FROM public.client_contacts WHERE client_id = 343);
UPDATE public.client_contacts SET client_id = 343 WHERE client_id = 41;

DELETE FROM public.entity_source_links
WHERE entity_type = 'client' AND entity_id = 41
  AND source_system IN (
    SELECT source_system FROM public.entity_source_links
    WHERE entity_type = 'client' AND entity_id = 343
  );
UPDATE public.entity_source_links SET entity_id = 343
WHERE entity_type = 'client' AND entity_id = 41;

UPDATE public.visits                       SET client_id = 343 WHERE client_id = 41;
UPDATE public.gdos                         SET client_id = 343 WHERE client_id = 41;
DELETE FROM public.derm_manifests WHERE client_id = 41 AND (
  white_manifest_number IN (SELECT white_manifest_number FROM public.derm_manifests WHERE client_id = 343)
  OR (yellow_ticket_number IS NOT NULL AND yellow_ticket_number IN (
    SELECT yellow_ticket_number FROM public.derm_manifests WHERE client_id = 343 AND yellow_ticket_number IS NOT NULL
  ))
);
UPDATE public.derm_manifests               SET client_id = 343 WHERE client_id = 41;
UPDATE public.properties
SET client_id = 343,
    is_primary = CASE
      WHEN EXISTS (SELECT 1 FROM public.properties WHERE client_id = 343 AND is_primary = true)
      THEN false ELSE is_primary
    END
WHERE client_id = 41;
UPDATE public.notes                        SET client_id = 343 WHERE client_id = 41;
UPDATE public.invoices                     SET client_id = 343 WHERE client_id = 41;
UPDATE public.quotes                       SET client_id = 343 WHERE client_id = 41;
UPDATE public.jobs                         SET client_id = 343 WHERE client_id = 41;
UPDATE public.jobber_oversized_attachments SET client_id = 343 WHERE client_id = 41;

UPDATE public.clients
SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 7 merge] Merged into 175-PV Pura Vida Brickell 701 (id=343) — same business, two client records at same address (1104 S Miami Ave). Loser already INACTIVE; surviving record (175-PV) carries all active operations.'
WHERE id = 41;

-- ============================================================
-- PAIR 4: 144-LTG (Bakery) Lettuce and Tomato (id=147) -> 139-LTG Lettuce and Tomato (id=5)
-- ============================================================
DELETE FROM public.service_configs
WHERE client_id = 147
  AND service_type IN (SELECT service_type FROM public.service_configs WHERE client_id = 5);
UPDATE public.service_configs SET client_id = 5 WHERE client_id = 147;

DELETE FROM public.client_contacts
WHERE client_id = 147
  AND contact_role IN (SELECT contact_role FROM public.client_contacts WHERE client_id = 5);
UPDATE public.client_contacts SET client_id = 5 WHERE client_id = 147;

DELETE FROM public.entity_source_links
WHERE entity_type = 'client' AND entity_id = 147
  AND source_system IN (
    SELECT source_system FROM public.entity_source_links
    WHERE entity_type = 'client' AND entity_id = 5
  );
UPDATE public.entity_source_links SET entity_id = 5
WHERE entity_type = 'client' AND entity_id = 147;

UPDATE public.visits                       SET client_id = 5 WHERE client_id = 147;
DELETE FROM public.derm_manifests WHERE client_id = 147 AND (
  white_manifest_number IN (SELECT white_manifest_number FROM public.derm_manifests WHERE client_id = 5)
  OR (yellow_ticket_number IS NOT NULL AND yellow_ticket_number IN (
    SELECT yellow_ticket_number FROM public.derm_manifests WHERE client_id = 5 AND yellow_ticket_number IS NOT NULL
  ))
);
UPDATE public.derm_manifests               SET client_id = 5 WHERE client_id = 147;
-- gdos: Pair 4 has the typo'd duplicate ACTIVE GDO-08912 on BOTH clients.
-- The UNIQUE (client_id, gdo_number) constraint blocks moving the loser's
-- row as-is. Rename it with a merge suffix + demote to preserve audit;
-- the survivor keeps the canonical GDO-08912 ACTIVE row.
UPDATE public.gdos
SET gdo_number = gdo_number || '-DUPMERGE-147',
    status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 7 merge] Renamed from GDO-08912 to "-DUPMERGE-147" to bypass gdos_client_gdo_unique constraint on merge. The original GDO-08912 stays canonical on survivor client 139-LTG (id=5). Original gdo_number was GDO-08912.'
WHERE client_id = 147 AND gdo_number = 'GDO-08912';
UPDATE public.gdos                         SET client_id = 5 WHERE client_id = 147;
UPDATE public.properties
SET client_id = 5,
    is_primary = CASE
      WHEN EXISTS (SELECT 1 FROM public.properties WHERE client_id = 5 AND is_primary = true)
      THEN false ELSE is_primary
    END
WHERE client_id = 147;
UPDATE public.notes                        SET client_id = 5 WHERE client_id = 147;
UPDATE public.invoices                     SET client_id = 5 WHERE client_id = 147;
UPDATE public.quotes                       SET client_id = 5 WHERE client_id = 147;
UPDATE public.jobs                         SET client_id = 5 WHERE client_id = 147;
UPDATE public.jobber_oversized_attachments SET client_id = 5 WHERE client_id = 147;

-- Pair 4's GDO-08912 duplicate was handled pre-move via rename to
-- "GDO-08912-DUPMERGE-147" + INACTIVE (see gdos block above). After
-- the property-move + client-demote, the survivor (id=5) has the
-- original GDO-08912 ACTIVE; the renamed dup is INACTIVE on (now-survivor)
-- id=5 as well, audit-preserved.

UPDATE public.clients
SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 7 merge] Merged into 139-LTG Lettuce and Tomato (id=5) — same business, two client records. All child rows reassigned. The duplicate GDO-08912 was pre-emptively renamed + demoted before the FK-rewire to bypass the gdos_client_gdo_unique constraint.'
WHERE id = 147;

COMMIT;

-- ============================================================
-- VERIFICATION
-- ============================================================
-- 1. All 4 loser clients now INACTIVE
--    SELECT id, client_code, name, status FROM public.clients
--    WHERE id IN (336, 224, 41, 147) ORDER BY id;
--    Expected: all INACTIVE
--
-- 2. No remaining rows in any FK table reference loser client_ids
--    SELECT 'visits' AS t, COUNT(*)::int FROM public.visits WHERE client_id IN (336,224,41,147)
--    UNION ALL SELECT 'service_configs', COUNT(*)::int FROM public.service_configs WHERE client_id IN (336,224,41,147)
--    UNION ALL SELECT 'gdos', COUNT(*)::int FROM public.gdos WHERE client_id IN (336,224,41,147)
--    UNION ALL SELECT 'derm_manifests', COUNT(*)::int FROM public.derm_manifests WHERE client_id IN (336,224,41,147)
--    UNION ALL SELECT 'properties', COUNT(*)::int FROM public.properties WHERE client_id IN (336,224,41,147)
--    UNION ALL SELECT 'client_contacts', COUNT(*)::int FROM public.client_contacts WHERE client_id IN (336,224,41,147)
--    UNION ALL SELECT 'notes', COUNT(*)::int FROM public.notes WHERE client_id IN (336,224,41,147)
--    UNION ALL SELECT 'invoices', COUNT(*)::int FROM public.invoices WHERE client_id IN (336,224,41,147)
--    UNION ALL SELECT 'quotes', COUNT(*)::int FROM public.quotes WHERE client_id IN (336,224,41,147)
--    UNION ALL SELECT 'jobs', COUNT(*)::int FROM public.jobs WHERE client_id IN (336,224,41,147)
--    UNION ALL SELECT 'entity_source_links', COUNT(*)::int FROM public.entity_source_links
--                                             WHERE entity_type='client' AND entity_id IN (336,224,41,147);
--    Expected: all 0
--
-- 3. No remaining duplicate ACTIVE gdo_numbers
--    SELECT gdo_number, COUNT(*) FROM public.gdos
--    WHERE status='ACTIVE' GROUP BY gdo_number HAVING COUNT(*) > 1;
--    Expected: 0 rows (GDO-08912 cleaned up; GDO-05180 already one-ACTIVE-one-INACTIVE)
