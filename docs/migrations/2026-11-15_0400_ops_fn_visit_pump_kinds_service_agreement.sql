-- =============================================================================
-- 2026-11-15_0400_ops_fn_visit_pump_kinds_service_agreement.sql
--
-- WHAT: ops.fn_visit_pump_kinds(visit, job), the one rule that says whether a visit is a pumping and of which kind (the
--       Calendar's estimate, the averages, Admin Review's Grease page and the portal's B1 all call it), counts a visit marked
--       Pumping whose old uncoded lines are only the plain "Service Agreement" as a grease trap pumping. One anchored edit of
--       the live body (md5-pinned below): a third arm in its CTE k. It fires only in the old-text branch (no coded line on the
--       visit or its job), only with every old line named exactly "Service Agreement", and only for a visit whose service
--       type is Pumping; a call for a job alone (no visit) never takes it.
--
-- WHY: Fred, 2026-11-15 about 2:45 AM ET, answering the page of the built Clients pages ("go ahead with recomended", pick
--      LL): "36 visits of January to June 2026 are marked Pumping but carry only the line 'Service Agreement' ... Count them
--      as grease trap pumpings, in the one rule the Calendar also uses." Their jobs (all archived) are titled grease trap
--      pumping. (Building Apps/Ops Portal/docs/00-fred-picks-2026-11-13-clients.md, the last section.)
--
-- WHAT MOVES (measured in the rehearsal of 2026-11-15, every reader of the rule before and after):
--   - the rule itself: 37 visits go from no kind to grease_trap: the 36 (completed, live, January 4 to June 16, 2026) and one
--     deleted scheduled visit of June 11 that no reader shows. No job's own kinds move.
--   - B1 (public.get_pumping_figures): the 36, from 'not_a_pumping' to 'trap_size' (the grease trap size on file at their
--     place), or to 'none' where the place has no size. Nothing else.
--   - the Calendar's live estimate (ops.fn_grease_estimates_live): the 36 become grease trap pumpings; no other row moves.
--   - what the Calendar SHOWS does NOT move: each of the 36 has its day stored in ops.visit_grease_frozen as "not a pumping",
--     and a stored past day wins (ops.fn_grease_estimates_resolved, ops.calendar_grease_estimates: identical, every row).
--     The freezer does not touch them either (it stores only days with no stored row, and re-stores only a pumping row whose
--     truck changed sides). So the Calendar's January to June days keep them out until someone decides to store them again.
--   - the averages (ops.fn_client_sludge_averages, ops.v_client_sludge_average) and Admin Review's Grease page
--     (public.get_grease_by_client): identical (none of the 36 has a truck tank row).
--
-- READ ONLY. No table, view, trigger or row is touched; ops.visit_grease_frozen is not written. RULE 8, AUDIT: no table.
-- THE CHECKS: the VERIFY keeps every reader's answer before the replacement and compares it after: the kinds of every visit
--   and of every job, B1 for every completed visit, the live estimate and the resolved one over 2026 to the last planned
--   visit, the Calendar's RPC over the same days in 45-day windows, the averages for those days and tomorrow, the view of
--   the averages and Admin Review's Grease page (both as the first active admin). It stops on any other change. Control (the
--   rehearsal): this VERIFY with the old body in place fails.
-- UNDO: 2026-11-15_rollback_ops_fn_visit_pump_kinds_service_agreement.sql (the old body back, md5-guarded).
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(replace(pg_get_functiondef('ops.fn_visit_pump_kinds(bigint,bigint)'::regprocedure), chr(13), '')) <> 'babdac78c98b1f1133525adc9e5d03f0' then
    raise exception 'ops.fn_visit_pump_kinds is not the body this migration was written from; stop';
  end if;
end
$pin$;

select set_config('request.jwt.claims', (select json_build_object('sub', u.id, 'email', u.email, 'role', 'authenticated')::text
   from public.employees e join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
  where e.status = 'ACTIVE' and e.access_level = 'admin' and u.email_confirmed_at is not null order by e.id limit 1), true);
-- The days compared: 2026 to the last planned visit; the averages for every day a visit falls on, and tomorrow.
create temp table _ll_range as
select date '2026-01-01' as f,
       greatest((now() at time zone 'America/New_York')::date + 1,
                (select max(cv.visit_date) from ops.v_calendar_visit cv)) as t;
create temp table _ll_days as
select distinct cv.visit_date as d from ops.v_calendar_visit cv
 where cv.visit_date between (select f from _ll_range) and (select t from _ll_range)
union select (now() at time zone 'America/New_York')::date + 1;
create temp table _ll_proc_old as
select row(p.prolang, p.provolatile, p.prosecdef, p.proconfig, p.proacl)::text as x from pg_proc p where p.oid = 'ops.fn_visit_pump_kinds(bigint,bigint)'::regprocedure;
create temp table _ll_cal_shape as select * from ops.calendar_grease_estimates(current_date, current_date) limit 0;
create temp table _ll_grease_shape as select * from public.get_grease_by_client() limit 0;
select set_config('request.jwt.claims', '', true);
create temp table _ll_kinds_old as
select vv.id as visit_id, ops.fn_visit_pump_kinds(vv.id, vv.job_id) as kinds from public.visits vv;
create temp table _ll_jobkinds_old as
select j.id as job_id, ops.fn_visit_pump_kinds(null::bigint, j.id) as kinds from public.jobs j;
create temp table _ll_b1_old as
select (x ->> 'visit_id')::bigint as visit_id, x as entry
  from (select array_agg(vv.id) as ids from public.visits vv
         where vv.deleted_at is null and vv.visit_status = 'completed' group by vv.id / 2000) c
 cross join lateral jsonb_array_elements(public.get_pumping_figures(null, c.ids) -> 'visits') x;
create temp table _ll_live_old as select * from ops.fn_grease_estimates_live((select f from _ll_range), (select t from _ll_range));
create temp table _ll_resolved_old as select * from ops.fn_grease_estimates_resolved((select f from _ll_range), (select t from _ll_range));
create temp table _ll_avg_old as
select * from ops.fn_client_sludge_averages((select array_agg(distinct d) from _ll_days d));
create temp table _ll_vcsa_old as select * from ops.v_client_sludge_average;
create temp table _ll_cal_old (like _ll_cal_shape);
create temp table _ll_grease_old (like _ll_grease_shape);
do $as_admin$
declare w date;
begin
  perform set_config('request.jwt.claims', (select json_build_object('sub', u.id, 'email', u.email, 'role', 'authenticated')::text
     from public.employees e join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
    where e.status = 'ACTIVE' and e.access_level = 'admin' and u.email_confirmed_at is not null order by e.id limit 1), true);
  w := (select f from _ll_range);
  while w <= (select t from _ll_range) loop
    insert into _ll_cal_old select * from ops.calendar_grease_estimates(w, least(w + 45, (select t from _ll_range)));
    w := w + 46;
  end loop;
  insert into _ll_grease_old select * from public.get_grease_by_client();
  perform set_config('request.jwt.claims', '', true);
end $as_admin$;

CREATE OR REPLACE FUNCTION ops.fn_visit_pump_kinds(p_visit_id bigint, p_job_id bigint)
 RETURNS text[]
 LANGUAGE sql
 STABLE
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
  WITH own AS (
    SELECT sli.service_type, sli.location_target
      FROM public.line_items li
      JOIN public.service_line_items sli ON sli.code = lpad(substring(btrim(li.name), '^([0-9]+)'), 2, '0')
     WHERE li.visit_id = p_visit_id AND sli.schedulable
  ), coded AS (
    SELECT * FROM own
    UNION ALL
    SELECT sli.service_type, sli.location_target
      FROM public.line_items li
      JOIN public.service_line_items sli ON sli.code = lpad(substring(btrim(li.name), '^([0-9]+)'), 2, '0')
     WHERE li.job_id = p_job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND sli.schedulable
       AND NOT EXISTS (SELECT 1 FROM own)
  ), old_text AS (  -- dated exception: lines from before the codes, only when nothing is coded
    SELECT btrim(li.name) AS nm
      FROM public.line_items li
     WHERE (li.visit_id = p_visit_id OR (li.job_id = p_job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL))
       AND btrim(li.name) !~ '^[0-9]'
       AND NOT EXISTS (SELECT 1 FROM coded)
  ), k AS (
    SELECT CASE WHEN c.service_type = 'Pumping' AND c.location_target ~* 'grease trap' THEN 1
                WHEN c.service_type = 'Pumping' AND c.location_target ~* 'grey water' THEN 2
                WHEN c.service_type = 'Pumping' AND c.location_target ~* 'lift station' THEN 3 END AS r
      FROM coded c
    UNION ALL
    SELECT CASE WHEN o.nm ~* 'grease trap' THEN 1
                WHEN o.nm ~* 'grey water' THEN 2
                WHEN o.nm ~* '(lift|lyft) station' THEN 3 END
      FROM old_text o
    UNION ALL
    -- LL (2026-11-15, Fred: "go ahead with recomended"): a visit marked Pumping whose old lines are only the plain
    -- "Service Agreement" was a grease trap pumping billed under the agreement line (36 visits, January to June 2026).
    SELECT 1
     WHERE EXISTS (SELECT 1 FROM old_text o WHERE o.nm ~* '^service agreement$')
       AND NOT EXISTS (SELECT 1 FROM old_text o WHERE o.nm !~* '^service agreement$')
       AND EXISTS (SELECT 1 FROM public.visits vv WHERE vv.id = p_visit_id AND vv.service_type = 'Pumping')
  )
  SELECT coalesce(array_agg(CASE r WHEN 1 THEN 'grease_trap' WHEN 2 THEN 'grey_water' ELSE 'lift_station' END ORDER BY r),
                  '{}'::text[])
    FROM (SELECT DISTINCT r FROM k WHERE r IS NOT NULL) d
$function$;

do $md5$
begin
  if md5(replace(pg_get_functiondef('ops.fn_visit_pump_kinds(bigint,bigint)'::regprocedure), chr(13), '')) <> 'c1e484205b1e89b51d366e7d2a4b7e60' then
    raise exception 'verify_fail: the stored body is not the one written here';
  end if;
end
$md5$;

create temp table _ll_kinds_new as
select vv.id as visit_id, ops.fn_visit_pump_kinds(vv.id, vv.job_id) as kinds from public.visits vv;
create temp table _ll_jobkinds_new as
select j.id as job_id, ops.fn_visit_pump_kinds(null::bigint, j.id) as kinds from public.jobs j;
create temp table _ll_b1_new as
select (x ->> 'visit_id')::bigint as visit_id, x as entry
  from (select array_agg(vv.id) as ids from public.visits vv
         where vv.deleted_at is null and vv.visit_status = 'completed' group by vv.id / 2000) c
 cross join lateral jsonb_array_elements(public.get_pumping_figures(null, c.ids) -> 'visits') x;
create temp table _ll_live_new as select * from ops.fn_grease_estimates_live((select f from _ll_range), (select t from _ll_range));
create temp table _ll_resolved_new as select * from ops.fn_grease_estimates_resolved((select f from _ll_range), (select t from _ll_range));
create temp table _ll_avg_new as
select * from ops.fn_client_sludge_averages((select array_agg(distinct d) from _ll_days d));
create temp table _ll_vcsa_new as select * from ops.v_client_sludge_average;
create temp table _ll_cal_new (like _ll_cal_shape);
create temp table _ll_grease_new (like _ll_grease_shape);
do $as_admin$
declare w date;
begin
  perform set_config('request.jwt.claims', (select json_build_object('sub', u.id, 'email', u.email, 'role', 'authenticated')::text
     from public.employees e join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
    where e.status = 'ACTIVE' and e.access_level = 'admin' and u.email_confirmed_at is not null order by e.id limit 1), true);
  w := (select f from _ll_range);
  while w <= (select t from _ll_range) loop
    insert into _ll_cal_new select * from ops.calendar_grease_estimates(w, least(w + 45, (select t from _ll_range)));
    w := w + 46;
  end loop;
  insert into _ll_grease_new select * from public.get_grease_by_client();
  perform set_config('request.jwt.claims', '', true);
end $as_admin$;

do $verify$
declare
  v_bad bigint; v_n bigint; v_msg text := '';
  r record;
begin
  -- 1. The function keeps its kind and its grants: SQL, STABLE, INVOKER, its search_path, EXECUTE for service_role only.
  if (select row(p.prolang, p.provolatile, p.prosecdef, p.proconfig, p.proacl)::text from pg_proc p where p.oid = 'ops.fn_visit_pump_kinds(bigint,bigint)'::regprocedure)
     is distinct from (select x from _ll_proc_old) then
    raise exception 'verify_fail: the function''s kind or grants changed';
  end if;
  if has_function_privilege('authenticated', 'ops.fn_visit_pump_kinds(bigint,bigint)', 'execute') or has_function_privilege('anon', 'ops.fn_visit_pump_kinds(bigint,bigint)', 'execute') then
    raise exception 'verify_fail: authenticated or anon can execute the rule';
  end if;

  -- 2. The rule: every visit that moved went from no kind to grease_trap, is marked Pumping and carries a line named exactly
  --    "Service Agreement" and no coded line; exactly 36 of them are live and completed (Fred's 36). No job moved.
  drop table if exists _ll_moved;
  create temp table _ll_moved as
  select o.visit_id, vv.deleted_at is null and vv.visit_status = 'completed' as live_done
    from _ll_kinds_old o join _ll_kinds_new n using (visit_id) join public.visits vv on vv.id = o.visit_id
   where o.kinds is distinct from n.kinds;
  select count(*) into v_bad
    from _ll_moved m join _ll_kinds_old o using (visit_id) join _ll_kinds_new n using (visit_id) join public.visits vv on vv.id = m.visit_id
   where o.kinds <> '{}' or n.kinds <> '{grease_trap}' or vv.service_type is distinct from 'Pumping'
      or not exists (select 1 from public.line_items li where li.visit_id = vv.id and btrim(li.name) ~* '^service agreement$')
      or exists (select 1 from public.line_items li where li.visit_id = vv.id and btrim(li.name) ~ '^[0-9]');
  if v_bad <> 0 then raise exception 'verify_fail: % visits moved that are not a Service Agreement pumping', v_bad; end if;
  if (select count(*) from _ll_moved where live_done) <> 36 then
    raise exception 'verify_fail: % live completed visits moved, not the 36', (select count(*) from _ll_moved where live_done);
  end if;
  if (select count(*) from _ll_kinds_old) <> (select count(*) from _ll_kinds_new) then raise exception 'verify_fail: the visits changed under the check'; end if;
  select count(*) into v_bad from _ll_jobkinds_old o full join _ll_jobkinds_new n using (job_id) where o.kinds is distinct from n.kinds;
  if v_bad <> 0 then raise exception 'verify_fail: % jobs changed kinds', v_bad; end if;

  -- 3. B1: only the 36 move, from not_a_pumping to the grease trap size on file (trap_size), or none where there is no size.
  select count(*) into v_bad
    from _ll_b1_old o full join _ll_b1_new n using (visit_id)
    left join public.visits vv on vv.id = coalesce(o.visit_id, n.visit_id)
    left join public.properties p on p.id = vv.property_id
   where o.entry is distinct from n.entry
     and not (o.visit_id in (select visit_id from _ll_moved where live_done)
              and o.entry ->> 'source' = 'not_a_pumping'
              and (o.entry - 'source' - 'gallons') = (n.entry - 'source' - 'gallons')
              and ((n.entry ->> 'source' = 'trap_size' and (n.entry ->> 'gallons')::int = nullif(p.grease_trap_size_gallons, 0))
                   or (n.entry ->> 'source' = 'none' and nullif(p.grease_trap_size_gallons, 0) is null)));
  if v_bad <> 0 then raise exception 'verify_fail: % B1 entries moved without a reason', v_bad; end if;
  if (select count(*) from _ll_b1_old o join _ll_b1_new n using (visit_id) where o.entry is distinct from n.entry) <> 36 then
    raise exception 'verify_fail: B1 did not move the 36';
  end if;

  -- 4. The Calendar's live estimate: the 36 become grease trap pumpings; no other row moves.
  select (select count(*) from (select * from _ll_live_old except select * from _ll_live_new) x where x.visit_id not in (select visit_id from _ll_moved))
       + (select count(*) from (select * from _ll_live_new except select * from _ll_live_old) x where x.visit_id not in (select visit_id from _ll_moved))
    into v_bad;
  if v_bad <> 0 then raise exception 'verify_fail: % rows of the live estimate moved outside the 36', v_bad; end if;
  select count(*) into v_bad
    from _ll_moved m join _ll_live_new n using (visit_id)
   where not m.live_done or n.pump_kind is distinct from 'grease_trap' or n.pump_kinds is distinct from '{grease_trap}'
      or n.basis not in ('measured', 'trap_size', 'unknown');
  if v_bad <> 0 or (select count(*) from _ll_live_new n where n.visit_id in (select visit_id from _ll_moved)) <> 36 then
    raise exception 'verify_fail: the 36 are not each one grease trap row of the live estimate';
  end if;

  -- 5. What the Calendar shows does not move: each of the 36 has its day stored as "not a pumping", and the resolved estimate
  --    and the Calendar's RPC are identical, every row.
  select count(*) into v_bad
    from _ll_moved m join public.visits vv on vv.id = m.visit_id
   where m.live_done and not exists (select 1 from ops.visit_grease_frozen f
                                      where f.visit_id = vv.id and f.visit_date = vv.visit_date and f.superseded_at is null
                                        and f.pump_kind is null and f.basis = 'not_pumping');
  if v_bad <> 0 then raise exception 'verify_fail: % of the 36 have no stored "not a pumping" day', v_bad; end if;
  select (select count(*) from (select * from _ll_resolved_old except select * from _ll_resolved_new) x)
       + (select count(*) from (select * from _ll_resolved_new except select * from _ll_resolved_old) x)
       + (select count(*) from (select * from _ll_cal_old except select * from _ll_cal_new) x)
       + (select count(*) from (select * from _ll_cal_new except select * from _ll_cal_old) x)
    into v_bad;
  if v_bad <> 0 then raise exception 'verify_fail: % rows of what the Calendar shows moved', v_bad; end if;
  if (select count(*) from _ll_cal_new) = 0 or (select count(*) from _ll_resolved_new) = 0 then raise exception 'verify_fail: the Calendar comparison is empty'; end if;

  -- 6. The averages, their view and Admin Review's Grease page: identical.
  select (select count(*) from (select * from _ll_avg_old except select * from _ll_avg_new) x)
       + (select count(*) from (select * from _ll_avg_new except select * from _ll_avg_old) x)
       + (select count(*) from (select * from _ll_vcsa_old except select * from _ll_vcsa_new) x)
       + (select count(*) from (select * from _ll_vcsa_new except select * from _ll_vcsa_old) x)
       + (select count(*) from (select * from _ll_grease_old except select * from _ll_grease_new) x)
       + (select count(*) from (select * from _ll_grease_new except select * from _ll_grease_old) x)
    into v_bad;
  if v_bad <> 0 then raise exception 'verify_fail: % rows of the averages or the Grease page moved', v_bad; end if;
  if (select count(*) from _ll_avg_new) = 0 or (select count(*) from _ll_grease_new) = 0 then raise exception 'verify_fail: the averages comparison is empty'; end if;

  select string_agg(x.m, ', ') into v_msg from (
    select 'rule ' || count(*) || ' (' || count(*) filter (where live_done) || ' live completed)' as m from _ll_moved
    union all select 'B1 ' || string_agg(q.s || ' ' || q.c, ', ') from (select n.entry ->> 'source' as s, count(*) as c from _ll_b1_new n
      where n.visit_id in (select visit_id from _ll_moved) group by 1 order by 1) q
    union all select 'live ' || string_agg(q.b || ' ' || q.c, ', ') from (select n.basis as b, count(*) as c from _ll_live_new n
      where n.visit_id in (select visit_id from _ll_moved) group by 1 order by 1) q
    union all select 'compared: ' || (select count(*) from _ll_kinds_new) || ' visits, ' || (select count(*) from _ll_jobkinds_new) || ' jobs, '
      || (select count(*) from _ll_b1_new) || ' B1, ' || (select count(*) from _ll_live_new) || ' live, ' || (select count(*) from _ll_resolved_new)
      || ' resolved, ' || (select count(*) from _ll_cal_new) || ' Calendar RPC, ' || (select count(*) from _ll_avg_new) || ' averages, '
      || (select count(*) from _ll_vcsa_new) || ' view, ' || (select count(*) from _ll_grease_new) || ' Grease page rows') x;
  raise notice 'verify ok: %; nothing else moved', v_msg;
end $verify$;

COMMIT;
