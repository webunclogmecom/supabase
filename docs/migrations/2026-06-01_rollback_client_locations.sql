-- 2026-06-01_rollback_client_locations.sql
--
-- Reverses 2026-06-01_client_locations.sql + 2026-06-01b_seed_casa_neos_wynd...sql.
-- Order matters: DROP the gdos.client_location_id column FIRST (this removes the FK
-- constraint + its index + un-links the 3 Casa Neos GDOs), THEN drop the table.
-- public.set_updated_at() and audit.log_change() are SHARED -> do NOT drop them.
--
-- Hard-delete note (Rule 6): this drops a brand-new identity table + a brand-new
-- column. No canonical business data is lost — the GDOs themselves, their
-- location_labels, visits, manifests and the Wynd client (id=233) all survive. The
-- Wynd tenant NAMES survive in reports/_wyn_at_verify.json (captured 2026-06-01).
--
-- audit.logs rows from the seed INSERTs/UPDATEs are RETAINED (append-only, ADR 010).

BEGIN;
ALTER TABLE public.gdos DROP COLUMN IF EXISTS client_location_id;
DROP TABLE IF EXISTS public.client_locations CASCADE;
COMMIT;

-- Post-rollback:
--   SELECT to_regclass('public.client_locations');                                       -- NULL
--   SELECT column_name FROM information_schema.columns
--     WHERE table_schema='public' AND table_name='gdos' AND column_name='client_location_id';  -- 0 rows
