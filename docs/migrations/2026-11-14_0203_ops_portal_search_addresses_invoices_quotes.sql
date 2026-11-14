-- =============================================================================
-- 2026-11-14_0203_ops_portal_search_addresses_invoices_quotes.sql
--
-- WHAT: ops.portal_search(text), the Ops Portal's "Search everything", gains three groups for a person who has the
--       Client App (B4 of the Client App move, decision 7):
--   properties  a live site whose address, name or city holds the words, or whose ZIP starts with them: id, client_id,
--               code, client_name, name, address, city, zip, is_billing, tab = 'sites', rank
--   invoices    an invoice whose number holds them: id, client_id, code, client_name, invoice_number, status, issued
--               (the day it was sent, Eastern), tab = 'billing', rank
--   quotes      a quote whose number or title holds them: id, client_id, code, client_name, quote_number, title, status,
--               archived (archived ones come last), tab = 'billing', rank
--   At most 5 each, best first (the number itself, then a number that starts with it, then the rest). Each opens its
--   client's page on its tab: /clients/<client_id>?tab=sites&site=<id>, or ?tab=billing.
--   ONE anchored edit of the live body: the new block sits right before the final RETURN. The groups the function had
--   (clients, visits, requests, people) are not touched, and their answers are compared below, term by term.
--
-- WHY: Fred, 2026-11-14 about 12:40 AM ET, on the Client App move plan: "AA to FF all yes, and all defaults".
--      Decision 7: "in the same publish, the portal's search gains the three groups the Client App's search has and the
--      portal's lacks (properties, invoices, quotes) for a person with the Client App. Each opens its client page on
--      the right tab. Without it, moving the Clients item takes away finding a client by an address, an invoice number
--      or a quote number." Plan: Building Apps/Ops Portal/docs/specs/2026-11-13-client-app-move-plan.md, B4, risk 9.
--
-- THE LIVE PORTAL: its search (shell/search.tsx on main, published) reads only the keys clients, visits, requests and
--   people, and counts only those for "Nothing found". New keys are ignored by it until the portal's next publish, so
--   it shows nothing new and nothing breaks. The VERIFY proves the four old keys are unchanged.
-- KEEPS ITS RULES: a group shows only for an app the person can open (the bell's rule, v_closed): these three need the
--   Client App, like the clients group. No email, phone, lock box, note or pay.
-- READ ONLY. SECURITY DEFINER, search_path '', STABLE, grants kept (authenticated, service_role; never anon).
-- RULE 8, AUDIT: no table. Z8: it reads no truck tank object.
-- UNDO: 2026-11-14_rollback_ops_portal_search_addresses_invoices_quotes.sql (puts the 2026-11-05_0230 body back).
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

-- The live body must be the one 2026-11-05_0230 applied. The answers of that body are kept, for every term of a corpus
-- read from the data and for three people (an admin, an office person, one without the Client App), for the comparison
-- at the end.
do $pin$
declare v_term text; r record; v_res jsonb;
begin
  if md5(replace(pg_get_functiondef('ops.portal_search(text)'::regprocedure), chr(13), '')) <> '3ddd56fed24618c59d16ff16c8f4ed4d' then
    raise exception 'ops.portal_search(text) is not the 2026-11-05_0230 body; stop';
  end if;

  create temp table _m5_terms as
  select distinct t as term from (
    select c.client_code as t from (select client_code from public.clients where client_code is not null order by id limit 12) c
    union all select left(c.name, 4) from (select name from public.clients where name is not null order by id desc limit 12) c
    union all select split_part(e.full_name, ' ', 1) from (select full_name from public.employees where status = 'ACTIVE' order by id limit 6) e
    union all select split_part(p.address, ' ', 2) from (select address from public.properties where deleted_at is null and address like '% %' order by id limit 8) p
    union all select left(p.address, 9) from (select address from public.properties where deleted_at is null order by id desc limit 4) p
    union all select i.invoice_number from (select invoice_number from public.invoices where invoice_number is not null order by id desc limit 5) i
    union all select left(i.invoice_number, 3) from (select invoice_number from public.invoices where invoice_number is not null order by id limit 3) i
    union all select q.quote_number from (select quote_number from public.quotes where quote_number is not null order by id desc limit 4) q
    union all select split_part(q.title, ' ', 1) from (select title from public.quotes where title like '% %' order by id limit 3) q
    union all select unnest(array['', 'a', 'zz', '%', '_', '\', '12', 'Miami', 'Doral', repeat('x', 81), '112-YA'])
  ) x where t is not null;

  create temp table _m5_people as
  select * from (
    (select e.id as emp, u.id as uid, u.email from public.employees e join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
      where e.status = 'ACTIVE' and e.access_level = 'admin' and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until <= now())
      order by e.id limit 1)
    union all
    (select e.id, u.id, u.email from public.employees e join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
      where e.status = 'ACTIVE' and e.access_level = 'office' and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until <= now())
      order by e.id limit 1)
    ) p;
  -- the third person: the first active one with a working sign-in who does NOT have the Client App (field people first)
  for r in
    select e.id as emp, u.id as uid, u.email from public.employees e join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
     where e.status = 'ACTIVE' and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until <= now())
     order by (e.access_level = 'field') desc, e.id
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', r.uid, 'email', r.email, 'role', 'authenticated')::text, true);
    if hr.fn_app_level('client_app') = 'none' then
      insert into _m5_people values (r.emp, r.uid, r.email);
      exit;
    end if;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  if (select count(*) from _m5_people) <> 3 then
    raise exception 'three people were wanted for the comparison (an admin, an office person, one without the Client App), found %',
      (select count(*) from _m5_people);
  end if;

  create temp table _m5_old (emp bigint, term text, j jsonb);
  for r in select * from _m5_people loop
    perform set_config('request.jwt.claims', json_build_object('sub', r.uid, 'email', r.email, 'role', 'authenticated')::text, true);
    for v_term in select term from _m5_terms loop
      set local role authenticated;
      v_res := ops.portal_search(v_term);
      reset role;
      insert into _m5_old values (r.emp, v_term, v_res);
    end loop;
  end loop;
  perform set_config('request.jwt.claims', '', true);
end
$pin$;

CREATE OR REPLACE FUNCTION ops.portal_search(p_q text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_access jsonb := hr.get_my_access();
  v_q text := btrim(coalesce(p_q, ''));
  v_like text;
  v_closed text[];
  v_calendar boolean;
  v_clients boolean;
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
  v_found jsonb := '[]'::jsonb;
  v_ids bigint[] := '{}';
  v_out jsonb := '{}'::jsonb;
BEGIN
  IF v_access IS NULL OR v_access->>'employee_id' IS NULL OR length(v_q) < 2 OR length(v_q) > 80 THEN
    RETURN v_out;
  END IF;

  SELECT coalesce(array_agg(a->>'app'), '{}'::text[]) INTO v_closed
    FROM jsonb_array_elements(coalesce(v_access->'apps', '[]'::jsonb)) a
   WHERE a->>'mode' = 'on' AND coalesce(a->>'level', 'none') NOT IN ('view', 'edit');

  v_calendar := NOT 'visit_calendar' = ANY (v_closed);
  v_clients := NOT 'client_app' = ANY (v_closed);
  v_like := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');

  IF v_calendar OR v_clients THEN
    SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.rank, x.inactive, x.code), '[]'::jsonb),
           coalesce(array_agg(x.id ORDER BY x.rank, x.inactive, x.code), '{}'::bigint[])
      INTO v_found, v_ids
      FROM (
        SELECT c.id, c.client_code AS code, c.name, c.status,
               CASE WHEN lower(c.client_code) = lower(v_q) THEN 0
                    WHEN c.client_code ILIKE v_like || '%' THEN 1
                    WHEN c.name ILIKE v_like || '%' THEN 2
                    ELSE 3 END AS rank,
               c.status = 'INACTIVE' AS inactive
          FROM public.clients c
         WHERE c.client_code ILIKE '%' || v_like || '%' OR c.name ILIKE '%' || v_like || '%'
         ORDER BY rank, inactive, c.client_code
         LIMIT 6
      ) x;
    v_out := v_out || jsonb_build_object('clients', v_found);
  END IF;

  IF v_calendar AND cardinality(v_ids) > 0 THEN
    -- The next visit of the first 3 clients found, or the last one when none is coming.
    v_out := v_out || jsonb_build_object('visits', (
      SELECT coalesce(jsonb_agg(to_jsonb(y) ORDER BY array_position(v_ids, y.client_id)), '[]'::jsonb)
        FROM (
          SELECT DISTINCT ON (v.client_id)
                 v.id, v.client_id, v.client_code, v.client_name, v.visit_date, v.start_at, v.is_all_day,
                 coalesce(v.service_label, v.service_type) AS service, v.truck_name AS truck, v.driver_name AS driver,
                 CASE WHEN v.visit_date >= v_today THEN 'next' ELSE 'last' END AS kind
            FROM ops.v_calendar_visit v
           WHERE v.client_id = ANY (v_ids[1:3])
             AND ((v.visit_date >= v_today AND v.visit_status = 'scheduled')
               OR (v.visit_date < v_today AND v.visit_status = 'completed'))
           ORDER BY v.client_id,
                    (v.visit_date >= v_today) DESC,
                    CASE WHEN v.visit_date >= v_today THEN v.visit_date END ASC,
                    v.visit_date DESC,
                    v.start_at
        ) y));
    v_out := v_out || jsonb_build_object('requests', (
      SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY array_position(v_ids, z.client_id), z.age_days DESC), '[]'::jsonb)
        FROM (
          SELECT r.id, r.client_id, r.client_code, r.client_name, r.service_summary AS service, r.age_days, r.call_required
            FROM ops.v_visit_requests r
           WHERE r.client_id = ANY (v_ids)
           ORDER BY r.age_days DESC
           LIMIT 4
        ) z));
  END IF;

  IF NOT 'hr' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('people', (
      SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.full_name), '[]'::jsonb)
        FROM (
          SELECT e.id, e.full_name, e.access_level, e.color_hex
            FROM public.employees e
           WHERE e.status = 'ACTIVE' AND e.full_name ILIKE '%' || v_like || '%'
           ORDER BY e.full_name
           LIMIT 4
        ) p));
  END IF;

  -- Addresses, invoices and quotes, for a person who has the Client App (2026-11-14, the Client App move, decision 7).
  -- Each carries what opens its client's page on the right tab: "sites" with the site's id, or "billing". New keys only:
  -- the four groups above are unchanged. No email, phone or pay.
  IF v_clients THEN
    v_out := v_out || jsonb_build_object(
      'properties', (
        SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.rank, p.code, p.address, p.id), '[]'::jsonb)
          FROM (
            SELECT pr.id, pr.client_id, c.client_code AS code, c.name AS client_name, pr.name, pr.address, pr.city, pr.zip,
                   coalesce(pr.is_billing, false) AS is_billing, 'sites' AS tab,
                   CASE WHEN pr.address ILIKE v_like || '%' THEN 0
                        WHEN pr.address ILIKE '%' || v_like || '%' THEN 1
                        ELSE 2 END AS rank
              FROM public.properties pr
              JOIN public.clients c ON c.id = pr.client_id
             WHERE pr.deleted_at IS NULL
               AND (pr.address ILIKE '%' || v_like || '%' OR pr.name ILIKE '%' || v_like || '%'
                    OR pr.city ILIKE '%' || v_like || '%' OR pr.zip ILIKE v_like || '%')
             ORDER BY rank, c.client_code, pr.address, pr.id
             LIMIT 5
          ) p),
      'invoices', (
        SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.rank, i.issued DESC NULLS LAST, i.id DESC), '[]'::jsonb)
          FROM (
            SELECT inv.id, inv.client_id, c.client_code AS code, c.name AS client_name, inv.invoice_number,
                   inv.invoice_status AS status, (inv.sent_at AT TIME ZONE 'America/New_York')::date AS issued,
                   'billing' AS tab,
                   CASE WHEN lower(inv.invoice_number) = lower(v_q) THEN 0
                        WHEN inv.invoice_number ILIKE v_like || '%' THEN 1
                        ELSE 2 END AS rank
              FROM public.invoices inv
              JOIN public.clients c ON c.id = inv.client_id
             WHERE inv.invoice_number ILIKE '%' || v_like || '%'
             ORDER BY rank, issued DESC NULLS LAST, inv.id DESC
             LIMIT 5
          ) i),
      'quotes', (
        SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.rank, q.archived, q.id DESC), '[]'::jsonb)
          FROM (
            SELECT qt.id, qt.client_id, c.client_code AS code, c.name AS client_name, qt.quote_number, qt.title,
                   qt.quote_status AS status, coalesce(qt.quote_status, '') = 'archived' AS archived, 'billing' AS tab,
                   CASE WHEN lower(qt.quote_number) = lower(v_q) THEN 0
                        WHEN qt.quote_number ILIKE v_like || '%' THEN 1
                        WHEN qt.quote_number ILIKE '%' || v_like || '%' THEN 2
                        ELSE 3 END AS rank
              FROM public.quotes qt
              JOIN public.clients c ON c.id = qt.client_id
             WHERE qt.quote_number ILIKE '%' || v_like || '%' OR qt.title ILIKE '%' || v_like || '%'
             ORDER BY rank, archived, qt.id DESC
             LIMIT 5
          ) q));
  END IF;

  RETURN v_out;
END;
$function$;

notify pgrst, 'reload schema';

do $verify$
declare
  v_sig constant text := 'ops.portal_search(text)';
  r record; t record; v_res jsonb; v_bad bigint := 0; v_n bigint := 0; v_clients boolean; v_new int := 0;
  v_addr text; v_pid bigint; v_inv text; v_quo text;
begin
  -- 1. Who may run it: as before.
  if has_function_privilege('anon', v_sig, 'execute') or has_function_privilege('public', v_sig, 'execute') then
    raise exception 'verify_fail: anon or PUBLIC can execute';
  end if;
  if not has_function_privilege('authenticated', v_sig, 'execute') or not has_function_privilege('service_role', v_sig, 'execute') then
    raise exception 'verify_fail: a grant was lost';
  end if;
  if not (select p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'verify_fail: not SECURITY DEFINER, STABLE, with an empty search_path';
  end if;

  -- 2. For every term and every person: the four old groups exactly as before; the three new ones only for a person
  --    who has the Client App and a term of 2 to 80 characters, each with exactly the documented keys.
  for r in select * from _m5_people loop
    perform set_config('request.jwt.claims', json_build_object('sub', r.uid, 'email', r.email, 'role', 'authenticated')::text, true);
    v_clients := hr.fn_app_level('client_app') in ('view', 'edit');
    for t in select o.term, o.j from _m5_old o where o.emp = r.emp loop
      set local role authenticated;
      v_res := ops.portal_search(t.term);
      reset role;
      v_n := v_n + 1;
      if (v_res - 'properties' - 'invoices' - 'quotes') is distinct from t.j then
        raise exception 'verify_fail: the old groups changed for person % and the term %', r.emp, t.term;
      end if;
      if (v_res ? 'properties' or v_res ? 'invoices' or v_res ? 'quotes') is distinct from
         (v_clients and length(btrim(coalesce(t.term, ''))) between 2 and 80) then
        raise exception 'verify_fail: the new groups show when they must not, or not when they must (person %, term %)', r.emp, t.term;
      end if;
      if v_res ? 'properties' then
        v_new := v_new + jsonb_array_length(v_res -> 'properties') + jsonb_array_length(v_res -> 'invoices') + jsonb_array_length(v_res -> 'quotes');
        select count(*) into v_bad from (
          select x from jsonb_array_elements(v_res -> 'properties') x
           where (select array_agg(k order by k) from jsonb_object_keys(x) k)
                 <> array['address', 'city', 'client_id', 'client_name', 'code', 'id', 'is_billing', 'name', 'rank', 'tab', 'zip'] or x ->> 'tab' <> 'sites'
          union all
          select x from jsonb_array_elements(v_res -> 'invoices') x
           where (select array_agg(k order by k) from jsonb_object_keys(x) k)
                 <> array['client_id', 'client_name', 'code', 'id', 'invoice_number', 'issued', 'rank', 'status', 'tab'] or x ->> 'tab' <> 'billing'
          union all
          select x from jsonb_array_elements(v_res -> 'quotes') x
           where (select array_agg(k order by k) from jsonb_object_keys(x) k)
                 <> array['archived', 'client_id', 'client_name', 'code', 'id', 'quote_number', 'rank', 'status', 'tab', 'title'] or x ->> 'tab' <> 'billing') q;
        if v_bad <> 0 then raise exception 'verify_fail: % new results do not have the documented keys (term %)', v_bad, t.term; end if;
      end if;
    end loop;
  end loop;
  if v_n < 150 or v_new = 0 then raise exception 'verify_fail: only % comparisons and % new results', v_n, v_new; end if;

  -- 3. An address, an invoice number and a quote number each find their record, for the admin.
  select p.address, p.id into v_addr, v_pid from public.properties p
   where p.deleted_at is null and length(p.address) between 12 and 80
     and (select count(*) from public.properties p2 where p2.deleted_at is null and p2.address ilike '%' || p.address || '%') = 1
   order by p.id desc limit 1;
  select i.invoice_number into v_inv from public.invoices i where i.invoice_number ~ '^[0-9]+$'
   and (select count(*) from public.invoices i2 where i2.invoice_number = i.invoice_number) = 1 order by i.id desc limit 1;
  select q.quote_number into v_quo from public.quotes q where q.quote_number ~ '^[0-9]+$'
   and (select count(*) from public.quotes q2 where q2.quote_number = q.quote_number) = 1 order by q.id desc limit 1;
  select p.* into r from _m5_people p join public.employees e on e.id = p.emp where e.access_level = 'admin';
  perform set_config('request.jwt.claims', json_build_object('sub', r.uid, 'email', r.email, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_res := ops.portal_search(v_addr);
  if not (v_res -> 'properties') @> jsonb_build_array(jsonb_build_object('id', v_pid, 'tab', 'sites')) then
    reset role; raise exception 'verify_fail: an address does not find its site';
  end if;
  v_res := ops.portal_search(v_inv);
  if (v_res -> 'invoices' -> 0 ->> 'invoice_number') is distinct from v_inv then
    reset role; raise exception 'verify_fail: an invoice number does not find its invoice first';
  end if;
  v_res := ops.portal_search(v_quo);
  if (v_res -> 'quotes' -> 0 ->> 'quote_number') is distinct from v_quo then
    reset role; raise exception 'verify_fail: a quote number does not find its quote first';
  end if;
  reset role;
  perform set_config('request.jwt.claims', '', true);

  drop table _m5_old; drop table _m5_terms; drop table _m5_people;
  raise notice 'verify ok: % comparisons, the old groups unchanged; % new results', v_n, v_new;
end $verify$;

COMMIT;
