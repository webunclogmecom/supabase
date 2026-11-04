-- Frozen leads integrity (Trello #166, migrations 2026-11-03_1700 / _1730 / _1848_leads_privacy_fixes /
-- _2039_leads_label_mask_and_quiet_load). Read-only.
-- Healthy = every row 'ok'. Run as owner (Management API). The CONTROL rows must be 'ok', or nothing above them means
-- anything. Values from BSI are compared inside SQL and never printed.
-- Since _1848 the privacy rows test VALUES: the first version tested only column names and passed while 18 BSI contact
-- names showed in owner_company. Since _2039 the name test covers EVERY cell, on leads.fn_name_key: the _1848 version
-- tested owner_company and location only and passed while 3 BSI labels (the name column) were contact names.
-- Accepted by design, so not tested: a contact's name INSIDE a longer business name (2 labels, 2 owner names on
-- 2026-11-03), and owner names that look like a person's but are not BSI contacts (the plan keeps the mailing name).
with links as (
  select l.entity_id as source_record_id, count(*) as n
    from public.entity_source_links l where l.entity_type = 'source_record' group by 1
), newest as (
  select distinct on (md.source_record_id, md.property_id) md.source_record_id, md.property_id, md.verdict
    from leads.match_decisions md where md.source_record_id is not null
   order by md.source_record_id, md.property_id, md.id desc
), private as materialized (   -- every CCN, contact email, phone and contact name BSI ever gave us
  select distinct 'ccn' as kind, upper(btrim(x)) as val
    from leads.source_versions v
    cross join lateral (values (v.payload -> 'search_item' ->> 'ccn'), (v.payload -> 'detail' ->> 'ccn')) t(x)
   where length(btrim(coalesce(x, ''))) >= 3
  union
  select 'email', lower(btrim(v.payload -> 'search_item' -> 'contact' ->> 'email')) from leads.source_versions v
   where v.payload -> 'search_item' -> 'contact' ->> 'email' like '%@%'
  union
  select 'phone', regexp_replace(v.payload -> 'search_item' -> 'contact' ->> 'phone', '[^0-9]', '', 'g') from leads.source_versions v
   where length(regexp_replace(coalesce(v.payload -> 'search_item' -> 'contact' ->> 'phone', ''), '[^0-9]', '', 'g')) >= 7
  union
  select 'name', leads.fn_name_key(v.payload -> 'search_item' -> 'contact' ->> 'name')
    from leads.source_versions v
   where leads.fn_name_key(v.payload -> 'search_item' -> 'contact' ->> 'name') is not null
), cells as materialized (     -- every non-null cell of the three views Viktor reads
  select kv.key as col, kv.value as cell
    from (select to_jsonb(t) as j from public.v_frozen_leads t
          union all select to_jsonb(t) from public.v_lead_interceptors t
          union all select to_jsonb(t) from public.v_lead_review t) r
    cross join lateral jsonb_each_text(r.j) kv
   where kv.value is not null
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
  select 'no public leads view cell holds a CCN, a contact email or a contact phone',
         (select count(*) from cells c
           where exists (select 1 from private p where p.kind = 'ccn' and position(p.val in upper(c.cell)) > 0)
              or exists (select 1 from private p where p.kind = 'email' and position(p.val in lower(c.cell)) > 0)
              or exists (select 1 from private p where p.kind = 'phone' and position(p.val in regexp_replace(c.cell, '[^0-9]', '', 'g')) > 0))
  union all
  select 'no cell of a public leads view is a BSI contact''s name (any column, leads.fn_name_key)',
         (select count(*) from cells c
           where leads.fn_name_key(c.cell) in (select p.val from private p where p.kind = 'name'))
  union all
  select 'signed-in staff see no frozen-leads link (client.entity_source_links)',
         (select count(*) from client.entity_source_links where entity_type = 'source_record')
  union all
  select 'no frozen-leads link carries the BSI label (entity_source_links.source_name; service_role reads that table)',
         (select count(*) from public.entity_source_links where entity_type = 'source_record' and source_name is not null)
  union all
  select 'the loader''s entry takes text and gives up on a busy lock at 500 ms (leads.ingest_quiet)',
         (select count(*) from (values
            (to_regprocedure('leads.ingest_quiet(text,timestamptz,jsonb,text,boolean)') is not null),
            (not exists (select 1 from pg_proc where oid = to_regprocedure('leads.ingest_quiet(text,text,text,text,boolean)')
                                                 and proconfig @> array['lock_timeout=500ms']))) t(bad)
           where bad)
  union all
  select 'public leads views: only postgres, service_role and db_backup_reader (SELECT)',
         (select count(*) from pg_class c cross join lateral aclexplode(c.relacl) a
           where c.oid in ('public.v_frozen_leads'::regclass, 'public.v_lead_interceptors'::regclass, 'public.v_lead_review'::regclass)
             and not (pg_get_userbyid(a.grantee) = 'postgres'
                      or (pg_get_userbyid(a.grantee) in ('service_role', 'db_backup_reader') and a.privilege_type = 'SELECT')))
  union all
  select 'no API role reads a leads table or view',
         (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
           cross join (values ('anon'), ('authenticated'), ('service_role')) r(role)
           where n.nspname = 'leads' and c.relkind in ('r', 'v', 'm') and has_table_privilege(r.role, c.oid, 'SELECT'))
  union all
  select 'no API role can run a leads function (service_role: the three pure helpers only)',
         (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           cross join (values ('anon'), ('authenticated'), ('service_role')) r(role)
           where n.nspname = 'leads' and has_function_privilege(r.role, p.oid, 'EXECUTE')
             and not (r.role = 'service_role' and p.proname in ('fn_street_key', 'fn_name_key', 'fn_bsi_date')))
  union all
  select 'every leads table has RLS on',
         (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'leads' and c.relkind = 'r' and not c.relrowsecurity)
)
select check_name, case when bad = 0 then 'ok' else 'FAIL: ' || bad end as status from checks
union all
select 'CONTROL: records visible', case when (select count(*) from leads.source_records) >= 400 then 'ok'
                                         else 'CONTROL FAILED: ' || (select count(*) from leads.source_records) end
union all
select 'CONTROL: the value test finds the CCNs where they are (leads.v_src_bsi)',
       case when (select count(*) from leads.v_src_bsi s
                   where exists (select 1 from private p where p.kind = 'ccn' and position(p.val in upper(to_jsonb(s)::text)) > 0)) >= 400
              and (select count(*) from cells) >= 1000
            then 'ok' else 'CONTROL FAILED' end
union all
select 'CONTROL: the name test finds the contact names where they are (leads.v_src_bsi labels and mailing names)',
       case when (select count(*) from leads.v_src_bsi s
                   where leads.fn_name_key(s.name) in (select p.val from private p where p.kind = 'name')) >= 1
              and (select count(*) from leads.v_src_bsi s
                   where leads.fn_name_key(s.owner_company) in (select p.val from private p where p.kind = 'name')) >= 10
            then 'ok' else 'CONTROL FAILED' end;
