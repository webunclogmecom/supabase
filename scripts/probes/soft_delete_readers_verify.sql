-- ---- VERIFY -------------------------------------------------------------------------------------
do $verify$
declare
  v_retired bigint; v_live bigint; v_total bigint;
  v_n bigint; v_pre bigint; o text; v_def text; v_bad text := '';
  -- Objects whose count MUST move, and by how much. Everything else must not move at all.
  --   client.properties / ops.properties : grain = property, so they lose exactly the retired rows.
  --   the rest of the changed set        : aggregates, ON-clauses and subqueries, so their ROW
  --                                        COUNT is unchanged even though their VALUES may change.
  expect_drop text[] := array['client.properties','ops.properties'];
begin
  select count(*) filter (where deleted_at is not null), count(*) filter (where deleted_at is null), count(*)
    into v_retired, v_live, v_total from public.properties;

  -- 1. the filter is actually present in all seven bodies -----------------------------------------
  foreach o in array array['client.properties','ops.properties','client.clients','customer.clients',
                           'public.zones_with_usage','derm.v_stamp_clients'] loop
    v_def := pg_get_viewdef(o::regclass, true);
    if v_def !~* 'deleted_at IS NULL' then
      raise exception 'VERIFY: % does not filter deleted_at', o;
    end if;
  end loop;
  if (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='client' and p.proname='global_search') !~* 'pr\.deleted_at is null' then
    raise exception 'VERIFY: client.global_search does not filter pr.deleted_at';
  end if;

  -- 2. client.clients got BOTH lateral edits, not one ---------------------------------------------
  -- A single-occurrence check would pass with only one of the two applied, which is exactly the
  -- half-applied state that leaves a retired property still voting on grease capacity.
  if (select count(*) from regexp_matches(pg_get_viewdef('client.clients'::regclass, true),
                                          'deleted_at IS NULL', 'g')) <> 2 then
    raise exception 'VERIFY: client.clients must carry exactly 2 deleted_at filters (zone + grease)';
  end if;

  -- 3. the property-grain views lost EXACTLY the retired rows -------------------------------------
  foreach o in array expect_drop loop
    execute format('select count(*) from %s', o) into v_n;
    select n into v_pre from _pre_counts where obj = o;
    if v_n <> v_live then
      raise exception 'VERIFY: % returns % rows, expected % (live properties)', o, v_n, v_live;
    end if;
    if v_pre - v_n <> v_retired then
      raise exception 'VERIFY: % dropped % rows, expected % (retired properties)', o, v_pre - v_n, v_retired;
    end if;
  end loop;

  -- 4. 🛑 NOTHING ELSE MOVED. This is the assertion that catches a filter applied to the wrong
  --    grain, which would delete visits or manifests rather than hide a property.
  for o, v_pre in select obj, n from _pre_counts where obj <> all(expect_drop) loop
    execute format('select count(*) from %s', o) into v_n;
    if v_n <> v_pre then
      v_bad := v_bad || format('%s %s->%s; ', o, v_pre, v_n);
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'VERIFY: an untouched view changed its row count: %', v_bad;
  end if;

  -- 5. CONTROLS. A filter that hides everything would satisfy check 3 if v_live were 0, and a
  --    filter that hides nothing would satisfy check 4. Name a real row on each side.
  if v_retired = 0 then
    raise exception 'VERIFY: no retired properties exist, so checks 3 and 4 prove nothing. Refusing.';
  end if;
  if exists (select 1 from client.properties cp
              join public.properties pp on pp.id = cp.id where pp.deleted_at is not null) then
    raise exception 'VERIFY: a retired property is still visible in client.properties';
  end if;
  if not exists (select 1 from client.properties cp
                  join public.properties pp on pp.id = cp.id where pp.deleted_at is null) then
    raise exception 'VERIFY: client.properties is empty - the filter hid everything';
  end if;

  -- 6. grants survived (CREATE OR REPLACE keeps them; DROP VIEW would not) -------------------------
  foreach o in array array['client.properties','ops.properties','client.clients','customer.clients',
                           'public.zones_with_usage','derm.v_stamp_clients'] loop
    if not has_table_privilege('authenticated', o, 'SELECT') then
      raise exception 'VERIFY: authenticated lost SELECT on %', o;
    end if;
    if has_table_privilege('anon', o, 'SELECT') then
      raise exception 'VERIFY: % became anon-readable', o;
    end if;
  end loop;

  raise notice 'VERIFY ok: 7 objects filter deleted_at; % retired rows hidden from % property-grain views; 28 other views unchanged; grants intact',
    v_retired, array_length(expect_drop, 1);
end $verify$;
