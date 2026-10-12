-- 2026-10-12_2100_broward_dump_samsara_link.sql
--
-- Fred, 2026-10-12: "create the Broward dump geofence through the API". The Broward dump (000-DP, client 76,
-- property 155, 3100 N Powerline Rd) had NO Samsara address, so no truck's arrival there was ever recorded as a
-- geofence event (the tank-readings collector stored only the Miami-Dade dump's 27 entries/exits).
-- Samsara address 4000003697171 "000-DP DUMP Pompano" was created through the API the same evening: a 200 m circle
-- centred on where David's truck stopped on 2026-10-02 and 2026-10-08 (225 of 289 stopped GPS points within
-- 150 m, 37 m median from the stored property point). It records arrivals from its creation on; earlier
-- Broward dumps come from GPS stops, not from geofence events.
-- This links it to client 76 and property 155, the same two-row shape as 000-DH (322485232 -> 365 / 98).
-- entity_source_links has no audit trigger (sync bridge); inserts only.

begin;
set local lock_timeout = '3s';

insert into public.entity_source_links
  (entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence, synced_at)
select t.entity_type, t.entity_id, 'samsara', '4000003697171', '000-DP DUMP Pompano', 'manual', 1, now()
  from (values ('client', 76::bigint), ('property', 155::bigint)) t(entity_type, entity_id)
 where not exists (select 1 from public.entity_source_links e
                    where e.source_system = 'samsara' and e.source_id = '4000003697171' and e.entity_type = t.entity_type);

do $$
begin
  if (select count(*) from public.entity_source_links where source_system='samsara' and source_id='4000003697171') <> 2 then
    raise exception 'VERIFY 1: expected 2 links for the Broward dump address';
  end if;
  if not exists (select 1 from ops.v_dump_sites where property_id = 155) then
    raise exception 'VERIFY 2: property 155 is not a dump site in ops.v_dump_sites, the collector will not resolve it';
  end if;
end $$;

commit;
