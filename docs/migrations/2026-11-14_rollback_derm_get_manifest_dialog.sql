-- ROLLBACK of 2026-11-14_0155_derm_get_manifest_dialog.sql (B2 of the Client App move).
--
-- Drops exactly the one function it created; nothing else existed to undo (no table, view, trigger or other grant).
-- Nothing on the old Client App host reads it. A portal build that already opens the manifest dialog shows it as
-- "could not be read" until it is back. Run this one BEFORE the undo of 2026-11-14_0135 (that one refuses while this
-- function exists, because it reads the row states core).

BEGIN;
SET LOCAL lock_timeout = '3s';

drop function derm.get_manifest_dialog(text);

notify pgrst, 'reload schema';

do $verify$
begin
  if to_regprocedure('derm.get_manifest_dialog(text)') is not null then
    raise exception 'verify_fail: derm.get_manifest_dialog still exists';
  end if;
  raise notice 'verify ok: derm.get_manifest_dialog is gone';
end $verify$;

COMMIT;
