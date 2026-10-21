-- ============================================================================
-- 2026-10-21_0530 The trap size list joins the daily health email (trap-size-health)
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-21: "go ahead with step 3, the trap size list" (Grease pumped plan step 3,
--   Building Apps/Visit Calendar/docs/specs/2026-10-21-grease-pumped-data-audit-and-plan.md, sections 4.3 to 4.5).
--   Since 2026-10-21_0545 ("sensor wins") a Moises reading above the trap size on file counts and is flagged
--   (public.v_visit_tank_service.sludge_above_trap_size). This check turns those flags into a list a person acts on,
--   so a wrong size is corrected at the source instead of living on in every David and Cloggy estimate (root
--   CLAUDE.md section 7: the reason must reach a person on its own).
-- WHAT IT DOES
--   public.log_trap_size_health() writes one sync_log row ('trap-size-health', ok | attention) whose items are:
--     1. one item per property with at least one TRUSTED (high/medium) Moises reading in the last 90 days that is
--        above 1.5 x its trap size on file + 40 gal. Moises keeps only the grease (the water goes back), so the
--        real trap is at least the reading: the size on file is too small. Readings that are only low confidence
--        (082-TFC, 091-SB, 092-TCE on 2026-10-21) are left out on purpose: the audit found them to be sensor noise
--        or conflicting. The item disappears by itself once the size is corrected (the flag compares with the
--        current size), in Jobber or the Client App (two-way custom field sync).
--     2. visits dated 2026-01-01 to 3 days ago with no stored Grease pumped row (ops.visit_grease_frozen): the
--        freezer's own coverage, the watch the 2026-10-14 plan promised and never built. 0 today.
--   Items carry 'reason' and 'what_to_do' (rendered by health-escalate) and a unique 'kind' (the item key); no
--   'visit_id' field, so two problems on one visit never collapse into one item.
--   Cron 'trap-size-health' 13:23 UTC, before health-escalation at 13:30 (it reads only the latest run).
--   ops.v_health_items and ops.v_health_status get one source entry + one CASE arm each, spliced from the live
--   text with md5 pins (CREATE OR REPLACE keeps their grants).
-- RULE 8: no new table. GRANTS: the function is postgres only (revoked by name from PUBLIC, anon, authenticated,
--   service_role), like log_hr_bonus_health.
-- ROLLBACK: 2026-10-21_rollback_trap_size_health.sql.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE FUNCTION public.log_trap_size_health() RETURNS integer
LANGUAGE plpgsql SET search_path = '' AS $f$
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
end $f$;

REVOKE ALL ON FUNCTION public.log_trap_size_health() FROM PUBLIC, anon, authenticated, service_role;

-- The two health views: splice from the live text, pinned.
DO $s$
DECLARE v text; c int;
BEGIN
  v := pg_get_viewdef('ops.v_health_items'::regclass);
  IF md5(v) <> '247db2120c5ef853354c05ca56e29cdb' THEN RAISE EXCEPTION 'v_health_items changed since it was read'; END IF;
  c := (length(v) - length(replace(v, '''hr-bonus-health''::text]))', ''))) / length('''hr-bonus-health''::text]))');
  IF c <> 1 THEN RAISE EXCEPTION 'items list anchor found % times', c; END IF;
  v := replace(v, '''hr-bonus-health''::text]))', '''hr-bonus-health''::text, ''trap-size-health''::text]))');
  c := (length(v) - length(replace(v, 'WHEN ''hr-bonus-health''::text THEN COALESCE((la.details -> ''items''::text), ''[]''::jsonb)', '')))
       / length('WHEN ''hr-bonus-health''::text THEN COALESCE((la.details -> ''items''::text), ''[]''::jsonb)');
  IF c <> 1 THEN RAISE EXCEPTION 'items CASE anchor found % times', c; END IF;
  v := replace(v, 'WHEN ''hr-bonus-health''::text THEN COALESCE((la.details -> ''items''::text), ''[]''::jsonb)',
               'WHEN ''hr-bonus-health''::text THEN COALESCE((la.details -> ''items''::text), ''[]''::jsonb)'
               || ' WHEN ''trap-size-health''::text THEN COALESCE((la.details -> ''items''::text), ''[]''::jsonb)');
  EXECUTE 'CREATE OR REPLACE VIEW ops.v_health_items AS ' || v;

  v := pg_get_viewdef('ops.v_health_status'::regclass);
  IF md5(v) <> 'db60c71e61629dd662cd6bf2b51623b0' THEN RAISE EXCEPTION 'v_health_status changed since it was read'; END IF;
  c := (length(v) - length(replace(v, '''hr-bonus-health''::text]))', ''))) / length('''hr-bonus-health''::text]))');
  IF c <> 2 THEN RAISE EXCEPTION 'status list anchor found % times', c; END IF;
  v := replace(v, '''hr-bonus-health''::text]))', '''hr-bonus-health''::text, ''trap-size-health''::text]))');
  c := (length(v) - length(replace(v, 'WHEN ''hr-bonus-health''::text THEN COALESCE((l.details -> ''items''::text), ''[]''::jsonb)', '')))
       / length('WHEN ''hr-bonus-health''::text THEN COALESCE((l.details -> ''items''::text), ''[]''::jsonb)');
  IF c <> 1 THEN RAISE EXCEPTION 'status CASE anchor found % times', c; END IF;
  v := replace(v, 'WHEN ''hr-bonus-health''::text THEN COALESCE((l.details -> ''items''::text), ''[]''::jsonb)',
               'WHEN ''hr-bonus-health''::text THEN COALESCE((l.details -> ''items''::text), ''[]''::jsonb)'
               || ' WHEN ''trap-size-health''::text THEN COALESCE((l.details -> ''items''::text), ''[]''::jsonb)');
  EXECUTE 'CREATE OR REPLACE VIEW ops.v_health_status AS ' || v;
END $s$;

SELECT cron.schedule('trap-size-health', '23 13 * * *', 'select public.log_trap_size_health()');

-- VERIFY
DO $v$
DECLARE n int; v_status text;
BEGIN
  IF has_function_privilege('anon', 'public.log_trap_size_health()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.log_trap_size_health()', 'EXECUTE')
     OR has_function_privilege('service_role', 'public.log_trap_size_health()', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: log_trap_size_health is executable by an API role';
  END IF;
  IF (SELECT string_agg(relname || ' ' || array_to_string(relacl, ','), ' | ' ORDER BY relname) FROM pg_class
       WHERE oid IN ('ops.v_health_items'::regclass, 'ops.v_health_status'::regclass))
     <> 'v_health_items postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,yannick_readonly=r/postgres,db_backup_reader=r/postgres | v_health_status postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,yannick_readonly=r/postgres,db_backup_reader=r/postgres' THEN
    RAISE EXCEPTION 'VERIFY: health view grants changed';
  END IF;
  n := public.log_trap_size_health();
  SELECT status INTO v_status FROM ops.v_health_status WHERE check_name = 'trap-size-health';
  IF v_status IS NULL THEN RAISE EXCEPTION 'VERIFY: trap-size-health missing from v_health_status'; END IF;
  IF (SELECT count(*) FROM ops.v_health_items WHERE check_name = 'trap-size-health') <> n THEN
    RAISE EXCEPTION 'VERIFY: v_health_items does not carry the % item(s)', n;
  END IF;
  -- positive control: 022-GRO (250 on file, 1,231 measured) must be listed; negative: 091-SB (low only) must not
  IF NOT EXISTS (SELECT 1 FROM ops.v_health_items WHERE check_name = 'trap-size-health' AND item->>'kind' = 'trap_size:too_small:p4') THEN
    RAISE EXCEPTION 'VERIFY: 022-GRO (property 4) is not listed';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.v_health_items WHERE check_name = 'trap-size-health' AND item->>'kind' = 'trap_size:too_small:p86') THEN
    RAISE EXCEPTION 'VERIFY: 091-SB (low-confidence only) is listed';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.v_health_items WHERE check_name = 'trap-size-health' AND item->>'issue' = 'grease_freeze_missing') THEN
    RAISE EXCEPTION 'VERIFY: frozen rows missing at install (expected 0)';
  END IF;
  IF (SELECT count(DISTINCT check_name) FROM ops.v_health_status) < 13 THEN RAISE EXCEPTION 'VERIFY: a check vanished from v_health_status'; END IF;
  RAISE NOTICE 'VERIFY passed: % item(s), status %', n, v_status;
END $v$;
COMMIT;
