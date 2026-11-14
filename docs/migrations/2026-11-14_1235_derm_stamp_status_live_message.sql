-- 2026-11-14_1235_derm_stamp_status_live_message.sql
--
-- WHAT
-- ----
-- A sheet's completion travels live: derm.stamp_sheet_status gets the same statement trigger the six live tables
-- already carry (public.tg_broadcast_inval), so every insert, update or delete there sends one private broadcast on
-- topic 'inval:stamp_sheet_status' with payload {table, op, at, id}. Another screen that listens reads the sheet again
-- instead of keeping the old state until a reload.
--
-- WHY
-- ---
-- Ops Portal Stage D, the new stamping screen (plan `Building Apps/Ops Portal/docs/specs/2026-11-14-stamping-screen-
-- build-plan.md`, row S5; Fred, 2026-11-14: "Yes" to building it next). Spec items M30 and C8 item 12: after Mark
-- completed or Reopen on one screen, another open screen and the Manifests rows still show the old state. Stage C's
-- rows need the same message ("The row redraws after stamping"); whichever ships first builds it, once: this is it.
--
-- REACH
-- -----
-- Old Stamp host (stamp.unclogme.app): none. It listens to inval:derm_manifests and inval:address_row_map only.
-- Nothing else changes: the realtime policy app_inval_read already admits every 'inval:%' topic for anon and
-- authenticated (unchanged); the payload names the table, never a row or a client.
--
-- REHEARSED (rolled back, 2026-11-14 ~12:30 ET, on test ticket #111111):
--   control: an update with no trigger wrote 0 messages; with the trigger: exactly 1 message on
--   inval:stamp_sheet_status, private, payload {table: stamp_sheet_status, op: UPDATE, at, id}; the five other
--   inval topics in the table did not move; the trigger definition equals address_row_map's with the table name
--   swapped; rollback (DROP TRIGGER) rehearsed in the same transaction: no message after it.
-- Rollback: 2026-11-14_rollback_derm_stamp_status_live_message.sql.

BEGIN;
SET LOCAL lock_timeout = '3s';

-- GUARD: the function and the state this was written against
DO $g$
BEGIN
  IF md5(replace(pg_get_functiondef('public.tg_broadcast_inval'::regproc), chr(13), '')) <> '5a7c77a9ecdab89836b90e1d912d4126'
    THEN RAISE EXCEPTION 'GUARD: public.tg_broadcast_inval changed since it was read'; END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'derm.stamp_sheet_status'::regclass AND tgname = 'zzz_broadcast_inval')
    THEN RAISE EXCEPTION 'GUARD: derm.stamp_sheet_status already has zzz_broadcast_inval'; END IF;
  IF (SELECT count(*) FROM pg_trigger WHERE tgfoid = 'public.tg_broadcast_inval'::regproc) <> 6
    THEN RAISE EXCEPTION 'GUARD: expected 6 tables on tg_broadcast_inval'; END IF;
END $g$;

CREATE TRIGGER zzz_broadcast_inval AFTER INSERT OR DELETE OR UPDATE ON derm.stamp_sheet_status
  FOR EACH STATEMENT EXECUTE FUNCTION public.tg_broadcast_inval();

-- VERIFY
DO $v$
BEGIN
  IF (SELECT pg_get_triggerdef(t.oid) FROM pg_trigger t WHERE t.tgrelid = 'derm.stamp_sheet_status'::regclass AND t.tgname = 'zzz_broadcast_inval')
     IS DISTINCT FROM 'CREATE TRIGGER zzz_broadcast_inval AFTER INSERT OR DELETE OR UPDATE ON derm.stamp_sheet_status FOR EACH STATEMENT EXECUTE FUNCTION tg_broadcast_inval()'
    THEN RAISE EXCEPTION 'VERIFY: trigger definition is not as intended'; END IF;
  IF (SELECT count(*) FROM pg_trigger WHERE tgfoid = 'public.tg_broadcast_inval'::regproc) <> 7
    THEN RAISE EXCEPTION 'VERIFY: expected 7 tables on tg_broadcast_inval'; END IF;
END $v$;

COMMIT;
