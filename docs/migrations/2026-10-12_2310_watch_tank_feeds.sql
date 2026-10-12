-- 2026-10-12 23:10 ET · Watch the stop-facts sources and observe the tank business flags in the daily health check (M7)
-- APPLIED to Prod 2026-10-12 ~19:15 ET after a rolled-back run of this file.
-- Plan: docs/superpowers/specs/2026-10-12-samsara-tank-sensors-db-plan.md (sections 8 and 10.2 M7).
--
-- WHAT (one function, public.log_jobber_sync_health(), spliced from its LIVE text, md5-pinned; nothing retyped)
--   1. Four sources join its watched list, each with a 2-hour staleness window (the refresh runs hourly at :35,
--      cron 'vehicle-stop-facts' of 2026-10-12_2250, so 2 hours = one missed run):
--        stop_facts_refresh    the derivation ran; error only when a step raised
--        tank_feed_freshness   feed checks T1 to T5; error when any fires
--        stop_facts_integrity  must-be-zero checks Z1 to Z4, Z7 to Z9 (and the Z8 control); error when any fires
--        tank_geometry_drift   Z6 alone, because it can stay open for days waiting on an owner decision
--      Separate sources give separate item kinds (sync_failed:<source>, sync_stalled:<source>, sync_stuck:<source>),
--      so a long-open data finding cannot hide a later process failure (plan V37). All four write 'success' or
--      'error' only, which the existing arms already read correctly ('success' is a clean word; 'error' counts as
--      failed). railway_samsara_readings is already watched (2026-10-12_2120).
--   2. A COUNT-ONLY observation of the tank business flags F1, F1b and F3, copied from the billing-observation
--      precedent in the same function: details.tank_flags_observation (CURRENT | STALE | NO_EVIDENCE) and
--      details.tank_flags ({F1, F1b, F3}), read from the newest successful stop_facts_refresh row. NOT in items and
--      NOT in the total, so it cannot alert, change this check's status or mail anyone. The verdict is read first
--      so a missing or old refresh reads NO_EVIDENCE / STALE, never a comforting zero.
--
-- WHY
--   Plan section 8: process failures and data findings go to separate sources so one long-open data issue cannot hide
--   a feed failure; and "record gaps reach a person before D6": F1 (a Pumping visit with no stop), F1b (a Dump Offload
--   record with no dump stop) and F3 (a dump with no Dump Offload record). Owner, 2026-10-12: "Before showing it on
--   an app, let's work on it to be correct everything in the DB".
--
-- KNOWN BEHAVIOUR, kept on purpose: the failed arm needs 2 or more failed runs in 24 hours (and 2 % of runs), so the
--   FIRST error row on an hourly source opens no item; the second hour does. The stuck arm fires after 72 hours of
--   continuous 'error'. The item's reason text says the runs "did not reconcile anything", which is wrong for a data
--   finding; details carries the real cause (plan section 8, known wart). The 'covers' sentence of this function
--   still says "seven Jobber sync surfaces" (stale before this change; not touched here).
--
-- 3NF / RULE 8: no table created or changed.
-- GRANTS: CREATE OR REPLACE keeps the ACL ({postgres=X, service_role=X}). EXECUTE revoked BY NAME from public, anon,
--   authenticated and asserted with has_function_privilege below.
-- LOCKS: SET LOCAL lock_timeout = '3s'. CREATE OR REPLACE FUNCTION takes no lock on app tables.
-- VERIFY (below): every anchor found exactly once; the new body names the four sources and the observation keys;
--   anon/authenticated cannot EXECUTE; one run writes a jobber-sync-health row carrying tank_flags_observation.
--   Behaviour (a fake old row reads stalled and a fresh one does not; two error rows on tank_geometry_drift open
--   sync_failed:tank_geometry_drift while stop_facts_integrity stays clean; NO_EVIDENCE without a refresh row) was
--   proven by a rolled-back probe before apply.
-- ROLLBACK: splice the five additions back out of the live body (they are delimited by the "M7" comments), or
--   re-apply the previous body from audit (pg_get_functiondef before apply, md5 f13ce28dfec3e401d029285d320c02e7).

begin;
set local lock_timeout = '3s';

do $mig$
declare
  v_def text := pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure);
  v_a1 text := E'      (''railway_samsara_readings'',      interval ''30 minutes'')\n  ),';
  v_b1 text := E'      (''railway_samsara_readings'',      interval ''30 minutes''),\n'
            || E'      -- M7 (2026-10-12): the hourly stop-facts refresh (cron vehicle-stop-facts, :35) writes four sources;\n'
            || E'      -- 2 hours = one missed run. Process failure and data findings are separate sources on purpose.\n'
            || E'      (''stop_facts_refresh'',            interval ''2 hours''),\n'
            || E'      (''tank_feed_freshness'',           interval ''2 hours''),\n'
            || E'      (''stop_facts_integrity'',          interval ''2 hours''),\n'
            || E'      (''tank_geometry_drift'',           interval ''2 hours'')\n  ),';
  v_a2 text := E'  v_link_shown     int := 0;\n';
  v_b2 text := E'  v_link_shown     int := 0;\n'
            || E'  v_tank_verdict   text;      -- M7\n'
            || E'  v_tank_flags     jsonb;     -- M7\n';
  v_a3 text := E'  v_total := v_conflict + v_stuck';
  v_b3 text := E'  -- M7 (2026-10-12): TANK SENSOR BUSINESS FLAGS, COUNT-ONLY like the billing observation above. Not in\n'
            || E'  --    v_items, not in v_total: it cannot alert or mail anyone. The verdict is read FIRST, so a refresh\n'
            || E'  --    that never ran reads NO_EVIDENCE and an old one STALE, never a comforting zero.\n'
            || E'  select case when max(l.started_at) is null then ''NO_EVIDENCE''\n'
            || E'              when max(l.started_at) < now() - interval ''2 hours'' then ''STALE'' else ''CURRENT'' end\n'
            || E'    into v_tank_verdict\n'
            || E'    from public.sync_log l where l.sync_source = ''stop_facts_refresh'' and l.status = ''success'';\n'
            || E'  if v_tank_verdict is distinct from ''NO_EVIDENCE'' then\n'
            || E'    select jsonb_build_object(''F1'', l.details->''flags''->''F1'', ''F1b'', l.details->''flags''->''F1b'',\n'
            || E'                              ''F3'', l.details->''flags''->''F3'')\n'
            || E'      into v_tank_flags\n'
            || E'      from public.sync_log l where l.sync_source = ''stop_facts_refresh'' and l.status = ''success''\n'
            || E'     order by l.started_at desc limit 1;\n'
            || E'  end if;\n\n'
            || E'  v_total := v_conflict + v_stuck';
  v_a4 text := E'            ''billing_never_confirmed'', v_bill_neverconf,\n';
  v_b4 text := E'            ''billing_never_confirmed'', v_bill_neverconf,\n'
            || E'            -- M7: count-only, deliberately NOT in items and NOT in v_total.\n'
            || E'            ''tank_flags_observation'', v_tank_verdict,\n'
            || E'            ''tank_flags'',             v_tank_flags,\n';
  a text;
begin
  if md5(v_def) <> 'f13ce28dfec3e401d029285d320c02e7' then
    raise exception 'log_jobber_sync_health changed since this migration was written (md5 %)', md5(v_def);
  end if;
  foreach a in array array[v_a1, v_a2, v_a3, v_a4] loop
    if (length(v_def) - length(replace(v_def, a, ''))) / length(a) <> 1 then
      raise exception 'anchor not found exactly once: %', left(a, 60);
    end if;
  end loop;
  v_def := replace(v_def, v_a1, v_b1);
  v_def := replace(v_def, v_a2, v_b2);
  v_def := replace(v_def, v_a3, v_b3);
  v_def := replace(v_def, v_a4, v_b4);
  execute v_def;
end
$mig$;

revoke all on function public.log_jobber_sync_health() from public, anon, authenticated;

-- VERIFY
do $v$
declare v_def text := pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure); s text; v_details jsonb;
begin
  foreach s in array array['''stop_facts_refresh''','''tank_feed_freshness''','''stop_facts_integrity''','''tank_geometry_drift''',
                           '''railway_samsara_readings''','''railway_samsara_gps''','''tank_flags_observation''','''tank_flags'''] loop
    if position(s in v_def) = 0 then raise exception 'VERIFY M7-1: % missing from the new body', s; end if;
  end loop;
  if has_function_privilege('anon', 'public.log_jobber_sync_health()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.log_jobber_sync_health()', 'EXECUTE')
     or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'public.log_jobber_sync_health()'::regprocedure and a.grantee = 0) then
    raise exception 'VERIFY M7-2: log_jobber_sync_health is executable by anon, authenticated or PUBLIC';
  end if;
  perform public.log_jobber_sync_health();
  select details into v_details from public.sync_log where sync_source = 'jobber-sync-health' order by id desc limit 1;
  if not (v_details ? 'tank_flags_observation') then raise exception 'VERIFY M7-3: tank_flags_observation not written'; end if;
end
$v$;

commit;
