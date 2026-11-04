-- ============================================================================
-- 2026-11-03_2255_route_line27_alert_keys  Line-27 routing alerts: a new visit is a new alert; only work counts
-- ============================================================================
-- THE ASK: Fred 2026-11-03, Trello #169: "Only line item 27 visits ... That are from Boca Raton." Root CLAUDE.md
--   section 7: "if the system refuses or waits, the reason must reach a person on its own". A third read-only
--   adversarial pass (each finding re-measured by a refuter) re-attacked the 20:38 ET changes. It found nothing new
--   on privacy; this migration fixes its two confirmed routing defects.
-- WHAT (public.log_rpa_derm_health(), its line-27 routing block only; the rule is unchanged):
--   1. A NEW COMPLETED VISIT IS A NEW ALERT. The three bsi_route items were keyed on kind and client only, and the
--      client's "has line 27" test uses the fixed launch cutoff (2026-07-21), so an item never resolved: after its
--      first email, a client's later line-27 visits raised nothing new, and the "silence 30d" line the email prints
--      under every item hid them all for 30 days (for a GDO + Boca Raton client, while those visits sit in the
--      Miami-Dade queue). The key is now kind:client:completed visits:newest completed visit, e.g.
--      bsi_route_unfiled:357:2:5944, and the text names the count and the newest date. A new completed visit gives a
--      new key: the email lists it as new and the old key under "Resolved"; a silence covers only the visits shown.
--      Still one item per client and kind (0 today).
--   2. ONLY WORK COUNTS, NOT AN ADDRESS. Each item now looks at the line-27 work it is about: gdo_and_boca at a Boca
--      Raton property, other_city at a property elsewhere (or with no property), unfiled at any. Line-27 work = an
--      open job's own lines (at the job's property) or a GDO-reporting visit since the cutoff (at the visit's
--      property). Before, any live property counted, so a billing address raised an item that could never resolve:
--      client 245's "other city" is its BILLING address 396 (Beverly Hills, no job, no visit), and a GDO client with
--      a billing address in Boca Raton would raise gdo_and_boca. A billing row cannot simply be skipped: 1 of the 19
--      live billing rows has visits (a client whose only property is its billing row).
--   3. GRANT EXECUTE on public.fn_city_is_boca_raton(text) to service_role. log_rpa_derm_health runs as its caller,
--      service_role keeps EXECUTE on it (2026-09-24_1045 kept postgres and service_role on the health functions), and since _2039 a
--      service_role call failed 42501 on the helper. The helper reads nothing but its argument. Its comment now says
--      exactly what it reads (it is a PREFIX test on a-z letters: an accented "Ratón" does not count, "Boca Raton
--      West" does).
-- CORRECTIONS TO EARLIER HEADERS (those files record what was applied, so they are corrected here, not edited):
--   - _2039_route_line27_alerts: "GRANTS: fn_city_is_boca_raton: postgres only (every caller is SECURITY DEFINER, or
--     runs as postgres)" was wrong: the logger is SECURITY INVOKER and service_role may call it (item 3).
--   - _2039_route_line27_alerts, item 3: "It also catches line 27 on a routed client that is not in the City program"
--     named only the 5 clients with no BSI record. Until Yan's review records a 'same' decision through
--     leads.decide_client (0 on 2026-11-03), no routed client is matched, so scripts/checks/bsi_routing.sql fails on
--     line 27 on ANY routed client, Grove Kosher included.
--   - _2039_route_line27_alerts, VERIFY: case (5) (client 245) ran only the new body; it had no old-body control.
--   - _2039_leads_label_mask_and_quiet_load: its 16:41 ET ERROR line did reach Logs Explorer WITH part of its
--     statement (re-measured 2026-11-03 ~22:50 ET: message 2,487 characters, statement 838: the DO block's code
--     without the line that carried the payload, no $leadsjson$ tag and no leads.ingest( call; 0 CCN- or
--     email-shaped values in either). Its "3,326 characters" was about the two together (2,487 + 838 = 3,325), not the
--     message alone. Why that line was left out is not
--     known, so a shorter failing statement holding one value may well be shipped whole: the protection is that the
--     loader's statement does not fail, not the log shipper.
-- GRANTS: fn_city_is_boca_raton: postgres + service_role. log_rpa_derm_health keeps its grants (read back below).
-- RULE 8: no table created. RULE 7: no CHECK widened.
-- LOCKS: CREATE OR REPLACE FUNCTION takes no lock that readers of the views wait on; lock_timeout 3s, applied clear of
--   the backup dump (:17 on even UTC hours).
-- VERIFY (inside): the edit landed once; grants; today the old and new bodies give the same reasons; and on
--   rolled-back fixtures, each new behaviour against the OLD body as a control (which must not show it):
--   (A) Grove Kosher: line 27 on completed visit 5943 is NEW, its email is marked sent and silenced, then line 27 on
--       5944 is NEW again (the old key resolved); the old body stays silent (CONTROL);
--   (B) client 245: line 27 on its Boca Raton job raises only bsi_route_unfiled (the old body also raised other_city,
--       CONTROL); the same job at the billing address raises other_city;
--   (C) 041-MB (a GDO) with its only property, where its line-27 work is, set to Boca Raton: gdo_and_boca, with the
--       count and newest date read from the data;
--   (D) 110-CLA (a GDO): its billing address, with no work, set to Boca Raton raises nothing (the old body fired,
--       CONTROL);
--   (E) service_role runs the logger (it failed 42501 before the grant, CONTROL) and gets postgres's reasons.
-- ROLLBACK: docs/migrations/2026-11-03_rollback_route_line27_alert_keys.sql (its guard refuses unless this body is live; then the
--   _2039 alerts rollback, then the _1848 follow-ups one, each guarded the same way).
-- ============================================================================
begin;
set local lock_timeout = '3s';
set local search_path = public, extensions;

do $pre$
begin
  if md5((select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) <> '8b58a04cb61ed27fa29ee460797b6c12' then
    raise exception 'alert keys: log_rpa_derm_health changed since this migration was written';
  end if;
  if md5((select prosrc from pg_proc where oid = 'public.fn_client_files_with_bsi(bigint)'::regprocedure)) <> 'a4ea8dbbaf3c7927b69f8865628005ce'
     or md5((select prosrc from pg_proc where oid = 'public.fn_city_is_boca_raton(text)'::regprocedure)) <> '0725795c5e7a0d0444b98fb75c2bcaa0' then
    raise exception 'alert keys: the rule or the Boca Raton test changed since this migration was written';
  end if;
  if has_function_privilege('service_role', 'public.fn_city_is_boca_raton(text)', 'EXECUTE') then
    raise exception 'alert keys: service_role can already run fn_city_is_boca_raton';
  end if;
end $pre$;

-- the old body, kept as the control for VERIFY
do $old$
begin
  execute replace(pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure),
                  'FUNCTION public.log_rpa_derm_health(', 'FUNCTION pg_temp._old_log_rpa_derm_health(');
end $old$;
create temp table _k_acl_before on commit drop as
select p.proacl::text as acl from pg_proc p where p.oid = 'public.log_rpa_derm_health()'::regprocedure;

-- 1 + 2. the anchored edit: the routing block, from its comment to its "if jsonb_array_length(rc)" line
do $edit$
declare d text; a text; b text; i int; j int;
begin
  d := pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure);
  a := '  -- 2026-11-03_1848 / _2039: the line-27 routing works per client (fn_client_files_with_bsi), so two client shapes';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'alert keys: block start not found once'; end if;
  i := position(a in d);
  a := E'  if jsonb_array_length(rc) > 0 then attn := true; reasons := reasons || rc; end if;\n';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'alert keys: block end not found once'; end if;
  j := position(a in d) + length(a);
  if j <= i then raise exception 'alert keys: block markers out of order'; end if;
  b := $blk$  -- 2026-11-03_1848 / _2039 / 2026-11-03_2255: the line-27 routing works per client (fn_client_files_with_bsi), so
  -- two client shapes send some line-27 visits to the wrong place, and a client that files with BSI is filed by nobody
  -- yet (the BSI bot is plan S6-S8). Line-27 work = an open job's own lines (at the job's property) or a GDO-reporting
  -- visit since the launch cutoff (its visit, invoice or job line: fn_visit_is_gdo_reporting, the routing's own test;
  -- at the visit's property). Each item looks only at the work it is about: gdo_and_boca at a Boca Raton property,
  -- other_city at a property elsewhere (or none), unfiled at any, so an address with no work (a billing address)
  -- raises nothing. Never a test client. One item per client and kind, keyed kind:client:completed visits:newest
  -- completed visit, so a new completed line-27 visit is a NEW item (the old key is listed as resolved) and a silence
  -- covers only the visits it was shown.
  select coalesce(jsonb_agg(x.item order by x.k), '[]'::jsonb)
    into rc
    from (with w as (
            select j.client_id, j.property_id, null::bigint as done_id, null::date as done_date
              from public.jobs j join public.line_items li on li.job_id = j.id and li.visit_id is null
             where public.fn_line_item_is_gdo_reporting(li.name) and j.job_status not in ('archived', 'destroyed')
            union all
            select v.client_id, v.property_id,
                   case when v.visit_status = 'completed' then v.id end,
                   case when v.visit_status = 'completed' then v.visit_date end
              from public.visits v
             where v.deleted_at is null and v.visit_date >= public.rpa_launch_cutoff()
               and public.fn_visit_is_gdo_reporting(v.id)),
          wk as (
            select w.client_id, w.done_id, w.done_date,
                   coalesce(public.fn_city_is_boca_raton(p.city), false) as at_boca,
                   public.fn_client_files_with_bsi(w.client_id) as routed
              from w left join public.properties p on p.id = w.property_id
             where not exists (select 1 from public.v_non_customer_clients n where n.client_id = w.client_id)),
          k as (
            select 'bsi_route_gdo_and_boca' as kind, wk.client_id, wk.done_id, wk.done_date from wk
             where wk.at_boca
               and exists (select 1 from public.gdos g
                            where g.client_id = wk.client_id and g.permit_type = 'GDO' and g.status in ('ACTIVE', 'EXPIRED'))
            union all
            select 'bsi_route_other_city', wk.client_id, wk.done_id, wk.done_date from wk where wk.routed and not wk.at_boca
            union all
            select 'bsi_route_unfiled', wk.client_id, wk.done_id, wk.done_date from wk where wk.routed),
          g as (
            select k.kind, k.client_id, count(distinct k.done_id) as n, max(k.done_id) as newest_id, max(k.done_date) as newest_date
              from k group by k.kind, k.client_id)
          select g.kind || ':' || g.client_id || ':' || g.n || ':' || coalesce(g.newest_id, 0) as k,
                 jsonb_build_object('kind', g.kind || ':' || g.client_id || ':' || g.n || ':' || coalesce(g.newest_id, 0),
                   'client_code', c.client_code, 'client', c.name,
                   'issue', case g.kind
                              when 'bsi_route_gdo_and_boca' then 'this client has a Miami-Dade GDO permit AND line-27 work at a Boca Raton property, so its Boca Raton visits are filed with Miami-Dade'
                              when 'bsi_route_other_city' then 'this client files with BSI (a Boca Raton property, no GDO permit) but has line-27 work at a property in another city, whose visits are kept out of the Miami-Dade queue and its alerts'
                              else 'this client files with BSI Online (City of Boca Raton) and line 27 is on its work, but nothing files BSI reports yet, so these visits are kept out of the Miami-Dade queue and filed by no one'
                            end
                            || case when g.n = 0 then ' (no completed visit with line 27 yet)'
                                    else ' (' || g.n || ' completed visit' || case when g.n = 1 then '' else 's' end
                                         || ' with line 27 since ' || to_char(public.rpa_launch_cutoff(), 'FMMM/FMDD/YYYY')
                                         || ', newest on ' || to_char(g.newest_date, 'FMMM/FMDD/YYYY') || ')'
                               end,
                   'what_to_do', case g.kind
                              when 'bsi_route_gdo_and_boca' then 'Fred: the line-27 routing works per client and cannot send this client''s visits to two places. Its Boca Raton property files on BSI Online, never with Miami-Dade: decide where this client''s Boca Raton visits are filed.'
                              when 'bsi_route_other_city' then 'Fred: the line-27 routing works per client and cannot send this client''s visits to two places. Check the other property (a wrong city, or a Miami-Dade location that needs its GDO permit entered).'
                              else 'Yan: file this client''s grease trap reports on BSI Online by hand (the BSI bot is not built yet). If the client is not in the City of Boca Raton program (no BSI record), take line 27 off its job.'
                            end) as item
            from g join public.clients c on c.id = g.client_id) x;
  if jsonb_array_length(rc) > 0 then attn := true; reasons := reasons || rc; end if;
$blk$;
  execute left(d, i - 1) || b || substr(d, j);
end $edit$;

-- (E) CONTROL before the grant: service_role cannot run the logger yet
do $ctl$
begin
  begin
    perform set_config('role', 'service_role', true);
    perform public.log_rpa_derm_health();
    raise exception 'alert keys VERIFY: CONTROL FAILED, service_role ran the logger before the grant';
  exception when insufficient_privilege then
    null;   -- 42501, as measured; the sub-block's role change is undone with it
  end;
  if current_user <> 'postgres' then raise exception 'alert keys VERIFY: the role did not come back'; end if;
end $ctl$;

-- 3. the grant, and the helper's comment
grant execute on function public.fn_city_is_boca_raton(text) to service_role;
comment on function public.fn_city_is_boca_raton(text) is
  'True when a property''s city reads Boca Raton: its a-z letters, lower-cased, START WITH "bocaraton" ("Boca Raton", '
  '"BOCA RATON", "Boca Raton, FL", "Boca-Raton" and a non-breaking space count; "Boca" alone and "West Boca Raton" do '
  'not; an accented "Ratón" does not, since its o-acute is dropped; "Boca Raton West" does). The one test the line-27 '
  'routing (fn_client_files_with_bsi), its health items in log_rpa_derm_health and scripts/checks/bsi_routing.sql use '
  '(2026-11-03_2039). It reads the city NAME, so a "Boca Raton" postal address outside the City limits counts too: the '
  'BSI record match decides. EXECUTE: postgres and service_role (log_rpa_derm_health runs as its caller; 2026-11-03_2255).';

-- VERIFY
do $verify$
declare v_old jsonb; v_new jsonb; v_scan jsonb; v_n int; v_row bigint; v_k text; v_exp_n int; v_exp_id bigint; v_exp_date date;
begin
  -- the edit landed, once
  if position('kind:client:completed visits:newest' in (select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) = 0
     or (select count(*) from regexp_matches((select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure), 'into rc', 'g')) <> 1 then
    raise exception 'alert keys VERIFY: the edit did not land once';
  end if;
  -- the whole body: the old body plus exactly this block (computed offline from the live body; the rollback's guard pins it too)
  if md5((select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) <> '57a1cad01dac85dc947dfa8a5fb1f462' then
    raise exception 'alert keys VERIFY: the new body is not the old body plus exactly this block';
  end if;

  -- grants
  if (select p.proacl::text from pg_proc p where p.oid = 'public.log_rpa_derm_health()'::regprocedure) is distinct from (select acl from _k_acl_before) then
    raise exception 'alert keys VERIFY: the logger''s grants changed';
  end if;
  if not has_function_privilege('service_role', 'public.fn_city_is_boca_raton(text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.fn_city_is_boca_raton(text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.fn_city_is_boca_raton(text)', 'EXECUTE') then
    raise exception 'alert keys VERIFY: fn_city_is_boca_raton grants are not postgres + service_role';
  end if;

  -- today: the old and the new body give the same reasons, and no routing item
  begin
    perform pg_temp._old_log_rpa_derm_health();
    select s.details -> 'reasons' into v_old from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if v_old is distinct from v_new then raise exception 'alert keys VERIFY: today''s health reasons changed: % -> %', v_old, v_new; end if;
    if v_new::text like '%bsi_route_%' then raise exception 'alert keys VERIFY: a bsi_route item fires today: %', v_new; end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (A) Grove Kosher (357, routed): a second completed line-27 visit after an emailed, silenced first one
  begin
    if exists (select 1 from public.visits v where v.client_id = 357 and v.deleted_at is null and v.visit_date >= public.rpa_launch_cutoff()
                and public.fn_visit_is_gdo_reporting(v.id))
       or (select string_agg(v.visit_status || ':' || v.visit_date, ',' order by v.id) from public.visits v where v.id in (5943, 5944))
          is distinct from 'completed:2026-08-27,completed:2026-10-27' then
      raise exception 'alert keys VERIFY: fixture Grove visits 5943 / 5944 are not as measured';
    end if;
    insert into public.line_items (visit_id, name, quantity, unit_price, total_price) values (5943, '27 - GDO Online Reporting', 1, 0, 0);
    perform public.log_rpa_derm_health();
    select s.id, s.details -> 'reasons' into v_row, v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if not exists (select 1 from jsonb_array_elements(v_new) e
                    where e ->> 'kind' = 'bsi_route_unfiled:357:1:5943'
                      and e ->> 'issue' like '%(1 completed visit with line 27 since 7/21/2026, newest on 8/27/2026)') then
      raise exception 'alert keys VERIFY: the first Grove visit did not raise bsi_route_unfiled:357:1:5943: %', v_new;
    end if;
    v_scan := public.fn_health_alert_scan(3, 7);
    if not exists (select 1 from jsonb_array_elements(v_scan -> 'new') e where e ->> 'item_key' = 'bsi_route_unfiled:357:1:5943') then
      raise exception 'alert keys VERIFY: the first Grove item is not NEW in the scan';
    end if;
    perform public.fn_health_alert_mark_sent(v_scan -> 'new');   -- what health-escalate does after it sends
    perform public.fn_health_ack('rpa-derm-health', 'bsi_route_unfiled:357:1:5943', 30, 'VERIFY fixture', 'VERIFY');
    -- that email went out yesterday (one transaction has one now(), and "resolved" means resolved AFTER the email)
    update public.health_alert_state set first_seen_at = now() - interval '1 day', last_alerted_at = now() - interval '1 day'
     where check_name = 'rpa-derm-health' and item_key = 'bsi_route_unfiled:357:1:5943';
    insert into public.line_items (visit_id, name, quantity, unit_price, total_price) values (5944, '27 - GDO Online Reporting', 1, 0, 0);
    update public.sync_log set started_at = started_at - interval '1 minute' where id = v_row;   -- the next run is then the latest
    perform public.log_rpa_derm_health();
    v_scan := public.fn_health_alert_scan(3, 7);
    if not exists (select 1 from jsonb_array_elements(v_scan -> 'new') e where e ->> 'item_key' = 'bsi_route_unfiled:357:2:5944') then
      raise exception 'alert keys VERIFY: the second Grove visit is not NEW after the silence: %', v_scan;
    end if;
    if not exists (select 1 from jsonb_array_elements(v_scan -> 'resolved') e where e ->> 'item_key' = 'bsi_route_unfiled:357:1:5943') then
      raise exception 'alert keys VERIFY: the first Grove key was not listed as resolved';
    end if;
    if (select count(*) from ops.v_health_items where check_name = 'rpa-derm-health' and item_key like 'bsi_route_%') <> 1 then
      raise exception 'alert keys VERIFY: Grove is not exactly one health item';
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;
  -- (A) CONTROL: the same steps with the old body; the second visit raises nothing
  begin
    insert into public.line_items (visit_id, name, quantity, unit_price, total_price) values (5943, '27 - GDO Online Reporting', 1, 0, 0);
    perform pg_temp._old_log_rpa_derm_health();
    select s.id into v_row from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    v_scan := public.fn_health_alert_scan(3, 7);
    if not exists (select 1 from jsonb_array_elements(v_scan -> 'new') e where e ->> 'item_key' = 'bsi_route_unfiled:357') then
      raise exception 'alert keys VERIFY: CONTROL FAILED, the old body did not raise Grove''s item';
    end if;
    perform public.fn_health_alert_mark_sent(v_scan -> 'new');
    perform public.fn_health_ack('rpa-derm-health', 'bsi_route_unfiled:357', 30, 'VERIFY control', 'VERIFY');
    insert into public.line_items (visit_id, name, quantity, unit_price, total_price) values (5944, '27 - GDO Online Reporting', 1, 0, 0);
    update public.sync_log set started_at = started_at - interval '1 minute' where id = v_row;
    perform pg_temp._old_log_rpa_derm_health();
    v_scan := public.fn_health_alert_scan(3, 7);
    if exists (select 1 from jsonb_array_elements(v_scan -> 'new') e where e ->> 'item_key' like 'bsi_route_%') then
      raise exception 'alert keys VERIFY: CONTROL FAILED, the old body announced the second visit';
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (B) client 245 (routed): its job 962 at its Boca Raton property 668, reopened with line 27
  begin
    update public.jobs set job_status = 'upcoming' where id = 962 and client_id = 245 and property_id = 668;
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'alert keys VERIFY: fixture job 962 of client 245 at property 668 not found'; end if;
    insert into public.line_items (job_id, name, quantity, unit_price, total_price) values (962, '27 - GDO Online Reporting', 1, 0, 0);
    perform public.log_rpa_derm_health();
    select s.id, s.details -> 'reasons' into v_row, v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if (select array_agg(e ->> 'kind' order by e ->> 'kind') from jsonb_array_elements(v_new) e where e ->> 'kind' like 'bsi_route_%')
       is distinct from array['bsi_route_unfiled:245:0:0']
       or not exists (select 1 from jsonb_array_elements(v_new) e
                       where e ->> 'kind' = 'bsi_route_unfiled:245:0:0' and e ->> 'issue' like '%(no completed visit with line 27 yet)') then
      raise exception 'alert keys VERIFY: client 245''s Boca Raton job did not raise exactly the unfiled item: %', v_new;
    end if;
    perform pg_temp._old_log_rpa_derm_health();
    select s.details -> 'reasons' into v_old from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if not exists (select 1 from jsonb_array_elements(v_old) e where e ->> 'kind' = 'bsi_route_other_city:245') then
      raise exception 'alert keys VERIFY: CONTROL FAILED, the old body did not raise other_city on the billing address';
    end if;
    -- the same job at the Beverly Hills billing address: work in another city, so other_city fires
    update public.jobs set property_id = 396 where id = 962;
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if (select array_agg(e ->> 'kind' order by e ->> 'kind') from jsonb_array_elements(v_new) e where e ->> 'kind' like 'bsi_route_%')
       is distinct from array['bsi_route_other_city:245:0:0', 'bsi_route_unfiled:245:0:0'] then
      raise exception 'alert keys VERIFY: client 245''s job in another city did not raise other_city and unfiled: %', v_new;
    end if;
    if (select (s.details ->> 'bsi_route_conflicts')::int from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1) <> 2 then
      raise exception 'alert keys VERIFY: bsi_route_conflicts does not count both items';
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (C) 041-MB (client 10, a live GDO, its line-27 work at its only property 138) with 138 in Boca Raton
  begin
    select count(*), max(v.id), max(v.visit_date) into v_exp_n, v_exp_id, v_exp_date
      from public.visits v
     where v.client_id = 10 and v.property_id = 138 and v.deleted_at is null and v.visit_status = 'completed'
       and v.visit_date >= public.rpa_launch_cutoff() and public.fn_visit_is_gdo_reporting(v.id);
    if v_exp_n < 1 then raise exception 'alert keys VERIFY: fixture 041-MB has no completed line-27 visit at property 138'; end if;
    update public.properties set city = 'Boca Raton' where id = 138 and client_id = 10;
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'alert keys VERIFY: fixture property 138 of client 10 not found'; end if;
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    v_k := 'bsi_route_gdo_and_boca:10:' || v_exp_n || ':' || v_exp_id;
    if (select array_agg(e ->> 'kind') from jsonb_array_elements(v_new) e where e ->> 'kind' like 'bsi_route_%') is distinct from array[v_k]
       or not exists (select 1 from jsonb_array_elements(v_new) e
                       where e ->> 'kind' = v_k
                         and e ->> 'issue' like '%(' || v_exp_n || ' completed visit' || case when v_exp_n = 1 then '' else 's' end
                                                  || ' with line 27 since 7/21/2026, newest on ' || to_char(v_exp_date, 'FMMM/FMDD/YYYY') || ')') then
      raise exception 'alert keys VERIFY: 041-MB in Boca Raton did not raise exactly % with its count and date: %', v_k, v_new;
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (D) 110-CLA (client 372, a live GDO): its billing address 501, with no work, set to Boca Raton
  begin
    if exists (select 1 from public.jobs j where j.property_id = 501) or exists (select 1 from public.visits v where v.property_id = 501) then
      raise exception 'alert keys VERIFY: fixture property 501 has work now';
    end if;
    update public.properties set city = 'Boca Raton' where id = 501 and client_id = 372;
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'alert keys VERIFY: fixture property 501 of client 372 not found'; end if;
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if v_new::text like '%bsi_route_%' then
      raise exception 'alert keys VERIFY: a Boca Raton address with no work raised an item: %', v_new;
    end if;
    perform pg_temp._old_log_rpa_derm_health();
    select s.details -> 'reasons' into v_old from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if not exists (select 1 from jsonb_array_elements(v_old) e where e ->> 'kind' = 'bsi_route_gdo_and_boca:372') then
      raise exception 'alert keys VERIFY: CONTROL FAILED, the old body did not fire on the idle Boca Raton address';
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (E) service_role runs the logger now and gets the reasons postgres gets
  begin
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_old from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    perform set_config('role', 'service_role', true);
    perform public.log_rpa_derm_health();
    perform set_config('role', 'none', true);
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if v_old is distinct from v_new then raise exception 'alert keys VERIFY: service_role got other reasons: % vs %', v_new, v_old; end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;
  if current_user <> 'postgres' then raise exception 'alert keys VERIFY: the role did not come back'; end if;
end $verify$;

-- the control is a temp object of this session: drop it, so a reused connection cannot meet it again
drop function pg_temp._old_log_rpa_derm_health();

commit;
