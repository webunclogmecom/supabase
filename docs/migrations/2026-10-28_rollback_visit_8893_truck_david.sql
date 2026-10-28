-- Rollback for 2026-10-28_0955_visit_8893_truck_david.sql: visit 8893 back to Cloggy (vehicle 2).
-- Only if the truck is still the one the repair wrote; audited like the repair.
begin;
select set_config('request.headers', jsonb_build_object(
  'x-app-source', 'truck-fix-by-hand',
  'x-change-reason', 'Rollback of the 2026-10-28 hand repair: truck back to Cloggy.')::text, true);
update public.visits set vehicle_id = 2 where id = 8893 and vehicle_id = 3 and deleted_at is null;
do $v$ begin
  if (select vehicle_id from public.visits where id = 8893) is distinct from 2 then raise exception 'rollback did not apply'; end if;
end $v$;
commit;
