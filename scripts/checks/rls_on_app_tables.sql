-- Every table in an app schema (the PostgREST-exposed schemas we own) has RLS on, and the guard that
-- keeps it so is installed. Trello FFSF71BI, migration 2026-10-28_1804_rls_on_every_app_table.
-- Healthy = one row, status 'ok'. Anything else names what drifted. Read-only.
-- If a schema is ever added to PostgREST's exposed list, add it here AND to public.rls_auto_enable().
with app_tables as (
  select n.nspname || '.' || c.relname as t, c.relrowsecurity as rls
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('public', 'derm', 'ops', 'client', 'customer', 'hr')
     and c.relkind in ('r', 'p')
),
off as (select count(*) as n, string_agg(t, ', ' order by t) as list from app_tables where not rls)
select case
         -- control: the instrument sees the estate (239 tables in all schemas, 152 in these six on 2026-10-28)
         when (select count(*) from app_tables) < 100
           then 'CONTROL FAILED: only ' || (select count(*) from app_tables) || ' app tables seen'
         when not exists (select 1 from pg_event_trigger where evtname = 'rls_auto_enable' and evtenabled = 'O')
           then 'GUARD MISSING: event trigger rls_auto_enable is not installed or is disabled'
         when not exists (select 1 from pg_policy
                           where polrelid = 'derm.page_slots'::regclass and polname = 'page_slots_staff_read')
           then 'POLICY MISSING: derm.page_slots_staff_read (DERM Stamp Studio reads page_slots directly)'
         when (select n from off) > 0
           then 'RLS OFF: ' || (select list from off)
         else 'ok'
       end as status,
       (select count(*) from app_tables) as app_tables;
