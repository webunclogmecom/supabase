-- Standing check of the Ops Portal Home's truck crews, ops.portal_home() 'trucks' (Trello #224, data check B3;
-- migration 2026-11-17_1615_portal_home_crew_assigned_truck.sql). Run as owner (the Management API), as ONE request,
-- once that migration is applied. It reads only, and RAISES unless, read as the first active admin with a confirmed
-- sign-in:
--   ops.v_calendar_visit's vehicle_source still means what the rule assumes: 'assigned' = the visit has its own truck,
--   'default' = no truck, the Calendar shows its guess, 'none' = no truck and no guess;
--   the trucks add up to today's visits, not cancelled (a visit on a guessed truck still counts there);
--   each truck's crew is exactly the drivers of its visits today that are NOT on a guessed truck (the "No truck" row
--   names the drivers of visits with no truck at all).
-- The notice says how many visits today named a driver on a truck ONLY by a guess: those are the cases the rule
-- decides. 0 means the rule was not exercised today, and the check then proves only that the crews still match.
-- Control: before the migration it fails on any day with such a visit (rehearsed 2026-11-17: Grecia on Moises, visit
-- 8597). It can fail once for a reason in the data (a visit changed between its reads): run it again before believing it.

do $check$
declare
  v_today date := (now() at time zone 'America/New_York')::date;
  v_uid uuid; v_email text; v_home jsonb; v_n bigint; v_bad jsonb; v_bites bigint; v_names bigint;
begin
  if exists (select 1 from ops.v_calendar_visit v
              where v.visit_date = v_today
                and v.vehicle_source is distinct from case when v.assigned_vehicle_id is not null then 'assigned'
                                                           when v.vehicle_id is not null then 'default' else 'none' end) then
    raise exception 'verify_fail: ops.v_calendar_visit vehicle_source no longer means assigned / default (a guess) / none';
  end if;

  select u.id, u.email into v_uid, v_email
    from public.employees e join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
   where e.status = 'ACTIVE' and e.access_level = 'admin' and u.email_confirmed_at is not null
     and (u.banned_until is null or u.banned_until <= now())
   order by e.id limit 1;
  if v_uid is null then raise exception 'verify_fail: no admin sign-in to read the Home as'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_home := ops.portal_home();
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_home -> 'trucks' is null then raise exception 'verify_fail: the Home gave an admin no trucks'; end if;

  select count(*) into v_n from ops.v_calendar_visit v where v.visit_date = v_today and v.visit_status <> 'cancelled';
  if (select coalesce(sum((t ->> 'visits')::int), 0) from jsonb_array_elements(v_home -> 'trucks') t) is distinct from v_n then
    raise exception 'verify_fail: the trucks do not add up to today''s % visits', v_n;
  end if;

  with want as (
    select coalesce(v.truck_name, 'No truck') as truck,
           coalesce(jsonb_agg(distinct v.driver_name) filter (where v.vehicle_source <> 'default' and v.driver_name is not null), '[]'::jsonb) as crew
      from ops.v_calendar_visit v where v.visit_date = v_today and v.visit_status <> 'cancelled' group by 1),
  got as (
    select t ->> 'name' as truck, coalesce((select jsonb_agg(distinct c ->> 'name') from jsonb_array_elements(t -> 'crew') c), '[]'::jsonb) as crew
      from jsonb_array_elements(v_home -> 'trucks') t)
  select jsonb_agg(jsonb_build_object('truck', coalesce(w.truck, g.truck), 'want', w.crew, 'got', g.crew)) into v_bad
    from want w full join got g on g.truck = w.truck
   where w.crew is distinct from g.crew;
  if v_bad is not null then raise exception 'verify_fail: a truck''s crew is not the drivers of its visits that are not a guess: %', v_bad; end if;

  select count(*) into v_bites from ops.v_calendar_visit g
   where g.visit_date = v_today and g.visit_status <> 'cancelled' and g.vehicle_source = 'default' and g.driver_name is not null
     and not exists (select 1 from ops.v_calendar_visit a
                      where a.visit_date = v_today and a.visit_status <> 'cancelled' and a.vehicle_source = 'assigned'
                        and a.vehicle_id = g.vehicle_id and a.driver_name = g.driver_name);
  select count(*) into v_names from jsonb_array_elements(v_home -> 'trucks') t, jsonb_array_elements(t -> 'crew') c;
  raise notice 'verify ok: % visits on % trucks, % crew names; % visits named a driver on a truck only by a guess (0 = the rule was not exercised today)',
    v_n, jsonb_array_length(v_home -> 'trucks'), v_names, v_bites;
end $check$;
