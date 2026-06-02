-- 2026-05-25u_drop_service_configs_permit_cols.sql
--
-- Phase 4b final: drop the legacy permit_* columns from
-- public.service_configs. All readers were rewired in 25t to read from
-- public.gdos (canonical). The webhook-airtable Edge Function was
-- redeployed in same session to stop writing to these columns.
--
-- BEFORE
-- public.service_configs had:
--   permit_number TEXT, permit_expiration DATE, permit_document_path TEXT
-- These were populated by the AT webhook with the client's GDO Number,
-- expiration, and PDF URL — duplicated across all of the client's service
-- configs (the workaround documented in CLAUDE.md). Phase 2 backfilled the
-- canonical gdos table. Phases 3 + 4a rewired all dependent views.
--
-- AFTER
-- The 3 columns are gone. Data is preserved in public.gdos. customer.permits
-- + 6 dependent views read from gdos via subqueries.
--
-- DESTRUCTIVE (column drop loses the data in the dropped columns) — but
-- the data was already preserved in public.gdos by Phase 2. No data loss
-- in any meaningful sense.
--
-- AUDIT (Rule 8): DDL doesn't generate audit.logs rows. The column drop
-- is logged in pg_event_trigger if needed for forensics.

BEGIN;

ALTER TABLE public.service_configs DROP COLUMN IF EXISTS permit_number;
ALTER TABLE public.service_configs DROP COLUMN IF EXISTS permit_expiration;
ALTER TABLE public.service_configs DROP COLUMN IF EXISTS permit_document_path;

COMMIT;

-- VERIFY
--   SELECT column_name FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='service_configs'
--     AND column_name LIKE 'permit%';
--   Expected: 0 rows.
--
--   SELECT COUNT(*)::int FROM customer.permits;          -- still works
--   SELECT COUNT(*)::int FROM ops.v_gdo_expiry;          -- still works
--   SELECT COUNT(*)::int FROM ops.service_configs;       -- still works
