-- ============================================================================
-- 2026-09-25_2350 · Atomic invoice- and visit-scoped line-item rewrites for webhook-jobber
-- ============================================================================
-- WHY. webhook-jobber's handleInvoice (and handleVisit) replaced an owner's line items as TWO PostgREST
-- requests: `delete ... where invoice_id = X`, then `insert`. Two transactions, nothing spanning them.
-- Jobber delivers real webhooks in PAIRS (same occurredAt), so two handler runs interleave as
-- delete, delete, insert, insert and the owner keeps a duplicate line until something rewrites it.
-- Seen on 2026-09-25: [TEST] invoice #3248 (id 2836) held 2 identical lines from 21:22:21 until the
-- 21:26:03 poll replay (audit.logs 225074/225076/225077); #3246 the same at 19:44 (122543/122544).
--
-- MEASURED BEFORE THIS CHANGE (2026-09-25 23:30 ET):
--   * group-by (invoice_id, name, unit_price, quantity) having count > 1: 32 groups on 27 invoices,
--     45 extra rows. That number OVERSTATES the defect: compared line by line against Jobber
--     (read-only, API 2026-04-16), 21 of the 27 invoices hold exactly what Jobber holds, i.e. the
--     identical lines are REAL in Jobber and must never be deduplicated DB-side.
--   * 6 invoices hold MORE lines than Jobber, 8 extra rows, every one written on or after
--     2026-08-31 (real webhooks started working 2026-08-21): 2561 (#3065 275-MLP, $349 + $12.32 fee
--     twice), 2629 (#3087 076-TCE, $75 + $0.75 twice), 2722 (#3136 325-OSA), 2755 (#3168 241-WYN),
--     2816 (#3228 112-YA), and 2719 (#3134 323-CHA, since deleted in Jobber).
--   * Pre-fix control: 4 concurrent signed INVOICE_UPDATE replays of invoice 2836, 5 rounds, left 2
--     lines (Jobber has 1) in 3 of 5 rounds.
--
-- WHAT. Two SECURITY DEFINER functions mirroring public.rewrite_job_line_items (which closed the same
-- race for job-scoped lines): take a per-owner transaction advisory lock, delete the owner's lines and
-- insert the new set in ONE transaction. The delete predicate is EXACTLY the one the handler used
-- (`invoice_id = X`, `visit_id = X`), so the set of rows touched does not change, only the atomicity.
-- Two deliberate differences from the job function:
--   * p_lines must be a JSON array (an empty array is a legitimate "no lines"). NULL or any other
--     JSON type RAISES instead of silently deleting every line.
--   * rows are inserted in the array's order (WITH ORDINALITY), so ids follow Jobber's order.
-- Values are inserted as given: no COALESCE, because the handler inserted explicit NULLs.
--
-- RULE 8. No new table. public.line_items keeps audit_line_items (unchanged). The functions write only
-- through that audited table.
-- GRANTS. service_role only (webhook-jobber). Revoked BY NAME from public, anon, authenticated:
-- Supabase's default privileges grant EXECUTE on a new public function to authenticated.
--
-- ROLLBACK: drop function public.rewrite_invoice_line_items(bigint, jsonb);
--           drop function public.rewrite_visit_line_items(bigint, jsonb);
--           (redeploy webhook-jobber at the previous version first; it calls these.)
-- ============================================================================

create or replace function public.rewrite_invoice_line_items(p_invoice_id bigint, p_lines jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if p_invoice_id is null then
    raise exception 'rewrite_invoice_line_items: p_invoice_id is required' using errcode = '22023';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'rewrite_invoice_line_items: p_lines must be a JSON array (got %)', coalesce(jsonb_typeof(p_lines), 'null')
      using errcode = '22023';
  end if;

  -- serialize concurrent rewrites of the SAME invoice; released at transaction end
  perform pg_advisory_xact_lock(hashtextextended('public.rewrite_invoice_line_items', p_invoice_id));

  delete from public.line_items where invoice_id = p_invoice_id;

  insert into public.line_items (invoice_id, name, description, quantity, unit_price, total_price, taxable)
  select p_invoice_id, x.name, x.description, x.quantity, x.unit_price, x.total_price, x.taxable
    from jsonb_array_elements(p_lines) with ordinality as e(v, ord)
    cross join lateral jsonb_to_record(e.v)
      as x(name text, description text, quantity numeric, unit_price numeric, total_price numeric, taxable boolean)
   order by e.ord;
end
$function$;

create or replace function public.rewrite_visit_line_items(p_visit_id bigint, p_lines jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if p_visit_id is null then
    raise exception 'rewrite_visit_line_items: p_visit_id is required' using errcode = '22023';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'rewrite_visit_line_items: p_lines must be a JSON array (got %)', coalesce(jsonb_typeof(p_lines), 'null')
      using errcode = '22023';
  end if;

  -- serialize concurrent rewrites of the SAME visit; released at transaction end
  perform pg_advisory_xact_lock(hashtextextended('public.rewrite_visit_line_items', p_visit_id));

  delete from public.line_items where visit_id = p_visit_id;

  insert into public.line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
  select p_visit_id, x.name, x.description, x.quantity, x.unit_price, x.total_price, x.taxable
    from jsonb_array_elements(p_lines) with ordinality as e(v, ord)
    cross join lateral jsonb_to_record(e.v)
      as x(name text, description text, quantity numeric, unit_price numeric, total_price numeric, taxable boolean)
   order by e.ord;
end
$function$;

revoke all on function public.rewrite_invoice_line_items(bigint, jsonb) from public, anon, authenticated;
revoke all on function public.rewrite_visit_line_items(bigint, jsonb) from public, anon, authenticated;
grant execute on function public.rewrite_invoice_line_items(bigint, jsonb) to service_role;
grant execute on function public.rewrite_visit_line_items(bigint, jsonb) to service_role;

-- VERIFY (rolled back inside a subtransaction: nothing below persists)
do $$
declare
  v_n int; v_names text; v_ok boolean;
begin
  if has_function_privilege('authenticated', 'public.rewrite_invoice_line_items(bigint,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.rewrite_invoice_line_items(bigint,jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public.rewrite_visit_line_items(bigint,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.rewrite_visit_line_items(bigint,jsonb)', 'execute') then
    raise exception 'verify: anon/authenticated can execute a rewrite function';
  end if;
  if not has_function_privilege('service_role', 'public.rewrite_invoice_line_items(bigint,jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.rewrite_visit_line_items(bigint,jsonb)', 'execute') then
    raise exception 'verify: service_role cannot execute a rewrite function';
  end if;

  begin
    -- [TEST] invoice #3248 on 112-YA (id 2836): two lines in order, then one, then an empty array.
    perform public.rewrite_invoice_line_items(2836, '[{"name":"[TEST] a","quantity":1,"unit_price":2,"total_price":2,"taxable":null},{"name":"[TEST] b","quantity":null,"unit_price":null,"total_price":null,"taxable":false}]'::jsonb);
    select count(*), string_agg(name, ',' order by id) into v_n, v_names from public.line_items where invoice_id = 2836;
    if v_n <> 2 or v_names <> '[TEST] a,[TEST] b' then raise exception 'verify: expected 2 ordered lines, got % (%)', v_n, v_names; end if;
    if (select taxable from public.line_items where invoice_id = 2836 and name = '[TEST] a') is not null then
      raise exception 'verify: an explicit NULL was not kept';
    end if;
    perform public.rewrite_invoice_line_items(2836, '[{"name":"[TEST] c","quantity":1,"unit_price":1,"total_price":1,"taxable":false}]'::jsonb);
    select count(*) into v_n from public.line_items where invoice_id = 2836;
    if v_n <> 1 then raise exception 'verify: rewrite did not replace (got %)', v_n; end if;
    perform public.rewrite_invoice_line_items(2836, '[]'::jsonb);
    select count(*) into v_n from public.line_items where invoice_id = 2836;
    if v_n <> 0 then raise exception 'verify: empty array did not clear (got %)', v_n; end if;
    -- a non-array must refuse, not wipe
    v_ok := false;
    begin
      perform public.rewrite_invoice_line_items(2836, '{"name":"x"}'::jsonb);
    exception when sqlstate '22023' then v_ok := true;
    end;
    if not v_ok then raise exception 'verify: a non-array payload was accepted'; end if;
    -- the visit twin, on a soft-deleted 112-YA [TEST] visit (8208, one line today)
    perform public.rewrite_visit_line_items(8208, '[{"name":"[TEST] v1","quantity":1,"unit_price":0,"total_price":0,"taxable":false},{"name":"[TEST] v2","quantity":1,"unit_price":0,"total_price":0,"taxable":false}]'::jsonb);
    select count(*), string_agg(name, ',' order by id) into v_n, v_names from public.line_items where visit_id = 8208;
    if v_n <> 2 or v_names <> '[TEST] v1,[TEST] v2' then raise exception 'verify: visit rewrite expected 2 ordered lines, got % (%)', v_n, v_names; end if;
    v_ok := false;
    begin
      perform public.rewrite_visit_line_items(8208, null);
    exception when sqlstate '22023' then v_ok := true;
    end;
    if not v_ok then raise exception 'verify: a NULL visit payload was accepted'; end if;
    raise exception 'rollback-sentinel';
  exception when others then
    if sqlerrm <> 'rollback-sentinel' then raise; end if;
  end;
end $$;
