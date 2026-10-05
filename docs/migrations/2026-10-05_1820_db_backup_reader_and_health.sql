-- ============================================================================
-- 2026-10-05_1820  db_backup_reader role + the db-backup-health check
-- ============================================================================
-- WHY. Fred, 2026-10-05: "Go with the 2-hour copy on Railway." PITR is OFF on Prod (one daily backup,
-- about a week kept), so a bad day can lose up to 24 hours. Instead of PITR (about $100 a month) we keep
-- our own copy every 2 hours on Railway: service Supabase/services/db-backup/ (README there). This
-- migration gives that service a least-privilege login and makes a stopped backup visible.
--
-- 1. ROLE public.db_backup_reader: NOLOGIN on purpose. Fred turns it on himself, with a password that
--    lives only in his password manager and the Railway variable, never in a file:
--      ALTER ROLE db_backup_reader LOGIN PASSWORD '<from the password manager>';
--    BYPASSRLS because pg_dump refuses tables with RLS otherwise (83 business tables have RLS).
--    READ ONLY by construction: SELECT on tables and sequences of the business schemas (public, derm,
--    ops, client, sync, raw, audit, customer, hr), plus default privileges for future postgres-owned
--    tables there. One write: INSERT on public.sync_log, for its own heartbeat row (sync_source
--    'db_backup').
--    NOT pg_read_all_data: measured, that role can SELECT vault.decrypted_secrets, so a leaked backup
--    password would leak every service key. NOT public.webhook_tokens (Jobber/Samsara OAuth tokens and
--    the client secret): revoked here and left out of every copy; after a restore, re-connect Jobber.
--    A NEW table that holds a secret must be revoked from this role and excluded in backup.sh too.
--
-- 2. HEALTH: public.log_db_backup_health() writes a verdict row ('db-backup-health') with items when
--    the last good 2-hour copy is older than 5 hours, the last good daily copy older than 30 hours, or
--    the last run failed. Registered in BOTH ops.v_health_items and ops.v_health_status (root and
--    Supabase CLAUDE.md: a check missing from either is half-wired). Silent until the first heartbeat
--    ever arrives, on purpose: setup on Railway is a known pending step, not a failure.
--    Cron 'db-backup-health' at 13:25 UTC, 5 minutes before 'health-escalation' reads the views.
--    The two views are rebuilt from their LIVE text with exactly one CASE arm and one list entry
--    added; the md5 of each live definition is pinned and checked first.
--
-- RULE 8 (audit trail): no table is created or altered; not applicable.
-- ============================================================================

BEGIN;

-- Pin: refuse if either view changed since this file was written (2026-10-05 ~18:25 ET).
DO $pin$
BEGIN
  IF md5(pg_get_viewdef('ops.v_health_items'::regclass, true)) <> '9b649d0602d881504db3284ac55b3b69' THEN
    RAISE EXCEPTION 'ops.v_health_items changed since this migration was written; rebuild it from the live text';
  END IF;
  IF md5(pg_get_viewdef('ops.v_health_status'::regclass, true)) <> '3c40b085b47a7e22e9542794793b51b8' THEN
    RAISE EXCEPTION 'ops.v_health_status changed since this migration was written; rebuild it from the live text';
  END IF;
END
$pin$;

-- 1. The role --------------------------------------------------------------
CREATE ROLE db_backup_reader NOLOGIN NOINHERIT BYPASSRLS CONNECTION LIMIT 2;
COMMENT ON ROLE db_backup_reader IS 'Read-only login for the 2-hourly pg_dump on Railway (Supabase/services/db-backup). NOLOGIN until Fred sets a password. 2026-10-05.';

DO $grants$
DECLARE s text;
BEGIN
  FOREACH s IN ARRAY ARRAY['public','derm','ops','client','sync','raw','audit','customer','hr'] LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO db_backup_reader', s);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO db_backup_reader', s);
    EXECUTE format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA %I TO db_backup_reader', s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT SELECT ON TABLES TO db_backup_reader', s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT SELECT ON SEQUENCES TO db_backup_reader', s);
  END LOOP;
END
$grants$;

REVOKE ALL ON public.webhook_tokens FROM db_backup_reader;
GRANT INSERT ON public.sync_log TO db_backup_reader;
GRANT USAGE ON SEQUENCE public.sync_log_id_seq TO db_backup_reader;

-- 2. The health check ------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_db_backup_health()
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  n            integer;
  v_items      jsonb := '[]'::jsonb;
  v_any        boolean;
  v_last_ok    timestamptz;
  v_last_daily timestamptz;
  v_last       record;
  et           text := 'America/New_York';
begin
  select exists (select 1 from public.sync_log where sync_source = 'db_backup') into v_any;
  if v_any then
    select max(finished_at) into v_last_ok
      from public.sync_log where sync_source = 'db_backup' and status = 'success';
    select max(finished_at) into v_last_daily
      from public.sync_log where sync_source = 'db_backup' and status = 'success' and details->>'kind' = 'daily';
    select status, finished_at, error_details into v_last
      from public.sync_log where sync_source = 'db_backup' order by started_at desc limit 1;

    if v_last_ok is null or v_last_ok < now() - interval '5 hours' then
      v_items := v_items || jsonb_build_object('kind', 'db_backup_stale',
        'reason', format('No successful 2-hour database copy since %s ET. Check the Railway service db-backup.',
                         coalesce(to_char(v_last_ok at time zone et, 'Mon FMDD FMHH12:MI AM'), 'it was set up')));
    end if;
    if v_last_daily is null or v_last_daily < now() - interval '30 hours' then
      v_items := v_items || jsonb_build_object('kind', 'db_backup_daily_stale',
        'reason', format('No successful full daily database copy since %s ET. Check the Railway service db-backup.',
                         coalesce(to_char(v_last_daily at time zone et, 'Mon FMDD FMHH12:MI AM'), 'it was set up')));
    end if;
    if v_last.status = 'error' then
      v_items := v_items || jsonb_build_object('kind', 'db_backup_failed',
        'reason', format('The last database copy failed (%s ET): %s',
                         to_char(v_last.finished_at at time zone et, 'Mon FMDD FMHH12:MI AM'),
                         left(coalesce(v_last.error_details->>'message', 'no message'), 200)));
    end if;
  end if;

  n := jsonb_array_length(v_items);
  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('db-backup-health', clock_timestamp(), clock_timestamp(), n,
          case when n > 0 then 'attention' else 'ok' end,
          jsonb_build_object('count', n, 'items', v_items, 'heartbeats_seen', v_any));
  return n;
end
$function$;

REVOKE ALL ON FUNCTION public.log_db_backup_health() FROM PUBLIC, anon, authenticated;

SELECT cron.schedule('db-backup-health', '25 13 * * *', 'select public.log_db_backup_health()');

-- 3. Register the check in both health views (live text + one arm + one list entry) ------------
CREATE OR REPLACE VIEW ops.v_health_items AS
WITH latest AS (
         SELECT DISTINCT ON (l.sync_source) l.sync_source,
            l.status,
            l.started_at,
            l.details
           FROM sync_log l
          WHERE l.sync_source = ANY (ARRAY['calendar-push-health'::text, 'blackout-health'::text, 'rpa-derm-health'::text, 'sa-schedule-gap-check'::text, 'jobber-sync-health'::text, 'note-photo-sync-health'::text, 'jobber-client-state-sweep'::text, 'start-flags-health'::text, 'db-backup-health'::text])
          ORDER BY l.sync_source, l.started_at DESC
        )
 SELECT la.sync_source AS check_name,
    la.status,
    la.started_at AS last_run_at,
    COALESCE(i.value ->> 'visit_id'::text, i.value ->> 'dump_folder'::text, i.value ->> 'kind'::text, i.value ->> 'client_code'::text, i.value::text) AS item_key,
    i.value AS item
   FROM latest la
     CROSS JOIN LATERAL jsonb_array_elements(
        CASE la.sync_source
            WHEN 'calendar-push-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'blackout-health'::text THEN COALESCE(la.details -> 'sheets'::text, '[]'::jsonb)
            WHEN 'rpa-derm-health'::text THEN COALESCE(la.details -> 'reasons'::text, '[]'::jsonb)
            WHEN 'sa-schedule-gap-check'::text THEN COALESCE(la.details -> 'sample'::text, '[]'::jsonb)
            WHEN 'jobber-sync-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'note-photo-sync-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'jobber-client-state-sweep'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'start-flags-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'db-backup-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            ELSE '[]'::jsonb
        END) i(value);

CREATE OR REPLACE VIEW ops.v_health_status AS
WITH runs AS (
         SELECT l.id,
            l.sync_source,
            l.status,
            l.started_at,
            l.rows_errored,
            l.details,
            row_number() OVER (PARTITION BY l.sync_source ORDER BY l.started_at DESC) AS rn,
                CASE l.sync_source
                    WHEN 'calendar-push-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'blackout-health'::text THEN COALESCE(l.details -> 'sheets'::text, '[]'::jsonb)
                    WHEN 'rpa-derm-health'::text THEN COALESCE(l.details -> 'reasons'::text, '[]'::jsonb)
                    WHEN 'sa-schedule-gap-check'::text THEN COALESCE(l.details -> 'sample'::text, '[]'::jsonb)
                    WHEN 'jobber-sync-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'jobber-client-state-sweep'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'start-flags-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'note-photo-sync-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'db-backup-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    ELSE '[]'::jsonb
                END AS raw_items
           FROM sync_log l
          WHERE l.sync_source = ANY (ARRAY['calendar-push-health'::text, 'blackout-health'::text, 'rpa-derm-health'::text, 'sa-schedule-gap-check'::text, 'jobber-sync-health'::text, 'jobber-client-state-sweep'::text, 'start-flags-health'::text, 'note-photo-sync-health'::text, 'db-backup-health'::text])
        ), keyed AS (
         SELECT r.id,
            r.sync_source,
            r.status,
            r.started_at,
            r.rows_errored,
            r.details,
            r.rn,
            r.raw_items,
            COALESCE(( SELECT jsonb_agg(DISTINCT COALESCE(i.value ->> 'visit_id'::text, i.value ->> 'dump_folder'::text, i.value ->> 'kind'::text, i.value ->> 'client_code'::text, i.value::text)) AS jsonb_agg
                   FROM jsonb_array_elements(r.raw_items) i(value)), '[]'::jsonb) AS item_keys
           FROM runs r
          WHERE r.rn <= 2
        ), streak AS (
         SELECT g.sync_source,
            g.status,
            count(*) AS runs_in_streak,
            min(g.started_at) AS streak_started_at
           FROM ( SELECT l.sync_source,
                    l.status,
                    l.started_at,
                    row_number() OVER (PARTITION BY l.sync_source ORDER BY l.started_at DESC) - row_number() OVER (PARTITION BY l.sync_source, l.status ORDER BY l.started_at DESC) AS grp
                   FROM sync_log l
                  WHERE l.sync_source = ANY (ARRAY['calendar-push-health'::text, 'blackout-health'::text, 'rpa-derm-health'::text, 'sa-schedule-gap-check'::text, 'jobber-sync-health'::text, 'jobber-client-state-sweep'::text, 'start-flags-health'::text, 'note-photo-sync-health'::text, 'db-backup-health'::text])) g
          GROUP BY g.sync_source, g.status, g.grp
         HAVING max(g.started_at) = (( SELECT max(l2.started_at) AS max
                   FROM sync_log l2
                  WHERE l2.sync_source = g.sync_source))
        ), cur AS (
         SELECT keyed.id,
            keyed.sync_source,
            keyed.status,
            keyed.started_at,
            keyed.rows_errored,
            keyed.details,
            keyed.rn,
            keyed.raw_items,
            keyed.item_keys
           FROM keyed
          WHERE keyed.rn = 1
        ), prev AS (
         SELECT keyed.id,
            keyed.sync_source,
            keyed.status,
            keyed.started_at,
            keyed.rows_errored,
            keyed.details,
            keyed.rn,
            keyed.raw_items,
            keyed.item_keys
           FROM keyed
          WHERE keyed.rn = 2
        )
 SELECT c.sync_source AS check_name,
    c.status,
    c.started_at AS last_run_at,
    jsonb_array_length(c.item_keys) AS item_count,
    COALESCE(jsonb_array_length(p.item_keys), 0) AS item_count_previous_run,
    c.rows_errored AS rows_errored_raw,
    ( SELECT COALESCE(jsonb_agg(k.value), '[]'::jsonb) AS "coalesce"
           FROM jsonb_array_elements(c.item_keys) k(value)
          WHERE NOT COALESCE(p.item_keys, '[]'::jsonb) @> jsonb_build_array(k.value)) AS new_items,
    ( SELECT COALESCE(jsonb_agg(k.value), '[]'::jsonb) AS "coalesce"
           FROM jsonb_array_elements(COALESCE(p.item_keys, '[]'::jsonb)) k(value)
          WHERE NOT c.item_keys @> jsonb_build_array(k.value)) AS resolved_items,
    c.item_keys = COALESCE(p.item_keys, '[]'::jsonb) AS unchanged_since_last_run,
    s.runs_in_streak AS consecutive_runs_same_status,
    s.streak_started_at AS status_since,
    c.details
   FROM cur c
     LEFT JOIN prev p ON p.sync_source = c.sync_source
     LEFT JOIN streak s ON s.sync_source = c.sync_source AND s.status = c.status;

-- 4. VERIFY ---------------------------------------------------------------
DO $verify$
DECLARE r record; v_bad int; v_acl_items text; v_acl_status text; v_n int;
BEGIN
  SELECT rolcanlogin, rolbypassrls, rolinherit INTO r FROM pg_roles WHERE rolname = 'db_backup_reader';
  IF r IS NULL THEN RAISE EXCEPTION 'VERIFY: role missing'; END IF;
  IF r.rolcanlogin THEN RAISE EXCEPTION 'VERIFY: role must be NOLOGIN until Fred sets a password'; END IF;
  IF NOT r.rolbypassrls THEN RAISE EXCEPTION 'VERIFY: role needs BYPASSRLS for pg_dump'; END IF;
  IF pg_has_role('db_backup_reader', 'pg_read_all_data', 'MEMBER') THEN RAISE EXCEPTION 'VERIFY: must not be in pg_read_all_data'; END IF;

  -- Positive control and the deliberate gaps
  IF NOT has_table_privilege('db_backup_reader', 'public.visits', 'SELECT') THEN RAISE EXCEPTION 'VERIFY: control failed, no SELECT on public.visits'; END IF;
  IF has_table_privilege('db_backup_reader', 'public.webhook_tokens', 'SELECT') THEN RAISE EXCEPTION 'VERIFY: webhook_tokens must not be readable'; END IF;
  IF has_table_privilege('db_backup_reader', 'vault.decrypted_secrets', 'SELECT') THEN RAISE EXCEPTION 'VERIFY: vault must not be readable'; END IF;
  IF NOT has_table_privilege('db_backup_reader', 'public.sync_log', 'INSERT') THEN RAISE EXCEPTION 'VERIFY: heartbeat INSERT missing'; END IF;
  IF has_table_privilege('db_backup_reader', 'public.visits', 'INSERT') OR has_table_privilege('db_backup_reader', 'public.visits', 'UPDATE')
     OR has_table_privilege('db_backup_reader', 'public.visits', 'DELETE') OR has_table_privilege('db_backup_reader', 'public.sync_log', 'UPDATE') THEN
    RAISE EXCEPTION 'VERIFY: role can write beyond its heartbeat';
  END IF;

  -- Every table, matview and sequence of the 9 schemas is readable, except exactly webhook_tokens
  SELECT count(*) INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname IN ('public','derm','ops','client','sync','raw','audit','customer','hr')
     AND c.relkind IN ('r','p','m','S','v')
     AND NOT has_table_privilege('db_backup_reader', c.oid, 'SELECT');
  IF v_bad <> 1 THEN RAISE EXCEPTION 'VERIFY: expected exactly 1 unreadable relation (webhook_tokens), got %', v_bad; END IF;

  -- The function is not callable from the apps
  IF has_function_privilege('anon', 'public.log_db_backup_health()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.log_db_backup_health()', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: log_db_backup_health callable by anon or authenticated';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'db-backup-health' AND schedule = '25 13 * * *') THEN
    RAISE EXCEPTION 'VERIFY: cron job missing';
  END IF;

  -- Both views know the check, and their grants did not move
  IF pg_get_viewdef('ops.v_health_items'::regclass, true) NOT LIKE '%''db-backup-health''::text THEN%' THEN RAISE EXCEPTION 'VERIFY: v_health_items arm missing'; END IF;
  IF pg_get_viewdef('ops.v_health_status'::regclass, true) NOT LIKE '%''db-backup-health''::text THEN%' THEN RAISE EXCEPTION 'VERIFY: v_health_status arm missing'; END IF;
  SELECT relacl::text INTO v_acl_items FROM pg_class WHERE oid = 'ops.v_health_items'::regclass;
  SELECT relacl::text INTO v_acl_status FROM pg_class WHERE oid = 'ops.v_health_status'::regclass;
  -- Expected: the old grants plus exactly db_backup_reader=r (step 1 grants SELECT on all of ops).
  IF v_acl_items NOT LIKE '%db_backup_reader=r/postgres%' OR v_acl_status NOT LIKE '%db_backup_reader=r/postgres%'
     OR replace(v_acl_items, ',db_backup_reader=r/postgres', '') <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,yannick_readonly=r/postgres}'
     OR replace(v_acl_status, ',db_backup_reader=r/postgres', '') <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,yannick_readonly=r/postgres}' THEN
    RAISE EXCEPTION 'VERIFY: a health view''s grants changed beyond db_backup_reader=r (items %, status %)', v_acl_items, v_acl_status;
  END IF;

  -- First run: no heartbeat yet, so the check must say ok and report nothing
  v_n := public.log_db_backup_health();
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY: expected 0 items before any heartbeat, got %', v_n; END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.v_health_status WHERE check_name = 'db-backup-health' AND status = 'ok') THEN
    RAISE EXCEPTION 'VERIFY: db-backup-health not visible in ops.v_health_status';
  END IF;

  RAISE NOTICE 'VERIFY ok';
END
$verify$;

COMMIT;
