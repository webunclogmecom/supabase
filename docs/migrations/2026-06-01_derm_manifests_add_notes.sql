-- 2026-06-01_derm_manifests_add_notes.sql
--
-- Add a free-text ops-notes column to derm_manifests for manifest-level annotations,
-- e.g. "paper manifest damaged / lost — doc permanently unavailable", or other known
-- accepted documentation gaps that ops should NOT keep chasing.
--
-- Nullable + additive (non-breaking). webhook-airtable's handleDermRecord does NOT
-- write this column, so Airtable syncs will not clobber it. Reversible:
--   ALTER TABLE public.derm_manifests DROP COLUMN notes;

ALTER TABLE public.derm_manifests ADD COLUMN IF NOT EXISTS notes TEXT;

COMMENT ON COLUMN public.derm_manifests.notes IS
  'Free-text ops annotation (e.g. damaged/lost paper manifest, known accepted doc gaps). Not synced from Airtable; safe from webhook overwrite.';

-- The derm.manifests + derm.manifest_health views were regenerated (CREATE OR REPLACE)
-- to append `dm.notes` as the last column, so the DERM Tracker app can surface the note.
-- (Done programmatically by appending ', dm.notes' before the main FROM; non-breaking.)

-- First use: manifest id 512 (Chima Steakhouse 010-CS, yellow ticket #296623,
-- service 2026-01-26) — DERM Address on file, DERM Manifest doc damaged/unavailable.
