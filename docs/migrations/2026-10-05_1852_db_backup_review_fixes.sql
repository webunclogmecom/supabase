-- ============================================================================
-- 2026-10-05_1852  db-backup review fixes: a narrow heartbeat, a read-only default, two more alerts
-- ============================================================================
-- WHY. An independent three-lens review of 2026-10-05_1820 (the 2-hour backup on Railway, Fred: "Go with
-- the 2-hour copy on Railway") found:
--  1. The role held table-wide INSERT on public.sync_log, the shared journal the health views read. As a
--     BYPASSRLS login it could have written a row for ANY check (faking another check's verdict) or a
--     future-dated success that silences its own staleness alert. Now: one SECURITY DEFINER function,
--     public.fn_db_backup_heartbeat, writes only sync_source 'db_backup', with bounded values and
--     finished_at = now(); the raw INSERT and the sequence grant are revoked.
--  2. "Read only by construction" was not quite true: like every login on Supabase it inherits PUBLIC's
--     grants on the pg_net schema (it can send HTTP and touch net.http_request_queue), which postgres
--     cannot revoke (grantor supabase_admin). Mistake-proofing only: default_transaction_read_only = on
--     for the role (pg_dump reads anyway; the heartbeat opens a read-write transaction). The real control
--     is the Railway account (two-step login) and, optionally, Supabase network restrictions.
--  3. log_db_backup_health stayed silent for ever when the setup never worked (no heartbeat at all, e.g. a
--     wrong password). Now: LOGIN switched on + no heartbeat ever = item 'db_backup_never_ran'. And a copy
--     failing on most runs but succeeding just before 13:25 UTC raised nothing: now 2+ errors in 24 hours
--     = item 'db_backup_failing'. Body copied from the LIVE definition (md5 pinned), two arms added.
-- RULE 8: no table created or altered.
-- ============================================================================

BEGIN;

DO $pin$
BEGIN
  IF md5(pg_get_functiondef('public.log_db_backup_health()'::regprocedure)) <> '00498c5106e373e28ba30e1164ee9527' THEN
    RAISE EXCEPTION 'log_db_backup_health changed since this migration was written; rebuild from the live body';
  END IF;
END
$pin$;

CREATE FUNCTION public.fn_db_backup_heartbeat(p_status text, p_kind text, p_secs numeric, p_bytes bigint,
                                              p_sha text, p_file text, p_msg text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
declare
  v_secs numeric := least(greatest(coalesce(p_secs, 0), 0), 10800);
begin
  if p_status is null or p_status not in ('success', 'error') then
    raise exception using errcode = '22023', message = 'status must be success or error';
  end if;
  if p_kind is null or p_kind not in ('two_hourly', 'daily', 'setup') or (p_kind = 'setup' and p_status = 'success') then
    raise exception using errcode = '22023', message = 'kind must be two_hourly, daily, or setup (errors only)';
  end if;
  insert into public.sync_log (sync_source, started_at, finished_at, duration_seconds, status, details, error_details)
  values ('db_backup', now() - make_interval(secs => v_secs), now(), v_secs, p_status,
          jsonb_build_object('kind', p_kind, 'bytes', greatest(coalesce(p_bytes, 0), 0),
                             'sha256', left(coalesce(p_sha, ''), 64), 'file', left(coalesce(p_file, ''), 120)),
          case when coalesce(p_msg, '') = '' then null else jsonb_build_object('message', left(p_msg, 400)) end);
end
$f$;
COMMENT ON FUNCTION public.fn_db_backup_heartbeat(text, text, numeric, bigint, text, text, text) IS
  'The only write of the db-backup service (Supabase/services/db-backup): one bounded sync_log row per run. 2026-10-05.';

REVOKE ALL ON FUNCTION public.fn_db_backup_heartbeat(text, text, numeric, bigint, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_db_backup_heartbeat(text, text, numeric, bigint, text, text, text) TO db_backup_reader;
REVOKE INSERT ON public.sync_log FROM db_backup_reader;
REVOKE USAGE ON SEQUENCE public.sync_log_id_seq FROM db_backup_reader;
ALTER ROLE db_backup_reader SET default_transaction_read_only = on;

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

  -- 2026-10-05 review: also speak when the setup never worked, and when copies fail often.
  -- LOGIN switched on is the one database-side sign that Fred finished the Railway setup.
  if not v_any and (select rolcanlogin from pg_roles where rolname = 'db_backup_reader') then
    v_items := v_items || jsonb_build_object('kind', 'db_backup_never_ran',
      'reason', 'The backup login is switched on but no database copy has ever reported in. Check the Railway service db-backup: its password, PGUSER db_backup_reader.wbasvhvvismukaqdnouk, the pooler host and the volume.');
  end if;
  if v_any and (select count(*) from public.sync_log where sync_source = 'db_backup' and status = 'error'
                  and finished_at > now() - interval '24 hours') >= 2 then
    v_items := v_items || jsonb_build_object('kind', 'db_backup_failing',
      'reason', format('%s database copies failed in the last 24 hours. Check the Railway service db-backup.',
                       (select count(*) from public.sync_log where sync_source = 'db_backup' and status = 'error'
                          and finished_at > now() - interval '24 hours')));
  end if;

  n := jsonb_array_length(v_items);
  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('db-backup-health', clock_timestamp(), clock_timestamp(), n,
          case when n > 0 then 'attention' else 'ok' end,
          jsonb_build_object('count', n, 'items', v_items, 'heartbeats_seen', v_any));
  return n;
end
$function$
;

REVOKE ALL ON FUNCTION public.log_db_backup_health() FROM PUBLIC, anon, authenticated;

DO $verify$
DECLARE v_before int; v_after int; v_cfg text[];
BEGIN
  IF has_table_privilege('db_backup_reader', 'public.sync_log', 'INSERT') THEN RAISE EXCEPTION 'VERIFY: raw INSERT on sync_log still granted'; END IF;
  IF NOT has_function_privilege('db_backup_reader', 'public.fn_db_backup_heartbeat(text,text,numeric,bigint,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: the role cannot call its heartbeat';
  END IF;
  IF has_function_privilege('anon', 'public.fn_db_backup_heartbeat(text,text,numeric,bigint,text,text,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_db_backup_heartbeat(text,text,numeric,bigint,text,text,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.log_db_backup_health()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.log_db_backup_health()', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: an app role can call a db-backup function';
  END IF;
  SELECT rolconfig INTO v_cfg FROM pg_roles WHERE rolname = 'db_backup_reader';
  IF NOT ('default_transaction_read_only=on' = ANY (coalesce(v_cfg, '{}'))) THEN RAISE EXCEPTION 'VERIFY: read-only default missing'; END IF;
  IF pg_get_functiondef('public.log_db_backup_health()'::regprocedure) NOT LIKE '%db_backup_never_ran%'
     OR pg_get_functiondef('public.log_db_backup_health()'::regprocedure) NOT LIKE '%db_backup_failing%' THEN
    RAISE EXCEPTION 'VERIFY: new health arms missing';
  END IF;

  -- The heartbeat refuses what it should
  BEGIN PERFORM public.fn_db_backup_heartbeat('weird', 'two_hourly', 1, 1, '', '', ''); RAISE EXCEPTION 'VERIFY: bad status accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN PERFORM public.fn_db_backup_heartbeat('success', 'setup', 1, 1, '', '', ''); RAISE EXCEPTION 'VERIFY: setup success accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;

  -- And writes exactly one bounded row (undone by the subtransaction)
  SELECT count(*) INTO v_before FROM public.sync_log WHERE sync_source = 'db_backup';
  BEGIN
    PERFORM public.fn_db_backup_heartbeat('success', 'two_hourly', 99999, 5, repeat('a', 100), 'f.dump', '');
    SELECT count(*) INTO v_after FROM public.sync_log WHERE sync_source = 'db_backup'
       AND duration_seconds = 10800 AND length(details->>'sha256') = 64 AND finished_at = now();
    IF v_after <> v_before + 1 THEN RAISE EXCEPTION 'VERIFY: heartbeat row wrong (% -> %)', v_before, v_after; END IF;
    RAISE EXCEPTION 'undo_probe';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'undo_probe' THEN RAISE; END IF;
  END;
  IF (SELECT count(*) FROM public.sync_log WHERE sync_source = 'db_backup') <> v_before THEN RAISE EXCEPTION 'VERIFY: probe row not undone'; END IF;

  RAISE NOTICE 'VERIFY ok';
END
$verify$;

COMMIT;
