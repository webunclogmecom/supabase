-- Rollback of 2026-11-14_2140_derm_manifest_archive_restore.sql.
-- Puts derm.fn_dirty_on_card_change back verbatim, drops the three functions, the CHECK and the three archive columns.
-- public.derm_delete_manifests is untouched.
-- 🛑 Roll back 2026-11-14_2200 (pick E, the client rows with no visit) FIRST: its rows carry a reason in these columns.
-- Dropping the columns loses every reason written since the forward migration (the rows stay soft-deleted; deleted_at is
-- not touched). Read the reasons out first if they matter:
--   select id, deleted_at, archive_reason, archive_note, archived_by from public.derm_manifests where archive_reason is not null;
-- Rehearsed in the same rolled-back transaction as the forward migration (rows2/rehearse_m1.mjs).

BEGIN;
SET LOCAL lock_timeout = '3s';
-- derm.fn_dirty_on_card_change back to its body before 2026-11-14_2140 (md5 5689022eea0d35122774914a1abc56de), verbatim
CREATE OR REPLACE FUNCTION derm.fn_dirty_on_card_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_folder text;
BEGIN
  v_folder := COALESCE(NEW.dump_folder, OLD.dump_folder);
  IF v_folder IS NULL THEN RETURN NULL; END IF;

  -- Clearing `completed` is enough: derm.fn_stamp_sheet_reopen_pin (trg_aa_reopen_pin) stamps
  -- reopened_at/by on the true->false flip, and that pin is what stops a machine re-completing it.
  UPDATE derm.stamp_sheet_status s
     SET completed = false, completed_at = NULL, completed_by = NULL, updated_at = now()
   WHERE s.dump_folder = v_folder AND s.completed;

  RETURN NULL;
END $function$;
DROP FUNCTION IF EXISTS derm.archived_manifest_rows();
DROP FUNCTION IF EXISTS public.derm_restore_manifests(bigint[]);
DROP FUNCTION IF EXISTS public.derm_archive_manifests(bigint[], text, text);
ALTER TABLE public.derm_manifests DROP CONSTRAINT IF EXISTS derm_manifests_archive_reason_chk;
ALTER TABLE public.derm_manifests DROP COLUMN IF EXISTS archive_reason, DROP COLUMN IF EXISTS archive_note, DROP COLUMN IF EXISTS archived_by;
DO $v$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'derm_manifests'
              AND column_name IN ('archive_reason', 'archive_note', 'archived_by'))
     OR to_regprocedure('public.derm_archive_manifests(bigint[], text, text)') IS NOT NULL
     OR to_regprocedure('public.derm_restore_manifests(bigint[])') IS NOT NULL
     OR to_regprocedure('derm.archived_manifest_rows()') IS NOT NULL
    THEN RAISE EXCEPTION 'VERIFY: the rollback left something behind'; END IF;
  IF md5(replace(pg_get_functiondef('public.derm_delete_manifests(bigint[])'::regprocedure), chr(13), '')) <> '80df507b5b7af25962cbcfff024856a3'
    THEN RAISE EXCEPTION 'VERIFY: public.derm_delete_manifests moved'; END IF;
  IF md5(replace(pg_get_functiondef('derm.fn_dirty_on_card_change()'::regprocedure), chr(13), '')) <> '5689022eea0d35122774914a1abc56de'
    THEN RAISE EXCEPTION 'VERIFY: derm.fn_dirty_on_card_change is not its old body'; END IF;
END $v$;
COMMIT;
