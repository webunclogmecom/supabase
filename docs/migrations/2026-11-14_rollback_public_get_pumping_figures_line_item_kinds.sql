-- ROLLBACK of 2026-11-14_0350_public_get_pumping_figures_line_item_kinds.sql
-- (the B1 fix: the trap size for a grease trap pumping only, and a pumping and its kind from the line items).
--
-- Puts public.get_pumping_figures(bigint, bigint[]) back to its 2026-11-14_0140 body (verbatim, md5 f8610c4739bc5422d79f836020b92eed with
-- carriage returns removed; CREATE OR REPLACE keeps its grants). Guarded: refuses unless the live body is the one the
-- fix applied (md5 000f3eba9eba1c8fdb29ea574e9479dc). Run it BEFORE 2026-11-14_rollback_public_get_pumping_figures.sql if both are wanted
-- (that one drops the function). A portal build that reads B1 then shows the old sources again: the trap size on any
-- pumping, and "a pumping" by the service type.

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(replace(pg_get_functiondef('public.get_pumping_figures(bigint,bigint[])'::regprocedure), chr(13), '')) <> '000f3eba9eba1c8fdb29ea574e9479dc' then
    raise exception 'public.get_pumping_figures is not the body of 2026-11-14_0350_public_get_pumping_figures_line_item_kinds; do not undo blindly';
  end if;
end
$pin$;

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
$function$;

notify pgrst, 'reload schema';

do $verify$
begin
  if md5(replace(pg_get_functiondef('public.get_pumping_figures(bigint,bigint[])'::regprocedure), chr(13), '')) <> 'f8610c4739bc5422d79f836020b92eed' then
    raise exception 'verify_fail: public.get_pumping_figures is not the 2026-11-14_0140 body';
  end if;
  if has_function_privilege('anon', 'public.get_pumping_figures(bigint,bigint[])', 'execute')
     or has_function_privilege('service_role', 'public.get_pumping_figures(bigint,bigint[])', 'execute')
     or not has_function_privilege('authenticated', 'public.get_pumping_figures(bigint,bigint[])', 'execute') then
    raise exception 'verify_fail: the grants of public.get_pumping_figures are not what they were';
  end if;
  raise notice 'verify ok: public.get_pumping_figures is the 2026-11-14_0140 body again';
end $verify$;

COMMIT;
