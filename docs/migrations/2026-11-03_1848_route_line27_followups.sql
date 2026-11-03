-- ============================================================================
-- 2026-11-03_1848_route_line27_followups  Line-27 routing: the reader it missed, and alerts for the cases it cannot route
-- ============================================================================
-- THE ASK: Trello 0lAWU6Ge (#169); Fred 2026-11-03: the BSI bot files "Only line item 27 visits ... That are from Boca
--   Raton"; "Leads + routing now" (plan docs/specs/2026-11-03-boca-bsi-leads-and-filing-plan.md, stage S4). Root
--   CLAUDE.md section 7: when the system waits or cannot decide, the reason must reach a person on its own.
-- WHY (a read-only adversarial check of 2026-11-03_1830, each finding re-measured by a second agent):
--   - derm.gdo_report_status reads line 27 through fn_visit_is_gdo_reporting directly, not through v_derm_portal_fields,
--     so the routing did not reach it: once line 27 is on a Boca job, its visits would read "pending" there. Nothing
--     reads the view today (no app, function or bot), so this only keeps the next reader honest.
--   - public.fn_client_files_with_bsi works per CLIENT. Two client shapes defeat it, and only scripts/checks/
--     bsi_routing.sql (run by hand) noticed one of them: (a) a live GDO permit plus a Boca Raton property: "a live GDO
--     always wins", so its Boca line-27 visits would be filed with Miami-Dade under that permit; (b) a client routed to
--     BSI that also has a property in another city: that property's line-27 visits leave the DERM queue and its
--     "no permit" alerts. Neither exists today (0 clients, and no routed client has line 27 on an open job).
--   - S4 of the plan starts with a one-line fix to public.fn_health_alert_scan: its insert takes ops.v_health_items as
--     is, and two items sharing a key make INSERT ... ON CONFLICT DO UPDATE fail ("cannot affect row a second time"),
--     which would stop the whole health email. It was not done with the routing.
-- WHAT (anchored edits of live bodies, md5 pinned; owner, grants and columns unchanged):
--   public.fn_health_alert_scan   its insert reads SELECT DISTINCT ON (i.check_name, i.item_key).
--   derm.gdo_report_status        WHERE gains AND NOT public.fn_client_files_with_bsi(v.client_id) (authenticated and
--                                 db_backup_reader, its readers, already hold EXECUTE on the rule).
--   public.log_rpa_derm_health()  two items, only for a client with line 27 on an open job and never for a test
--                                 client, keyed 'bsi_route_gdo_and_boca:<client id>' and 'bsi_route_other_city:<client
--                                 id>' (unique keys); details gain bsi_route_conflicts.
-- NOT CHANGED, a decision for Fred: the DERM Tracker shows its GDO Online Report section on EVERY visit, with
--   "Record a manual filing" (Fred, 2026-08-19: "with or without line item 27"), so a Boca visit offers a manual filing
--   "with Miami-Dade" (derm.visit_gdo_manual_eligibility, fn_record_manual_gdo_report). Refusing it for Boca clients
--   would change that rule, and would also remove the manual-filing test on 112-YA (a test client the rule routes).
-- VERIFY (inside, every fixture undone):
--   (a) nothing moves today: derm.gdo_report_status hashed before and after; the old and new health bodies give the
--       same reasons on today's data; no bsi_route item today.
--   (b) controls that must fail on the old bodies: two items with one key make the OLD scan fail and the new one pass;
--       line 27 on Grove Kosher's job 1325 puts Grove in the OLD derm.gdo_report_status, not in the new one.
--   (c) each new item appears when its shape is built, and not otherwise: 041-MB (live GDO, line 27 on an open job)
--       with its property's city set to Boca Raton -> bsi_route_gdo_and_boca:10; client 245 (Boca Raton property 668 +
--       a property in another city) with line 27 on job 962, reopened -> bsi_route_other_city:245; Grove (Boca only)
--       with line 27 -> neither.
-- LOCKS: derm.gdo_report_status has no reader; the two functions take no table lock. lock_timeout 3s.
-- ROLLBACK: docs/migrations/2026-11-03_rollback_route_line27_followups.sql
-- ============================================================================
begin;
set local lock_timeout = '3s';
set local search_path = public, extensions;   -- pg_get_viewdef / functiondef text below is written and re-read under this path

do $pre$
begin
  if md5((select prosrc from pg_proc where oid = 'public.fn_health_alert_scan(integer,integer)'::regprocedure)) <> '94fad52fba8aa7755203074fc7f0686e' then
    raise exception 'route follow-up: fn_health_alert_scan changed since this migration was written';
  end if;
  if md5(pg_get_viewdef('derm.gdo_report_status'::regclass, false)) <> 'ffeccbedcca6bb7cd553654d22881c99' then
    raise exception 'route follow-up: derm.gdo_report_status changed since this migration was written';
  end if;
  if md5((select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) <> '8f4830779d4c88dc04216ac99c555c78' then
    raise exception 'route follow-up: log_rpa_derm_health changed since this migration was written';
  end if;
end $pre$;

-- the old bodies, kept for the controls (temporary objects, gone at commit)
do $old$
begin
  execute replace(pg_get_functiondef('public.fn_health_alert_scan(integer,integer)'::regprocedure),
                  'FUNCTION public.fn_health_alert_scan(', 'FUNCTION pg_temp._old_health_alert_scan(');
  execute replace(pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure),
                  'FUNCTION public.log_rpa_derm_health(', 'FUNCTION pg_temp._old_log_rpa_derm_health(');
  execute 'create temp view _old_gdo_report_status as ' || rtrim(btrim(pg_get_viewdef('derm.gdo_report_status'::regclass, false)), ';');
end $old$;
create temp table _f_grs_before on commit drop as
select md5(coalesce(string_agg(t::text, '|' order by t::text), '')) as h, count(*) as n from derm.gdo_report_status t;

-- the three anchored edits
do $edit$
declare d text; a text; b text;
begin
  d := pg_get_functiondef('public.fn_health_alert_scan(integer,integer)'::regprocedure);
  a := E'  SELECT i.check_name, i.item_key, now(), now()\n    FROM ops.v_health_items i\n  ON CONFLICT';
  b := E'  SELECT DISTINCT ON (i.check_name, i.item_key) i.check_name, i.item_key, now(), now()   -- 2026-11-03_1848: one row per key\n    FROM ops.v_health_items i\n  ON CONFLICT';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'route follow-up: scan anchor not found once'; end if;
  execute replace(d, a, b);

  d := rtrim(btrim(pg_get_viewdef('derm.gdo_report_status'::regclass, false)), ';');
  a := 'WHERE ((v.deleted_at IS NULL) AND fn_visit_is_gdo_reporting(v.id))';
  b := 'WHERE ((v.deleted_at IS NULL) AND fn_visit_is_gdo_reporting(v.id) AND (NOT public.fn_client_files_with_bsi(v.client_id)))';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'route follow-up: report status anchor not found once'; end if;
  execute 'create or replace view derm.gdo_report_status as ' || replace(d, a, b);

  d := pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure);
  a := 'np jsonb; nc jsonb; pc jsonb;';
  b := 'np jsonb; nc jsonb; pc jsonb; rc jsonb;';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'route follow-up: health declare anchor not found once'; end if;
  d := replace(d, a, b);
  a := E'  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)';
  b := E'  -- 2026-11-03_1848: the line-27 routing works per client (fn_client_files_with_bsi), so two client shapes send some\n'
    || E'  -- line-27 visits to the wrong place. Only for a client with line 27 on an open job; never a test client; one item\n'
    || E'  -- per client and shape, keyed on its kind (which carries the client id).\n'
    || E'  select coalesce(jsonb_agg(x.item order by x.k), ''[]''::jsonb)\n'
    || E'    into rc\n'
    || E'    from (select ''bsi_route_gdo_and_boca:'' || c.id as k,\n'
    || E'                 jsonb_build_object(''kind'', ''bsi_route_gdo_and_boca:'' || c.id, ''client_code'', c.client_code, ''client'', c.name,\n'
    || E'                   ''issue'', ''this client has a Miami-Dade GDO permit AND a Boca Raton property, so all its line-27 visits, Boca Raton ones included, are filed with Miami-Dade'',\n'
    || E'                   ''what_to_do'', ''Fred: the line-27 routing works per client and cannot send this client''''s visits to two places. Check which property the line-27 job is for (a Boca Raton property files on BSI Online, never with Miami-Dade).'') as item\n'
    || E'            from public.clients c\n'
    || E'           where exists (select 1 from public.gdos g\n'
    || E'                          where g.client_id = c.id and g.permit_type = ''GDO'' and g.status in (''ACTIVE'', ''EXPIRED''))\n'
    || E'             and exists (select 1 from public.properties p\n'
    || E'                          where p.client_id = c.id and p.deleted_at is null and lower(btrim(p.city)) = ''boca raton'')\n'
    || E'             and exists (select 1 from public.jobs j join public.line_items li on li.job_id = j.id and li.visit_id is null\n'
    || E'                          where j.client_id = c.id and public.fn_line_item_is_gdo_reporting(li.name)\n'
    || E'                            and j.job_status not in (''archived'', ''destroyed''))\n'
    || E'             and not exists (select 1 from public.v_non_customer_clients n where n.client_id = c.id)\n'
    || E'          union all\n'
    || E'          select ''bsi_route_other_city:'' || c.id,\n'
    || E'                 jsonb_build_object(''kind'', ''bsi_route_other_city:'' || c.id, ''client_code'', c.client_code, ''client'', c.name,\n'
    || E'                   ''issue'', ''this client files with BSI (a Boca Raton property, no GDO permit) but also has a property in another city, whose line-27 visits are kept out of the Miami-Dade queue and its alerts'',\n'
    || E'                   ''what_to_do'', ''Fred: the line-27 routing works per client and cannot send this client''''s visits to two places. Check the other property (a wrong city, or a Miami-Dade location that needs its GDO permit entered).'')\n'
    || E'            from public.clients c\n'
    || E'           where public.fn_client_files_with_bsi(c.id)\n'
    || E'             and exists (select 1 from public.properties p\n'
    || E'                          where p.client_id = c.id and p.deleted_at is null and lower(btrim(coalesce(p.city, ''''))) <> ''boca raton'')\n'
    || E'             and exists (select 1 from public.jobs j join public.line_items li on li.job_id = j.id and li.visit_id is null\n'
    || E'                          where j.client_id = c.id and public.fn_line_item_is_gdo_reporting(li.name)\n'
    || E'                            and j.job_status not in (''archived'', ''destroyed''))\n'
    || E'             and not exists (select 1 from public.v_non_customer_clients n where n.client_id = c.id)) x;\n'
    || E'  if jsonb_array_length(rc) > 0 then attn := true; reasons := reasons || rc; end if;\n'
    || E'  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'route follow-up: health insert anchor not found once'; end if;
  d := replace(d, a, b);
  a := '''line27_no_permit_clients'',jsonb_array_length(nc),''reasons'',reasons';
  b := '''line27_no_permit_clients'',jsonb_array_length(nc),''bsi_route_conflicts'',jsonb_array_length(rc),''reasons'',reasons';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'route follow-up: health details anchor not found once'; end if;
  execute replace(d, a, b);
end $edit$;

-- VERIFY
do $verify$
declare v_old jsonb; v_new jsonb; v_failed boolean; v_n int; v_old_n int; v_new_n int;
begin
  -- the edits landed
  if position('DISTINCT ON (i.check_name, i.item_key)' in (select prosrc from pg_proc where oid = 'public.fn_health_alert_scan(integer,integer)'::regprocedure)) = 0
     or position('fn_client_files_with_bsi' in pg_get_viewdef('derm.gdo_report_status'::regclass, false)) = 0
     or position('bsi_route_other_city' in (select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) = 0 then
    raise exception 'route follow-up VERIFY: an edit did not land';
  end if;

  -- (a) nothing moves today
  if (select md5(coalesce(string_agg(t::text, '|' order by t::text), '')) from derm.gdo_report_status t)
     is distinct from (select h from _f_grs_before) then
    raise exception 'route follow-up VERIFY: derm.gdo_report_status rows moved today';
  end if;
  begin
    perform pg_temp._old_log_rpa_derm_health();
    select s.details -> 'reasons' into v_old from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if v_old is distinct from v_new then raise exception 'route follow-up VERIFY: today''s health reasons changed: % -> %', v_old, v_new; end if;
    if v_new::text like '%bsi_route_%' then raise exception 'route follow-up VERIFY: a bsi_route item fires today: %', v_new; end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (b1) two items with one key: the OLD scan fails, the new one passes
  begin
    insert into public.sync_log (sync_source, started_at, finished_at, status, details)
    values ('rpa-derm-health', now(), now(), 'attention',
            jsonb_build_object('reasons', '[{"kind":"verify_duplicate_key"},{"kind":"verify_duplicate_key"}]'::jsonb));
    v_failed := false;
    begin
      perform pg_temp._old_health_alert_scan();
    exception when cardinality_violation then v_failed := true;
    end;
    if not v_failed then raise exception 'route follow-up VERIFY: CONTROL FAILED, the old scan took two items with one key'; end if;
    perform public.fn_health_alert_scan();
    if (select count(*) from public.health_alert_state where check_name = 'rpa-derm-health' and item_key = 'verify_duplicate_key') <> 1 then
      raise exception 'route follow-up VERIFY: the new scan did not record the duplicated item once';
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (b2) line 27 on Grove Kosher's job 1325: the OLD report-status body lists Grove, the new one does not
  begin
    insert into public.line_items (job_id, name, quantity, unit_price, total_price) values (1325, '27 - GDO Online Reporting', 1, 0, 0);
    select count(*) into v_old_n from _old_gdo_report_status where client_id = 357;
    select count(*) into v_new_n from derm.gdo_report_status where client_id = 357;
    if v_old_n = 0 then raise exception 'route follow-up VERIFY: CONTROL FAILED, the old report-status body shows no Grove visit'; end if;
    if v_new_n <> 0 then raise exception 'route follow-up VERIFY: the new report-status body still shows % Grove visits', v_new_n; end if;
    -- Grove is Boca Raton only: line 27 on its job raises no routing item
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if v_new::text like '%bsi_route_%' then raise exception 'route follow-up VERIFY: Grove alone raised a routing item: %', v_new; end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (c1) a live GDO and a Boca Raton property: 041-MB (client 10) with its property's city set to Boca Raton
  begin
    update public.properties set city = 'Boca Raton' where id = 138 and client_id = 10;
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'route follow-up VERIFY: fixture property 138 of client 10 not found'; end if;
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if not exists (select 1 from jsonb_array_elements(v_new) e where e ->> 'kind' = 'bsi_route_gdo_and_boca:10') then
      raise exception 'route follow-up VERIFY: the GDO + Boca Raton item did not appear: %', v_new;
    end if;
    if (select count(*) from ops.v_health_items where check_name = 'rpa-derm-health' and item_key = 'bsi_route_gdo_and_boca:10') <> 1 then
      raise exception 'route follow-up VERIFY: the GDO + Boca Raton item is not one health item';
    end if;
    perform pg_temp._old_log_rpa_derm_health();
    select s.details -> 'reasons' into v_old from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if v_old::text like '%bsi_route_%' then raise exception 'route follow-up VERIFY: CONTROL FAILED, the old body raised a routing item'; end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (c2) routed to BSI with a property in another city: client 245, line 27 on job 962 (reopened for the test)
  begin
    if not public.fn_client_files_with_bsi(245) then raise exception 'route follow-up VERIFY: fixture client 245 is not routed to BSI'; end if;
    update public.jobs set job_status = 'upcoming' where id = 962 and client_id = 245;
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'route follow-up VERIFY: fixture job 962 of client 245 not found'; end if;
    insert into public.line_items (job_id, name, quantity, unit_price, total_price) values (962, '27 - GDO Online Reporting', 1, 0, 0);
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if not exists (select 1 from jsonb_array_elements(v_new) e where e ->> 'kind' = 'bsi_route_other_city:245') then
      raise exception 'route follow-up VERIFY: the other-city item did not appear: %', v_new;
    end if;
    if (select (s.details ->> 'bsi_route_conflicts')::int from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1) <> 1 then
      raise exception 'route follow-up VERIFY: bsi_route_conflicts does not count the item';
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;
end $verify$;

commit;
