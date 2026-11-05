-- 2026-11-05_0245 ET · Monthly Report page in the DERM Tracker: the database half (Trello EOnFKqSK, #173)
--
-- Fred, 2026-11-05: "adding the monthly report to the apps ... instead of using the dashboard made by Jon", then
-- "i don't want the simple fields to fill the data ... i want to have maybe a prefilled data, where you can select
-- the visits/clients", then "board first, report-only, and yes save the trap size" and "DERM Edit, yes keep the work,
-- leave the outside filing out". Plan: Building Apps/DERM Tracker/docs/specs/2026-11-05-monthly-report-in-the-app.md.
--
-- The report's engine stays in the GDO bot. The app talks to the edge function lwt-monthly, which holds the bot's key.
-- This migration adds only what the page needs from OUR database, all behind DERM Tracker access:
--   1. hr.check_app_action: lwt_monthly_view (View) and lwt_monthly_edit (Edit), so the edge function can ask.
--   2. derm.lwt_board(tickets, from, to): the trucks, each ticket's stops with their real truck, and GPS dump stops.
--   3. derm.lwt_stop_suggestions(dump date, truck): completed visits in the 14 days before a dump, grouped. It SUGGESTS.
--      Measured on 73 real tickets: "same truck since its previous ticket" finds 53% of real stops with almost no wrong
--      ones, 27 of 73 tickets mix trucks, and stops sit at most 14 days before the dump. So every group is returned and
--      a person decides.
--   4. derm.lwt_save_trap_size(property, gallons): fills a MISSING size only, so it can never overwrite one. It writes
--      public.properties, so trg_properties_enqueue_outbound queues the Jobber push exactly as the Client App's save does.
--      client.update_property_capacity is left alone (that one overwrites, and it is the Client App's).
--   5. A private bucket lwt-monthly-work: the work in progress per month, written only by the edge function with the
--      server key. No storage policy on purpose. A table was rejected: rule 8 would audit a whole JSON document per save.
--
-- Rule 8: no new table, so nothing to opt in or out. public.properties is already audited.
-- A ticket nobody logged goes on the report only (Fred's pick): nothing here writes derm_manifests or manifest_visits.
-- Rollback: 2026-11-05_rollback_monthly_report_page.sql

BEGIN;

SET LOCAL lock_timeout = '3s';

-- 1 --------------------------------------------------------------------------------------------------------------
do $splice$
declare v_def text := pg_get_functiondef('hr.check_app_action(text)'::regprocedure);
  v_old text := $a$                 ('record_manual_gdo_report',     array['derm_tracker'], 'edit'),$a$;
begin
  if md5(v_def) <> '2d6fe7a461fc3acbcba0eb73a3ea2342' then raise exception 'hr.check_app_action changed; re-splice from the live body'; end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then raise exception 'anchor not found once'; end if;
  execute replace(v_def, v_old, v_old
    || E'\n                 (''lwt_monthly_view'',             array[''derm_tracker''], ''view''),   -- 2026-11-05_0245: the Monthly Report page'
    || E'\n                 (''lwt_monthly_edit'',             array[''derm_tracker''], ''edit''),   -- 2026-11-05_0245');
end $splice$;

-- 2 --------------------------------------------------------------------------------------------------------------
create or replace function derm.lwt_board(p_tickets text[], p_from date default null, p_to date default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_stops jsonb; v_trucks jsonb; v_gps jsonb; v_from date := p_from; v_to date := p_to;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and not coalesce(public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))), false) then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  perform hr.fn_require_app('derm_tracker', 'view');
  if coalesce(cardinality(p_tickets), 0) > 500 then raise exception 'Too many tickets.' using errcode = '22023'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'ticket', r.ticket_number, 'visit_id', r.visit_id, 'pickup_date', r.pickup_date, 'offload_date', r.offload_date,
           'client_code', r.client_code, 'client_name', r.client_name, 'address', r.address, 'city', r.city, 'county', r.county,
           'vehicle_id', v.vehicle_id, 'truck', r.truck, 'gallons', r.gallons, 'gallons_source', r.gallons_source,
           'property_id', v.property_id, 'in_dade', r.offload_in_dade)
           order by r.ticket_number, r.pickup_date, r.client_code), '[]'::jsonb),
         coalesce(v_from, min(r.offload_date) - 3), coalesce(v_to, max(r.offload_date) + 3)
    into v_stops, v_from, v_to
    from derm.v_lwt_monthly_rows r
    join public.visits v on v.id = r.visit_id
   where r.ticket_number = any(coalesce(p_tickets, '{}'::text[]));

  select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'color', v.color_hex, 'decal', d.decal_number) order by v.id), '[]'::jsonb)
    into v_trucks
    from public.vehicles v
    left join public.vehicle_decals d on d.vehicle_id = v.id and d.jurisdiction = 'Miami-Dade' and d.status = 'ACTIVE'
   where v.status = 'ACTIVE';

  -- A hint and nothing more: 25 of 29 tickets since these began on 2026-08-21 have one. Silence proves nothing.
  select coalesce(jsonb_agg(jsonb_build_object(
           'vehicle_id', d.vehicle_id,
           'day', (d.arrived_at at time zone 'America/New_York')::date,
           'at', to_char(d.arrived_at at time zone 'America/New_York', 'FMHH12:MI AM'),
           'site', s.short_name) order by d.arrived_at), '[]'::jsonb)
    into v_gps
    from public.v_vehicle_dumps d
    left join public.properties p on p.id = d.site_property_id
    left join public.dump_sites s on s.client_id = p.client_id
   where (d.arrived_at at time zone 'America/New_York')::date between v_from and v_to;

  return jsonb_build_object('stops', v_stops, 'trucks', v_trucks, 'gps', v_gps);
end
$function$;

-- 3 --------------------------------------------------------------------------------------------------------------
create or replace function derm.lwt_stop_suggestions(p_dump_date date, p_vehicle_id bigint default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_prev date; v_out jsonb;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and not coalesce(public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))), false) then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  perform hr.fn_require_app('derm_tracker', 'view');
  if p_dump_date is null then raise exception 'A dump date is required.' using errcode = '22023'; end if;

  select max(m.dump_ticket_date) into v_prev
    from public.derm_manifests m
    join public.manifest_visits mv on mv.manifest_id = m.id
    join public.visits v on v.id = mv.visit_id
   where m.deleted_at is null and m.dump_ticket_date < p_dump_date and v.vehicle_id = p_vehicle_id;

  with base as (
    select v.id visit_id, v.visit_date, v.vehicle_id, v.title, c.client_code, c.name client_name,
           coalesce(p.address, pp.address) address, coalesce(p.city, pp.city) city, coalesce(p.county, pp.county) county,
           v.property_id, ve.name truck, ve.color_hex truck_color,
           (select string_agg(distinct coalesce(m.white_manifest_number, m.yellow_ticket_number), ', ')
              from public.manifest_visits mv join public.derm_manifests m on m.id = mv.manifest_id and m.deleted_at is null
             where mv.visit_id = v.id) on_ticket
      from public.visits v
      join public.clients c on c.id = v.client_id
      left join public.properties p on p.id = v.property_id
      left join public.properties pp on pp.client_id = v.client_id and pp.is_primary = true and v.property_id is null
      left join public.vehicles ve on ve.id = v.vehicle_id
     where v.deleted_at is null and v.visit_status = 'completed'
       and v.visit_date between p_dump_date - 14 and p_dump_date
       and not public.fn_is_non_customer(c.id, array['dump_site'])
       and (v.derm_required is null or v.derm_required = true
            or exists (select 1 from public.v_visit_lift_station_pumping l where l.visit_id = v.id)
            or exists (select 1 from public.v_visit_grey_water_pumping g where g.visit_id = v.id))
  ), grouped as (
    select b.*,
      case when b.vehicle_id = p_vehicle_id and b.on_ticket is null and b.visit_date >= coalesce(v_prev, p_dump_date - 7) then 'likely'
           when b.vehicle_id = p_vehicle_id and b.on_ticket is null then 'same_truck_older'
           when b.on_ticket is null then 'other_truck'
           when b.vehicle_id = p_vehicle_id then 'same_truck_on_ticket'
           else 'other_truck_on_ticket' end grp
      from base b
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'visit_id', visit_id, 'visit_date', visit_date, 'client_code', client_code, 'client_name', client_name,
           'address', address, 'city', city, 'county', county, 'property_id', property_id, 'vehicle_id', vehicle_id,
           'truck', truck, 'truck_color', truck_color, 'on_ticket', on_ticket, 'group', grp)
           order by array_position(array['likely','same_truck_older','other_truck','same_truck_on_ticket','other_truck_on_ticket'], grp),
                    visit_date desc, client_code), '[]'::jsonb)
    into v_out from grouped;

  return jsonb_build_object('previous_dump', v_prev, 'visits', v_out);
end
$function$;

-- 4 --------------------------------------------------------------------------------------------------------------
create or replace function derm.lwt_save_trap_size(p_property_id bigint, p_gallons integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_client bigint; v_now integer;
begin
  perform hr.fn_check_app('derm_tracker', 'edit', 'save a trap size from the Monthly Report');
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if not coalesce(public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))), false) then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_gallons is null or p_gallons < 1 or p_gallons > 20000 then
    raise exception 'Capacity must be between 1 and 20,000 gallons.' using errcode = '22023';
  end if;

  update public.properties
     set grease_trap_size_gallons = p_gallons
   where id = p_property_id and deleted_at is null and coalesce(grease_trap_size_gallons, 0) = 0
  returning client_id into v_client;

  if v_client is null then
    select grease_trap_size_gallons into v_now from public.properties where id = p_property_id and deleted_at is null;
    if not found then raise exception 'Property % was not found.', p_property_id using errcode = 'P0002'; end if;
    raise exception 'This property already has a trap size (% gallons). Change it in the Client App.', v_now
      using errcode = '22023', detail = 'blocker=size_already_set';
  end if;
  return jsonb_build_object('property_id', p_property_id, 'gallons', p_gallons);
end
$function$;

revoke all on function derm.lwt_board(text[], date, date) from public, anon;
revoke all on function derm.lwt_stop_suggestions(date, bigint) from public, anon;
revoke all on function derm.lwt_save_trap_size(bigint, integer) from public, anon;
grant execute on function derm.lwt_board(text[], date, date) to authenticated, service_role;
grant execute on function derm.lwt_stop_suggestions(date, bigint) to authenticated, service_role;
grant execute on function derm.lwt_save_trap_size(bigint, integer) to authenticated, service_role;

-- 5 --------------------------------------------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('lwt-monthly-work', 'lwt-monthly-work', false, 5242880, array['application/json'])
on conflict (id) do nothing;

-- VERIFY ---------------------------------------------------------------------------------------------------------
do $verify$
declare
  v_edit uuid := 'cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8';   -- an office person with DERM Tracker Edit
  v_none uuid := '1915f40f-1973-4432-9c95-c0a9ec77f5f9';   -- a field person with no DERM Tracker access
  v_mail text; v jsonb; v_prop bigint; v_fn text; v_sql text; v_refused boolean;
begin
  -- grants: read the catalogue, not what the statements above say
  foreach v_fn in array array['derm.lwt_board(text[],date,date)', 'derm.lwt_stop_suggestions(date,bigint)', 'derm.lwt_save_trap_size(bigint,integer)'] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') then raise exception 'VERIFY: anon can run %', v_fn; end if;
    if not has_function_privilege('authenticated', v_fn, 'EXECUTE') then raise exception 'VERIFY: authenticated cannot run %', v_fn; end if;
  end loop;
  if (select public from storage.buckets where id = 'lwt-monthly-work') is not false then raise exception 'VERIFY: bucket is not private'; end if;

  -- a person with Edit
  select email into v_mail from auth.users where id = v_edit;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_edit, 'role', 'authenticated', 'email', v_mail)::text, true);
  perform set_config('role', 'authenticated', true);
  if hr.check_app_action('lwt_monthly_view') ->> 'ok' <> 'true' then raise exception 'VERIFY: view refused for Edit'; end if;
  if hr.check_app_action('lwt_monthly_edit') ->> 'ok' <> 'true' then raise exception 'VERIFY: edit refused for Edit'; end if;
  v := derm.lwt_stop_suggestions('2026-10-20', 1);
  if jsonb_array_length(v -> 'visits') = 0 then raise exception 'VERIFY: no suggestions at all for a working truck'; end if;
  if v #>> '{visits,0,group}' not in ('likely','same_truck_older','other_truck','same_truck_on_ticket','other_truck_on_ticket') then raise exception 'VERIFY: unknown group'; end if;
  v := derm.lwt_board(array['000000'], '2026-10-01', '2026-10-31');
  if jsonb_array_length(v -> 'trucks') = 0 then raise exception 'VERIFY: no trucks'; end if;
  if jsonb_array_length(v -> 'gps') = 0 then raise exception 'VERIFY: no GPS dump stops in October, the hint is broken'; end if;
  perform set_config('role', 'postgres', true);

  -- the trap size fills a missing one and refuses an existing one; undone by the block's exception
  select id into v_prop from public.properties where deleted_at is null and coalesce(grease_trap_size_gallons, 0) > 0 order by id limit 1;
  begin
    update public.properties set grease_trap_size_gallons = null where id = v_prop;
    perform set_config('role', 'authenticated', true);
    v := derm.lwt_save_trap_size(v_prop, 750);
    if (v ->> 'gallons')::int <> 750 then raise exception 'VERIFY: size not returned'; end if;
    v_refused := false;
    begin perform derm.lwt_save_trap_size(v_prop, 500); exception when sqlstate '22023' then v_refused := true; end;
    if not v_refused then raise exception 'VERIFY: overwrote an existing size'; end if;
    perform set_config('role', 'postgres', true);
    if (select grease_trap_size_gallons from public.properties where id = v_prop) <> 750 then raise exception 'VERIFY: size not stored'; end if;
    if not exists (select 1 from sync.outbound_queue where entity_type = 'property' and entity_id = v_prop and status = 'pending') then raise exception 'VERIFY: no Jobber push queued'; end if;
    raise exception 'undo' using errcode = 'ZZ001';
  exception when sqlstate 'ZZ001' then null;
  end;
  perform set_config('role', 'postgres', true);

  -- a person with no DERM Tracker access is refused at every door
  select email into v_mail from auth.users where id = v_none;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_none, 'role', 'authenticated', 'email', v_mail)::text, true);
  perform set_config('role', 'authenticated', true);
  foreach v_sql in array array[
    $q$select hr.check_app_action('lwt_monthly_view')$q$,
    $q$select hr.check_app_action('lwt_monthly_edit')$q$,
    $q$select derm.lwt_stop_suggestions('2026-10-20', 1)$q$,
    $q$select derm.lwt_board(array['000000'])$q$,
    format($q$select derm.lwt_save_trap_size(%s, 500)$q$, v_prop)] loop
    v_refused := false;
    begin execute v_sql; exception when sqlstate '42501' then v_refused := true; end;
    if not v_refused then raise exception 'VERIFY: no-access person passed: %', v_sql; end if;
  end loop;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $verify$;

COMMIT;
