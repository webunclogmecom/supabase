-- jobber_links_one_id_form.sql: every Jobber link holds the ENCODED id, and no Jobber record sits on two rows of one kind.
-- Read only. Every row must read 'ok'. Background: 2026-11-14_0805_jobber_links_encoded_ids_only.sql (two quotes were
-- stored twice, once under the encoded id and once under the bare number, before 2026-04-29).
-- The CONTROL rows prove the instrument can see a failure: the decoder must decode a known id, and a made-up pair of
-- links for one Jobber record (one encoded, one bare) must be counted as a double by the same query.
with links as (
  select entity_type, entity_id, source_id
    from public.entity_source_links
   where source_system = 'jobber'
),
decoded as (
  select entity_type, entity_id, source_id,
         case when source_id ~ '^[0-9]+$' then source_id
              when source_id ~ '^[A-Za-z0-9+/=]+$'
                then substring(convert_from(decode(rpad(source_id, ((length(source_id) + 3) / 4) * 4, '='), 'base64'), 'UTF8') from '([0-9]+)$')
         end as jid
    from links
),
fixture as (   -- a made-up double: entity 1 encoded, entity 2 bare, same Jobber number
  select 'quote'::text as entity_type, 1::bigint as entity_id, 'Z2lkOi8vSm9iYmVyL1F1b3RlLzU4Mzg1MzQw'::text as source_id
  union all select 'quote', 2, '58385340'
),
fixture_decoded as (
  select entity_type, entity_id,
         case when source_id ~ '^[0-9]+$' then source_id
              else substring(convert_from(decode(rpad(source_id, ((length(source_id) + 3) / 4) * 4, '='), 'base64'), 'UTF8') from '([0-9]+)$') end as jid
    from fixture
)
select 'no Jobber link holds a bare number' as check_name,
       case when count(*) = 0 then 'ok' else 'FAIL: ' || count(*) || ' bare-number links' end as result
  from links where source_id ~ '^[0-9]+$'
union all
select 'no Jobber record on two rows of one kind',
       case when count(*) = 0 then 'ok' else 'FAIL: ' || count(*) || ' doubled records (' || string_agg(distinct entity_type, ', ') || ')' end
  from (select entity_type, jid from decoded where jid is not null group by 1, 2 having count(distinct entity_id) > 1) d
union all
select 'the database refuses a bare number (CHECK present and validated)',
       case when exists (select 1 from pg_constraint where conname = 'entity_source_links_jobber_id_encoded' and convalidated) then 'ok'
            else 'FAIL: CHECK entity_source_links_jobber_id_encoded missing or not validated' end
union all
select 'CONTROL: the decoder decodes a known id',
       case when substring(convert_from(decode(rpad('Z2lkOi8vSm9iYmVyL1F1b3RlLzU4Mzg1MzQw', 36, '='), 'base64'), 'UTF8') from '([0-9]+)$') = '58385340'
            then 'ok' else 'FAIL: the decoder is broken, the double check above proves nothing' end
union all
select 'CONTROL: a made-up double is counted as one',
       case when (select count(*) from (select entity_type, jid from fixture_decoded group by 1, 2 having count(distinct entity_id) > 1) x) = 1
            then 'ok' else 'FAIL: the double check cannot see a double' end;
