-- 2026-06-01_derm_manifests_client_id_not_null.sql
--
-- Enforce that every DERM manifest belongs to a client. A null-client manifest is
-- uncategorizable: it can't appear in any client's compliance view and surfaces as a
-- P0 "Empty placeholder" in DERM Tracker Health. webhook-airtable already guards
-- against null-client inserts (handleDermRecord line ~537); this backstops the other
-- write path — the DERM Tracker app's anon INSERT — and anything else, at the DB level.
--
-- Safe to apply: as of 2026-06-01 every derm_manifests row has a client_id. The
-- null-client rows were cleaned in derm_null_client_cleanup_2026-06-01 (959 relinked
-- to Casa Neos; 1055 dup + 5 app-test rows removed) and the last one (1132) removed.
--
-- Reversible: ALTER TABLE public.derm_manifests ALTER COLUMN client_id DROP NOT NULL;

ALTER TABLE public.derm_manifests ALTER COLUMN client_id SET NOT NULL;

-- VERIFY: SELECT is_nullable FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='derm_manifests' AND column_name='client_id';  -- 'NO'
