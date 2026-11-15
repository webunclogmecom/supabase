-- =============================================================================
-- 2026-11-15_0330_public_get_pumping_figures_size_on_file.sql
--
-- WHAT: public.get_pumping_figures(bigint, bigint[]) (B1, the portal's Clients pages and the manifest dialog) gives a lift
--       station or grey water pumping with no trusted truck tank reading, at a place with no grease trap service, the size
--       on file, under a new source 'size_on_file'. The truck tank's reading still comes first; a grease trap pumping keeps
--       'trap_size'; a lift station or grey water pumping at a place WITH a grease trap service stays 'none' (the size on
--       file there is the grease trap's).
--   "A place with a grease trap service" is the Calendar's step 7 rule (ops.fn_grease_estimates_live, its CTE gt), copied
--   into a CTE here: an open job (not archived or destroyed) at the place whose own lines pump a grease trap, the pump
--   kinds from ops.fn_visit_pump_kinds(null, job). The size on file is the one B1 already reads,
--   properties.grease_trap_size_gallons (0 is none).
--   Three anchored edits of the live body (md5-pinned below): a gt CTE and an own_tank flag before g's grease_trap flag, and
--   one line in each of the source and gallons CASEs. Unchanged: the gate, the trust rule of a reading, the site figures,
--   the grants, every other source.
--
-- WHY: Fred, 2026-11-15 about 2:45 AM ET, answering the page of the built Clients pages ("go ahead with recomended", pick
--      KK): "A lift station or grey water pumping with no tank reading, at a place with no grease trap service: show the size
--      on file, labelled 'size on file', as the Calendar does. One rule in every app. At a place with no grease trap, the
--      size field holds the tank that is pumped there. The truck tank's reading always comes first when there is one."
--      (Building Apps/Ops Portal/docs/00-fred-picks-2026-11-13-clients.md, the last section.)
--
-- WHAT MOVES (every completed, live visit, measured in the rehearsal of 2026-11-15): only 'none' to 'size_on_file', 54
--   visits at 6 places (5 grey water, 1 lift station); nothing else of any entry, and no site figure. The page counted 47:
--   those were the 2026-11-14_0350 moves from 'trap_size' to 'none' that the Calendar shows with the size on file. The other
--   7 are the same case: 6 that 0350 moved from 'not_a_pumping' to 'none' (5 marked Cleaning, 1 with no service type,
--   pumpings by their lines) and 1 the Calendar shows with its Moises average (B1 never shows an estimate).
--
-- READ ONLY. No table, view, trigger or row is touched. RULE 8, AUDIT: no table. Z8: it stays in public.
-- No live app reads B1 (the portal's Clients screens are on the local branch clients-move); the app's words for the new
-- source ("N gal, size on file") are on that branch.
-- THE CHECKS: the VERIFY compares the answer with the Calendar's estimate (ops.fn_grease_estimates_live, live, never the
--   frozen rows) on every completed 2026 visit, both ways, now for 'size_on_file' too: it appears only where the Calendar
--   shows the size on file (or its Moises average) for a lift station or grey water pumping, with the same gallons, and
--   every such visit of the Calendar with a size on its own place has it here. So the two copies of the grease trap service
--   rule cannot drift apart unseen. ponytail: a visit the Calendar shows with its Moises average is checked one way only
--   (its output does not say whether the place has a grease trap service); 1 visit today.
--   With the old body's answer (kept before the replacement): every visit that moved went from 'none' to 'size_on_file'
--   and is that case; nothing else moved. The standing check scripts/checks/client_page_reads.sql runs the same, without
--   the old body. Control (the rehearsal): this VERIFY on the 0350 body fails.
-- UNDO: 2026-11-15_rollback_public_get_pumping_figures_size_on_file.sql (the 0350 body back, md5-guarded).
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(replace(pg_get_functiondef('public.get_pumping_figures(bigint,bigint[])'::regprocedure), chr(13), '')) <> '000f3eba9eba1c8fdb29ea574e9479dc' then
    raise exception 'public.get_pumping_figures is not the 2026-11-14_0350 body; stop';
  end if;
end
$pin$;

-- The old body's answer for every completed, live visit (in chunks of 2,000), and the site figures of 112-YA and of the
-- two clients with the most site figures, for the comparison at the end of the VERIFY (which drops them).
create temp table _kk_old as
select (x ->> 'visit_id')::bigint as visit_id, x ->> 'source' as source, (x ->> 'gallons')::int as gallons,
       x - 'source' - 'gallons' as rest
  from (select array_agg(vv.id) as ids from public.visits vv
         where vv.deleted_at is null and vv.visit_status = 'completed' group by vv.id / 2000) c
 cross join lateral jsonb_array_elements(public.get_pumping_figures(null, c.ids) -> 'visits') x;
create temp table _kk_old_sites as
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
  ), gt as materialized (
    -- KK (2026-11-15): the places with a grease trap service, by the Calendar's own rule (ops.fn_grease_estimates_live,
    -- its step 7): an open job (not archived or destroyed) at the place whose own lines pump a grease trap. Only the places
    -- of a lift station or grey water pumping are looked at.
    select distinct j.property_id as prop
      from public.jobs j
     where j.property_id in (select v.property_id from v where v.kinds <> '{}' and not ('grease_trap' = any (v.kinds)))
       and coalesce(j.job_status, '') not in ('archived', 'destroyed')
       and 'grease_trap' = any (ops.fn_visit_pump_kinds(null::bigint, j.id))
  ), g as (
    select v.id, v.client_id, v.property_id, v.visit_date, v.trap,
           v.kinds <> '{}' as pumping,
           -- the size on file is the grease trap's where the place has a grease trap service: a grease trap pumping falls
           -- back to it as the trap size
           'grease_trap' = any (v.kinds) as grease_trap,
           -- KK: a lift station or grey water pumping at a place with no grease trap service falls back to it as the size
           -- on file, the tank pumped there, as the Calendar's estimate does
           (v.kinds <> '{}' and not ('grease_trap' = any (v.kinds))
            and not exists (select 1 from gt where gt.prop = v.property_id)) as own_tank,
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
                          when g.own_tank and g.trap is not null then 'size_on_file'
                          else 'none' end,
           'gallons', case when not g.pumping then null
                           when g.tank_gallons is not null then g.tank_gallons
                           when g.grease_trap and g.trap is not null then g.trap
                           when g.own_tank and g.trap is not null then g.trap end)
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

do $md5$
begin
  if md5(replace(pg_get_functiondef('public.get_pumping_figures(bigint,bigint[])'::regprocedure), chr(13), '')) <> '7013ce05687fa4337edadf6cfe670e24' then
    raise exception 'verify_fail: the stored body is not the one written here';
  end if;
end
$md5$;

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

  -- 3. Every completed, live visit (in chunks of 2,000): one entry each, one of the five sources, gallons exactly when the
  --    source has them, and the size as it is on file for both size sources.
  drop table if exists _kk_new;
  create temp table _kk_new as
  select (x ->> 'visit_id')::bigint as visit_id, x ->> 'source' as source, (x ->> 'gallons')::int as gallons,
         (x ->> 'property_id')::bigint as pid, x - 'source' - 'gallons' as rest
    from (select array_agg(vv.id) as ids from public.visits vv
           where vv.deleted_at is null and vv.visit_status = 'completed' group by vv.id / 2000) c
   cross join lateral jsonb_array_elements(public.get_pumping_figures(null, c.ids) -> 'visits') x;
  if (select count(*) from _kk_new) <> (select count(*) from public.visits vv where vv.deleted_at is null and vv.visit_status = 'completed')
     or (select count(distinct n.visit_id) from _kk_new n) <> (select count(*) from _kk_new) then
    raise exception 'verify_fail: not one entry per completed visit';
  end if;
  select count(*) into v_bad
    from _kk_new n
    join public.visits vv on vv.id = n.visit_id
    left join public.properties p on p.id = vv.property_id
   where n.source is null or n.source not in ('tank', 'trap_size', 'size_on_file', 'none', 'not_a_pumping')
      or (n.gallons is null) <> (n.source in ('none', 'not_a_pumping'))
      or (n.source in ('trap_size', 'size_on_file') and n.gallons is distinct from nullif(p.grease_trap_size_gallons, 0));
  if v_bad <> 0 then raise exception 'verify_fail: % visits are malformed', v_bad; end if;

  -- 4. Both ways against the Calendar's estimate (ops.fn_grease_estimates_live: live, never the frozen rows; the same pump
  --    kinds function), on every completed 2026 visit:
  --    a. "not a pumping" exactly when the estimate finds no pump kind;
  --    b. the trap size only where its kinds hold a grease trap, and "none" never on a grease trap pumping with a size;
  --    c. "size on file" only on a lift station or grey water pumping the Calendar shows with the size on file (the same
  --       gallons) or with its Moises average, never one it leaves unknown (a place with a grease trap service);
  --    d. every lift station or grey water pumping the Calendar shows with the size on file, with no truck tank reading here
  --       and a size on its own place, is "size on file" here.
  --    Each of the five sources must appear, so the comparison is not empty.
  with cal as materialized (
    select e.visit_id, e.visit_date, e.pump_kinds, e.basis, e.gallons
      from ops.fn_grease_estimates_live(date '2026-01-01',
             greatest((now() at time zone 'America/New_York')::date,
                      (select max(vv.visit_date) from public.visits vv where vv.deleted_at is null and vv.visit_status = 'completed'))) e
  )
  select count(*) filter (where c.visit_id is null
                             or (n.source = 'not_a_pumping') <> (c.pump_kinds = '{}')
                             or (n.source = 'trap_size' and not ('grease_trap' = any (c.pump_kinds)))
                             or (n.source = 'none' and 'grease_trap' = any (c.pump_kinds) and nullif(p.grease_trap_size_gallons, 0) is not null)
                             or (n.source = 'size_on_file'
                                 and (c.pump_kinds = '{}' or 'grease_trap' = any (c.pump_kinds)
                                      or c.basis not in ('trap_size', 'measured')
                                      or (c.basis = 'trap_size' and c.gallons is distinct from n.gallons::numeric)))
                             or (c.basis = 'trap_size' and c.pump_kinds <> '{}' and not ('grease_trap' = any (c.pump_kinds))
                                 and n.source <> 'tank' and nullif(p.grease_trap_size_gallons, 0) is not null
                                 and n.source is distinct from 'size_on_file')),
         count(distinct n.source)
    into v_bad, v_n
    from _kk_new n
    join public.visits vv on vv.id = n.visit_id
    left join public.properties p on p.id = vv.property_id
    left join cal c on c.visit_id = n.visit_id and c.visit_date = vv.visit_date
   where vv.visit_date >= date '2026-01-01';
  if v_bad <> 0 then raise exception 'verify_fail: % visits differ from the Calendar''s estimate', v_bad; end if;
  if v_n <> 5 then raise exception 'verify_fail: only % of the five sources among the 2026 visits', v_n; end if;

  -- 5. Both ways against the averages (the other home of the trust rule): unchanged.
  with av as (
    select distinct (rr ->> 'visit_id')::bigint as visit_id, round((rr ->> 'gallons')::numeric)::int as g
      from ops.fn_client_sludge_averages((select array_agg(distinct t.visit_date + 1) from public.v_visit_tank_service t)) a
     cross join lateral jsonb_array_elements(a.readings) rr
  )
  select (select count(*) from av left join _kk_new b on b.visit_id = av.visit_id where b.source is distinct from 'tank' or b.gallons is distinct from av.g)
       + (select count(*) from _kk_new b where b.source = 'tank' and b.pid is not null and not exists (select 1 from av where av.visit_id = b.visit_id))
    into v_bad;
  if v_bad <> 0 then raise exception 'verify_fail: % readings differ between this read and the averages', v_bad; end if;

  -- 6. Nothing else moved, against the old body's answer (kept before the replacement): every visit keeps its entry, and
  --    keeps its source and gallons unless it went from 'none' to 'size_on_file' as a lift station or grey water pumping
  --    with no trusted reading, a size on its place and no grease trap service there. The site figures do not move.
  select count(*) into v_bad
    from _kk_old o
    full join _kk_new n on n.visit_id = o.visit_id
    left join public.visits vv on vv.id = coalesce(o.visit_id, n.visit_id)
    left join public.properties p on p.id = vv.property_id
    cross join lateral (select ops.fn_visit_pump_kinds(vv.id, vv.job_id) as kinds) k
   where o.visit_id is null or n.visit_id is null or o.rest is distinct from n.rest
      or ((o.source, o.gallons) is distinct from (n.source, n.gallons)
          and not (o.source = 'none' and n.source = 'size_on_file' and n.gallons = nullif(p.grease_trap_size_gallons, 0)
                   and k.kinds <> '{}' and not ('grease_trap' = any (k.kinds))
                   and not exists (select 1 from public.jobs j
                                    where j.property_id = vv.property_id and coalesce(j.job_status, '') not in ('archived', 'destroyed')
                                      and 'grease_trap' = any (ops.fn_visit_pump_kinds(null::bigint, j.id)))));
  if v_bad <> 0 then raise exception 'verify_fail: % visits moved without a reason', v_bad; end if;
  select count(*) into v_bad from _kk_old_sites s where s.sites is distinct from public.get_pumping_figures(s.client_id) -> 'sites';
  if v_bad <> 0 or (select count(*) from _kk_old_sites) < 3 then raise exception 'verify_fail: the site figures moved (% of the clients)', v_bad; end if;
  select string_agg(q.m, ', ' order by q.m) into v_moves
    from (select o.source || ' to ' || n.source || ' ' || count(*) as m
            from _kk_old o join _kk_new n on n.visit_id = o.visit_id
           where o.source <> n.source group by o.source, n.source) q;
  raise notice 'verify ok: moved %; now % tank, % trap_size, % size_on_file, % none, % not_a_pumping', coalesce(v_moves, 'nothing'),
    (select count(*) from _kk_new b where b.source = 'tank'), (select count(*) from _kk_new b where b.source = 'trap_size'),
    (select count(*) from _kk_new b where b.source = 'size_on_file'), (select count(*) from _kk_new b where b.source = 'none'),
    (select count(*) from _kk_new b where b.source = 'not_a_pumping');
  drop table _kk_old; drop table _kk_old_sites;
  drop table _kk_new;
end $verify$;

COMMIT;
