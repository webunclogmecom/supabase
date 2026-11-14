-- =============================================================================
-- 2026-11-14_0350_public_get_pumping_figures_line_item_kinds.sql
--
-- WHAT: two corrections to public.get_pumping_figures(bigint, bigint[]) (B1 of the Client App move,
--       2026-11-14_0140), under Fred's rule for a visit's gallons: "the truck tank's reading, else the trap size
--       labelled, else Not measured; never the Calendar's estimate".
--   1. The trap-size fallback is the GREASE TRAP's size (properties.grease_trap_size_gallons), so it applies to a grease
--      trap pumping only. A lift station or grey water pumping with no trusted tank reading is "none" (Not measured), as
--      the Calendar's estimate shows those kinds at a place with a grease trap service. Before, any pumping took it.
--   2. "A pumping" and its kind come from the visit's line items, by the rule the Calendar's estimate uses:
--      ops.fn_visit_pump_kinds(visit, job) is CALLED here, not copied (ops.fn_grease_estimates_live and
--      ops.fn_client_sludge_averages call the same function), so the rule lives in one place. A visit with no pumping
--      line is "not_a_pumping", first, whatever else it has. Before, visits.service_type decided: 91 completed 2026 visits
--      disagree with their lines, and a visit with no service type was "none".
--   Three anchored edits of the live body (md5-pinned below): the visits CTE reads the pump kinds instead of the service
--   type; g takes "a pumping" and "a grease trap pumping" from them; the source CASE puts "not a pumping" first and gives
--   the trap size to a grease trap pumping only. Unchanged: the gate, the tank reading's trust rule, the site figures,
--   the shape (the same four sources and keys), the grants.
--
-- WHY: decided by the session named Supabase on 2026-11-14 under Fred's rule (Building Apps/Ops Portal/docs/
--      00-fred-picks-2026-11-13-clients.md, round 11 defaults: "a visit's gallons are the truck tank's reading, else the
--      trap size labelled, else Not measured"). The size on file is the grease trap's, so showing it for a lift station
--      or grey water pumping labels a figure of another tank; and the service type said "Pumping" where the lines say
--      otherwise (and the reverse), so B1 and the Calendar answered differently for the same visit.
--
-- WHAT MOVES (every completed, live visit, measured in the rehearsal): 215 of 1,663, all of them 2026:
--   none to not_a_pumping 80, trap_size to not_a_pumping 38, trap_size to none 61, not_a_pumping to none 25,
--   not_a_pumping to trap_size 10, none to trap_size 1. Unchanged 1,448; after: trap_size 656, not_a_pumping 632,
--   tank 223 (the same readings), none 152. Of the 61 lift station or grey water pumpings that lose the trap size, the
--   Calendar's live estimate shows 47 with the size on file (a place with no grease trap service, where its step 7
--   still uses that size), 13 as unknown and 1 as measured: B1 and the Calendar differ on those 47 by correction 1.
--   Of the 54 visits of service type Pumping that become not_a_pumping, 36 carry only the plain line "Service
--   Agreement" (January to June 2026); the Calendar's estimate already counts them as no pumping. No visit has a
--   trusted tank reading without a pumping line, so putting "not a pumping" before the reading moves nothing today.
--
-- READ ONLY. No table, view, trigger or row is touched. RULE 8, AUDIT: no table. Z8: it stays in public.
-- No app reads B1 yet (the portal's Clients screens are on a local branch), so nothing on screen changes.
-- THE CHECKS: the VERIFY compares the answer, on every completed 2026 visit and both ways, with the Calendar's estimate
--   (ops.fn_grease_estimates_live, read live, never the frozen rows); with the averages both ways (the trust rule); and
--   with the old body's answer, kept before the replacement: every visit that moved is explained by one of the two
--   corrections, and nothing else of any entry or of the site figures moved. The standing check
--   scripts/checks/client_page_reads.sql runs the same, without the old body.
-- COST (best of 3, old and new body in one rolled-back request, 2026-11-14): 0.39 s for a client, as before; 0.12 s
--   for 200 visit ids (0.10 before).
-- UNDO: 2026-11-14_rollback_public_get_pumping_figures_line_item_kinds.sql (the 2026-11-14_0140 body back, md5-guarded).
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(replace(pg_get_functiondef('public.get_pumping_figures(bigint,bigint[])'::regprocedure), chr(13), '')) <> 'f8610c4739bc5422d79f836020b92eed' then
    raise exception 'public.get_pumping_figures is not the 2026-11-14_0140 body; stop';
  end if;
end
$pin$;

-- The old body's answer for every completed, live visit (in chunks of 2,000), and the site figures of 112-YA and of the
-- two clients with the most site figures, for the comparison at the end of the VERIFY (which drops them).
create temp table _b1fix_old as
select (x ->> 'visit_id')::bigint as visit_id, x ->> 'source' as source, (x ->> 'gallons')::int as gallons,
       x - 'source' - 'gallons' as rest
  from (select array_agg(vv.id) as ids from public.visits vv
         where vv.deleted_at is null and vv.visit_status = 'completed' group by vv.id / 2000) c
 cross join lateral jsonb_array_elements(public.get_pumping_figures(null, c.ids) -> 'visits') x;
create temp table _b1fix_old_sites as
select c.client_id, public.get_pumping_figures(c.client_id) -> 'sites' as sites
  from ((select 381::bigint as client_id)
        union
        (select a.client_id from ops.fn_client_sludge_averages(array[(now() at time zone 'America/New_York')::date + 1]) a
          group by 1 order by count(*) desc, 1 limit 2)) c;

CREATE OR REPLACE FUNCTION public.get_pumping_figures(p_client_id bigint DEFAULT NULL::bigint, p_visit_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    select vv.id, vv.client_id, vv.property_id, vv.visit_date,
           nullif(p.grease_trap_size_gallons, 0) as trap,
           -- its pump kinds from its line items, by the Calendar's own rule (its estimate and the averages call this same
           -- function): grease_trap, grey_water, lift_station; empty when no line pumps anything. Never visits.service_type.
           ops.fn_visit_pump_kinds(vv.id, vv.job_id) as kinds
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
           v.kinds <> '{}' as pumping,
           -- the trap size on file is the grease trap's, so only a grease trap pumping falls back to it
           'grease_trap' = any (v.kinds) as grease_trap,
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
           'source', case when not g.pumping then 'not_a_pumping'
                          when g.tank_gallons is not null then 'tank'
                          when g.grease_trap and g.trap is not null then 'trap_size'
                          else 'none' end,
           'gallons', case when not g.pumping then null
                           when g.tank_gallons is not null then g.tank_gallons
                           when g.grease_trap and g.trap is not null then g.trap end)
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
$function$;

notify pgrst, 'reload schema';

do $verify$
declare
  v_sig constant text := 'public.get_pumping_figures(bigint,bigint[])';
  v_role text; v_uid uuid; v_email text; v_res jsonb; v_state text; v_msg text; v_bad bigint; v_n bigint; v_moves text;
  r record;
begin
  -- 1. Who may run it (unchanged).
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

  -- 3. Every completed, live visit (in chunks of 2,000): one entry each, one of the four sources, gallons exactly when
  --    the source has them, and the trap size as it is on file.
  drop table if exists _b1fix_new;
  create temp table _b1fix_new as
  select (x ->> 'visit_id')::bigint as visit_id, x ->> 'source' as source, (x ->> 'gallons')::int as gallons,
         (x ->> 'property_id')::bigint as pid, x - 'source' - 'gallons' as rest
    from (select array_agg(vv.id) as ids from public.visits vv
           where vv.deleted_at is null and vv.visit_status = 'completed' group by vv.id / 2000) c
   cross join lateral jsonb_array_elements(public.get_pumping_figures(null, c.ids) -> 'visits') x;
  if (select count(*) from _b1fix_new) <> (select count(*) from public.visits vv where vv.deleted_at is null and vv.visit_status = 'completed')
     or (select count(distinct n.visit_id) from _b1fix_new n) <> (select count(*) from _b1fix_new) then
    raise exception 'verify_fail: not one entry per completed visit';
  end if;
  select count(*) into v_bad
    from _b1fix_new n
    join public.visits vv on vv.id = n.visit_id
    left join public.properties p on p.id = vv.property_id
   where n.source is null or n.source not in ('tank', 'trap_size', 'none', 'not_a_pumping')
      or (n.gallons is null) <> (n.source in ('none', 'not_a_pumping'))
      or (n.source = 'trap_size' and n.gallons is distinct from nullif(p.grease_trap_size_gallons, 0));
  if v_bad <> 0 then raise exception 'verify_fail: % visits are malformed', v_bad; end if;

  -- 4. Both ways against the Calendar's estimate, which finds a visit's pump kinds with the same function
  --    (ops.fn_grease_estimates_live: live, never the frozen rows), on every completed 2026 visit: "not a pumping"
  --    exactly when the estimate finds no pump kind; the trap size only where its kinds hold a grease trap; and "none"
  --    never on a grease trap pumping with a trap size on file (that one has the trap size, or a trusted reading).
  with cal as materialized (
    select e.visit_id, e.visit_date, e.pump_kinds
      from ops.fn_grease_estimates_live(date '2026-01-01',
             greatest((now() at time zone 'America/New_York')::date,
                      (select max(vv.visit_date) from public.visits vv where vv.deleted_at is null and vv.visit_status = 'completed'))) e
  )
  select count(*) filter (where c.visit_id is null
                             or (n.source = 'not_a_pumping') <> (c.pump_kinds = '{}')
                             or (n.source = 'trap_size' and not ('grease_trap' = any (c.pump_kinds)))
                             or (n.source = 'none' and 'grease_trap' = any (c.pump_kinds) and nullif(p.grease_trap_size_gallons, 0) is not null)),
         count(distinct n.source)
    into v_bad, v_n
    from _b1fix_new n
    join public.visits vv on vv.id = n.visit_id
    left join public.properties p on p.id = vv.property_id
    left join cal c on c.visit_id = n.visit_id and c.visit_date = vv.visit_date
   where vv.visit_date >= date '2026-01-01';
  if v_bad <> 0 then raise exception 'verify_fail: % visits differ from the Calendar''s estimate', v_bad; end if;
  if v_n <> 4 then raise exception 'verify_fail: only % of the four sources among the 2026 visits', v_n; end if;

  -- 5. Both ways against the averages (the other home of the trust rule): a reading the averages use (any date) is
  --    "tank" here with the same whole gallons, and every "tank" reading of a visit with a site is one they use (a
  --    "tank" reading now always has a pump kind).
  with av as (
    select distinct (rr ->> 'visit_id')::bigint as visit_id, round((rr ->> 'gallons')::numeric)::int as g
      from ops.fn_client_sludge_averages((select array_agg(distinct t.visit_date + 1) from public.v_visit_tank_service t)) a
     cross join lateral jsonb_array_elements(a.readings) rr
  )
  select (select count(*) from av left join _b1fix_new b on b.visit_id = av.visit_id where b.source is distinct from 'tank' or b.gallons is distinct from av.g)
       + (select count(*) from _b1fix_new b where b.source = 'tank' and b.pid is not null and not exists (select 1 from av where av.visit_id = b.visit_id))
    into v_bad;
  if v_bad <> 0 then raise exception 'verify_fail: % readings differ between this read and the averages', v_bad; end if;
  if not exists (select 1 from _b1fix_new b where b.source = 'tank') then raise exception 'verify_fail: no tank reading at all'; end if;

  -- 6. The site figures are the averages' own, for a client that has some.
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

  -- 7. Nothing else moved, against the old body's answer (kept before the replacement): every visit keeps its entry,
  --    and keeps its source and gallons unless one of the two corrections moves it: (a) the old pumping verdict
  --    (service type Pumping and not a dump site; unknown without a service type) is not the line items' verdict, or
  --    (b) a lift station or grey water pumping had the trap size and now has none. The site figures do not move.
  select count(*) into v_bad
    from _b1fix_old o
    full join _b1fix_new n on n.visit_id = o.visit_id
    left join public.visits vv on vv.id = coalesce(o.visit_id, n.visit_id)
    left join public.v_visit_tank_service t on t.visit_id = vv.id
    cross join lateral (select ops.fn_visit_pump_kinds(vv.id, vv.job_id) as kinds) k
   where o.visit_id is null or n.visit_id is null or o.rest is distinct from n.rest
      or ((o.source, o.gallons) is distinct from (n.source, n.gallons)
          and not ((vv.service_type = 'Pumping' and coalesce(t.visit_kind, '') <> 'dump') is distinct from (k.kinds <> '{}')
                   or (o.source = 'trap_size' and n.source = 'none' and k.kinds <> '{}' and not ('grease_trap' = any (k.kinds)))));
  if v_bad <> 0 then raise exception 'verify_fail: % visits moved without a reason', v_bad; end if;
  select count(*) into v_bad from _b1fix_old_sites s where s.sites is distinct from public.get_pumping_figures(s.client_id) -> 'sites';
  if v_bad <> 0 or (select count(*) from _b1fix_old_sites) < 3 then raise exception 'verify_fail: the site figures moved (% of the clients)', v_bad; end if;
  select string_agg(q.m, ', ' order by q.m) into v_moves
    from (select o.source || ' to ' || n.source || ' ' || count(*) as m
            from _b1fix_old o join _b1fix_new n on n.visit_id = o.visit_id
           where o.source <> n.source group by o.source, n.source) q;

  raise notice 'verify ok: moved %; now % tank, % trap_size, % none, % not_a_pumping', coalesce(v_moves, 'nothing'),
    (select count(*) from _b1fix_new b where b.source = 'tank'), (select count(*) from _b1fix_new b where b.source = 'trap_size'),
    (select count(*) from _b1fix_new b where b.source = 'none'), (select count(*) from _b1fix_new b where b.source = 'not_a_pumping');
  drop table _b1fix_old; drop table _b1fix_old_sites; drop table _b1fix_new;
end $verify$;

COMMIT;
