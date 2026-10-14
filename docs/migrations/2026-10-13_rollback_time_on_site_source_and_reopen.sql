-- ROLLBACK of 2026-10-13_2020_time_on_site_source_and_reopen. Roll 2026-10-13_2025 back FIRST (its writers set the
-- column). The time cleared on visit 6564 is not restored here: audit.logs old_row holds it if it is ever wanted.
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP TRIGGER trg_zz_clear_time_on_site_on_reopen ON public.visits;
DROP FUNCTION public.fn_clear_time_on_site_on_reopen();
ALTER TABLE public.visits DROP CONSTRAINT visits_time_on_site_source_chk;
ALTER TABLE public.visits DROP COLUMN time_on_site_source;
COMMIT;
