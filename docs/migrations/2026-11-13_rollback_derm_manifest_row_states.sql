-- 2026-11-13_rollback_derm_manifest_row_states.sql
-- Undoes 2026-11-13_0148_derm_manifest_row_states.sql. The Ops Portal branch that calls the function must not be live when this runs.
-- Undo of manifest_row_states.sql: drops exactly the one function it created. Nothing else exists to undo: the
-- migration made no table, no view, no trigger, and changed no other grant.
-- The Manifests list of the old host and of the portal as it is today do not call this function, so dropping it breaks
-- nothing that was there before. A portal build that already draws the new rows would show "could not be read" on
-- them until the function is back.
drop function derm.manifest_row_states();

notify pgrst, 'reload schema';

do $verify$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'derm' and p.proname = 'manifest_row_states') then
    raise exception 'verify_fail: derm.manifest_row_states still exists';
  end if;
  raise notice 'verify ok: derm.manifest_row_states() is gone';
end $verify$;
