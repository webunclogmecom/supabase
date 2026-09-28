-- 2026-09-28_1435  public.dump_visit_gdo_numbers(bigint[]): EVERY GDO number of a visit's client, for the DUMP app cards
--
-- WHY (Fred, 2026-09-28): "It seems we need to add the GDO Numbers on the App, for when showing the visits,
-- when a visit for the dump is created and for when clicking the button Add to dump ... put it below the
-- title of the client ... And if it has no GDO then put No GDO".
-- Trigger: Slack #C0BD3VDPB9S 2026-09-28 13:45 ET. Michael Escobar filled pad sheet 361 for ticket 836624
-- (dump visit 8190, Homestead, 2026-09-23) with ONE Casa Neos line, although Casa Neos holds THREE permits
-- (GDO-10877 Kitchen, GDO-15062 Bar, GDO-16389 Lounge). The DUMP app handed him one line with one number:
-- dump_outstanding_visits / ops.v_calendar_visit carry a single gdo_number from fn_resolve_gdo_number,
-- which is LIMIT 1 by design (it answers "which permit is THIS visit's trap", not "which permits does this
-- client hold"). The Manifest Generator prints one Section B row per permit.
--
-- THE RULE IS THE MANIFEST GENERATOR'S, MIRRORED, NOT RE-INVENTED. unclogme-pdf-service
-- pdf_service/app.py _active_gdos(): the client's gdos rows (embedded by client_id, no property filter),
-- status = 'ACTIVE', gdo_number strictly ^GDO-\d+$ (a comma-joined multi-permit string or "Not available"
-- never counts), sorted by gdo_number as a Python string. COLLATE "C" below is what makes the order the
-- same as Python's (GDO-10877 before GDO-8422). If that rule changes in the pdf-service, change it here in
-- the same cycle, or the driver's card and the office's printed sheet disagree.
-- Deliberately NOT fn_resolve_gdo_id: that one ignores status on purpose (a single best guess), this is the
-- list the office prints. An empty array means the printed sheet has no GDO for that client either.
--
-- Read-only, SECURITY INVOKER, service_role only (the dump-visit-create edge fn is its one caller).
-- Rule 8 (audit): no table created or changed, nothing to audit.

create or replace function public.dump_visit_gdo_numbers(p_visit_ids bigint[])
returns table (visit_id bigint, gdo_numbers text[])
language sql
stable
security invoker
set search_path = public, pg_temp
as $function$
  select v.id,
         coalesce(array_agg(g.gdo_number order by g.gdo_number collate "C") filter (where g.id is not null),
                  '{}'::text[])
  from public.visits v
  left join public.gdos g
    on g.client_id = v.client_id
   and g.status = 'ACTIVE'
   and g.gdo_number ~ '^GDO-[0-9]+$'
  where v.id = any(p_visit_ids)
  group by v.id
$function$;

comment on function public.dump_visit_gdo_numbers(bigint[]) is
  'DUMP app cards: every ACTIVE GDO-#### permit of each visit''s client, sorted as the Manifest Generator prints them (pdf-service _active_gdos). Empty array = no GDO. service_role only. 2026-09-28_1435.';

revoke all on function public.dump_visit_gdo_numbers(bigint[]) from public, anon, authenticated;
grant execute on function public.dump_visit_gdo_numbers(bigint[]) to service_role;

-- VERIFY (run inside the same transaction; any failure rolls the whole file back)
do $verify$
declare
  v_casa   text[];
  v_brow   text[];
  v_n      int;
  v_bad    int;
begin
  -- 1. Casa Neos visit 6569: all three permits, in the printed order.
  select gdo_numbers into v_casa from public.dump_visit_gdo_numbers(array[6569]::bigint[]);
  if v_casa is distinct from array['GDO-10877','GDO-15062','GDO-16389'] then
    raise exception 'VERIFY 1: Casa Neos 6569 gave %', v_casa;
  end if;

  -- 2. A client with no permit returns an EMPTY array, never NULL and never a missing row
  --    (224-MP, Broward, visit taken from the live outstanding list if present, else any 224-MP visit).
  select d.gdo_numbers into v_brow
    from public.dump_visit_gdo_numbers(array(
      select v.id from public.visits v join public.clients c on c.id = v.client_id
       where c.client_code = '224-MP' order by v.id desc limit 1)) d;
  if v_brow is null or cardinality(v_brow) <> 0 then
    raise exception 'VERIFY 2: 224-MP gave %', v_brow;
  end if;

  -- 3. One row per requested visit, unknown ids simply absent.
  select count(*) into v_n from public.dump_visit_gdo_numbers(array[6569, 6569, -1]::bigint[]);
  if v_n <> 1 then raise exception 'VERIFY 3: expected 1 row, got %', v_n; end if;

  -- 4. Mirror check against what the Manifest Generator actually printed: on every live generated
  --    Miami-Dade sheet made since 2026-09-01, rows_printed (frozen at generation) must equal
  --    greatest(1, cardinality) of this function for that visit. A mismatch means the rules differ
  --    (or a permit changed after printing; none are expected in this window).
  select count(*) into v_bad
    from derm.address_sheet_clients a
    join derm.address_sheets s on s.id = a.sheet_id and s.deleted_at is null
    join public.dump_visit_gdo_numbers(array(select a2.visit_id from derm.address_sheet_clients a2 where a2.visit_id is not null)) d
      on d.visit_id = a.visit_id
   where s.created_at >= timestamptz '2026-09-01'
     and a.rows_printed is not null
     and a.rows_printed <> greatest(1, cardinality(d.gdo_numbers));
  if v_bad <> 0 then raise exception 'VERIFY 4: % generated rows disagree with the printed row count', v_bad; end if;

  -- 5. Grants: only service_role may execute.
  if has_function_privilege('anon', 'public.dump_visit_gdo_numbers(bigint[])', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.dump_visit_gdo_numbers(bigint[])', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.dump_visit_gdo_numbers(bigint[])', 'EXECUTE') then
    raise exception 'VERIFY 5: grants wrong';
  end if;
end
$verify$;
