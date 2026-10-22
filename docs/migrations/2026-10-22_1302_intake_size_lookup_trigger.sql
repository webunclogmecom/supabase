-- ============================================================================
-- 2026-10-22_1302 Grease trap model lookup, part 2: run it on submit and every hour, and watch it (Trello 6t3RDVkE)
-- ============================================================================
-- Plan step 4 of Building Apps/Picture Planner/docs/specs/2026-10-22-grease-trap-model-lookup-plan.md. Applied only
-- after the Picture Planner labels the AI's number (plan step 3), because from here on lookup rows appear.
-- WHAT CHANGES
--   1. NEW public.fn_request_size_lookup(): posts to edge fn intake-size-lookup with the vault service key, and makes NO
--      HTTP call when public.v_size_lookup_backlog is empty (the shape of fn_request_gdo_permit_label_sweep).
--   2. NEW trigger zz_size_lookup_on_submit on public.property_intakes (AFTER UPDATE OF submitted_at, per statement):
--      a submitted form with a model or measurements is looked up right away. Its errors are swallowed (a warning), so a
--      submit is never blocked; the cron picks up what it missed.
--   3. NEW cron intake-size-lookup, hourly at :17.
--   4. public.log_trap_size_health (spliced, md5-pinned): two more items for Fred's health email:
--      trap_size:lookup_failed:<kind>:<id> (a text that failed 3 times) and trap_size:lookup_waiting (texts waiting more
--      than 3 hours). 'trap-size-health' is already in ops.v_health_items and ops.v_health_status, so no view changes.
-- RULE 8: no table. ponytail: two forms submitted in the same seconds can each post, and both runs then look up the same
--   first text (a duplicate paid call, the upsert keeps the last); a lock is worth it only if submits ever come in bursts.
-- ROLLBACK: 2026-10-22_rollback_intake_size_lookup_trigger.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.log_trap_size_health()'::regprocedure)) IS DISTINCT FROM '17252c6e58fd2c5109b991877857a76c' THEN
    RAISE EXCEPTION 'log_trap_size_health changed since this file was written: splice again';
  END IF;
END $g$;
CREATE TEMP TABLE acl_before ON COMMIT DROP AS
  SELECT (SELECT proacl::text FROM pg_proc WHERE oid = 'public.log_trap_size_health()'::regprocedure) AS a;

CREATE FUNCTION pg_temp.trap_health_before()
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

CREATE FUNCTION public.fn_request_size_lookup()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text;
begin
  if not exists (select 1 from public.v_size_lookup_backlog) then
    return;   -- nothing to look up: no HTTP call
  end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping the grease trap size lookup';
    return;
  end if;
  perform net.http_post(
    url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/intake-size-lookup',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body := jsonb_build_object('limit', 3),
    timeout_milliseconds := 150000);
end $function$;
REVOKE ALL ON FUNCTION public.fn_request_size_lookup() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_request_size_lookup() TO service_role;

CREATE FUNCTION public.trg_size_lookup_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public.fn_request_size_lookup();
  return null;
exception when others then
  raise warning 'grease trap size lookup request failed (% %); the hourly cron will retry', sqlstate, sqlerrm;
  return null;
end $function$;
REVOKE ALL ON FUNCTION public.trg_size_lookup_request() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER zz_size_lookup_on_submit AFTER UPDATE OF submitted_at ON public.property_intakes
  FOR EACH STATEMENT EXECUTE FUNCTION public.trg_size_lookup_request();

SELECT cron.schedule('intake-size-lookup', '17 * * * *', 'select public.fn_request_size_lookup()');

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
    union all
    -- 2026-10-22 (Trello 6t3RDVkE): the AI lookup of a grease trap's gallons (public.grease_trap_size_lookups, edge fn
    -- intake-size-lookup). A text that failed 3 times is never tried again on its own; texts waiting over 3 hours mean
    -- the trigger and the hourly cron are not reaching the function.
    select jsonb_build_object(
             'kind', 'trap_size:lookup_failed:' || g.kind || ':' || g.id,
             'issue', 'size_lookup_failed',
             'reason', format('The AI lookup of the grease trap %s "%s" failed 3 times. Last error: %s',
                              case g.kind when 'model' then 'model' else 'measurements' end, g.input_text,
                              coalesce(left(g.last_error, 300), 'none recorded')),
             'what_to_do', 'Read the error. If the Anthropic credit ran out or the key changed, fix that, then set attempts to 0 on that row of public.grease_trap_size_lookups: it is tried again within the hour. Otherwise the office types the gallons on the property by hand.',
             'lookup_id', g.id) as item
      from public.grease_trap_size_lookups g
     where g.status = 'error' and g.attempts >= 3
    union all
    select jsonb_build_object(
             'kind', 'trap_size:lookup_waiting',
             'issue', 'size_lookup_waiting',
             'reason', format('%s grease trap model or measurement text(s) from site survey forms submitted more than 3 hours ago are still waiting for the AI lookup.', w.n),
             'what_to_do', 'Check cron intake-size-lookup, run select public.fn_request_size_lookup(); and read the logs of edge fn intake-size-lookup.',
             'count', w.n) as item
      from (select count(*) as n
              from public.v_size_lookup_backlog b
              join public.property_intakes i on i.id = b.intake_id
             where i.submitted_at < now() - interval '3 hours') w
     where w.n > 0
  )
  select count(*), coalesce(jsonb_agg(item order by item->>'kind'), '[]'::jsonb) into n, v_items from items;

  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('trap-size-health', clock_timestamp(), clock_timestamp(), n,
          case when n > 0 then 'attention' else 'ok' end,
          jsonb_build_object('count', n, 'items', v_items));
  return n;
end $function$;

DO $v$
DECLARE v_new jsonb; v_old jsonb; l bigint;
BEGIN
  IF (SELECT a FROM acl_before) IS DISTINCT FROM (SELECT proacl::text FROM pg_proc WHERE oid = 'public.log_trap_size_health()'::regprocedure) THEN
    RAISE EXCEPTION 'V1: log_trap_size_health ACL changed';
  END IF;
  IF has_function_privilege('authenticated', 'public.fn_request_size_lookup()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.fn_request_size_lookup()', 'EXECUTE')
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'zz_size_lookup_on_submit' AND tgrelid = 'public.property_intakes'::regclass AND tgenabled = 'O')
     OR (SELECT count(*) FROM cron.job WHERE jobname = 'intake-size-lookup' AND schedule = '17 * * * *' AND active) <> 1 THEN
    RAISE EXCEPTION 'V1: grants, trigger or cron wrong';
  END IF;
  -- V2 the health items: the old ones exactly as before, plus the two new kinds; rolled back by the sentinel
  BEGIN
    INSERT INTO public.grease_trap_size_lookups (kind, input_text, input_key, status, attempts, looked_up_at, last_error)
    VALUES ('model', '[TEST] health check', public.fn_size_lookup_key('[TEST] health check'), 'error', 3, now(), 'anthropic 400: test')
    RETURNING id INTO l;
    PERFORM public.log_trap_size_health();
    SELECT details -> 'items' INTO v_new FROM public.sync_log WHERE sync_source = 'trap-size-health' ORDER BY id DESC LIMIT 1;
    PERFORM pg_temp.trap_health_before();
    SELECT details -> 'items' INTO v_old FROM public.sync_log WHERE sync_source = 'trap-size-health' ORDER BY id DESC LIMIT 1;
    IF (SELECT coalesce(jsonb_agg(x ORDER BY x ->> 'kind'), '[]') FROM jsonb_array_elements(v_new) x WHERE x ->> 'issue' NOT IN ('size_lookup_failed', 'size_lookup_waiting'))
       IS DISTINCT FROM (SELECT coalesce(jsonb_agg(x ORDER BY x ->> 'kind'), '[]') FROM jsonb_array_elements(v_old) x) THEN
      RAISE EXCEPTION 'V2: the existing health items moved';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_new) x WHERE x ->> 'kind' = 'trap_size:lookup_failed:model:' || l
                     AND x ->> 'reason' LIKE '%"[TEST] health check" failed 3 times. Last error: anthropic 400: test') THEN
      RAISE EXCEPTION 'V2: no failed item %', v_new;
    END IF;
    -- form 1047 (submitted 2026-09-30) is waiting: the waiting item counts it
    IF EXISTS (SELECT 1 FROM public.v_size_lookup_backlog WHERE intake_id = 1047)
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_new) x WHERE x ->> 'kind' = 'trap_size:lookup_waiting' AND (x ->> 'count')::int >= 1) THEN
      RAISE EXCEPTION 'V2: no waiting item %', v_new;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = 'sentinel';
  EXCEPTION WHEN sqlstate 'P0099' THEN NULL;
  END;
  IF EXISTS (SELECT 1 FROM public.grease_trap_size_lookups WHERE input_text = '[TEST] health check') THEN RAISE EXCEPTION 'V2: fixture left behind'; END IF;
END $v$;

COMMIT;
