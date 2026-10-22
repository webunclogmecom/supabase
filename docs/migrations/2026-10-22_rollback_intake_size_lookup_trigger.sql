-- ROLLBACK of 2026-10-22_1302_intake_size_lookup_trigger: no trigger, no cron, no request function, the health
-- logger as it was (md5 asserted). Lookup rows already written stay (roll part 1 back to drop them).
BEGIN;
SET LOCAL lock_timeout = '3s';
SELECT cron.unschedule('intake-size-lookup');
DROP TRIGGER zz_size_lookup_on_submit ON public.property_intakes;
DROP FUNCTION public.trg_size_lookup_request();
DROP FUNCTION public.fn_request_size_lookup();
CREATE OR REPLACE FUNCTION public.log_trap_size_health()
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  n integer;
  v_items jsonb;
  v_today date := (now() at time zone 'America/New_York')::date;
begin
  with flagged as (
    select t.property_id, t.visit_id, t.visit_date, t.sludge_collected_gallons as g
      from public.v_visit_tank_service t
     where t.sludge_above_trap_size
       and t.sludge_confidence in ('high', 'medium')
       and t.visit_date > v_today - 90
  ),
  per_prop as (
    select f.property_id, p.grease_trap_size_gallons as size_on_file, c.client_code, c.name as client_name,
           p.address, count(*) as n_above, max(f.g) as max_g,
           (array_agg(f.visit_date order by f.g desc))[1] as max_date,
           string_agg(format('%s gal on %s', round(f.g), to_char(f.visit_date, 'Mon FMDD')), ', ' order by f.visit_date) as readings
      from flagged f
      join public.properties p on p.id = f.property_id
      left join public.clients c on c.id = p.client_id
     group by f.property_id, p.grease_trap_size_gallons, c.client_code, c.name, p.address
  ),
  missing as (
    select count(*) as n, min(cv.visit_date) as first_date, max(cv.visit_date) as last_date
      from ops.v_calendar_visit cv
     where cv.visit_date between date '2026-01-01' and v_today - 3
       and not exists (select 1 from ops.visit_grease_frozen f
                        where f.visit_id = cv.id and f.visit_date = cv.visit_date and f.superseded_at is null)
  ),
  items as (
    select jsonb_build_object(
             'kind', 'trap_size:too_small:p' || pp.property_id,
             'issue', 'trap_size_too_small',
             'reason', format('The grease trap size on file for %s%s is %s gal, but Moises kept %s gal of grease from it (%s), after pushing the water back. The trap is bigger than the size on file.',
                              coalesce(pp.client_code || ' ', ''), coalesce(pp.client_name, 'property ' || pp.property_id),
                              pp.size_on_file, round(pp.max_g), pp.readings),
             'what_to_do', 'Have the trap size confirmed (the client, the GDO permit, or a crew measurement), then correct the Grease Trap size in Jobber or the Client App. This item clears by itself once the size is corrected.',
             'client_code', pp.client_code, 'property_id', pp.property_id,
             'size_on_file', pp.size_on_file, 'largest_reading', round(pp.max_g)) as item
      from per_prop pp
    union all
    select jsonb_build_object(
             'kind', 'trap_size:grease_freeze_missing',
             'issue', 'grease_freeze_missing',
             'reason', format('%s past visit(s) between %s and %s have no stored Grease pumped number, so their day on the Calendar can change.',
                              m.n, to_char(m.first_date, 'Mon FMDD'), to_char(m.last_date, 'Mon FMDD')),
             'what_to_do', 'Run select ops.fn_freeze_grease_estimates(); and read its sync_log row (calendar_grease_freeze). If it says held_back, a Samsara feed is behind (see samsara-feed-health).',
             'count', m.n) as item
      from missing m
     where m.n > 0
  )
  select count(*), coalesce(jsonb_agg(item order by item->>'kind'), '[]'::jsonb) into n, v_items from items;

  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('trap-size-health', clock_timestamp(), clock_timestamp(), n,
          case when n > 0 then 'attention' else 'ok' end,
          jsonb_build_object('count', n, 'items', v_items));
  return n;
end $function$;
DO $v$ BEGIN
  IF md5(pg_get_functiondef('public.log_trap_size_health()'::regprocedure)) <> '17252c6e58fd2c5109b991877857a76c' THEN RAISE EXCEPTION 'rollback: body not the original'; END IF;
END $v$;
COMMIT;
