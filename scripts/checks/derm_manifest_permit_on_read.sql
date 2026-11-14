-- Standing check: a manifest's permit is worked out on read (docs/migrations/2026-11-14_0100_derm_manifest_permit_on_read.sql).
-- public.derm_manifests.gdo_id is FROZEN: two one-time fills wrote it (2026-05-19/20, 2026-08-24) and nothing keeps it up.
-- Nothing new may read it or write it, and the two objects that used to read it work the permit out from the client's
-- ACTIVE GDO permits. Every row must read 'ok'. Run as owner (Management API: node scripts/q.js <this file> <out.json>).
-- It fails on the bodies before 2026-11-14_0100 (rows 1 to 4; measured 2026-11-14 00:59 ET, before it was applied).
-- Ceiling: function bodies are not swept for the column, because a regex cannot tell this gdo_id from the many others
-- (customer.gdo_reports, the bot's queue, the stamp cards). Before dropping the column, run the "WHO READS THIS
-- COLUMN?" sweep in CLAUDE.md, whole-row readers included.
with col as (
  select a.attnum from pg_attribute a where a.attrelid = 'public.derm_manifests'::regclass and a.attname = 'gdo_id'
),
readers as (
  select distinct r.ev_class::regclass::text as v
    from pg_depend d join pg_rewrite r on r.oid = d.objid cross join col
   where d.refobjid = 'public.derm_manifests'::regclass and d.refobjsubid = col.attnum
     and r.ev_class <> 'public.derm_manifests'::regclass
)
select '1 views reading derm_manifests.gdo_id: only the three that select it and never use it' as check_name,
       case when (select count(*) from readers
                   where v not in ('client.derm_manifests', 'customer.work_orders', 'customer.work_orders_all')) > 0 then 'FAIL'
            when (select count(*) from readers) = 0 then 'FAIL'
            else 'ok' end as result,
       coalesce((select string_agg(v, ', ' order by v) from readers),
                'none found: the instrument saw no reader (if the three were dropped with the column, retire this row)') as detail
union all
select '2 derm.gdos.manifest_count = the client''s live manifests under an ACTIVE GDO- permit, else 0',
       case when s.bad = 0 and s.counting > 0 then 'ok' else 'FAIL' end,
       s.bad || ' permits disagree; ' || s.counting || ' permits count a manifest (control: must be above 0)'
  from (select count(*) filter (where d.manifest_count is distinct from
                 (case when g.status = 'ACTIVE' and g.gdo_number ~ '^GDO-[0-9]+$'
                       then (select count(*) from public.derm_manifests m
                              where m.client_id = g.client_id and m.deleted_at is null)
                       else 0 end)) as bad,
               count(*) filter (where d.manifest_count > 0) as counting
          from derm.gdos d join public.gdos g on g.id = d.id) s
union all
select '3 derm.audit_pack looks the permit up by client, never the stored link',
       case when p.prosrc !~ 'v_m[.]gdo_id' and p.prosrc ~ 'g2[.]client_id = v_m[.]client_id' then 'ok' else 'FAIL' end,
       'reads v_m.gdo_id: ' || (p.prosrc ~ 'v_m[.]gdo_id') ||
       '; looks up by client (control): ' || (p.prosrc ~ 'g2[.]client_id = v_m[.]client_id')
  from pg_proc p where p.oid = 'derm.audit_pack(bigint)'::regprocedure
union all
select '4 derm_manifests.gdo_id is marked FROZEN',
       case when coalesce(col_description('public.derm_manifests'::regclass, col.attnum), '') like 'FROZEN%' then 'ok' else 'FAIL' end,
       left(coalesce(col_description('public.derm_manifests'::regclass, col.attnum), 'no comment'), 70)
  from col
union all
select '5 no manifest filed after the 2026-08-24 fill carries a link (nobody writes it)',
       case when count(*) = 0 then 'ok' else 'FAIL' end,
       count(*) || ' manifests created after 2026-08-24 19:57 UTC hold a gdo_id' ||
       coalesce(' (ids ' || string_agg(m.id::text, ', ' order by m.id) || ')', '')
  from public.derm_manifests m
 where m.created_at >= timestamptz '2026-08-24 19:57+00' and m.gdo_id is not null;
