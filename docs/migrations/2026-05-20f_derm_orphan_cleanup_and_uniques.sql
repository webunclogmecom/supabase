-- 2026-05-20f_derm_orphan_cleanup_and_uniques.sql
--
-- One-shot DERM cleanup + add unique constraints. Fred approved 2026-05-20
-- after the handoff in Building Apps/DERM Tracker/docs/handoffs/
-- orphan-manifest-audit-2026-05-20.md.
--
-- Removed (83 rows):
--   3 true dupes (losers, identical (client_id, WM#/YT#) to a kept row):
--     97  (kept 712, both WM#816562 / client 253 Fresko Bakery)
--     324 (kept 441, both WM#821038 / client 253 Fresko Bakery)
--     769 (kept 503, both YT='Broward' / client 373 — both losers + winners
--          had garbage 'Broward' literal in yellow_ticket_number; only
--          loser 769 deleted, 503 kept for the PDFs)
--   5 NULL-client orphans (4 from 5/16 webhook burst for WM#824533 +
--     ID 440 garbage placeholder):
--     440, 1004, 1008, 1012, 1013
--   75 hollow rows (had client_id but no WM#/YT#/PDFs/dump_date)
--
-- Kept as the only remaining NULL-client orphan:
--   959 (WM#822919, has both PDFs, AT Client field points to 207-BAR
--        Casa Neos BAR which is an unsynced AT client — needs to be
--        added to Jobber first per Rule 4 trust hierarchy)
--
-- Added 2 unique constraints to prevent future dupes at the DB layer:
--   derm_manifests_client_wm_unique (client_id, white_manifest_number)
--   derm_manifests_client_yt_unique (client_id, yellow_ticket_number)
-- NULLs are distinct in Postgres UNIQUE, so legitimate NULL cases (Broward
-- manifests have NULL WM#, Dade manifests have NULL YT#) aren't blocked.
--
-- Audit (Rule 8): derm_manifests + manifest_visits + entity_source_links
-- are all audited. All 83 deletes captured in audit.logs with full old_row
-- JSONB. Recoverable if needed.

BEGIN;

-- 1. Dedup: drop the 3 loser rows + their ESLs
DELETE FROM public.entity_source_links
  WHERE entity_type='derm_manifest' AND entity_id IN (97, 324, 769);
DELETE FROM public.derm_manifests WHERE id IN (97, 324, 769);

-- 2. NULL-client orphans (5)
DELETE FROM public.entity_source_links
  WHERE entity_type='derm_manifest' AND entity_id IN (440, 1004, 1008, 1012, 1013);
DELETE FROM public.derm_manifests
  WHERE id IN (440, 1004, 1008, 1012, 1013);

-- 3. Hollow rows (75)
DELETE FROM public.entity_source_links
  WHERE entity_type='derm_manifest' AND entity_id IN (
    SELECT id FROM public.derm_manifests
    WHERE client_id IS NOT NULL
      AND white_manifest_number IS NULL AND yellow_ticket_number IS NULL
      AND derm_manifest_url IS NULL AND derm_address_url IS NULL
      AND dump_ticket_date IS NULL
  );
DELETE FROM public.derm_manifests
  WHERE client_id IS NOT NULL
    AND white_manifest_number IS NULL AND yellow_ticket_number IS NULL
    AND derm_manifest_url IS NULL AND derm_address_url IS NULL
    AND dump_ticket_date IS NULL;

-- 4. Unique constraints — gates against future dupes
ALTER TABLE public.derm_manifests
  ADD CONSTRAINT derm_manifests_client_wm_unique UNIQUE (client_id, white_manifest_number);
ALTER TABLE public.derm_manifests
  ADD CONSTRAINT derm_manifests_client_yt_unique UNIQUE (client_id, yellow_ticket_number);

COMMIT;

-- Verification (run after deploy):
--   SELECT COUNT(*) FROM public.derm_manifests;
--   -- expect 931 (was 1014)
--   SELECT COUNT(*) FROM public.derm_manifests WHERE client_id IS NULL;
--   -- expect 1 (just id 959, awaiting Casa Neos BAR sync into Jobber)
