-- 2026-10-12_1625_unclogme_yard_depot.sql
--
-- Fred, 2026-10-12: "The truck yard, is the Yard of the company, is where the office and where
-- trucks are parked." / "Doral Yard is a client, changed it to a more semantic name. So create a
-- 000 client with it." / "yes UnclogMe Yard 000-YD, use the Client App".
--
-- Context. app_config.depot_property_id pointed at property 80, client 311 ("The Doral Yard",
-- 8455 NW 53rd St, Doral). That is a CUSTOMER, about 13 km from where the trucks park, and no truck
-- went within 150 m of it in 14 days. Samsara has a "yard" geofence (address 4000000737885) at
-- 650 NW 33rd St, Miami: Moises, Cloggy and David parked inside it on 10, 10 and 7 of the 14 days
-- from 2026-09-28. So the Calendar's "Hours driven" (ops.fn_drive_chain) and the Start of day pill
-- (heal-day-starts / calculate-driving-time, "ETA from the depot - 30") were timed from a client's
-- address.
--
-- The yard was created through the Client App (create-client, 2026-10-12 16:22 ET): client 630
-- "UnclogMe Yard" 000-YD, service property 1194 (geocode 25.8070549, -80.206472, inside the Samsara
-- yard polygon), Service Call job 2028 (same shape as the 000 dump sites).
--
-- This migration:
--   1. non_customer_clients.kind gains 'yard' (the yard is neither a dump site, a test nor a fixture).
--      Readers of kind: v_non_customer_clients (passes it through), fn_is_non_customer(id, kinds)
--      (NULL kinds = every kind). The two DERM views filter kind = 'dump_site' only, so they do not
--      change. fn_generate_sa_visits tests membership (any kind), so the yard can never get SA visits.
--   2. client 630 is registered as kind 'yard'.
--   3. depot_property_id: 80 -> 1194 (guarded on the old value).
--   4. entity_source_links: the Samsara "yard" address is linked to client 630 and property 1194,
--      the same two-row shape as 000-DH (client 365 / property 98 / address 322485232).
--
-- Effects, stated so nobody is surprised:
--   * Hours driven is computed LIVE per read, so every Calendar day re-times from the yard at once.
--     Legs from the new point are not cached yet: those days read "pending" until plan-drive-fill
--     buys them (the Calendar's kick, or cron plan-drive-warm at 09:15 UTC; 300/day budget).
--   * Existing Start of day minutes are NOT rewritten. A Start is recomputed only when it is flagged
--     (first visit changed); from now on that recompute uses the yard.
--
-- Rule 8 (audit): no new table. non_customer_clients and app_config are already audited
-- (audit_non_customer_clients, audit_app_config). entity_source_links has no trigger (sync bridge,
-- documented exclusion); these two rows are inserts, not deletes.

begin;
set local lock_timeout = '3s';

-- 1. widen the kind vocabulary
do $$
declare v_name text;
begin
  select conname into v_name from pg_constraint
   where conrelid = 'public.non_customer_clients'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) ilike '%kind%';
  if v_name is null then raise exception 'kind CHECK not found on non_customer_clients'; end if;
  execute format('alter table public.non_customer_clients drop constraint %I', v_name);
end $$;
alter table public.non_customer_clients
  add constraint non_customer_clients_kind_check
  check (kind = any (array['dump_site','test','fixture','yard']));

-- 2. register the yard
insert into public.non_customer_clients (client_id, client_code, kind, reason, added_by)
select 630, '000-YD', 'yard',
       'Our own truck yard and office (650 NW 33rd St, Miami), where the trucks park. Not a customer.',
       'claude/2026-10-12'
 where not exists (select 1 from public.non_customer_clients where client_id = 630);

-- 3. point the depot at the yard
update public.app_config set value = '1194'
 where key = 'depot_property_id' and value = '80';

-- 4. link the Samsara "yard" address
insert into public.entity_source_links
  (entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence, synced_at)
select t.entity_type, t.entity_id, 'samsara', '4000000737885', 'yard', 'manual', 1, now()
  from (values ('client', 630::bigint), ('property', 1194::bigint)) t(entity_type, entity_id)
 where not exists (select 1 from public.entity_source_links e
                    where e.source_system = 'samsara' and e.source_id = '4000000737885'
                      and e.entity_type = t.entity_type);

-- VERIFY
do $$
declare v record; n int;
begin
  -- the client and property are the ones the Client App made
  select c.client_code, p.address, p.is_billing, p.deleted_at, p.latitude, p.longitude into v
    from public.clients c join public.properties p on p.client_id = c.id
   where c.id = 630 and p.id = 1194;
  if v.client_code is distinct from '000-YD' or v.is_billing or v.deleted_at is not null then
    raise exception 'VERIFY 0: property 1194 is not the live service property of 000-YD';
  end if;
  -- inside the Samsara yard polygon (lat 25.806886..25.807340, lng -80.206986..-80.206409)
  if not (v.latitude between 25.806886 and 25.807340 and v.longitude between -80.206986 and -80.206409) then
    raise exception 'VERIFY 0b: property 1194 geocode % , % is outside the Samsara yard polygon', v.latitude, v.longitude;
  end if;

  select count(*) into n from ops.v_depot where property_id = 1194 and depot_name = 'UnclogMe Yard';
  if n <> 1 then raise exception 'VERIFY 1: ops.v_depot does not resolve to the yard (got % rows)', n; end if;
  select count(*) into n from ops.v_depot;
  if n <> 1 then raise exception 'VERIFY 1b: ops.v_depot returns % rows, expected 1', n; end if;

  if not public.fn_is_non_customer(630) then raise exception 'VERIFY 2: yard is not a non-customer'; end if;
  if not public.fn_is_non_customer(630, array['yard']) then raise exception 'VERIFY 2b: kind yard not found'; end if;
  if public.fn_is_non_customer(630, array['dump_site']) then raise exception 'VERIFY 2c: yard must not read as a dump site'; end if;
  -- control: the dump sites are untouched
  if not public.fn_is_non_customer(365, array['dump_site']) then raise exception 'VERIFY 2d: control 000-DH lost its dump_site kind'; end if;

  select count(*) into n from public.entity_source_links
   where source_system = 'samsara' and source_id = '4000000737885';
  if n <> 2 then raise exception 'VERIFY 3: expected 2 Samsara yard links, got %', n; end if;
end $$;

commit;
