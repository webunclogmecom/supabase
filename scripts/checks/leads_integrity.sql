-- Frozen leads integrity (Trello #166, migrations 2026-11-03_1700 / _1730). Read-only. Healthy = every row 'ok'.
-- Run as owner (Management API). The last row is the control: it must see at least 400 records, or nothing above
-- means anything.
with links as (
  select l.entity_id as source_record_id, count(*) as n
    from public.entity_source_links l where l.entity_type = 'source_record' group by 1
), newest as (
  select distinct on (md.source_record_id, md.property_id) md.source_record_id, md.property_id, md.verdict
    from leads.match_decisions md where md.source_record_id is not null
   order by md.source_record_id, md.property_id, md.id desc
), checks as (
  select 'every record has exactly one link' as check_name,
         (select count(*) from leads.source_records r left join links k on k.source_record_id = r.id
           where coalesce(k.n, 0) <> 1) as bad
  union all
  select 'every source_record link has a record',
         (select count(*) from public.entity_source_links l
           where l.entity_type = 'source_record' and not exists (select 1 from leads.source_records r where r.id = l.entity_id))
  union all
  select 'every record has a version',
         (select count(*) from leads.source_records r where not exists (select 1 from leads.source_versions v where v.source_record_id = r.id))
  union all
  select 'every ACTIVE restaurant has a record, no INACTIVE one does',
         (select count(*) from leads.establishments e
           where (e.status = 'ACTIVE') <> exists (select 1 from leads.source_records r where r.establishment_id = e.id))
  union all
  select 'every linked record rests on a newest same decision',
         (select count(*) from leads.source_records r join leads.establishments e on e.id = r.establishment_id
           where e.property_id is not null and e.status = 'ACTIVE'
             and not exists (select 1 from newest n where n.source_record_id = r.id and n.property_id = e.property_id and n.verdict = 'same'))
  union all
  select 'no public leads view has a CCN or contact column',
         (select count(*) from information_schema.columns
           where table_schema = 'public' and table_name in ('v_frozen_leads', 'v_lead_interceptors', 'v_lead_review')
             and (column_name ilike '%ccn%' or column_name ilike '%contact%' or column_name ilike '%phone%'
                  or column_name ilike '%email%' or column_name ilike '%mailing%'))
  union all
  select 'public leads views: only postgres, service_role and db_backup_reader (SELECT)',
         (select count(*) from pg_class c cross join lateral aclexplode(c.relacl) a
           where c.oid in ('public.v_frozen_leads'::regclass, 'public.v_lead_interceptors'::regclass, 'public.v_lead_review'::regclass)
             and not (pg_get_userbyid(a.grantee) = 'postgres'
                      or (pg_get_userbyid(a.grantee) in ('service_role', 'db_backup_reader') and a.privilege_type = 'SELECT')))
  union all
  select 'no API role reads a leads table',
         (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
           cross join (values ('anon'), ('authenticated'), ('service_role')) r(role)
           where n.nspname = 'leads' and c.relkind = 'r' and has_table_privilege(r.role, c.oid, 'SELECT'))
  union all
  select 'every leads table has RLS on',
         (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'leads' and c.relkind = 'r' and not c.relrowsecurity)
)
select check_name, case when bad = 0 then 'ok' else 'FAIL: ' || bad end as status from checks
union all
select 'CONTROL: records visible', case when (select count(*) from leads.source_records) >= 400 then 'ok'
                                         else 'CONTROL FAILED: ' || (select count(*) from leads.source_records) end;
