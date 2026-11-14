-- =============================================================================
-- 2026-11-14_0155_derm_get_manifest_dialog.sql
--
-- WHAT: derm.get_manifest_dialog(p_number text), ONE new read (B2 of the Client App move): everything the manifest
--       dialog (M2) shows for one ticket, the manifest number every page links. It returns jsonb, or null when no live
--       manifest row carries that number:
--   number           the number asked for
--   row_states       the ticket's entries of the Manifests list, as derm.fn_manifest_row_states_core() gives them (the
--                    IC1 icons and their tooltips: papers, stamps, copies, city, visit, sheets). Keyed by the list's row
--                    key, so a Miami-Dade and a Broward ticket that share digits would come as two keys (none today)
--   clients          one entry per live manifest row with that number (one client on the ticket), by client code:
--     manifest_id, client_id, client_code, client_name, white_manifest_number, yellow_ticket_number
--     service_date, dump_ticket_date, dump_site, sheet_no
--     papers         manifest_urls, sheet_urls (the address sheet pages, in order), receipt_path, fog_manifest_url, as
--                    stored on the row (they differ between the rows of 5 tickets today, so each row keeps its own)
--     permits        the client's live GDO permit numbers, by the list rule (ACTIVE, type GDO, GDO-<digits>), never the
--                    row's stored gdo_id (frozen since 2026-11-14_0100)
--     stamp          the stamp cards of this row (derm.address_row_map by matched_manifest_id): cards, placed, last_placed_at
--     copies         the client's copies (derm.redacted_manifest_docs, which the browser cannot read): url, page, made_at
--     client_emails  the copies emailed to the client (public.v_client_email_sends): sent_at, sent_by_name, to_count,
--                    with_photos and the delivery state as that view gives it. No address (B3 has them)
--     visits         the live visits linked to the row, by date: visit_id, visit_date, visit_status, service_type,
--                    arrived_at, duration_minutes, property_id, site, city, crew [{name, color}], truck {name, color},
--                    job_number, invoice_number,
--                    city {state, sends: [...]} (public.v_visit_city_email_state and public.v_visit_city_email_sends,
--                    whose rules decide; never computed here), county_report {needed, report_state, filed: [...]}
--                    (derm.gdo_report_status; derm.visit_gdo_report with screenshot_path)
--   No gallons: this read may not touch the truck tank views (Z8, it lives in derm). The dialog asks
--   public.get_pumping_figures(null, <the visit ids>) for them. derm.manifests.gallons is always null, so it is not read.
--
-- WHY: Fred, 2026-11-14 about 12:40 AM ET, on the Client App move plan: "AA to FF all yes, and all defaults".
--      Decision 4: the manifest dialog everywhere (the Clients pages, the DERM visit page, the delivery section,
--      Manifests Health, Stamp), in the same publish. Pick BB: it opens for a person with the Client App alone. Today a
--      browser cannot read the client copies, and the row states answer to the DERM Tracker setting only.
--      Plan: Building Apps/Ops Portal/docs/specs/2026-11-13-client-app-move-plan.md, B2, decision 4.
--
-- READ ONLY. No table, view, trigger or row is touched; nothing existing changes. RULE 8, AUDIT: no table.
-- ACCESS: SECURITY DEFINER, search_path '', STABLE. Gate: hr.fn_require_any_app(array['client_app', 'derm_tracker',
--   'stamp_studio'], 'view') (the three apps that open the dialog), then the staff check. EXECUTE revoked from PUBLIC,
--   anon and service_role by name, granted to authenticated only. It returns client names and codes, staff names, file
--   addresses and dates: what the three apps already show. No client email address, phone, lock box, code or note
--   text. A sender is named as public.v_client_email_sends and public.v_visit_city_email_sends name it (the staff
--   name, or the sender's own address when no staff row matches it, which no send does today).
-- COST: the row states core reads every ticket (about 0.15 s); the rest is per ticket.
-- UNDO: 2026-11-14_rollback_derm_get_manifest_dialog.sql (drops this one function). The undo of
--   2026-11-14_0135 refuses while this function exists: it reads the core.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if to_regprocedure('derm.get_manifest_dialog(text)') is not null then
    raise exception 'derm.get_manifest_dialog exists already; stop';
  end if;
  if to_regprocedure('derm.fn_manifest_row_states_core()') is null then
    raise exception 'derm.fn_manifest_row_states_core() is missing: apply 2026-11-14_0135 first';
  end if;
end
$pin$;

create function derm.get_manifest_dialog(p_number text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $fn$
declare
  v_num text := btrim(coalesce(p_number, ''));
  v_ids bigint[];
  v_out jsonb;
begin
  -- The gate of the pages that open the dialog (pick BB): the Client App, the DERM Tracker or Stamp Studio, at View.
  perform hr.fn_require_any_app(array['client_app', 'derm_tracker', 'stamp_studio'], 'view');
  if nullif(current_setting('request.jwt.claims', true), '') is not null
     and coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    if auth.uid() is null then
      raise exception 'authentication required' using errcode = '28000';
    end if;
    if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))) then
      raise exception 'not a staff account' using errcode = '42501';
    end if;
  end if;

  select array_agg(dm.id order by dm.id) into v_ids
    from public.derm_manifests dm
   where dm.deleted_at is null and v_num <> '' and coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_num;
  if v_ids is null then
    return null;
  end if;

  with m as materialized (
    select dm.*, c.client_code, c.name as client_name
      from public.derm_manifests dm
      left join public.clients c on c.id = dm.client_id
     where dm.id = any (v_ids)
  ), lv as materialized (
    select mv.manifest_id, v.*
      from public.manifest_visits mv
      join public.visits v on v.id = mv.visit_id and v.deleted_at is null
     where mv.manifest_id = any (v_ids)
  ), vis as (
    select lv.manifest_id, lv.visit_date, lv.id,
           jsonb_build_object(
             'visit_id', lv.id,
             'visit_date', lv.visit_date,
             'visit_status', lv.visit_status,
             'service_type', lv.service_type,
             'arrived_at', lv.actual_arrival_at,
             'duration_minutes', lv.duration_minutes,
             'property_id', lv.property_id,
             'site', (select coalesce(nullif(btrim(p.name), ''), p.address) from public.properties p where p.id = lv.property_id),
             'city', (select p.city from public.properties p where p.id = lv.property_id),
             'crew', (select coalesce(jsonb_agg(jsonb_build_object('name', e.full_name, 'color', e.color_hex) order by e.full_name), '[]'::jsonb)
                        from public.visit_team vt join public.employees e on e.id = vt.employee_id where vt.visit_id = lv.id),
             'truck', (select jsonb_build_object('name', ve.name, 'color', ve.color_hex) from public.vehicles ve where ve.id = lv.vehicle_id),
             'job_number', (select j.job_number from public.jobs j where j.id = lv.job_id),
             'invoice_number', (select i.invoice_number from public.invoices i where i.id = lv.invoice_id),
             'city_email', jsonb_build_object(
               'state', (select s.state from public.v_visit_city_email_state s where s.visit_id = lv.id),
               'sends', (select coalesce(jsonb_agg(jsonb_build_object('sent_at', cs.sent_at, 'via', cs.via, 'app_label', cs.app_label,
                                                                     'sent_by_name', cs.sent_by_name, 'with_manifest', cs.with_manifest,
                                                                     'with_photos', cs.with_photos, 'delivery_status', cs.delivery_status,
                                                                     'delivery_at', cs.delivery_at, 'delivery_detail', cs.delivery_detail)
                                                   order by cs.sent_at), '[]'::jsonb)
                           from public.v_visit_city_email_sends cs where cs.visit_id = lv.id)),
             'county_report', jsonb_build_object(
               'needed', exists (select 1 from derm.gdo_report_status g where g.visit_id = lv.id),
               'report_state', (select g.report_state from derm.gdo_report_status g where g.visit_id = lv.id limit 1),
               'filed', (select coalesce(jsonb_agg(jsonb_build_object('status', r.status, 'gdo_number', r.gdo_number,
                                                                      'attempted_at', r.attempted_at, 'is_manual', r.is_manual,
                                                                      'portal_confirmation', r.portal_confirmation,
                                                                      'screenshot_path', r.screenshot_path,
                                                                      'screenshot_missing_reason', r.screenshot_missing_reason)
                                                   order by r.attempted_at desc), '[]'::jsonb)
                           from derm.visit_gdo_report r where r.visit_id = lv.id))
           ) as j
      from lv
  ), core as (
    select derm.fn_manifest_row_states_core() as j
  )
  select jsonb_build_object(
    'number', v_num,
    'row_states', (select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb)
                     from core cross join lateral jsonb_each(core.j) e
                    where exists (select 1 from jsonb_array_elements_text(e.value -> 'manifest_ids') i where i.value::bigint = any (v_ids))),
    'clients', (select jsonb_agg(jsonb_build_object(
        'manifest_id', m.id,
        'client_id', m.client_id,
        'client_code', m.client_code,
        'client_name', m.client_name,
        'white_manifest_number', m.white_manifest_number,
        'yellow_ticket_number', m.yellow_ticket_number,
        'service_date', m.service_date,
        'dump_ticket_date', m.dump_ticket_date,
        'dump_site', (select f.name from public.disposal_facilities f where f.id = m.disposal_facility_id),
        'sheet_no', m.derm_address_no,
        'papers', jsonb_build_object(
          'manifest_urls', to_jsonb(array_remove(array[m.derm_manifest_url] || coalesce(m.derm_manifest_extra_urls, '{}'::text[]), null)),
          'sheet_urls', to_jsonb(array_remove(array[m.derm_address_url] || coalesce(m.derm_address_extra_urls, '{}'::text[]), null)),
          'receipt_path', m.wwtp_receipt_document_path,
          'fog_manifest_url', m.fog_manifest_url),
        'permits', (select coalesce(jsonb_agg(distinct g.gdo_number order by g.gdo_number), '[]'::jsonb)
                      from public.gdos g
                     where g.client_id = m.client_id and g.status = 'ACTIVE' and g.permit_type = 'GDO' and g.gdo_number ~ '^GDO-[0-9]+$'),
        'stamp', (select jsonb_build_object('cards', count(*), 'placed', count(*) filter (where a.stamp_placed_at is not null),
                                            'last_placed_at', max(a.stamp_placed_at))
                    from derm.address_row_map a where a.matched_manifest_id = m.id),
        'copies', (select coalesce(jsonb_agg(jsonb_build_object('url', d.url, 'page', d.effective_page, 'made_at', d.generated_at)
                                             order by d.effective_page), '[]'::jsonb)
                     from derm.redacted_manifest_docs d where d.manifest_id = m.id and d.client_id = m.client_id),
        'client_emails', (select coalesce(jsonb_agg(jsonb_build_object('sent_at', s.sent_at, 'sent_by_name', s.sent_by_name,
                                                                       'to_count', s.to_count, 'with_photos', s.with_photos,
                                                                       'delivery_status', s.delivery_status, 'delivery_at', s.delivery_at,
                                                                       'delivery_detail', s.delivery_detail)
                                                    order by s.sent_at), '[]'::jsonb)
                            from public.v_client_email_sends s where s.manifest_id = m.id and s.client_id = m.client_id),
        'visits', (select coalesce(jsonb_agg(vis.j order by vis.visit_date, vis.id), '[]'::jsonb) from vis where vis.manifest_id = m.id))
      order by m.client_code nulls last, m.id) from m))
    into v_out;

  return v_out;
end
$fn$;

revoke all on function derm.get_manifest_dialog(text) from public, anon, service_role;
grant execute on function derm.get_manifest_dialog(text) to authenticated;

notify pgrst, 'reload schema';

do $verify$
declare
  v_sig constant text := 'derm.get_manifest_dialog(text)';
  v_role text; v_uid uuid; v_email text; v_res jsonb; v_full jsonb; v_state text; v_msg text; v_bad bigint; v_n int := 0;
  v_num text;
  r record;
begin
  -- 1. Who may run it.
  foreach v_role in array array['public', 'anon', 'service_role'] loop
    if has_function_privilege(v_role, v_sig, 'execute') then raise exception 'verify_fail: % can execute', v_role; end if;
  end loop;
  if not has_function_privilege('authenticated', v_sig, 'execute') then raise exception 'verify_fail: authenticated cannot execute'; end if;
  if not (select p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'verify_fail: not SECURITY DEFINER, STABLE, with an empty search_path';
  end if;
  -- Z8: nothing in derm may name a truck tank view.
  if (select p.prosrc ~* 'tank_|vehicle_stop|water_balance|water_ledger|vehicle_dumps' from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'verify_fail: the function names a truck tank object';
  end if;

  -- 2. A signed-in person with none of the three apps is refused with the access sentence.
  for r in
    select u.id, u.email
      from public.employees e
      join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
     where e.status = 'ACTIVE' and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until <= now())
     order by (e.access_level = 'field') desc, e.id
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', r.id, 'email', r.email, 'role', 'authenticated')::text, true);
    if hr.fn_app_level('client_app') = 'none' and hr.fn_app_level('derm_tracker') = 'none' and hr.fn_app_level('stamp_studio') = 'none' then
      v_uid := r.id; v_email := r.email; exit;
    end if;
  end loop;
  if v_uid is null then raise exception 'verify_fail: no signed-in person without the three apps to test the refusal with'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    v_res := derm.get_manifest_dialog('111111');
    v_state := 'no error';
  exception when others then
    v_state := sqlstate; v_msg := sqlerrm;
  end;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_state is distinct from '42501' or v_msg not like 'You do not have access to do this.%' then
    raise exception 'verify_fail: a person without the three apps was not refused (% %)', v_state, v_msg;
  end if;

  -- 3. The tickets of 112-YA, the 8 tickets with the most rows and the 4 newest Broward tickets (the rehearsal runs every
  --    ticket): one client entry per live row with its number, each with its visits, copies and emails exactly as their
  --    sources hold them, and the ticket's entries of the row states exactly the core's.
  v_full := derm.fn_manifest_row_states_core();
  for v_num in
    (select distinct coalesce(dm.white_manifest_number, dm.yellow_ticket_number) from public.derm_manifests dm
      where dm.deleted_at is null and dm.client_id = 381 and coalesce(dm.white_manifest_number, dm.yellow_ticket_number) is not null)
    union
    (select coalesce(dm.white_manifest_number, dm.yellow_ticket_number) from public.derm_manifests dm
      where dm.deleted_at is null and coalesce(dm.white_manifest_number, dm.yellow_ticket_number) is not null
      group by 1 order by count(*) desc, 1 limit 8)
    union
    (select coalesce(dm.white_manifest_number, dm.yellow_ticket_number) from public.derm_manifests dm
      where dm.deleted_at is null and coalesce(dm.yellow_ticket_number, '') <> ''
      group by 1 order by max(dm.dump_ticket_date) desc nulls last, 1 limit 4)
  loop
    v_res := derm.get_manifest_dialog(v_num);
    if v_res is null then raise exception 'verify_fail: ticket %: no answer', v_num; end if;
    select count(*) into v_bad from (
      select (c ->> 'manifest_id')::bigint as id from jsonb_array_elements(v_res -> 'clients') c
      except
      select dm.id from public.derm_manifests dm where dm.deleted_at is null and coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_num) q;
    if v_bad <> 0 or jsonb_array_length(v_res -> 'clients') <> (select count(*) from public.derm_manifests dm
         where dm.deleted_at is null and coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_num) then
      raise exception 'verify_fail: ticket %: the clients are not its live rows', v_num;
    end if;
    select count(*) into v_bad from jsonb_array_elements(v_res -> 'clients') c
     where jsonb_array_length(c -> 'visits') <> (select count(*) from public.manifest_visits mv join public.visits v on v.id = mv.visit_id and v.deleted_at is null
                                                  where mv.manifest_id = (c ->> 'manifest_id')::bigint)
        or jsonb_array_length(c -> 'copies') <> (select count(*) from derm.redacted_manifest_docs d
                                                  where d.manifest_id = (c ->> 'manifest_id')::bigint and d.client_id = (c ->> 'client_id')::bigint)
        or jsonb_array_length(c -> 'client_emails') <> (select count(*) from public.v_client_email_sends s
                                                         where s.manifest_id = (c ->> 'manifest_id')::bigint and s.client_id = (c ->> 'client_id')::bigint)
        or exists (select 1 from jsonb_array_elements(c -> 'visits') v
                    where (v -> 'city_email' ->> 'state') is distinct from (select s.state from public.v_visit_city_email_state s where s.visit_id = (v ->> 'visit_id')::bigint)
                       or jsonb_array_length(v -> 'city_email' -> 'sends') <> (select count(*) from public.v_visit_city_email_sends cs where cs.visit_id = (v ->> 'visit_id')::bigint)
                       or jsonb_array_length(v -> 'county_report' -> 'filed') <> (select count(*) from derm.visit_gdo_report g where g.visit_id = (v ->> 'visit_id')::bigint));
    if v_bad <> 0 then raise exception 'verify_fail: ticket %: % clients differ from their sources', v_num, v_bad; end if;
    select count(*) into v_bad from (
      select e.key, e.value from jsonb_each(v_full) e
       where exists (select 1 from jsonb_array_elements_text(e.value -> 'manifest_ids') i
                       join public.derm_manifests dm on dm.id = i.value::bigint
                      where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_num and dm.deleted_at is null)
      except
      select e.key, e.value from jsonb_each(v_res -> 'row_states') e) q;
    if v_bad <> 0 or (select count(*) from jsonb_object_keys(v_res -> 'row_states')) = 0
       or (select count(*) from jsonb_object_keys(v_res -> 'row_states')) <> (
            select count(*) from jsonb_each(v_full) e
             where exists (select 1 from jsonb_array_elements_text(e.value -> 'manifest_ids') i
                             join public.derm_manifests dm on dm.id = i.value::bigint
                            where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_num and dm.deleted_at is null)) then
      raise exception 'verify_fail: ticket %: the row states are not the core''s', v_num;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n < 12 then raise exception 'verify_fail: only % tickets checked', v_n; end if;
  if derm.get_manifest_dialog('no such number') is not null or derm.get_manifest_dialog('') is not null or derm.get_manifest_dialog(null) is not null then
    raise exception 'verify_fail: a number with no row gets an answer';
  end if;

  raise notice 'verify ok: % tickets checked', v_n;
end $verify$;

COMMIT;
