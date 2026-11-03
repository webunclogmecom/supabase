-- ============================================================================
-- 2026-11-03_1800_leads_m3_view_speed  Frozen leads, step M3: the review and candidate views under PostgREST's 8 s
-- ============================================================================
-- WHY: measured right after the load (2026-11-03 ~16:50 ET), as service_role: public.v_lead_review 25,856 ms and
--   public.v_frozen_leads 3,167 ms. PostgREST stops a request at 8 s, so Viktor's review read would fail. Cause,
--   measured: leads.v_client_candidates took 3,448 ms because its inlined CTEs ran the key functions once per PAIR
--   (431 records x every Boca property, five regexp calls each) instead of once per row; v_lead_review then re-ran
--   the whole candidate view for each property in its "no record" branch (a correlated NOT EXISTS).
-- WHAT (no table, grant or column changes; CREATE OR REPLACE keeps owner and grants):
--   leads.v_client_candidates: rec, cli and pairs become MATERIALIZED CTEs (keys computed once per row) and cli keeps
--     only properties in a city we hold records for. Measured on the live data: 240 ms, the same 11 rows.
--   public.v_lead_review: the candidate view is computed once (a MATERIALIZED CTE) and reused by its two branches.
-- VERIFY (inside): an md5 of every row of the five leads views is taken before and after the replacement, in the
--   same transaction (so now() is one value): all five must be identical. Grants read back unchanged.
-- ROLLBACK: re-run the two CREATE OR REPLACE VIEW statements of 2026-11-03_1730_leads_m2_functions_views.sql.
-- ============================================================================
begin;
set local lock_timeout = '3s';

create temp table _m3_before on commit drop as
select 'v_client_candidates' as v, md5(string_agg(t::text, '|' order by t::text)) as h from leads.v_client_candidates t
union all select 'v_establishment_state', md5(string_agg(t::text, '|' order by t::text)) from leads.v_establishment_state t
union all select 'v_frozen_leads', md5(string_agg(t::text, '|' order by t::text)) from public.v_frozen_leads t
union all select 'v_lead_interceptors', md5(string_agg(t::text, '|' order by t::text)) from public.v_lead_interceptors t
union all select 'v_lead_review', md5(string_agg(t::text, '|' order by t::text)) from public.v_lead_review t;

create temp table _m3_acl_before on commit drop as
select c.oid, c.relacl::text as acl from pg_class c
 where c.oid in ('leads.v_client_candidates'::regclass, 'public.v_lead_review'::regclass);

create or replace view leads.v_client_candidates as
with rec as materialized (
  select s.source_record_id, s.establishment_id, s.source_id, s.name, s.street, s.owner_company,
         upper(btrim(s.city)) as city_key,
         leads.fn_street_key(s.street) as skey, leads.fn_name_key(s.name) as nkey, leads.fn_name_key(s.owner_company) as okey
    from leads.v_src_bsi s
), cli as materialized (
  select p.id as property_id, p.client_id, c.client_code, c.name as client_name, c.status as client_status,
         p.address as client_street, upper(btrim(p.city)) as city_key,
         leads.fn_street_key(p.address) as skey, leads.fn_name_key(c.name) as nkey
    from public.properties p
    join public.clients c on c.id = p.client_id
   where p.deleted_at is null
     and upper(btrim(p.city)) in (select r.city_key from rec r)
     and not coalesce(public.fn_is_non_customer(c.id), false)
), pairs as materialized (
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
with cand as materialized (
  select * from leads.v_client_candidates
), covered as materialized (
  select distinct upper(btrim(s.city)) as city_key from leads.v_src_bsi s
)
select 'client_candidate'::text as kind, c.source_record_id, c.establishment_id, 'bsi'::text as source_system,
       c.source_id, c.name as source_name, c.street as source_street, c.owner_company,
       c.property_id, c.client_code, c.client_name, c.client_street, c.matched_on, c.name_score,
       c.last_verdict, c.last_decided_by, c.last_decided_at
  from cand c
 where not c.decided
union all
select 'client_without_source_record', null::bigint, null::bigint, 'bsi', null::text, null::text, null::text, null::text,
       p.id, c.client_code, c.name, p.address, null::text, null::numeric, null::text, null::text, null::timestamptz
  from public.properties p
  join public.clients c on c.id = p.client_id
 where p.deleted_at is null and c.status <> 'INACTIVE'
   and upper(btrim(p.city)) in (select k.city_key from covered k)
   and not coalesce(public.fn_is_non_customer(c.id), false)
   and not exists (select 1 from leads.establishments e where e.property_id = p.id and e.status = 'ACTIVE')
   and not exists (select 1 from cand cc where cc.property_id = p.id and not cc.decided)
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

do $verify$
declare v_bad text;
begin
  select string_agg(b.v, ', ') into v_bad
    from _m3_before b
    join (select 'v_client_candidates' as v, md5(string_agg(t::text, '|' order by t::text)) as h from leads.v_client_candidates t
          union all select 'v_establishment_state', md5(string_agg(t::text, '|' order by t::text)) from leads.v_establishment_state t
          union all select 'v_frozen_leads', md5(string_agg(t::text, '|' order by t::text)) from public.v_frozen_leads t
          union all select 'v_lead_interceptors', md5(string_agg(t::text, '|' order by t::text)) from public.v_lead_interceptors t
          union all select 'v_lead_review', md5(string_agg(t::text, '|' order by t::text)) from public.v_lead_review t) a
      on a.v = b.v
   where a.h is distinct from b.h;
  if v_bad is not null then raise exception 'leads M3 VERIFY: rows changed in %', v_bad; end if;
  if exists (select 1 from _m3_acl_before x join pg_class c on c.oid = x.oid where c.relacl::text is distinct from x.acl) then
    raise exception 'leads M3 VERIFY: grants changed';
  end if;
end $verify$;

commit;
