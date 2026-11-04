-- ============================================================================
-- 2026-11-04_0042_route_line27_alert_set_keys  Line-27 routing alerts: keyed on WHICH visits; skipped and cancelled are not work
-- (Corrections to this header, added after it was applied, are at the END of this file. Everything else is as applied.)
-- ============================================================================
-- THE ASK: Fred 2026-11-03, Trello #169: "Only line item 27 visits ... That are from Boca Raton." Root CLAUDE.md
--   section 7: "if the system refuses or waits, the reason must reach a person on its own". A fourth read-only
--   adversarial pass (each finding re-measured by a refuter) re-attacked 2026-11-03_2255. This migration fixes its two
--   confirmed routing defects and one wording defect, all in public.log_rpa_derm_health()'s routing block (the rule,
--   fn_client_files_with_bsi, is unchanged; 0 bsi_route items today, and no production run has raised one yet).
-- WHAT:
--   1. THE KEY NAMES THE SET OF VISITS, NOT ITS COUNT AND HIGHEST ID. Since _2255 the key was
--      kind:client:completed visits:highest completed visit id. When one completed line-27 visit left the set and
--      another with a lower id than the highest came in, the count and the highest id stayed the same, so the key did
--      not change: a silence given for the first set covered the second, and the newly listed visit was never shown as
--      new (reproduced on clients 44 and 130 in rolled-back fixtures; visit ids are not in date order for many
--      clients). The fourth part is now a fingerprint of WHICH completed visits: the first 8 hex characters of the md5
--      of their ids sorted as text and joined with commas (0 when there is none), e.g. bsi_route_unfiled:44:2:ea924bf8
--      for visits 7463 and 7814. Any change to that set, a swap included, is a NEW item, the old key is listed under
--      "Resolved", and a silence covers only the set it was shown. The text still names the count and the date of the
--      newest visit.
--   2. A SKIPPED OR CANCELLED VISIT IS NOT WORK. A GDO-reporting visit counted whatever its status, so line 27 on a
--      visit that never happened raised bsi_route_unfiled or bsi_route_gdo_and_boca, and since the cutoff is fixed the
--      item could not resolve (28 such visits since 2026-07-21, none of a routed client today). The visit branch now
--      leaves out visit_status skipped and cancelled; a scheduled one is still work. (A NULL status would count: the
--      column allows it, 0 rows hold it.)
--   3. bsi_route_other_city also fires for line-27 work with NO property (a job or a visit whose property_id is NULL),
--      and its text said "a property in another city". It now says the work is not at a Boca Raton property (a
--      property in another city, or a job or visit with no property), and what_to_do says to check where that work is.
-- CORRECTIONS TO EARLIER HEADERS (those files record what was applied, so they are corrected here, not edited):
--   - _2255, item 1 and its function comment: "kind:client:completed visits:newest completed visit" was the HIGHEST
--     visit id, which is not the latest-dated visit for some clients (the text's "newest on" date was computed
--     separately and was right). "A new completed visit gives a new key ... a silence covers only the visits shown"
--     was false for a swap (item 1 here). And "a new visit" means a new COMPLETED line-27 visit: a newly scheduled one
--     changed nothing until it was completed (still true).
--   - _2255, item 2: "1 of the 19 live billing rows has visits (a client whose only property is its billing row)":
--     the count is right, the parenthetical is not. That row is 891 of client 478, which also has property 1018 (its
--     jobs): 3 live visits of its Service Agreement job 1308 were placed on 891 in June 2026, when 891 was its only
--     property, and stayed when the job moved to 1018 in August. The 3 billing rows that are their client's only live
--     property have no visits.
--   - _2255, VERIFY: "each new behaviour against the OLD body as a control": cases A, B and D had one; case E's control
--     was the EDITED body run as service_role before the grant (42501; the old body fails the same way); case C had
--     none. And 2026-11-03_1848_route_line27_followups case (c2) (client 245) had no old-body control either.
--   - _2255 (items 1 and 2) and _2039 describe misfires as past events ("raised nothing new", "a billing address raised
--     an item", client 245's billing row "raised other_city"). No routing logger body had run in production: the last
--     run before this migration is 2026-11-03 09:00 UTC, before _1830. They were seen only in rolled-back VERIFY
--     fixtures; they would have happened.
--   - _2255 CORRECTIONS, the 16:41 ET line: 2,487 + 838 = 3,325, one short of the "3,326" it explains; the extra
--     character is not accounted for (probably a separator between message and statement).
-- GRANTS: unchanged (read back below). RULE 8: no table created. RULE 7: no CHECK widened.
-- LOCKS: CREATE OR REPLACE FUNCTION takes no lock that readers of the views wait on; lock_timeout 3s.
-- VERIFY (inside): the edit landed once; the new body is the old body plus exactly this block (md5); grants; today the
--   old and new bodies give the same reasons; and on rolled-back fixtures, each new behaviour with the OLD body as a
--   control that must not show it:
--   (A) client 44 (no permit), its only property 133 set to Boca Raton: line 27 on completed visits 7463 and 7814 is
--       NEW; after its email and a silence, line 27 moves from 7463 to 7688 (same count, same highest id): a NEW key,
--       the old one listed as resolved, one item. CONTROL: the old body keeps one key and the scan shows nothing new;
--   (B) skipped visit 6310 of client 300 (a live GDO) and cancelled visit 8181 of client 512 (no permit), their only
--       properties set to Boca Raton, with line 27: nothing. CONTROL: the old body raised gdo_and_boca:300 and
--       unfiled:512. Then line 27 on their scheduled visits 6924 and 8121 raises both (a scheduled visit is work);
--   (C) client 482 (files with BSI): its open job 1714 with no property and line 27: other_city in its new words, plus
--       unfiled. CONTROL: the old text says "a property in another city";
--   (D) client 10 (a live GDO), its only property 138 set to Boca Raton: gdo_and_boca keyed on its 2 completed visits
--       6036 and 6037, with the count and the newest date. CONTROL: the old body keys it on the highest id, 6037;
--   (E) service_role gets postgres's reasons (a regression check; it has no control).
-- ROLLBACK: docs/migrations/2026-11-04_rollback_route_line27_alert_set_keys.sql (its guard refuses unless this body is
--   live; then 2026-11-03_rollback_route_line27_alert_keys.sql and the older ones, each guarded the same way).
-- ============================================================================
begin;
set local lock_timeout = '3s';
set local search_path = public, extensions;

do $pre$
begin
  if md5((select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) <> '57a1cad01dac85dc947dfa8a5fb1f462' then
    raise exception 'set keys: log_rpa_derm_health changed since this migration was written';
  end if;
  if md5((select prosrc from pg_proc where oid = 'public.fn_client_files_with_bsi(bigint)'::regprocedure)) <> 'a4ea8dbbaf3c7927b69f8865628005ce'
     or md5((select prosrc from pg_proc where oid = 'public.fn_city_is_boca_raton(text)'::regprocedure)) <> '0725795c5e7a0d0444b98fb75c2bcaa0' then
    raise exception 'set keys: the rule or the Boca Raton test changed since this migration was written';
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

-- the anchored edit: the routing block, from its comment to its "if jsonb_array_length(rc)" line
do $edit$
declare d text; a text; b text; i int; j int;
begin
  d := pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure);
  a := '  -- 2026-11-03_1848 / _2039 / 2026-11-03_2255: the line-27 routing works per client (fn_client_files_with_bsi), so';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'set keys: block start not found once'; end if;
  i := position(a in d);
  a := E'  if jsonb_array_length(rc) > 0 then attn := true; reasons := reasons || rc; end if;\n';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'set keys: block end not found once'; end if;
  j := position(a in d) + length(a);
  if j <= i then raise exception 'set keys: block markers out of order'; end if;
  b := $blk$  -- 2026-11-03_1848 / _2039 / _2255 / 2026-11-04_0042: the line-27 routing works per client
  -- (fn_client_files_with_bsi), so two client shapes send some line-27 visits to the wrong place, and a client that
  -- files with BSI is filed by nobody yet (the BSI bot is plan S6-S8). Line-27 work = an open job's own lines (at the
  -- job's property) or a GDO-reporting visit since the launch cutoff that was not skipped or cancelled (its visit,
  -- invoice or job line: fn_visit_is_gdo_reporting, the routing's own test; at the visit's property). Each item looks
  -- only at the work it is about: gdo_and_boca at a Boca Raton property, other_city at a property elsewhere (or none),
  -- unfiled at any, so an address with no work (a billing address) raises nothing. Never a test client. One item per
  -- client and kind, keyed kind:client:completed visits:a fingerprint of WHICH completed visits (the first 8 hex of the
  -- md5 of their ids sorted as text and joined with commas), so any change to that set, a swap included, is a NEW item
  -- (the old key is listed as resolved) and a silence covers only the set it was shown.
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
               and coalesce(v.visit_status, '') not in ('skipped', 'cancelled')
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
            select k.kind, k.client_id, count(distinct k.done_id) as n, max(k.done_date) as newest_date,
                   coalesce(left(md5(string_agg(distinct k.done_id::text, ',' order by k.done_id::text)), 8), '0') as visits_fp
              from k group by k.kind, k.client_id)
          select g.kind || ':' || g.client_id || ':' || g.n || ':' || g.visits_fp as k,
                 jsonb_build_object('kind', g.kind || ':' || g.client_id || ':' || g.n || ':' || g.visits_fp,
                   'client_code', c.client_code, 'client', c.name,
                   'issue', case g.kind
                              when 'bsi_route_gdo_and_boca' then 'this client has a Miami-Dade GDO permit AND line-27 work at a Boca Raton property, so its Boca Raton visits are filed with Miami-Dade'
                              when 'bsi_route_other_city' then 'this client files with BSI (a Boca Raton property, no GDO permit) but has line-27 work that is not at a Boca Raton property (a property in another city, or a job or visit with no property), whose visits are kept out of the Miami-Dade queue and its alerts'
                              else 'this client files with BSI Online (City of Boca Raton) and line 27 is on its work, but nothing files BSI reports yet, so these visits are kept out of the Miami-Dade queue and filed by no one'
                            end
                            || case when g.n = 0 then ' (no completed visit with line 27 yet)'
                                    else ' (' || g.n || ' completed visit' || case when g.n = 1 then '' else 's' end
                                         || ' with line 27 since ' || to_char(public.rpa_launch_cutoff(), 'FMMM/FMDD/YYYY')
                                         || ', newest on ' || to_char(g.newest_date, 'FMMM/FMDD/YYYY') || ')'
                               end,
                   'what_to_do', case g.kind
                              when 'bsi_route_gdo_and_boca' then 'Fred: the line-27 routing works per client and cannot send this client''s visits to two places. Its Boca Raton property files on BSI Online, never with Miami-Dade: decide where this client''s Boca Raton visits are filed.'
                              when 'bsi_route_other_city' then 'Fred: the line-27 routing works per client and cannot send this client''s visits to two places. Check where that work is (a wrong city, a job or visit with no property, or a Miami-Dade location that needs its GDO permit entered).'
                              else 'Yan: file this client''s grease trap reports on BSI Online by hand (the BSI bot is not built yet). If the client is not in the City of Boca Raton program (no BSI record), take line 27 off its job.'
                            end) as item
            from g join public.clients c on c.id = g.client_id) x;
  if jsonb_array_length(rc) > 0 then attn := true; reasons := reasons || rc; end if;
$blk$;
  execute left(d, i - 1) || b || substr(d, j);
end $edit$;

-- VERIFY
do $verify$
declare v_old jsonb; v_new jsonb; v_scan jsonb; v_n int; v_row bigint; v_li bigint; v_k1 text; v_k2 text;
begin
  -- the edit landed, once
  if position('a fingerprint of WHICH completed visits' in (select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) = 0
     or (select count(*) from regexp_matches((select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure), 'into rc', 'g')) <> 1 then
    raise exception 'set keys VERIFY: the edit did not land once';
  end if;
  -- the whole body: the old body plus exactly this block (computed offline from the live body; the rollback's guard pins it too)
  if md5((select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) <> '1773ee2bf7b5da5100b74cb693b19d4e' then
    raise exception 'set keys VERIFY: the new body is not the old body plus exactly this block';
  end if;
  if (select p.proacl::text from pg_proc p where p.oid = 'public.log_rpa_derm_health()'::regprocedure) is distinct from (select acl from _k_acl_before) then
    raise exception 'set keys VERIFY: the logger''s grants changed';
  end if;

  -- today: the old and the new body give the same reasons, and no routing item
  begin
    perform pg_temp._old_log_rpa_derm_health();
    select s.details -> 'reasons' into v_old from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if v_old is distinct from v_new then raise exception 'set keys VERIFY: today''s health reasons changed: % -> %', v_old, v_new; end if;
    if v_new::text like '%bsi_route_%' then raise exception 'set keys VERIFY: a bsi_route item fires today: %', v_new; end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (A) client 44 (no permit, not a test client, one live property: 133): a SWAP of which completed visits carry
  --     line 27 is a new item
  begin
    if (select string_agg(v.id || ':' || v.visit_status || ':' || v.visit_date || ':' || v.property_id, ',' order by v.id)
          from public.visits v where v.client_id = 44 and v.deleted_at is null and v.visit_date >= public.rpa_launch_cutoff())
         is distinct from '7463:completed:2026-07-30:133,7688:completed:2026-08-06:133,7814:completed:2026-08-27:133'
       or (select count(*) from public.properties p where p.client_id = 44 and p.deleted_at is null) <> 1
       or exists (select 1 from public.gdos g where g.client_id = 44 and g.status in ('ACTIVE', 'EXPIRED'))
       or exists (select 1 from public.v_non_customer_clients n where n.client_id = 44)
       or exists (select 1 from public.jobs j join public.line_items li on li.job_id = j.id and li.visit_id is null
                   where j.client_id = 44 and public.fn_line_item_is_gdo_reporting(li.name))
       or exists (select 1 from public.visits v where v.client_id = 44 and v.deleted_at is null and public.fn_visit_is_gdo_reporting(v.id)) then
      raise exception 'set keys VERIFY: fixture client 44 is not as measured';
    end if;
    update public.properties set city = 'Boca Raton' where id = 133 and client_id = 44;
    get diagnostics v_n = row_count;
    if v_n <> 1 or not public.fn_client_files_with_bsi(44) then raise exception 'set keys VERIFY: fixture client 44 does not file with BSI'; end if;
    insert into public.line_items (visit_id, name, quantity, unit_price, total_price) values (7463, '27 - GDO Online Reporting', 1, 0, 0) returning id into v_li;
    insert into public.line_items (visit_id, name, quantity, unit_price, total_price) values (7814, '27 - GDO Online Reporting', 1, 0, 0);
    perform public.log_rpa_derm_health();
    select s.id, s.details -> 'reasons' into v_row, v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    v_k1 := 'bsi_route_unfiled:44:2:' || left(md5('7463,7814'), 8);
    if (select array_agg(e ->> 'kind') from jsonb_array_elements(v_new) e where e ->> 'kind' like 'bsi_route_%') is distinct from array[v_k1]
       or not exists (select 1 from jsonb_array_elements(v_new) e
                       where e ->> 'kind' = v_k1 and e ->> 'issue' like '%(2 completed visits with line 27 since 7/21/2026, newest on 8/27/2026)') then
      raise exception 'set keys VERIFY: client 44 did not raise exactly %: %', v_k1, v_new;
    end if;
    v_scan := public.fn_health_alert_scan(3, 7);
    if not exists (select 1 from jsonb_array_elements(v_scan -> 'new') e where e ->> 'item_key' = v_k1) then
      raise exception 'set keys VERIFY: client 44''s first item is not NEW in the scan';
    end if;
    perform public.fn_health_alert_mark_sent(v_scan -> 'new');   -- what health-escalate does after it sends
    perform public.fn_health_ack('rpa-derm-health', v_k1, 30, 'VERIFY fixture', 'VERIFY');
    -- that email went out yesterday (one transaction has one now(), and "resolved" means resolved AFTER the email)
    update public.health_alert_state set first_seen_at = now() - interval '1 day', last_alerted_at = now() - interval '1 day'
     where check_name = 'rpa-derm-health' and item_key = v_k1;
    -- the swap: line 27 leaves 7463 and reaches 7688; the count (2) and the highest id (7814) stay the same
    delete from public.line_items where id = v_li;
    insert into public.line_items (visit_id, name, quantity, unit_price, total_price) values (7688, '27 - GDO Online Reporting', 1, 0, 0);
    update public.sync_log set started_at = started_at - interval '1 minute' where id = v_row;   -- the next run is then the latest
    perform public.log_rpa_derm_health();
    v_k2 := 'bsi_route_unfiled:44:2:' || left(md5('7688,7814'), 8);
    v_scan := public.fn_health_alert_scan(3, 7);
    if not exists (select 1 from jsonb_array_elements(v_scan -> 'new') e where e ->> 'item_key' = v_k2) then
      raise exception 'set keys VERIFY: the swapped set is not NEW after the silence: %', v_scan;
    end if;
    if not exists (select 1 from jsonb_array_elements(v_scan -> 'resolved') e where e ->> 'item_key' = v_k1) then
      raise exception 'set keys VERIFY: the first key was not listed as resolved';
    end if;
    if (select count(*) from ops.v_health_items where check_name = 'rpa-derm-health' and item_key like 'bsi_route_%') <> 1 then
      raise exception 'set keys VERIFY: client 44 is not exactly one health item';
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;
  -- (A) CONTROL: the same steps with the old body; the swap keeps the key, so the scan shows nothing new
  begin
    update public.properties set city = 'Boca Raton' where id = 133 and client_id = 44;
    insert into public.line_items (visit_id, name, quantity, unit_price, total_price) values (7463, '27 - GDO Online Reporting', 1, 0, 0) returning id into v_li;
    insert into public.line_items (visit_id, name, quantity, unit_price, total_price) values (7814, '27 - GDO Online Reporting', 1, 0, 0);
    perform pg_temp._old_log_rpa_derm_health();
    select s.id into v_row from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    v_scan := public.fn_health_alert_scan(3, 7);
    if not exists (select 1 from jsonb_array_elements(v_scan -> 'new') e where e ->> 'item_key' = 'bsi_route_unfiled:44:2:7814') then
      raise exception 'set keys VERIFY: CONTROL FAILED, the old body did not raise client 44''s item';
    end if;
    perform public.fn_health_alert_mark_sent(v_scan -> 'new');
    perform public.fn_health_ack('rpa-derm-health', 'bsi_route_unfiled:44:2:7814', 30, 'VERIFY control', 'VERIFY');
    update public.health_alert_state set first_seen_at = now() - interval '1 day', last_alerted_at = now() - interval '1 day'
     where check_name = 'rpa-derm-health' and item_key = 'bsi_route_unfiled:44:2:7814';
    delete from public.line_items where id = v_li;
    insert into public.line_items (visit_id, name, quantity, unit_price, total_price) values (7688, '27 - GDO Online Reporting', 1, 0, 0);
    update public.sync_log set started_at = started_at - interval '1 minute' where id = v_row;
    perform pg_temp._old_log_rpa_derm_health();
    v_scan := public.fn_health_alert_scan(3, 7);
    if exists (select 1 from jsonb_array_elements(v_scan -> 'new') e where e ->> 'item_key' like 'bsi_route_%') then
      raise exception 'set keys VERIFY: CONTROL FAILED, the old body announced the swap';
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (B) a skipped or a cancelled visit is not work; a scheduled one is. Client 300 (a live GDO, one live property: 82):
  --     skipped 6310, scheduled 6924. Client 512 (no permit, one live property: 1047): cancelled 8181, scheduled 8121
  begin
    if (select string_agg(v.id || ':' || v.client_id || ':' || v.visit_status || ':' || v.property_id, ',' order by v.id)
          from public.visits v where v.id in (6310, 6924, 8121, 8181) and v.deleted_at is null)
         is distinct from '6310:300:skipped:82,6924:300:scheduled:82,8121:512:scheduled:1047,8181:512:cancelled:1047'
       or (select count(*) from public.properties p where p.client_id in (300, 512) and p.deleted_at is null) <> 2
       or not exists (select 1 from public.gdos g where g.client_id = 300 and g.permit_type = 'GDO' and g.status in ('ACTIVE', 'EXPIRED'))
       or exists (select 1 from public.gdos g where g.client_id = 512 and g.status in ('ACTIVE', 'EXPIRED'))
       or exists (select 1 from public.v_non_customer_clients n where n.client_id in (300, 512))
       or exists (select 1 from public.jobs j join public.line_items li on li.job_id = j.id and li.visit_id is null
                   where j.client_id in (300, 512) and public.fn_line_item_is_gdo_reporting(li.name))
       or exists (select 1 from public.visits v where v.client_id in (300, 512) and v.deleted_at is null and public.fn_visit_is_gdo_reporting(v.id)) then
      raise exception 'set keys VERIFY: fixture clients 300 / 512 are not as measured';
    end if;
    update public.properties set city = 'Boca Raton' where (id = 82 and client_id = 300) or (id = 1047 and client_id = 512);
    get diagnostics v_n = row_count;
    if v_n <> 2 then raise exception 'set keys VERIFY: fixture properties 82 / 1047 not found'; end if;
    insert into public.line_items (visit_id, name, quantity, unit_price, total_price)
    values (6310, '27 - GDO Online Reporting', 1, 0, 0), (8181, '27 - GDO Online Reporting', 1, 0, 0);
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if v_new::text like '%bsi_route_%' then
      raise exception 'set keys VERIFY: a skipped or cancelled visit raised an item: %', v_new;
    end if;
    perform pg_temp._old_log_rpa_derm_health();
    select s.details -> 'reasons' into v_old from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if (select array_agg(e ->> 'kind' order by e ->> 'kind') from jsonb_array_elements(v_old) e where e ->> 'kind' like 'bsi_route_%')
       is distinct from array['bsi_route_gdo_and_boca:300:0:0', 'bsi_route_unfiled:512:0:0'] then
      raise exception 'set keys VERIFY: CONTROL FAILED, the old body did not raise both items: %', v_old;
    end if;
    -- a scheduled visit is work: line 27 on 6924 and 8121 raises both
    insert into public.line_items (visit_id, name, quantity, unit_price, total_price)
    values (6924, '27 - GDO Online Reporting', 1, 0, 0), (8121, '27 - GDO Online Reporting', 1, 0, 0);
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if (select array_agg(e ->> 'kind' order by e ->> 'kind') from jsonb_array_elements(v_new) e where e ->> 'kind' like 'bsi_route_%')
       is distinct from array['bsi_route_gdo_and_boca:300:0:0', 'bsi_route_unfiled:512:0:0'] then
      raise exception 'set keys VERIFY: scheduled line-27 visits did not raise both items: %', v_new;
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (C) client 482 (files with BSI; one live property, 1012, in Boca Raton): line 27 on its open job 1714 with no
  --     property raises other_city in words that fit work with no property, and unfiled
  begin
    if (select j.job_status || ':' || j.property_id from public.jobs j where j.id = 1714 and j.client_id = 482) is distinct from 'action_required:1012'
       or not public.fn_client_files_with_bsi(482)
       or exists (select 1 from public.v_non_customer_clients n where n.client_id = 482)
       or exists (select 1 from public.jobs j join public.line_items li on li.job_id = j.id and li.visit_id is null
                   where j.client_id = 482 and public.fn_line_item_is_gdo_reporting(li.name))
       or exists (select 1 from public.visits v where v.client_id = 482 and v.deleted_at is null and v.visit_date >= public.rpa_launch_cutoff()
                   and public.fn_visit_is_gdo_reporting(v.id)) then
      raise exception 'set keys VERIFY: fixture client 482 / job 1714 is not as measured';
    end if;
    update public.jobs set property_id = null where id = 1714 and client_id = 482;
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'set keys VERIFY: fixture job 1714 not found'; end if;
    insert into public.line_items (job_id, name, quantity, unit_price, total_price) values (1714, '27 - GDO Online Reporting', 1, 0, 0);
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if (select array_agg(e ->> 'kind' order by e ->> 'kind') from jsonb_array_elements(v_new) e where e ->> 'kind' like 'bsi_route_%')
         is distinct from array['bsi_route_other_city:482:0:0', 'bsi_route_unfiled:482:0:0']
       or not exists (select 1 from jsonb_array_elements(v_new) e
                       where e ->> 'kind' = 'bsi_route_other_city:482:0:0'
                         and e ->> 'issue' like '%line-27 work that is not at a Boca Raton property (a property in another city, or a job or visit with no property)%'
                         and e ->> 'what_to_do' like '%Check where that work is (a wrong city, a job or visit with no property,%') then
      raise exception 'set keys VERIFY: work with no property did not raise other_city in its new words, and unfiled: %', v_new;
    end if;
    perform pg_temp._old_log_rpa_derm_health();
    select s.details -> 'reasons' into v_old from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if not exists (select 1 from jsonb_array_elements(v_old) e
                    where e ->> 'kind' = 'bsi_route_other_city:482:0:0' and e ->> 'issue' like '%at a property in another city,%'
                      and e ->> 'issue' not like '%not at a Boca Raton property%') then
      raise exception 'set keys VERIFY: CONTROL FAILED, the old body did not word it as a property in another city: %', v_old;
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (D) client 10 (a live GDO; its completed line-27 visits since the cutoff are 6036 and 6037, at its only live
  --     property 138), with 138 set to Boca Raton: gdo_and_boca keyed on WHICH visits, with their count and newest date
  begin
    if (select string_agg(v.id || ':' || v.visit_date || ':' || v.property_id, ',' order by v.id)
          from public.visits v
         where v.client_id = 10 and v.deleted_at is null and v.visit_status = 'completed'
           and v.visit_date >= public.rpa_launch_cutoff() and public.fn_visit_is_gdo_reporting(v.id))
         is distinct from '6036:2026-07-28:138,6037:2026-09-29:138'
       or (select count(*) from public.properties p where p.client_id = 10 and p.deleted_at is null) <> 1 then
      raise exception 'set keys VERIFY: fixture client 10''s completed line-27 visits are not as measured';
    end if;
    update public.properties set city = 'Boca Raton' where id = 138 and client_id = 10;
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'set keys VERIFY: fixture property 138 of client 10 not found'; end if;
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    v_k1 := 'bsi_route_gdo_and_boca:10:2:' || left(md5('6036,6037'), 8);
    if (select array_agg(e ->> 'kind') from jsonb_array_elements(v_new) e where e ->> 'kind' like 'bsi_route_%') is distinct from array[v_k1]
       or not exists (select 1 from jsonb_array_elements(v_new) e
                       where e ->> 'kind' = v_k1 and e ->> 'issue' like '%(2 completed visits with line 27 since 7/21/2026, newest on 9/29/2026)') then
      raise exception 'set keys VERIFY: client 10 in Boca Raton did not raise exactly %: %', v_k1, v_new;
    end if;
    perform pg_temp._old_log_rpa_derm_health();
    select s.details -> 'reasons' into v_old from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if (select array_agg(e ->> 'kind') from jsonb_array_elements(v_old) e where e ->> 'kind' like 'bsi_route_%')
       is distinct from array['bsi_route_gdo_and_boca:10:2:6037'] then
      raise exception 'set keys VERIFY: CONTROL FAILED, the old body did not key client 10 on its highest visit id: %', v_old;
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (E) service_role runs the logger and gets the reasons postgres gets (a regression check; it has no control)
  begin
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_old from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    perform set_config('role', 'service_role', true);
    perform public.log_rpa_derm_health();
    perform set_config('role', 'none', true);
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if v_old is distinct from v_new then raise exception 'set keys VERIFY: service_role got other reasons: % vs %', v_new, v_old; end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;
  if current_user <> 'postgres' then raise exception 'set keys VERIFY: the role did not come back'; end if;
end $verify$;

-- the control is a temp object of this session: drop it, so a reused connection cannot meet it again
drop function pg_temp._old_log_rpa_derm_health();

commit;

-- ============================================================================
-- CORRECTIONS added 2026-11-04 ~01:45 ET, after a fifth adversarial check (no later migration exists to carry them, and
-- this check changed no database object). Nothing below runs. The live logger's behaviour was confirmed correct.
--   - WHAT, item 2: "28 such visits since 2026-07-21, none of a routed client today" mixed two counts. 28 is ALL live
--     skipped or cancelled visits since the cutoff (16 skipped, 12 cancelled, one of them dated 2027-01-01), with or
--     without line 27. 2 of them are GDO-reporting (6742 and 6743 of client 305, not routed, through their job's line).
--     3 of the 28 are on a routed client: the test client 112-YA (381), which the items skip.
--   - CORRECTIONS, the _2255 "newly scheduled" sentence: "changed nothing until it was completed (still true)" is true
--     of an existing item's KEY only. A scheduled line-27 visit of a client with no item of that kind yet raises one,
--     keyed :0:0 (case B here asserts exactly that).
--   - CORRECTIONS, billing row 891: "stayed when the job moved to 1018 in August": audit.logs shows job 1308's property_id
--     NULL as far back as the audit goes (2026-08-01) and NULL to 1018 on 2026-08-12. It was given 1018; no audited row
--     has it on 891.
--   - CORRECTIONS, the misfires: the quote "raised other_city" (client 245's billing row) was a sentence in CLAUDE.md, not
--     in _2255 or _2039 (in _2255 it describes a rolled-back fixture). _2039's own past-tense sentence is its item 1
--     ("was filed with Miami-Dade and raised nothing"). The fact stands: no routing logger body had run in production.
--   - ROLLBACK: "each guarded the same way": 2026-11-03_rollback_route_line27_ccn_to_bsi.sql has no opening md5 guard; it
--     refuses a wrong order through its closing VERIFY, and its transaction aborts all the same.
--   - The commit message of d2169abf says bsi_routing_mutations.mjs "proves every row can fail": that was false, 7 of its
--     17 rows never failed in any case. Commit 2026-11-04 (fifth check) made it true and made the suite enforce it.
-- ============================================================================
