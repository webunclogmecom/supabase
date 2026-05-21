-- 2026-05-20e_cleanup_empty_manifest_visits_links.sql
--
-- Cleanup 24 bad manifest_visits rows that linked visits to empty-placeholder
-- DERM records (no PDF, no manifest #, no dump date). Fred flagged
-- 191-TEN visit 5/18 showing "Linked manifests (1) — Pending paperwork"
-- card despite has_manifest=false in our view; the misleading card came
-- from the link still existing in manifest_visits.
--
-- Origin: 2026-05-19 backfill paired each AT-sourced DERM to the
-- nearest-date completed GT visit within ±10 days. For 24 visits, the
-- closest DERM was an empty placeholder ops created in AT but never
-- filled in. The link added no value and confused the UI.
--
-- After cleanup the 24 visits' detail pages render "No manifests filed
-- yet" — accurate. The 84 empty-placeholder derm_manifests rows
-- themselves stay (in case ops fills them in later, at which point the
-- patched Edge Function — webhook-airtable handleDermRecord — will
-- re-create the manifest_visits link from the AT GT Last Visit field).
--
-- Counts unchanged: Documented stays 352, Missing stays 185 (the strict
-- has_manifest rule from 2026-05-20d already classified these visits
-- as not-documented; this migration just fixes the link-table hygiene).
--
-- Audit (Rule 8): manifest_visits is in the audited set since 2026-05-18
-- (per ADR 010 opt-in for DERM Tracker). The 24 DELETEs are captured in
-- audit.logs with old_row JSONB — fully recoverable if needed.

BEGIN;

-- Before count for verification
-- SELECT COUNT(*) FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id=mv.manifest_id
--   WHERE dm.derm_manifest_url IS NULL AND dm.derm_address_url IS NULL
--     AND dm.white_manifest_number IS NULL AND dm.yellow_ticket_number IS NULL
--     AND dm.dump_ticket_date IS NULL;
-- Expected before this migration: 24. After: 0.

DELETE FROM public.manifest_visits mv
USING public.derm_manifests dm
WHERE mv.manifest_id = dm.id
  AND dm.derm_manifest_url      IS NULL
  AND dm.derm_address_url       IS NULL
  AND dm.white_manifest_number  IS NULL
  AND dm.yellow_ticket_number   IS NULL
  AND dm.dump_ticket_date       IS NULL;

COMMIT;
