-- =============================================================================
-- 2026-11-14_0140_public_get_pumping_figures.sql
--
-- WHAT: public.get_pumping_figures(p_client_id bigint default null, p_visit_ids bigint[] default null), ONE new read
--       (B1 of the Client App move). It returns jsonb:
--   "visits": every completed, live visit of the client (or exactly the visits asked for), each with its gallons and
--             where they come from, so the app labels them:
--               source "tank"           the truck tank's own reading (public.v_visit_tank_service.sludge_collected_gallons),
--                                       trusted exactly as the averages trust a reading: a volume visit, confidence high
--                                       or medium, 40 to 3,840 gal; whole gallons
--               source "trap_size"      a pumping with no trusted reading: the trap size on file (0 means none), which
--                                       the app shows labelled as the trap size, never as measured
--               source "none"           a pumping (or a visit whose work is not known) with neither: "Not measured"
--               source "not_a_pumping"  the work of the visit was not a pumping: "No pumping on this visit"
--             A pumping is the tank view's own rule: service type Pumping, not at a dump site. A visit with no service
--             type is not known to be a pumping, so it never gets the trap size.
--   "sites":  (only with p_client_id) per site and pump kind, the pumping figures of the client's live sites: average,
--             low, high, the last trusted reading (date and gallons) and how many readings the figures rest on. They are
--             ops.fn_client_sludge_averages() itself, as of tomorrow ET (the Calendar's average and Admin Review's
--             Grease page: the last 6 trusted readings of the place and pump kind), so the figures follow ONE rule.
--   Never ops.visit_grease_frozen: that is the Calendar's ESTIMATE, not a measure (round 10's pictures showed it as
--   measured: 6 of 7 figures wrong).
--
-- WHY: Fred, 2026-11-14 about 12:40 AM ET, on the Client App move plan: "AA to FF all yes, and all defaults".
--      Decision 6 (the visit panel's gallons), the Sites tab's pumping figures, the manifest dialog's gallons (it calls
--      this read with the ticket's visit ids: the dialog's own read may not touch the tank views). Fred's rule (redesign
--      answers): "A visit's gallons are the truck tank's reading, else the trap size labelled, else Not measured; never
--      the Calendar's estimate." Plan: Building Apps/Ops Portal/docs/specs/2026-11-13-client-app-move-plan.md, B1, risks 5, 6.
--
-- WHERE: public, because no object in client, derm or customer may read the tank views (the hourly boundary check Z8 in
--   public.fn_stop_facts_checks()).
-- READ ONLY. No table, view, trigger or row is touched; nothing existing changes. RULE 8, AUDIT: no table.
-- ACCESS: SECURITY DEFINER, search_path '', STABLE. Gate: hr.fn_require_any_app(array['client_app', 'derm_tracker',
--   'stamp_studio', 'admin_review'], 'view') (the manifest dialog opens from the Client App, the DERM Tracker and Stamp
--   Studio; Admin Review's Grease page already shows these figures for every client, so it widens nothing), then the
--   staff check. EXECUTE revoked from PUBLIC, anon and service_role by name, granted to authenticated only.
-- THE TRUST RULE is written in three places now: ops.fn_client_sludge_averages() (the pool), ops.calendar_grease_estimates()
--   and here. This VERIFY and the standing check scripts/checks/client_page_reads.sql compare this read with the
--   averages both ways, so the copies cannot drift apart unseen. One helper for all three would change the Calendar's
--   two functions: not done in this step.
-- COST: 0.40 s for a client (the averages read every trusted reading once); 0.10 s for a ticket's visits, where no site
--   figure is computed.
-- UNDO: 2026-11-14_rollback_public_get_pumping_figures.sql (drops this one function).
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if to_regprocedure('public.get_pumping_figures(bigint,bigint[])') is not null then
    raise exception 'public.get_pumping_figures exists already; stop';
  end if;
end
$pin$;

create function public.get_pumping_figures(p_client_id bigint default null, p_visit_ids bigint[] default null)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $fn$
declare
  v_visits jsonb;
  v_sites jsonb := '[]'::jsonb;
begin
  -- The gate of the pages that show these gallons (pick BB): the Client App, the DERM Tracker, Stamp Studio or Admin Review, at View.
  perform hr.fn_require_any_app(array['client_app', 'derm_tracker', 'stamp_studio', 'admin_review'], 'view');
  if nullif(current_setting('request.jwt.claims', true), '') is not null
     and coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    if auth.uid() is null then
      raise exception 'authentication required' using errcode = '28000';
    end if;
    if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))) then
      raise exception 'not a staff account' using errcode = '42501';
    end if;
  end if;
  if p_client_id is null and p_visit_ids is null then
    raise exception 'Give a client or a list of visits.' using errcode = '22023';
  end if;
  if cardinality(p_visit_ids) > 2000 then
    raise exception 'At most 2,000 visits at a time.' using errcode = '22023';
  end if;

  with v as materialized (
    select vv.id, vv.client_id, vv.property_id, vv.visit_date, vv.service_type,
           nullif(p.grease_trap_size_gallons, 0) as trap
      from public.visits vv
      left join public.properties p on p.id = vv.property_id
     where vv.deleted_at is null and vv.visit_status = 'completed'
       and (p_client_id is null or vv.client_id = p_client_id)
       and (p_visit_ids is null or vv.id = any (p_visit_ids))
  ), t as materialized (
    select s.visit_id, s.visit_kind, s.sludge_confidence, s.sludge_collected_gallons
      from public.v_visit_tank_service s
     where s.visit_id in (select v.id from v)
  ), g as (
    select v.id, v.client_id, v.property_id, v.visit_date, v.trap,
           -- a pumping: the tank view's own rule (service type Pumping, not a dump site); NULL when the work is not known
           v.service_type = 'Pumping' and coalesce(t.visit_kind, '') <> 'dump' as pumping,
           -- trusted exactly as ops.fn_client_sludge_averages() trusts a reading
           case when t.visit_kind = 'volume' and t.sludge_confidence in ('high', 'medium')
                     and t.sludge_collected_gallons between 40 and 3840
                then round(t.sludge_collected_gallons)::int end as tank_gallons
      from v left join t on t.visit_id = v.id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'visit_id', g.id,
           'client_id', g.client_id,
           'property_id', g.property_id,
           'visit_date', g.visit_date,
           'source', case when g.tank_gallons is not null then 'tank'
                          when g.pumping is false then 'not_a_pumping'
                          when g.pumping and g.trap is not null then 'trap_size'
                          else 'none' end,
           'gallons', case when g.tank_gallons is not null then g.tank_gallons
                           when g.pumping and g.trap is not null then g.trap end)
         order by g.visit_date desc, g.id desc), '[]'::jsonb)
    into v_visits
    from g;

  if p_client_id is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'property_id', a.property_id,
             'pump_kind', a.pump_kind,
             'average_gallons', round(a.avg_gallons)::int,
             'low_gallons', (select round(min((r ->> 'gallons')::numeric))::int from jsonb_array_elements(a.readings) r),
             'high_gallons', (select round(max((r ->> 'gallons')::numeric))::int from jsonb_array_elements(a.readings) r),
             'last_date', a.last_reading_date,
             'last_gallons', round((a.readings -> 0 ->> 'gallons')::numeric)::int,
             'readings_in_average', a.readings_n)
           order by a.property_id, a.pump_kind), '[]'::jsonb)
      into v_sites
      from ops.fn_client_sludge_averages(array[(now() at time zone 'America/New_York')::date + 1]) a
     where a.property_id in (select p.id from public.properties p where p.client_id = p_client_id and p.deleted_at is null);
  end if;

  return jsonb_build_object('visits', v_visits, 'sites', v_sites);
end
$fn$;

revoke all on function public.get_pumping_figures(bigint, bigint[]) from public, anon, service_role;
grant execute on function public.get_pumping_figures(bigint, bigint[]) to authenticated;

notify pgrst, 'reload schema';

do $verify$
declare
  v_sig constant text := 'public.get_pumping_figures(bigint,bigint[])';
  v_role text; v_uid uuid; v_email text; v_res jsonb; v_all jsonb; v_state text; v_msg text; v_bad bigint; v_n bigint;
  r record;
begin
  -- 1. Who may run it.
  foreach v_role in array array['public', 'anon', 'service_role'] loop
    if has_function_privilege(v_role, v_sig, 'execute') then raise exception 'verify_fail: % can execute', v_role; end if;
  end loop;
  if not has_function_privilege('authenticated', v_sig, 'execute') then raise exception 'verify_fail: authenticated cannot execute'; end if;
  if not (select p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'verify_fail: not SECURITY DEFINER, STABLE, with an empty search_path';
  end if;

  -- 2. A signed-in person with none of the four apps is refused with the access sentence.
  for r in
    select u.id, u.email
      from public.employees e
      join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
     where e.status = 'ACTIVE' and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until <= now())
     order by (e.access_level = 'field') desc, e.id
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', r.id, 'email', r.email, 'role', 'authenticated')::text, true);
    if hr.fn_app_level('client_app') = 'none' and hr.fn_app_level('derm_tracker') = 'none'
       and hr.fn_app_level('stamp_studio') = 'none' and hr.fn_app_level('admin_review') = 'none' then
      v_uid := r.id; v_email := r.email; exit;
    end if;
  end loop;
  if v_uid is null then raise exception 'verify_fail: no signed-in person without the four apps to test the refusal with'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    v_res := public.get_pumping_figures(381);
    v_state := 'no error';
  exception when others then
    v_state := sqlstate; v_msg := sqlerrm;
  end;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_state is distinct from '42501' or v_msg not like 'You do not have access to do this.%' then
    raise exception 'verify_fail: a person without the four apps was not refused (% %)', v_state, v_msg;
  end if;

  -- 3. The test client 112-YA, and every visit the tank view measures: one entry per completed live visit, each with
  --    one of the four sources, gallons exactly when the source has them, the trap size only on a pumping, and
  --    "not a pumping" only on a visit whose work is known and is not one.
  v_res := public.get_pumping_figures(381);
  v_all := public.get_pumping_figures(null, (select array_agg(t.visit_id) from public.v_visit_tank_service t));
  select count(*) into v_bad
    from (select x, true as ya from jsonb_array_elements(v_res -> 'visits') x
          union all select x, false from jsonb_array_elements(v_all -> 'visits') x) y
    left join public.visits vv on vv.id = (y.x ->> 'visit_id')::bigint
   where (y.ya and (y.x ->> 'client_id')::bigint <> 381)
      or y.x ->> 'source' not in ('tank', 'trap_size', 'none', 'not_a_pumping')
      or ((y.x ->> 'gallons') is null) <> (y.x ->> 'source' in ('none', 'not_a_pumping'))
      or (y.x ->> 'source' = 'trap_size' and vv.service_type is distinct from 'Pumping')
      or (y.x ->> 'source' = 'not_a_pumping' and (vv.service_type is null or vv.service_type = 'Pumping'
                                                   and not exists (select 1 from public.v_visit_tank_service t where t.visit_id = vv.id and t.visit_kind = 'dump')));
  if v_bad <> 0 then raise exception 'verify_fail: % visits are malformed', v_bad; end if;
  if jsonb_array_length(v_res -> 'visits') <> (select count(*) from public.visits v where v.client_id = 381 and v.deleted_at is null and v.visit_status = 'completed') then
    raise exception 'verify_fail: 112-YA does not get one entry per completed visit';
  end if;
  if jsonb_array_length(v_all -> 'visits') <> (select count(*) from public.v_visit_tank_service) then
    raise exception 'verify_fail: the visits of the tank view do not each get one entry';
  end if;

  -- 4. Both ways against the averages (the other home of the trust rule), over every visit the tank view measures:
  --    a reading the averages use (any date) is "tank" here with the same whole gallons, and a "tank" reading of a
  --    visit with a site and a pump kind is one the averages use.
  with av as (
    select distinct (rr ->> 'visit_id')::bigint as visit_id, round((rr ->> 'gallons')::numeric)::int as g
      from ops.fn_client_sludge_averages((select array_agg(distinct t.visit_date + 1) from public.v_visit_tank_service t)) a
     cross join lateral jsonb_array_elements(a.readings) rr
  ), b1 as (
    select (x ->> 'visit_id')::bigint as visit_id, (x ->> 'gallons')::int as g, x ->> 'source' as source, (x ->> 'property_id')::bigint as pid
      from jsonb_array_elements(v_all -> 'visits') x
  )
  select (select count(*) from av left join b1 on b1.visit_id = av.visit_id where b1.source is distinct from 'tank' or b1.g is distinct from av.g)
       + (select count(*) from b1 join public.visits vv on vv.id = b1.visit_id
           where b1.source = 'tank' and b1.pid is not null and ops.fn_visit_pump_kind(vv.id, vv.job_id) is not null
             and not exists (select 1 from av where av.visit_id = b1.visit_id))
    into v_bad;
  if v_bad <> 0 then raise exception 'verify_fail: % readings differ between this read and the averages', v_bad; end if;
  if (select count(*) from jsonb_array_elements(v_all -> 'visits') x where x ->> 'source' = 'tank') = 0 then
    raise exception 'verify_fail: no tank reading at all';
  end if;

  -- 5. The site figures are the averages' own, for a client that has some.
  select a.client_id into v_n from ops.fn_client_sludge_averages(array[(now() at time zone 'America/New_York')::date + 1]) a
   order by a.readings_n desc, a.property_id limit 1;
  v_res := public.get_pumping_figures(v_n);
  select count(*) into v_bad
    from ops.fn_client_sludge_averages(array[(now() at time zone 'America/New_York')::date + 1]) a
    join public.properties p on p.id = a.property_id and p.client_id = v_n and p.deleted_at is null
   where not exists (select 1 from jsonb_array_elements(v_res -> 'sites') s
                      where (s ->> 'property_id')::bigint = a.property_id and s ->> 'pump_kind' = a.pump_kind
                        and (s ->> 'average_gallons')::int = round(a.avg_gallons)::int and (s ->> 'readings_in_average')::int = a.readings_n
                        and (s ->> 'last_date')::date = a.last_reading_date);
  if v_bad <> 0 or jsonb_array_length(v_res -> 'sites') = 0 then raise exception 'verify_fail: the site figures of client % are not the averages (% differ)', v_n, v_bad; end if;

  raise notice 'verify ok: % visits measured by the tank, % with the trap size, across the tank era',
    (select count(*) from jsonb_array_elements(v_all -> 'visits') x where x ->> 'source' = 'tank'),
    (select count(*) from jsonb_array_elements(v_all -> 'visits') x where x ->> 'source' = 'trap_size');
end $verify$;

COMMIT;
