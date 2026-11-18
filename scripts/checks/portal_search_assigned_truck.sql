-- Standing check of the Ops Portal Search's visits, ops.portal_search(text) 'visits' (Trello #225; migration
-- 2026-11-17_1735_portal_search_assigned_truck_only.sql). Run as owner (the Management API), as ONE request, once that
-- migration is applied. It reads only, and RAISES unless, searched as the first active admin with a confirmed sign-in:
--   ops.v_calendar_visit's vehicle_source still means what the rule assumes: 'assigned' = the visit has its own truck,
--   'default' = no truck, the Calendar shows its guess, 'none' = no truck and no guess;
--   every visit Search returns names its truck only when vehicle_source = 'assigned' (null for a guess or no truck), and
--   its driver is the view's driver;
--   the rule was exercised both ways (at least one visit on a guessed truck and one on an assigned truck searched).
-- Whom it searches: Search's own pick per client (the next scheduled visit, else the last completed one), a few of each
-- kind (guessed truck with and without a driver, assigned, none), by exact client code.
-- Control: before the migration it fails whenever a searched client's visit is on a guessed truck (rehearsed 2026-11-17:
-- 7 guessed visits named, among them 8021 "Moises with Mark"). It can fail once for a reason in the data (a visit changed
-- between its reads): run it again before believing it.

do $check$
declare
  v_today date := (now() at time zone 'America/New_York')::date;
  v_uid uuid; v_email text; v_code text; v_codes text[]; v_got jsonb := '[]'::jsonb;
  v_rows bigint; v_guess bigint; v_guess_driver bigint; v_assigned bigint; v_bad jsonb;
begin
  with pick as (
    select distinct on (v.client_id) v.client_code, v.vehicle_source, v.driver_name is not null as has_driver
      from ops.v_calendar_visit v
     where (v.visit_date >= v_today and v.visit_status = 'scheduled') or (v.visit_date < v_today and v.visit_status = 'completed')
     order by v.client_id, (v.visit_date >= v_today) desc, case when v.visit_date >= v_today then v.visit_date end asc,
              v.visit_date desc, v.start_at),
  ranked as (
    select p.client_code, p.vehicle_source, p.has_driver,
           row_number() over (partition by p.vehicle_source, p.has_driver order by p.client_code) as n
      from pick p where length(p.client_code) between 2 and 80)
  select array_agg(distinct r.client_code) into v_codes
    from ranked r
   where r.n <= case when r.vehicle_source = 'default' and r.has_driver then 4
                     when r.vehicle_source = 'default' then 3
                     when r.vehicle_source = 'assigned' then 2
                     else 1 end;

  select u.id, u.email into v_uid, v_email
    from public.employees e join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
   where e.status = 'ACTIVE' and e.access_level = 'admin' and u.email_confirmed_at is not null
     and (u.banned_until is null or u.banned_until <= now())
   order by e.id limit 1;
  if v_uid is null then raise exception 'verify_fail: no admin sign-in to search as'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  set local role authenticated;
  foreach v_code in array v_codes loop
    v_got := v_got || coalesce(ops.portal_search(v_code) -> 'visits', '[]'::jsonb);
  end loop;
  reset role;
  perform set_config('request.jwt.claims', '', true);

  select count(*),
         count(*) filter (where v.vehicle_source = 'default' and v.truck_name is not null),
         count(*) filter (where v.vehicle_source = 'default' and v.truck_name is not null and v.driver_name is not null),
         count(*) filter (where v.vehicle_source = 'assigned' and v.truck_name is not null),
         jsonb_agg(jsonb_build_object('id', g.x ->> 'id', 'source', v.vehicle_source, 'got_truck', g.x ->> 'truck', 'view_truck', v.truck_name,
                                      'got_driver', g.x ->> 'driver', 'view_driver', v.driver_name))
           filter (where v.id is null
                      or (g.x ->> 'truck') is distinct from case when v.vehicle_source = 'assigned' then v.truck_name end
                      or (g.x ->> 'driver') is distinct from v.driver_name
                      or v.vehicle_source is distinct from case when v.assigned_vehicle_id is not null then 'assigned'
                                                                when v.vehicle_id is not null then 'default' else 'none' end)
    into v_rows, v_guess, v_guess_driver, v_assigned, v_bad
    from jsonb_array_elements(v_got) g(x)
    left join ops.v_calendar_visit v on v.id = (g.x ->> 'id')::bigint;
  if v_bad is not null then
    raise exception 'verify_fail: Search names a truck that is not the visit''s assigned truck, or moved a driver: %', v_bad;
  end if;
  if v_guess = 0 or v_assigned = 0 then
    raise exception 'verify_fail: not tested (% visits on a guessed truck, % on an assigned truck in % answers)', v_guess, v_assigned, v_rows;
  end if;
  raise notice 'verify ok: % clients searched, % visits: % on a guessed truck came back with no truck (% of them with a driver), % on an assigned truck kept it',
    cardinality(v_codes), v_rows, v_guess, v_guess_driver, v_assigned;
end $check$;
