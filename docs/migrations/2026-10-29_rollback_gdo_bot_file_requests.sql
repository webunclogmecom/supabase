-- ============================================================================
-- ROLLBACK of 2026-10-29_1245_gdo_bot_file_requests.sql
-- ============================================================================
-- Puts trg_rpa_submission_dry_run_guard back to its 2026-08-19_1558 body (md5 4dc90508...)
-- and drops public.gdo_bot_file_requests.
--
-- 🛑 It REFUSES while a live submission on a pre-cutoff visit relies on a logged press: the
--    old guard also runs on UPDATE, so such a row could no longer be corrected
--    (fn_correct_gdo_report) once the branch is gone. Decide what those filings are first.
-- The ledger is copied into the RAISE text of the refusal only; take a JSON backup of it
-- (backups/) before running this when it holds rows.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path = public, pg_catalog;

DO $pre$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.derm_portal_submissions s
      JOIN public.visits v ON v.id = s.visit_id
      JOIN public.gdo_bot_file_requests r ON r.visit_id = s.visit_id AND r.run_id = s.run_id AND NOT r.dry_run
     WHERE NOT s.dry_run AND v.visit_date < public.rpa_launch_cutoff()) THEN
    RAISE EXCEPTION 'rollback refused: live button filings exist on pre-cutoff visits';
  END IF;
END $pre$;

CREATE OR REPLACE FUNCTION public.trg_rpa_submission_dry_run_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE v_vdate date;
BEGIN
  -- A manual filing recorded by a person is outside this guard's scope. It is marked by a
  -- run_id the bot never uses, and pre-cutoff visits are excluded from the bot's queue by
  -- date regardless, so such a row cannot change what the bot does. See the migration header.
  IF NEW.run_id LIKE 'manual-%' AND NEW.dry_run IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  SELECT visit_date INTO v_vdate FROM public.visits WHERE id = NEW.visit_id;
  IF v_vdate IS NOT NULL AND NEW.dry_run <> (v_vdate < public.rpa_launch_cutoff()) THEN
    RAISE EXCEPTION 'dry_run=% disagrees with visit % service-date classification (visit_date %)',
      NEW.dry_run, NEW.visit_id, v_vdate;
  END IF;
  RETURN NEW;
END $function$;

DROP TABLE public.gdo_bot_file_requests;

DO $verify$
BEGIN
  IF md5(pg_get_functiondef('public.trg_rpa_submission_dry_run_guard()'::regprocedure))
     <> '4dc9050887046081e64922b8ffcc53f8' THEN
    RAISE EXCEPTION 'rollback: guard body is not the 2026-08-19_1558 one';
  END IF;
  IF to_regclass('public.gdo_bot_file_requests') IS NOT NULL THEN
    RAISE EXCEPTION 'rollback: table still present';
  END IF;
END $verify$;

COMMIT;
