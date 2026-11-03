-- ROLLBACK of 2026-11-03_1800_leads_m3_view_speed (written 2026-11-03 after the fact: M3 shipped without one).
-- M2's two bodies, copied from docs/migrations/2026-11-03_1730_leads_m2_functions_views.sql (not retyped), as
-- CREATE OR REPLACE. Run 2026-11-03_rollback_leads_privacy_fixes.sql first if that migration is applied: this file
-- puts back M2's v_lead_review, which shows owner_company unmasked. The views get slow again (25.9 s for v_lead_review).
begin;
set local lock_timeout = '3s';
create or replace view leads.v_client_candidates as
with rec as (
  select s.source_record_id, s.establishment_id, s.source_id, s.name, s.street, s.owner_company,
         upper(btrim(s.city)) as city_key,
         leads.fn_street_key(s.street) as skey, leads.fn_name_key(s.name) as nkey, leads.fn_name_key(s.owner_company) as okey
    from leads.v_src_bsi s
), cli as (
  select p.id as property_id, p.client_id, c.client_code, c.name as client_name, c.status as client_status,
         p.address as client_street, upper(btrim(p.city)) as city_key,
         leads.fn_street_key(p.address) as skey, leads.fn_name_key(c.name) as nkey
    from public.properties p
    join public.clients c on c.id = p.client_id
   where p.deleted_at is null and not coalesce(public.fn_is_non_customer(c.id), false)
), pairs as (
  select r.source_record_id, r.establishment_id, r.source_id, r.name, r.street, r.owner_company,
         k.property_id, k.client_id, k.client_code, k.client_name, k.client_status, k.client_street,
         (r.skey is not null and r.skey = k.skey) as street_match,
         greatest(coalesce(extensions.similarity(r.nkey, k.nkey), 0),
                  coalesce(extensions.word_similarity(r.nkey, k.nkey), 0),
                  coalesce(extensions.word_similarity(k.nkey, r.nkey), 0),
                  coalesce(extensions.similarity(r.okey, k.nkey), 0),
                  coalesce(extensions.word_similarity(r.okey, k.nkey), 0),
                  coalesce(extensions.word_similarity(k.nkey, r.okey), 0)) as name_score
    from rec r join cli k on k.city_key = r.city_key
)
select p.source_record_id, p.establishment_id, p.source_id, p.name, p.street, p.owner_company,
       p.property_id, p.client_id, p.client_code, p.client_name, p.client_status, p.client_street,
       case when p.street_match and p.name_score >= 0.8 then 'street_and_name'
            when p.street_match then 'street' else 'name' end as matched_on,
       round(p.name_score::numeric, 2) as name_score,
       d.verdict as last_verdict, d.decided_by as last_decided_by, d.decided_at as last_decided_at,
       (d.id is not null
        and (dv.payload -> 'search_item' ->> 'label') is not distinct from p.name
        and (dv.payload -> 'search_item' -> 'mailing_address' ->> 'name')
            is not distinct from (select x.payload -> 'search_item' -> 'mailing_address' ->> 'name'
                                    from leads.source_versions x where x.source_record_id = p.source_record_id
                                   order by x.fetched_at desc limit 1)) as decided
  from pairs p
  left join lateral (select md.id, md.verdict, md.decided_by, md.decided_at, md.source_record_id, md.seen_version_at
                       from leads.match_decisions md
                      where md.source_record_id = p.source_record_id and md.property_id = p.property_id
                      order by md.id desc limit 1) d on true
  left join leads.source_versions dv on dv.source_record_id = d.source_record_id and dv.fetched_at = d.seen_version_at
 where p.street_match or p.name_score >= 0.8;

create or replace view public.v_lead_review as
select 'client_candidate'::text as kind, c.source_record_id, c.establishment_id, 'bsi'::text as source_system,
       c.source_id, c.name as source_name, c.street as source_street, c.owner_company,
       c.property_id, c.client_code, c.client_name, c.client_street, c.matched_on, c.name_score,
       c.last_verdict, c.last_decided_by, c.last_decided_at
  from leads.v_client_candidates c
 where not c.decided
union all
select 'client_without_source_record', null::bigint, null::bigint, 'bsi', null::text, null::text, null::text, null::text,
       p.id, c.client_code, c.name, p.address, null::text, null::numeric, null::text, null::text, null::timestamptz
  from public.properties p
  join public.clients c on c.id = p.client_id
 where p.deleted_at is null and c.status <> 'INACTIVE' and not coalesce(public.fn_is_non_customer(c.id), false)
   and upper(btrim(p.city)) in (select distinct upper(btrim(s.city)) from leads.v_src_bsi s)
   and not exists (select 1 from leads.establishments e where e.property_id = p.id and e.status = 'ACTIVE')
   and not exists (select 1 from leads.v_client_candidates cc where cc.property_id = p.id and not cc.decided)
   and not exists (select 1 from leads.match_decisions md where md.property_id = p.id and md.verdict = 'absent' and md.absent_from = 'bsi')
union all
select 'client_record_changed', sr.id, e.id, 'bsi', s.source_id, s.name, s.street, s.owner_company,
       e.property_id, c.client_code, c.name, p.address, null::text, null::numeric, d.verdict, d.decided_by, d.decided_at
  from leads.establishments e
  join leads.source_records sr on sr.establishment_id = e.id
  join leads.v_src_bsi s on s.source_record_id = sr.id
  join public.properties p on p.id = e.property_id
  join public.clients c on c.id = p.client_id
  join lateral (select md.verdict, md.decided_by, md.decided_at, md.source_record_id, md.seen_version_at
                  from leads.match_decisions md
                 where md.source_record_id = sr.id and md.property_id = e.property_id
                 order by md.id desc limit 1) d on true
  join leads.source_versions dv on dv.source_record_id = d.source_record_id and dv.fetched_at = d.seen_version_at
 where e.status = 'ACTIVE' and d.verdict = 'same'
   and ((dv.payload -> 'search_item' ->> 'label') is distinct from s.name
        or (dv.payload -> 'search_item' -> 'mailing_address' ->> 'name')
           is distinct from (select x.payload -> 'search_item' -> 'mailing_address' ->> 'name'
                               from leads.source_versions x where x.source_record_id = sr.id
                              order by x.fetched_at desc limit 1));
commit;
