-- ============================================================================
-- 2026-11-03_2039_route_line27_alerts  Line-27 routing: one Boca Raton test, alerts that see every line 27
-- ============================================================================
-- THE ASK: Fred 2026-11-03, Trello #169: "Only line item 27 visits ... That are from Boca Raton." Root CLAUDE.md
--   section 7: "if the system refuses or waits, the reason must reach a person on its own". A second read-only
--   adversarial pass re-attacked the 18:48 follow-ups; this migration fixes its routing findings (the privacy ones are
--   in 2026-11-03_2039_leads_label_mask_and_quiet_load).
-- WHAT
--   1. NEW public.fn_city_is_boca_raton(city): one test for "this city reads Boca Raton", by its letters only and
--      case-blind ("Boca Raton", "  BOCA RATON  ", "Boca Raton, FL" and a non-breaking space all count; "Boca" alone
--      and "West Boca Raton" do not). The rule (fn_client_files_with_bsi) and the two health items each spelled the
--      test as lower(btrim(city)) = 'boca raton', three copies that missed any other spelling (a client with a live
--      GDO and a "Boca Raton, FL" property was filed with Miami-Dade and raised nothing). Today all 10 live Boca
--      Raton properties read exactly "Boca Raton", so the routed set does not move (11 clients: 10 real + 112-YA).
--   2. log_rpa_derm_health(): the two routing items saw line 27 only on an open job's own lines, while the routing
--      takes every visit whose visit, invoice or job carries it (fn_visit_is_gdo_reporting). A client now "has line 27"
--      when an open job's own lines carry it OR a visit since the launch cutoff (2026-07-21, the DERM queue's own
--      window) is GDO-reporting. 3 of the 18 clients with line-27 visits since the cutoff have it on the invoice only
--      (221-YAS, 222-SPE, 356-MAS); on a client of either shape those visits were misrouted with no item.
--   3. NEW item bsi_route_unfiled:<client id>, same test: a client that files with BSI and has line 27. Nothing files
--      BSI reports yet (the bot is plan S6-S8; Yan files by hand), so the routing parks these visits and until now
--      nothing said so. It also catches line 27 on a routed client that is not in the City program (081-TCE and
--      319-CAP sit in ZIP 33498, where BSI lists nobody; 135-BB, 361-SFG and Olympus are not in the scrape). 0 today.
--   details.bsi_route_conflicts now counts all three kinds (the key is kept: docs and readers name it).
-- CORRECTION TO AN EARLIER HEADER (that file records what was applied, so it is corrected here, not edited):
--   - _1848_route_line27_followups says of its two shapes "Neither exists today": shape (b) exists, client 245 (a Boca
--     Raton property and a "Beverly Hills" property marked Dade). It lacks only line 27, so nothing is misrouted today.
-- GRANTS: fn_city_is_boca_raton: postgres only (every caller is SECURITY DEFINER, or runs as postgres).
--   fn_client_files_with_bsi and log_rpa_derm_health keep their grants (read back below).
-- RULE 8: no table created. RULE 7: no CHECK widened.
-- LOCKS: CREATE OR REPLACE FUNCTION takes no lock that readers of the views wait on; lock_timeout 3s, applied clear of
--   the backup dump (:17 on even UTC hours).
-- VERIFY (inside): the helper's spellings; the routed set unchanged today; old and new health bodies give the same
--   reasons today; and on rolled-back fixtures, each new behaviour against the OLD bodies as controls (which must not
--   show it): a "Boca Raton, FL" property routes 023-GRO; an invoice-only line 27 on 222-SPE (live GDO) with a Boca
--   Raton property raises bsi_route_gdo_and_boca; a "Boca Raton, FL" property on 041-MB raises it too; a visit line
--   27 on Grove Kosher raises bsi_route_unfiled (one health item, and no other-city item); line 27 on client 245's job
--   raises both bsi_route_other_city and bsi_route_unfiled; exact grants.
-- ROLLBACK: docs/migrations/2026-11-03_rollback_route_line27_alerts.sql (run it before the _1848 follow-ups one).
-- APPLIED 2026-11-03 20:38 ET (20:38:09 to 20:38:37), after three rehearsals; named 2039 because the name was already
--   written into stored comments. Checked after: both function bodies equal the old bodies plus exactly these edits,
--   grants unchanged; the health logger runs in 2.9 s as before and raises no routing item today; the DERM queue views
--   read in 54 to 208 ms as service_role.
-- ============================================================================
begin;
set local lock_timeout = '3s';
set local search_path = public, extensions;

do $pre$
begin
  if md5((select prosrc from pg_proc where oid = 'public.fn_client_files_with_bsi(bigint)'::regprocedure)) <> '101f4373881a51813b60e957b264ee03' then
    raise exception 'route alerts: fn_client_files_with_bsi changed since this migration was written';
  end if;
  if md5((select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) <> '21e2025e707c5db977b5434261c0f276' then
    raise exception 'route alerts: log_rpa_derm_health changed since this migration was written';
  end if;
  if to_regprocedure('public.fn_city_is_boca_raton(text)') is not null then
    raise exception 'route alerts: fn_city_is_boca_raton already exists';
  end if;
end $pre$;

-- the old bodies, kept as controls for VERIFY
do $old$
begin
  execute replace(pg_get_functiondef('public.fn_client_files_with_bsi(bigint)'::regprocedure),
                  'FUNCTION public.fn_client_files_with_bsi(', 'FUNCTION pg_temp._old_fn_client_files_with_bsi(');
  execute replace(pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure),
                  'FUNCTION public.log_rpa_derm_health(', 'FUNCTION pg_temp._old_log_rpa_derm_health(');
end $old$;
create temp table _r_routed_before on commit drop as
select array_agg(c.id order by c.id) as ids from public.clients c where public.fn_client_files_with_bsi(c.id);
create temp table _r_acl_before on commit drop as
select p.oid, p.proacl::text as acl from pg_proc p
 where p.oid in ('public.fn_client_files_with_bsi(bigint)'::regprocedure, 'public.log_rpa_derm_health()'::regprocedure);

-- 1. the one Boca Raton test
create function public.fn_city_is_boca_raton(p_city text)
returns boolean
language sql immutable parallel safe set search_path = ''
as $fn$ select regexp_replace(lower(coalesce(p_city, '')), '[^a-z]+', '', 'g') like 'bocaraton%' $fn$;
comment on function public.fn_city_is_boca_raton(text) is
  'True when a property''s city reads Boca Raton, by its letters only and case-blind ("Boca Raton", "BOCA RATON", '
  '"Boca Raton, FL" and a non-breaking space all count; "Boca" alone and "West Boca Raton" do not). The one test the '
  'line-27 routing (fn_client_files_with_bsi), its health items in log_rpa_derm_health and '
  'scripts/checks/bsi_routing.sql use (2026-11-03_2039). It reads the city NAME, so a "Boca Raton" address outside '
  'the City limits counts too.';
revoke all on function public.fn_city_is_boca_raton(text) from public, anon, authenticated, service_role;

-- 2. the anchored edits
do $edit$
declare d text; a text; b text; i int; j int;
begin
  d := pg_get_functiondef('public.fn_client_files_with_bsi(bigint)'::regprocedure);
  a := 'lower(btrim(p.city)) = ''boca raton''';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'route alerts: rule anchor not found once'; end if;
  execute replace(d, a, 'public.fn_city_is_boca_raton(p.city)');

  d := pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure);
  a := '  -- 2026-11-03_1848: the line-27 routing works per client (fn_client_files_with_bsi), so two client shapes send some';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'route alerts: health block start not found once'; end if;
  i := position(a in d);
  a := E'  if jsonb_array_length(rc) > 0 then attn := true; reasons := reasons || rc; end if;\n';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'route alerts: health block end not found once'; end if;
  j := position(a in d) + length(a);
  if j <= i then raise exception 'route alerts: health block markers out of order'; end if;
  b := $blk$  -- 2026-11-03_1848 / _2039: the line-27 routing works per client (fn_client_files_with_bsi), so two client shapes
  -- send some line-27 visits to the wrong place, and a client that files with BSI is filed by nobody yet (the BSI bot
  -- is plan S6-S8). A client "has line 27" when an open job's own lines carry it, or a visit since the launch cutoff
  -- is GDO-reporting (its visit, invoice or job line: fn_visit_is_gdo_reporting, the routing's own test). Never a
  -- test client; one item per client and kind, keyed on its kind (which carries the client id).
  select coalesce(jsonb_agg(x.item order by x.k), '[]'::jsonb)
    into rc
    from (with l27 as (
            select j.client_id from public.jobs j join public.line_items li on li.job_id = j.id and li.visit_id is null
             where public.fn_line_item_is_gdo_reporting(li.name) and j.job_status not in ('archived', 'destroyed')
            union
            select v.client_id from public.visits v
             where v.deleted_at is null and v.visit_date >= public.rpa_launch_cutoff()
               and public.fn_visit_is_gdo_reporting(v.id))
          select 'bsi_route_gdo_and_boca:' || c.id as k,
                 jsonb_build_object('kind', 'bsi_route_gdo_and_boca:' || c.id, 'client_code', c.client_code, 'client', c.name,
                   'issue', 'this client has a Miami-Dade GDO permit AND a Boca Raton property, so all its line-27 visits, Boca Raton ones included, are filed with Miami-Dade',
                   'what_to_do', 'Fred: the line-27 routing works per client and cannot send this client''s visits to two places. Check which property the line-27 work is for (a Boca Raton property files on BSI Online, never with Miami-Dade).') as item
            from public.clients c
           where c.id in (select l.client_id from l27 l)
             and exists (select 1 from public.gdos g
                          where g.client_id = c.id and g.permit_type = 'GDO' and g.status in ('ACTIVE', 'EXPIRED'))
             and exists (select 1 from public.properties p
                          where p.client_id = c.id and p.deleted_at is null and public.fn_city_is_boca_raton(p.city))
             and not exists (select 1 from public.v_non_customer_clients n where n.client_id = c.id)
          union all
          select 'bsi_route_other_city:' || c.id,
                 jsonb_build_object('kind', 'bsi_route_other_city:' || c.id, 'client_code', c.client_code, 'client', c.name,
                   'issue', 'this client files with BSI (a Boca Raton property, no GDO permit) but also has a property in another city, whose line-27 visits are kept out of the Miami-Dade queue and its alerts',
                   'what_to_do', 'Fred: the line-27 routing works per client and cannot send this client''s visits to two places. Check the other property (a wrong city, or a Miami-Dade location that needs its GDO permit entered).')
            from public.clients c
           where c.id in (select l.client_id from l27 l)
             and public.fn_client_files_with_bsi(c.id)
             and exists (select 1 from public.properties p
                          where p.client_id = c.id and p.deleted_at is null and not public.fn_city_is_boca_raton(p.city))
             and not exists (select 1 from public.v_non_customer_clients n where n.client_id = c.id)
          union all
          select 'bsi_route_unfiled:' || c.id,
                 jsonb_build_object('kind', 'bsi_route_unfiled:' || c.id, 'client_code', c.client_code, 'client', c.name,
                   'issue', 'this client files with BSI Online (City of Boca Raton) and line 27 is on its work, but nothing files BSI reports yet, so these visits are kept out of the Miami-Dade queue and filed by no one',
                   'what_to_do', 'Yan: file this client''s grease trap reports on BSI Online by hand (the BSI bot is not built yet). If the client is not in the City of Boca Raton program (no BSI record), take line 27 off its job.')
            from public.clients c
           where c.id in (select l.client_id from l27 l)
             and public.fn_client_files_with_bsi(c.id)
             and not exists (select 1 from public.v_non_customer_clients n where n.client_id = c.id)) x;
  if jsonb_array_length(rc) > 0 then attn := true; reasons := reasons || rc; end if;
$blk$;
  execute left(d, i - 1) || b || substr(d, j);
end $edit$;

-- VERIFY
do $verify$
declare v_old jsonb; v_new jsonb; v_n int; v_spe bigint; v_gro bigint;
begin
  -- the edits landed
  if position('public.fn_city_is_boca_raton(p.city)' in (select prosrc from pg_proc where oid = 'public.fn_client_files_with_bsi(bigint)'::regprocedure)) = 0
     or position('bsi_route_unfiled' in (select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) = 0
     or position('lower(btrim(' in (select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) > 0 then
    raise exception 'route alerts VERIFY: an edit did not land';
  end if;

  -- the helper's spellings
  if not (public.fn_city_is_boca_raton('Boca Raton') and public.fn_city_is_boca_raton('  BOCA RATON  ')
          and public.fn_city_is_boca_raton('Boca Raton, FL') and public.fn_city_is_boca_raton('Boca' || chr(160) || 'Raton')
          and public.fn_city_is_boca_raton('boca-raton'))
     or public.fn_city_is_boca_raton('Boca') or public.fn_city_is_boca_raton('West Boca Raton')
     or public.fn_city_is_boca_raton('Delray Beach') or public.fn_city_is_boca_raton('') or public.fn_city_is_boca_raton(null) then
    raise exception 'route alerts VERIFY: fn_city_is_boca_raton reads a spelling wrongly';
  end if;

  -- grants
  if exists (select 1 from _r_acl_before x join pg_proc p on p.oid = x.oid where p.proacl::text is distinct from x.acl) then
    raise exception 'route alerts VERIFY: the rule''s or the logger''s grants changed';
  end if;
  if has_function_privilege('anon', 'public.fn_city_is_boca_raton(text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.fn_city_is_boca_raton(text)', 'EXECUTE')
     or has_function_privilege('service_role', 'public.fn_city_is_boca_raton(text)', 'EXECUTE') then
    raise exception 'route alerts VERIFY: an API role can run fn_city_is_boca_raton';
  end if;

  -- today: the routed set and the health reasons do not move
  if not exists (select 1 from _r_routed_before where 357 = any (ids)) then
    raise exception 'route alerts VERIFY: CONTROL FAILED, the routed set before was empty or lacked Grove Kosher (357)';
  end if;
  if (select array_agg(c.id order by c.id) from public.clients c where public.fn_client_files_with_bsi(c.id))
     is distinct from (select ids from _r_routed_before) then
    raise exception 'route alerts VERIFY: the routed set moved today';
  end if;
  begin
    perform pg_temp._old_log_rpa_derm_health();
    select s.details -> 'reasons' into v_old from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if v_old is distinct from v_new then raise exception 'route alerts VERIFY: today''s health reasons changed: % -> %', v_old, v_new; end if;
    if v_new::text like '%bsi_route_%' then raise exception 'route alerts VERIFY: a bsi_route item fires today: %', v_new; end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (1) a "Boca Raton, FL" property routes a client with no GDO (023-GRO); the old rule does not
  begin
    select c.id into v_gro from public.clients c where c.client_code = '023-GRO';
    update public.properties set city = 'Boca Raton, FL' where client_id = v_gro and deleted_at is null;
    get diagnostics v_n = row_count;
    if v_n = 0 then raise exception 'route alerts VERIFY: fixture 023-GRO has no live property'; end if;
    if pg_temp._old_fn_client_files_with_bsi(v_gro) then raise exception 'route alerts VERIFY: CONTROL FAILED, the old rule routed "Boca Raton, FL"'; end if;
    if not public.fn_client_files_with_bsi(v_gro) then raise exception 'route alerts VERIFY: the new rule did not route "Boca Raton, FL"'; end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (2) invoice-only line 27 (222-SPE: a live GDO, line 27 on visit 6791's invoice) and a Boca Raton property
  begin
    select c.id into v_spe from public.clients c where c.client_code = '222-SPE';
    if not public.fn_visit_is_gdo_reporting(6791) or exists (select 1 from public.jobs j join public.line_items li on li.job_id = j.id and li.visit_id is null
                                                               where j.client_id = v_spe and public.fn_line_item_is_gdo_reporting(li.name)
                                                                 and j.job_status not in ('archived', 'destroyed')) then
      raise exception 'route alerts VERIFY: fixture 222-SPE is not invoice-only line 27 any more';
    end if;
    update public.properties set city = 'Boca Raton' where id = 8 and client_id = v_spe;
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'route alerts VERIFY: fixture property 8 of 222-SPE not found'; end if;
    perform pg_temp._old_log_rpa_derm_health();
    select s.details -> 'reasons' into v_old from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if v_old::text like '%bsi_route_%' then raise exception 'route alerts VERIFY: CONTROL FAILED, the old body saw invoice-only line 27'; end if;
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if not exists (select 1 from jsonb_array_elements(v_new) e where e ->> 'kind' = 'bsi_route_gdo_and_boca:' || v_spe) then
      raise exception 'route alerts VERIFY: invoice-only line 27 did not raise the GDO + Boca Raton item: %', v_new;
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (3) a "Boca Raton, FL" property on 041-MB (client 10: a live GDO, line 27 on an open job)
  begin
    update public.properties set city = 'Boca Raton, FL' where id = 138 and client_id = 10;
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'route alerts VERIFY: fixture property 138 of client 10 not found'; end if;
    perform pg_temp._old_log_rpa_derm_health();
    select s.details -> 'reasons' into v_old from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if v_old::text like '%bsi_route_%' then raise exception 'route alerts VERIFY: CONTROL FAILED, the old body read "Boca Raton, FL"'; end if;
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if not exists (select 1 from jsonb_array_elements(v_new) e where e ->> 'kind' = 'bsi_route_gdo_and_boca:10') then
      raise exception 'route alerts VERIFY: "Boca Raton, FL" did not raise the GDO + Boca Raton item: %', v_new;
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (4) line 27 on a Grove Kosher visit (357, Boca Raton only): one unfiled item, no other-city item
  begin
    insert into public.line_items (visit_id, name, quantity, unit_price, total_price) values (8621, '27 - GDO Online Reporting', 1, 0, 0);
    if not public.fn_visit_is_gdo_reporting(8621) then raise exception 'route alerts VERIFY: fixture visit 8621 is not GDO-reporting'; end if;
    -- the new body first: ops.v_health_items takes the latest row by started_at, and every row of this transaction
    -- carries the same now(), so a second logger run before the check would make the pick arbitrary
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if not exists (select 1 from jsonb_array_elements(v_new) e where e ->> 'kind' = 'bsi_route_unfiled:357')
       or exists (select 1 from jsonb_array_elements(v_new) e where e ->> 'kind' like 'bsi_route_other_city:%' or e ->> 'kind' like 'bsi_route_gdo_and_boca:%') then
      raise exception 'route alerts VERIFY: Grove''s visit line 27 did not raise exactly the unfiled item: %', v_new;
    end if;
    if (select count(*) from ops.v_health_items where check_name = 'rpa-derm-health' and item_key = 'bsi_route_unfiled:357') <> 1 then
      raise exception 'route alerts VERIFY: the unfiled item is not one health item';
    end if;
    perform pg_temp._old_log_rpa_derm_health();
    select s.details -> 'reasons' into v_old from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if v_old::text like '%bsi_route_%' then raise exception 'route alerts VERIFY: CONTROL FAILED, the old body raised a routing item for Grove'; end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- (5) client 245 (routed, a "Beverly Hills" property): line 27 on job 962, reopened for the test
  begin
    update public.jobs set job_status = 'upcoming' where id = 962 and client_id = 245;
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'route alerts VERIFY: fixture job 962 of client 245 not found'; end if;
    insert into public.line_items (job_id, name, quantity, unit_price, total_price) values (962, '27 - GDO Online Reporting', 1, 0, 0);
    perform public.log_rpa_derm_health();
    select s.details -> 'reasons' into v_new from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1;
    if not exists (select 1 from jsonb_array_elements(v_new) e where e ->> 'kind' = 'bsi_route_other_city:245')
       or not exists (select 1 from jsonb_array_elements(v_new) e where e ->> 'kind' = 'bsi_route_unfiled:245') then
      raise exception 'route alerts VERIFY: client 245 did not raise both the other-city and the unfiled item: %', v_new;
    end if;
    if (select (s.details ->> 'bsi_route_conflicts')::int from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.id desc limit 1) <> 2 then
      raise exception 'route alerts VERIFY: bsi_route_conflicts does not count both items';
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;
end $verify$;

-- the controls are temp objects of this session: drop them, so a reused connection cannot meet them again
drop function pg_temp._old_fn_client_files_with_bsi(bigint);
drop function pg_temp._old_log_rpa_derm_health();

commit;
