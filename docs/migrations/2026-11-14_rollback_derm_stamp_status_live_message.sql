-- 2026-11-14_rollback_derm_stamp_status_live_message.sql
-- Undoes 2026-11-14_1235_derm_stamp_status_live_message.sql: derm.stamp_sheet_status stops sending
-- 'inval:stamp_sheet_status'. The six other tables keep theirs. Rehearsed in the migration's rolled-back rehearsal
-- (DROP TRIGGER, then an update wrote no message).
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP TRIGGER zzz_broadcast_inval ON derm.stamp_sheet_status;
DO $v$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'derm.stamp_sheet_status'::regclass AND tgname = 'zzz_broadcast_inval')
    THEN RAISE EXCEPTION 'VERIFY: trigger still there'; END IF;
  IF (SELECT count(*) FROM pg_trigger WHERE tgfoid = 'public.tg_broadcast_inval'::regproc) <> 6
    THEN RAISE EXCEPTION 'VERIFY: expected the six other tables to keep their trigger'; END IF;
END $v$;
COMMIT;
