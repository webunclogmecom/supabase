-- ============================================================================
-- Pre-sunset cleanup: 2026-05-04
-- Goal: a clean canonical dataset before Jobber + Airtable sunset in May 2026.
-- Removes pure-test records and one-off non-customer entries that came from
-- Jobber but never produced any business data.
--
-- Per Fred 2026-05-04, executed batch:
--   - HARD DELETE 16 test/junk clients + their ESL refs
--   - HARD DELETE 1 orphan property (id 208) + its ESL ref
--   - SOFT DELETE (status='INACTIVE') 5 borderline clients per Fred's notes
--   - LEAVE 085-VA Villa Azur (already INACTIVE) + Jewish Learning Center
--     (real client per Fred — has Jobber job #10000252 we haven't synced yet)
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- A. Hard delete test client records (15 X-prefix + 1 explicit "test test"
--    + 1 "NOT USE" prefix). All confirmed: 0 visits / 0 invoices / 0 jobs /
--    0 contacts. Their entity_source_links go too.
-- ---------------------------------------------------------------------------
DELETE FROM entity_source_links
WHERE entity_type = 'client'
  AND entity_id IN (187, 188, 189, 190, 191, 192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 271, 314);

DELETE FROM clients
WHERE id IN (187, 188, 189, 190, 191, 192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 271, 314);

-- ---------------------------------------------------------------------------
-- B. Hard delete orphan property 208 (Alta Standard One LLC half-empty
--    Boca Raton secondary record — no address, no visits, no jobs).
--    Alta Standard's primary property 396 (Beverly Hills) is preserved.
-- ---------------------------------------------------------------------------
DELETE FROM entity_source_links
WHERE entity_type = 'property' AND entity_id = 208;

DELETE FROM properties WHERE id = 208;

-- ---------------------------------------------------------------------------
-- C. Soft delete (status='INACTIVE') the 5 borderline clients per Fred's
--    specific feedback. They had one-off historical service or are non-
--    customer entities (vendor/internal note). Keep for audit trail.
-- ---------------------------------------------------------------------------
UPDATE clients SET status = 'INACTIVE', updated_at = now()
WHERE id IN (
  43,   -- Serendipity Surfside (one-time Feb 13, 2025 per Fred)
  117,  -- Ilan Attoun (one-time)
  176,  -- Pro Line (repair truck shop — vendor, not customer)
  268,  -- Commissary toilet (internal note, not a customer)
  337   -- Dylan (single first name, no other info)
);

-- ---------------------------------------------------------------------------
-- Note: NOT touched
--   id 50  (085-VA Villa Azur) — already INACTIVE
--   id 257 (Jewish learning Center) — Fred confirmed real, has Jobber job
--          #10000252 that needs investigation (sync gap, not a delete target)
--   id 245 (Alta Standard One LLC) — real client with invoice #1873 from
--          Jan 20 (also a sync gap; the invoice didn't make it to our DB).
--          Only their orphan secondary property 208 gets deleted.
-- ---------------------------------------------------------------------------

COMMIT;
