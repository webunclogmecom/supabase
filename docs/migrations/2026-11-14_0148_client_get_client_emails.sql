-- =============================================================================
-- 2026-11-14_0148_client_get_client_emails.sql
--
-- WHAT: client.get_client_emails(p_client_id bigint, p_address text default null), ONE new read (B3 of the Client App
--       move): the emails that went out for one client, to the client and to the city, newest first; with p_address,
--       only those sent to that address (a contact's Activity). It returns jsonb {"emails": [...]}, each email with:
--         source, send_id            the record (public.derm_email_sends or public.visit_photo_email_sends) and its id
--         kind                       "client" or "city"
--         sent_at                    when it went out
--         sent_by_email, sent_by_name  who sent it, as recorded (the name from public.employees; null when not recorded)
--         via                        derm_tracker, admin_review or automatic, read from public.v_visit_city_email_sends
--                                    for a city email of a linked visit (that view owns the rule); otherwise null
--         to, cc, bcc                the addresses as recorded; cc and bcc are null when they were not recorded (before
--                                    2026-08-28) and [] when there were none
--         manifest_ids, manifest_numbers, visit_id   what the email was about
--         with_photos                as recorded
--         copies                     the client's copies we hold of those manifests (derm.redacted_manifest_docs: url,
--                                    page, made_at). We do not keep the email's text (decision 10): nothing here is one.
--         resend_email_id            Resend's id
--         delivery_status, delivery_at, delivery_detail   from public.v_email_delivery, which owns the delivery rules
--                                    (never computed here)
--         matched_as                 with p_address: "to", "cc" or "bcc"
--
-- WHY: Fred, 2026-11-14 about 12:40 AM ET, on the Client App move plan: "AA to FF all yes, and all defaults". The
--      Compliance tab's "Emails to the client" inbox (To, Cc, Bcc, the attachment we hold, the delivery chip), the
--      Activity's emails, and a contact's Activity. Today the browser reads the delivery state but not To, Cc and Bcc
--      (public.derm_email_sends and public.visit_photo_email_sends refuse it), nor the client's copies
--      (derm.redacted_manifest_docs). Decision 10: the email's text is not kept, and the opened row says so.
--      Plan: Building Apps/Ops Portal/docs/specs/2026-11-13-client-app-move-plan.md, B3.
--
-- WHAT IS AN EMAIL HERE: a record with status 'sent' that is not a test (the rule of public.v_client_email_sends and
--   public.v_visit_city_email_sends); a city email of Admin Review counts for the client of its visit.
-- READ ONLY. No table, view, trigger or row is touched; nothing existing changes. RULE 8, AUDIT: no table.
-- ACCESS: SECURITY DEFINER, search_path '', STABLE. Gate: hr.fn_require_any_app(array['client_app', 'derm_tracker'],
--   'view') then the staff check. EXECUTE revoked from PUBLIC, anon and service_role by name, granted to authenticated only.
--   It returns staff and client email addresses: the people who pass the gate already read the client's contacts.
-- UNDO: 2026-11-14_rollback_client_get_client_emails.sql (drops this one function).
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if to_regprocedure('client.get_client_emails(bigint,text)') is not null then
    raise exception 'client.get_client_emails exists already; stop';
  end if;
end
$pin$;

create function client.get_client_emails(p_client_id bigint, p_address text default null)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $fn$
declare
  v_addr text := lower(btrim(p_address));
  v_out jsonb;
begin
  -- The gate of the pages that show these emails (pick BB): the Client App or the DERM Tracker, at View.
  perform hr.fn_require_any_app(array['client_app', 'derm_tracker'], 'view');
  if nullif(current_setting('request.jwt.claims', true), '') is not null
     and coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    if auth.uid() is null then
      raise exception 'authentication required' using errcode = '28000';
    end if;
    if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))) then
      raise exception 'not a staff account' using errcode = '42501';
    end if;
  end if;
  if p_client_id is null then
    raise exception 'Give a client.' using errcode = '22023';
  end if;
  if p_address is not null and v_addr = '' then
    raise exception 'Give an address, or none for every email of the client.' using errcode = '22023';
  end if;

  with r as materialized (
    select 'derm_email_sends'::text as source, d.id as send_id, d.recipient_type as kind, d.sent_at, d.sent_by_email,
           d.recipient_email, d.cc_emails, d.bcc_emails, d.include_photos, d.resend_email_id,
           case when d.manifest_id is null then '{}'::bigint[] else array[d.manifest_id] end as manifest_ids,
           null::bigint as visit_id
      from public.derm_email_sends d
     where d.client_id = p_client_id and d.status = 'sent' and not coalesce(d.is_test, false)
    union all
    select 'visit_photo_email_sends', s.id, 'city', s.sent_at, s.sent_by_email,
           s.recipient_email, s.cc_emails, s.bcc_emails, s.include_photos, s.resend_email_id,
           coalesce((select array_agg(mv.manifest_id order by mv.manifest_id)
                       from public.manifest_visits mv
                       join public.derm_manifests dm on dm.id = mv.manifest_id and dm.deleted_at is null
                      where mv.visit_id = s.visit_id), '{}'::bigint[]),
           s.visit_id
      from public.visit_photo_email_sends s
      join public.visits v on v.id = s.visit_id
     where v.client_id = p_client_id and s.status = 'sent' and not coalesce(s.is_test, false)
  ), x as (
    select r.*,
           array(select btrim(a) from unnest(string_to_array(coalesce(r.recipient_email, ''), ',')) a
                  where position('@' in a) > 0) as to_list,
           case when v_addr is null then null
                when v_addr in (select lower(btrim(a)) from unnest(string_to_array(coalesce(r.recipient_email, ''), ',')) a) then 'to'
                when v_addr in (select lower(btrim(a)) from unnest(coalesce(r.cc_emails, '{}'::text[])) a) then 'cc'
                when v_addr in (select lower(btrim(a)) from unnest(coalesce(r.bcc_emails, '{}'::text[])) a) then 'bcc'
           end as matched_as
      from r
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'source', x.source,
           'send_id', x.send_id,
           'kind', x.kind,
           'sent_at', x.sent_at,
           'sent_by_email', x.sent_by_email,
           'sent_by_name', (select e.full_name from public.employees e
                             where x.sent_by_email is not null and lower(btrim(e.email)) = lower(btrim(x.sent_by_email))
                             order by e.id limit 1),
           'via', (select c.via from public.v_visit_city_email_sends c
                    where c.source_table = x.source and c.send_id = x.send_id limit 1),
           'to', to_jsonb(x.to_list),
           'cc', to_jsonb(x.cc_emails),
           'bcc', to_jsonb(x.bcc_emails),
           'manifest_ids', to_jsonb(x.manifest_ids),
           'manifest_numbers', (select coalesce(jsonb_agg(distinct coalesce(dm.white_manifest_number, dm.yellow_ticket_number)), '[]'::jsonb)
                                  from public.derm_manifests dm where dm.id = any (x.manifest_ids)),
           'visit_id', x.visit_id,
           'with_photos', x.include_photos,
           'copies', (select coalesce(jsonb_agg(jsonb_build_object('manifest_id', d.manifest_id, 'url', d.url,
                                                                 'page', d.effective_page, 'made_at', d.generated_at)
                                                order by d.manifest_id, d.effective_page), '[]'::jsonb)
                        from derm.redacted_manifest_docs d
                       where d.manifest_id = any (x.manifest_ids) and d.client_id = p_client_id),
           'resend_email_id', x.resend_email_id,
           'delivery_status', ed.delivery_status,
           'delivery_at', ed.delivery_at,
           'delivery_detail', ed.delivery_detail,
           'matched_as', x.matched_as)
         order by x.sent_at desc, x.send_id desc), '[]'::jsonb)
    into v_out
    from x
    left join public.v_email_delivery ed on ed.resend_email_id = x.resend_email_id
   where v_addr is null or x.matched_as is not null;

  return jsonb_build_object('emails', v_out);
end
$fn$;

revoke all on function client.get_client_emails(bigint, text) from public, anon, service_role;
grant execute on function client.get_client_emails(bigint, text) to authenticated;

notify pgrst, 'reload schema';

do $verify$
declare
  v_sig constant text := 'client.get_client_emails(bigint,text)';
  v_role text; v_uid uuid; v_email text; v_res jsonb; v_state text; v_msg text; v_bad bigint; v_client bigint; v_n bigint;
  v_addr text; v_want bigint;
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

  -- 2. A signed-in person with neither the Client App nor the DERM Tracker is refused with the access sentence.
  for r in
    select u.id, u.email
      from public.employees e
      join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
     where e.status = 'ACTIVE' and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until <= now())
     order by (e.access_level = 'field') desc, e.id
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', r.id, 'email', r.email, 'role', 'authenticated')::text, true);
    if hr.fn_app_level('client_app') = 'none' and hr.fn_app_level('derm_tracker') = 'none' then v_uid := r.id; v_email := r.email; exit; end if;
  end loop;
  if v_uid is null then raise exception 'verify_fail: no signed-in person without both apps to test the refusal with'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    v_res := client.get_client_emails(381);
    v_state := 'no error';
  exception when others then
    v_state := sqlstate; v_msg := sqlerrm;
  end;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_state is distinct from '42501' or v_msg not like 'You do not have access to do this.%' then
    raise exception 'verify_fail: a person without both apps was not refused (% %)', v_state, v_msg;
  end if;

  -- 3. Every client that has sent emails: one entry per sent record that is not a test, each with its delivery state
  --    exactly as public.v_email_delivery gives it; the client emails are exactly public.v_client_email_sends' rows.
  v_n := 0;
  for v_client in
    select d.client_id from public.derm_email_sends d where d.status = 'sent' and not coalesce(d.is_test, false) and d.client_id is not null
    union
    select v.client_id from public.visit_photo_email_sends s join public.visits v on v.id = s.visit_id
     where s.status = 'sent' and not coalesce(s.is_test, false) and v.client_id is not null
  loop
    v_res := client.get_client_emails(v_client);
    select (select count(*) from public.derm_email_sends d where d.client_id = v_client and d.status = 'sent' and not coalesce(d.is_test, false))
         + (select count(*) from public.visit_photo_email_sends s join public.visits v on v.id = s.visit_id
             where v.client_id = v_client and s.status = 'sent' and not coalesce(s.is_test, false))
      into v_want;
    if jsonb_array_length(v_res -> 'emails') <> v_want then
      raise exception 'verify_fail: client % gets % emails for % sent records', v_client, jsonb_array_length(v_res -> 'emails'), v_want;
    end if;
    select count(*) into v_bad from jsonb_array_elements(v_res -> 'emails') m
      left join public.v_email_delivery ed on ed.resend_email_id = m ->> 'resend_email_id'
     where m ->> 'kind' not in ('client', 'city')
        or (m ->> 'delivery_status') is distinct from ed.delivery_status
        or (m -> 'delivery_detail') is distinct from ed.delivery_detail
        or jsonb_array_length(m -> 'to') = 0
        or m ? 'text' or m ? 'body' or m ? 'html';
    if v_bad <> 0 then raise exception 'verify_fail: client %: % emails are malformed or their delivery is not the view''s', v_client, v_bad; end if;
    select count(*) into v_bad from (
      select (m ->> 'send_id')::bigint as send_id from jsonb_array_elements(v_res -> 'emails') m where m ->> 'kind' = 'client'
      except
      select s.send_id from public.v_client_email_sends s where s.client_id = v_client) q;
    if v_bad <> 0 or (select count(*) from jsonb_array_elements(v_res -> 'emails') m where m ->> 'kind' = 'client')
                      <> (select count(*) from public.v_client_email_sends s where s.client_id = v_client) then
      raise exception 'verify_fail: client %: the client emails are not the rows of public.v_client_email_sends', v_client;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n < 10 then raise exception 'verify_fail: only % clients with emails checked', v_n; end if;

  -- 4. One address: only the emails that carried it, each saying how; an address nobody got gets none. Two addresses:
  --    the most used To address of a client email, and the most used Bcc address (no email carries a Cc today).
  for v_addr, v_client in
    (select a.addr, a.client_id
       from (select lower(btrim(x)) as addr, d.client_id
               from public.derm_email_sends d cross join lateral unnest(string_to_array(d.recipient_email, ',')) x
              where d.status = 'sent' and not coalesce(d.is_test, false) and d.recipient_type = 'client') a
      group by 1, 2 order by count(*) desc, 1 limit 1)
    union all
    (select a.addr, a.client_id
       from (select lower(btrim(x)) as addr, d.client_id
               from public.derm_email_sends d cross join lateral unnest(d.bcc_emails) x
              where d.status = 'sent' and not coalesce(d.is_test, false)
             union all
             select lower(btrim(x)), v.client_id
               from public.visit_photo_email_sends s join public.visits v on v.id = s.visit_id cross join lateral unnest(s.bcc_emails) x
              where s.status = 'sent' and not coalesce(s.is_test, false)) a
      group by 1, 2 order by count(*) desc, 1 limit 1)
  loop
  v_res := client.get_client_emails(v_client, '  ' || upper(v_addr) || ' ');
  if jsonb_array_length(v_res -> 'emails') = 0
     or exists (select 1 from jsonb_array_elements(v_res -> 'emails') m
                 where m ->> 'matched_as' not in ('to', 'cc', 'bcc')
                    or not exists (select 1 from jsonb_array_elements_text(m -> (m ->> 'matched_as')) t where lower(btrim(t)) = v_addr))
     or jsonb_array_length(v_res -> 'emails') <> (
          select count(*) from public.derm_email_sends d
           where d.client_id = v_client and d.status = 'sent' and not coalesce(d.is_test, false)
             and (v_addr in (select lower(btrim(x)) from unnest(string_to_array(coalesce(d.recipient_email, ''), ',')) x)
                  or v_addr in (select lower(btrim(x)) from unnest(coalesce(d.cc_emails, '{}'::text[])) x)
                  or v_addr in (select lower(btrim(x)) from unnest(coalesce(d.bcc_emails, '{}'::text[])) x)))
        + (select count(*) from public.visit_photo_email_sends s join public.visits v on v.id = s.visit_id
            where v.client_id = v_client and s.status = 'sent' and not coalesce(s.is_test, false)
              and (v_addr in (select lower(btrim(x)) from unnest(string_to_array(coalesce(s.recipient_email, ''), ',')) x)
                   or v_addr in (select lower(btrim(x)) from unnest(coalesce(s.cc_emails, '{}'::text[])) x)
                   or v_addr in (select lower(btrim(x)) from unnest(coalesce(s.bcc_emails, '{}'::text[])) x))) then
    raise exception 'verify_fail: the emails to one address are wrong';
  end if;
  end loop;
  if jsonb_array_length((client.get_client_emails(v_client, 'nobody@example.invalid')) -> 'emails') <> 0 then
    raise exception 'verify_fail: an address nobody got gets emails';
  end if;

  raise notice 'verify ok: % clients with emails checked', v_n;
end $verify$;

COMMIT;
