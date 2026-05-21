-- 2026-05-20h_derm_delete_pdfless_visitless_ghosts.sql
--
-- Sweep 52 ghost derm_manifests rows that had a WM# / YT# but no PDFs and
-- no manifest_visits links. Fred approved 2026-05-20 after seeing one of
-- them (id 1017, MR. Pasta FACTORY, WM#824533) cluttering the DERM
-- Tracker manifests page.
--
-- These were ops placeholders: typed a manifest number into AT, never
-- uploaded the PDF, never linked the visit. Of the 52, only 1 had a
-- matchable visit in our DB at the time of cleanup (Jobber sync didn't
-- cover March/April 2025 visits, so the historical ones had no visit to
-- link to even if we wanted to).
--
-- Distribution:
--   March 2025:  36 rows (pre-Jobber-sync history)
--   April 2025:  14 rows (pre-Jobber-sync history)
--   May   2026:   2 rows (recent placeholders ops abandoned)
--
-- Per Fred: "the audit trail is when everything is in prod" — audit.logs
-- captured all 52 DELETEs with full old_row JSONB, recoverable if needed.
--
-- Note: rows that have visits linked but no PDFs (e.g. ids 1002 + 1009 for
-- WM#824533) are NOT deleted. They're "partially documented" (we know
-- which visit they cover, just missing the PDF). They show up under
-- "needs paperwork" in the manifest health view, not the main list.

BEGIN;

DELETE FROM public.entity_source_links
  WHERE entity_type='derm_manifest' AND entity_id IN (
    SELECT dm.id FROM public.derm_manifests dm
    WHERE dm.derm_manifest_url IS NULL AND dm.derm_address_url IS NULL
      AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id=dm.id)
      AND (dm.white_manifest_number IS NOT NULL OR dm.yellow_ticket_number IS NOT NULL)
  );

DELETE FROM public.derm_manifests dm
  WHERE dm.derm_manifest_url IS NULL AND dm.derm_address_url IS NULL
    AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id=dm.id)
    AND (dm.white_manifest_number IS NOT NULL OR dm.yellow_ticket_number IS NOT NULL);

COMMIT;

-- Verification:
--   SELECT COUNT(*) FROM public.derm_manifests;  -- expect 885 (was 937)
--   SELECT COUNT(*) FROM public.derm_manifests dm
--     WHERE dm.derm_manifest_url IS NULL AND dm.derm_address_url IS NULL
--       AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id=dm.id)
--       AND (dm.white_manifest_number IS NOT NULL OR dm.yellow_ticket_number IS NOT NULL);
--   -- expect 0
