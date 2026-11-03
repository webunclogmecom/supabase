-- ============================================================================
-- 2026-11-03_1730_leads_m2_functions_views  Frozen leads, step M2: helpers, the load, the decision, the views
-- ============================================================================
-- THE ASK: as in 2026-11-03_1700_leads_schema_m1 (Trello IWJkqTq1 / f3Q3Q55i; Fred: "Leads + routing now", CCNs and
--   BSI contacts kept privately). Plan docs/specs/2026-11-03-boca-bsi-leads-and-filing-plan.md, section 8.1, stage S2.
-- WHAT
--   Helpers (pure, IMMUTABLE): leads.fn_street_key(text) house number + first street word (direction words skipped;
--     STATE ROAD / SR / FLORIDA read as SR; unit and ZIP ignored), leads.fn_name_key(text) (LLC, INC, THE ... dropped),
--     leads.fn_bsi_date(text) (BSI's dates; anything before 2000 or unreadable = unknown).
--   leads.ingest(source, run_started_at, records, file): the only writer of records and versions. One call per run;
--     a new version only when a payload changed, otherwise last_seen_at moves; refuses an unknown source, an empty or
--     duplicate batch, and a run older than data already held. One sync_log row ('leads:<source>').
--   leads.decide_client(property, verdict, reason, by, record, absent_from): the only writer of decisions and links.
--     same = this record IS that property (a property already holding a restaurant receives the record: a merge);
--     different = it is not (a split or an unlink); absent = that property has no record in that source.
--     Refuses a non-staff `by` (public.fn_is_staff_email), a test client, an empty reason.
--   Views (leads.*, private): v_src_bsi (newest BSI version, typed; holds the CCN and contact, never granted),
--     v_client_candidates (possible matches, computed live from public: same city AND (same street key OR name score
--     >= 0.8)), v_establishment_state ("frozen" is computed here, never stored).
--   Views for Viktor (public, postgres-owned, owner's rights, SELECT for service_role only; no CCN, no contact):
--     public.v_frozen_leads, public.v_lead_interceptors (the #169 bridge), public.v_lead_review.
-- FROZEN = an ACTIVE restaurant not linked to one of our properties and with no possible client match waiting.
--   linked: client / warm (ACTIVE with no client code = a Jobber lead) / former_client (INACTIVE client or deleted
--   property); not linked with an open pair: needs_review.
-- GRANTS: nothing on leads.* for anon / authenticated; service_role holds USAGE on leads and EXECUTE on the three
--   helpers only (an owner-rights view runs its functions as the CALLER, Supabase CLAUDE.md "asymmetry"); the two
--   writers are postgres-only (run through the Management API). The three public views: exactly postgres,
--   service_role=r, db_backup_reader=r (read back below).
-- RULE 8: no table created here. RULE 7: no CHECK widened.
-- VERIFY (inside): helper cases; exact grants; a fake two-record ingest, its idempotent re-run, a changed payload
--   and an older run refused; a fake Boca record next to Grove (property 4) shows as a candidate, 'same' makes it a
--   client, 'different' makes it frozen; a non-staff email and a test client are refused. All undone before commit.
-- ROLLBACK: docs/migrations/2026-11-03_rollback_leads_m2.sql (drops views and functions only; data stays).
-- ============================================================================
begin;
set local lock_timeout = '3s';

do $pre$
begin
  if not exists (select 1 from pg_namespace where nspname = 'leads') then raise exception 'leads M2: run M1 first'; end if;
  if exists (select 1 from pg_class where relname in ('v_frozen_leads', 'v_lead_interceptors', 'v_lead_review')
              and relnamespace = 'public'::regnamespace) then
    raise exception 'leads M2: a public view of that name already exists';
  end if;
end $pre$;

-- ---------------------------------------------------------------- helpers
create function leads.fn_street_key(p text) returns text
language sql immutable parallel safe set search_path = ''
as $fn$
  select case when a.m[1] is null or b.w = '' then null else a.m[1] || '|' || b.w end
    from (select regexp_match(btrim(regexp_replace(regexp_replace(regexp_replace(upper(coalesce(p, '')),
                   '[^A-Z0-9 ]', ' ', 'g'), '\m(STATE ROAD|STATE RD|S R|FLORIDA)\M', 'SR', 'g'), ' +', ' ', 'g')),
                   '^([0-9]+)[A-Z]? (.*)$') as m) a,
         lateral (select split_part(regexp_replace(coalesce(a.m[2], ''),
                   '^((N|S|E|W|NE|NW|SE|SW|NORTH|SOUTH|EAST|WEST|NORTHEAST|NORTHWEST|SOUTHEAST|SOUTHWEST) )+', ''),
                   ' ', 1) as w) b
$fn$;
comment on function leads.fn_street_key(text) is
  'House number + first street word, direction words skipped, STATE ROAD / SR / FLORIDA read as SR; unit and ZIP '
  'ignored. ''22191 POWERLINE RD A6-A9'' and ''22191 Powerline Road Palms Plaza'' both give ''22191|POWERLINE''.';

create function leads.fn_name_key(p text) returns text
language sql immutable parallel safe set search_path = ''
as $fn$
  select nullif(btrim(regexp_replace(regexp_replace(regexp_replace(upper(replace(coalesce(p, ''), '&', ' AND ')),
           '[^A-Z0-9 ]', ' ', 'g'),
           '\m(LLC|L L C|INC|INCORPORATED|CORP|CORPORATION|CO|COMPANY|THE|DBA|LTD|LP|LLP|PA|PLLC)\M', ' ', 'g'),
           ' +', ' ', 'g')), '')
$fn$;
comment on function leads.fn_name_key(text) is 'A business name for comparison: upper case, punctuation and LLC / INC / THE ... removed.';

create function leads.fn_bsi_date(p text) returns date
language plpgsql immutable set search_path = ''
as $fn$
begin
  if p is null or p !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' or left(p, 4)::int < 2000 then return null; end if;
  return left(p, 10)::date;   -- BSI's calendar date (its own midnight with an offset); never converted
exception when others then return null;
end $fn$;
comment on function leads.fn_bsi_date(text) is 'BSI''s calendar date from its timestamp text (first 10 characters). Before 2000 or unreadable = unknown (NULL).';

-- ---------------------------------------------------------------- the load
create function leads.ingest(p_source text, p_run_started_at timestamptz, p_records jsonb, p_file text)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  v_rec jsonb; v_sid text; v_srid bigint; v_est bigint; v_latest record; v_log bigint;
  v_t0 timestamptz := clock_timestamp();
  n_new_records int := 0; n_new_versions int := 0; n_unchanged int := 0;
begin
  if p_source is distinct from 'bsi' then
    raise exception 'leads.ingest: unknown source %', p_source using errcode = '22023';
  end if;
  if p_run_started_at is null then raise exception 'leads.ingest: run start required' using errcode = '22023'; end if;
  if jsonb_typeof(p_records) is distinct from 'array' or jsonb_array_length(p_records) = 0 then
    raise exception 'leads.ingest: records must be a non-empty array' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_records) e
              where coalesce(e ->> 'source_id', '') = '' or jsonb_typeof(e -> 'payload') is distinct from 'object') then
    raise exception 'leads.ingest: every record needs a source_id and an object payload' using errcode = '22023';
  end if;
  if (select count(*) from jsonb_array_elements(p_records))
     <> (select count(distinct e ->> 'source_id') from jsonb_array_elements(p_records) e) then
    raise exception 'leads.ingest: a source_id appears twice in the batch' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('leads'));

  if exists (select 1 from leads.source_versions v
               join public.entity_source_links l
                 on l.entity_type = 'source_record' and l.entity_id = v.source_record_id and l.source_system = p_source
              where v.fetched_at > p_run_started_at or v.last_seen_at > p_run_started_at) then
    raise exception 'leads.ingest: this run (%) is older than data already held for %', p_run_started_at, p_source
      using errcode = '22023';
  end if;

  insert into public.sync_log (sync_source, started_at, status, details)
  values ('leads:' || p_source, v_t0, 'running', jsonb_build_object('file', p_file, 'run_started_at', p_run_started_at))
  returning id into v_log;

  for v_rec in select e from jsonb_array_elements(p_records) e loop
    v_sid := v_rec ->> 'source_id';
    v_srid := null;
    select l.entity_id into v_srid from public.entity_source_links l
     where l.entity_type = 'source_record' and l.source_system = p_source and l.source_id = v_sid;
    if v_srid is null then
      insert into leads.establishments default values returning id into v_est;
      insert into leads.source_records (establishment_id) values (v_est) returning id into v_srid;
      insert into public.entity_source_links (entity_type, entity_id, source_system, source_id, source_name,
                                              match_method, match_confidence, synced_at)
      values ('source_record', v_srid, p_source, v_sid, v_rec ->> 'source_name', 'api_pull', 1, p_run_started_at);
      insert into leads.source_versions (source_record_id, fetched_at, last_seen_at, payload)
      values (v_srid, p_run_started_at, p_run_started_at, v_rec -> 'payload');
      n_new_records := n_new_records + 1;
      n_new_versions := n_new_versions + 1;
    else
      select x.fetched_at, x.payload into v_latest from leads.source_versions x
       where x.source_record_id = v_srid order by x.fetched_at desc limit 1;
      if v_latest.payload is distinct from (v_rec -> 'payload') then
        insert into leads.source_versions (source_record_id, fetched_at, last_seen_at, payload)
        values (v_srid, p_run_started_at, p_run_started_at, v_rec -> 'payload');
        n_new_versions := n_new_versions + 1;
      else
        update leads.source_versions set last_seen_at = p_run_started_at
         where source_record_id = v_srid and fetched_at = v_latest.fetched_at and last_seen_at < p_run_started_at;
        n_unchanged := n_unchanged + 1;
      end if;
      update public.entity_source_links
         set source_name = coalesce(v_rec ->> 'source_name', source_name), synced_at = p_run_started_at
       where entity_type = 'source_record' and entity_id = v_srid and source_system = p_source;
    end if;
  end loop;

  update public.sync_log
     set finished_at = clock_timestamp(), status = 'success', rows_inserted = n_new_versions, rows_updated = n_unchanged,
         duration_seconds = extract(epoch from clock_timestamp() - v_t0),
         details = details || jsonb_build_object('records', jsonb_array_length(p_records), 'new_records', n_new_records,
                                                 'new_versions', n_new_versions, 'unchanged', n_unchanged)
   where id = v_log;
  return jsonb_build_object('records', jsonb_array_length(p_records), 'new_records', n_new_records,
                            'new_versions', n_new_versions, 'unchanged', n_unchanged, 'sync_log_id', v_log);
end $fn$;
comment on function leads.ingest(text, timestamptz, jsonb, text) is
  'The only writer of leads.source_records / source_versions. p_records = [{source_id, source_name, payload}], one '
  'call per run (scripts/leads/load_bsi.mjs). A new version only when the payload changed; otherwise last_seen_at '
  'moves. Never touches a link, a decision or a status.';

-- ---------------------------------------------------------------- the decision
create function leads.decide_client(p_property_id bigint, p_verdict text, p_reason text, p_by text,
                                    p_source_record_id bigint default null, p_absent_from text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  v_client bigint; v_rec_est bigint; v_rec_prop bigint; v_seen timestamptz; v_holder bigint; v_new_est bigint; v_id bigint;
begin
  if p_by is null or public.fn_is_staff_email(p_by) is not true then
    raise exception 'leads.decide_client: % is not a staff email', coalesce(p_by, '(none)') using errcode = '42501';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'leads.decide_client: a reason is required' using errcode = '22023';
  end if;
  if p_verdict is null or p_verdict not in ('same', 'different', 'absent') then
    raise exception 'leads.decide_client: verdict must be same, different or absent' using errcode = '22023';
  end if;
  select p.client_id into v_client from public.properties p where p.id = p_property_id and p.deleted_at is null;
  if v_client is null then
    raise exception 'leads.decide_client: property % not found or deleted', p_property_id using errcode = '22023';
  end if;
  if coalesce(public.fn_is_non_customer(v_client), false) then
    raise exception 'leads.decide_client: property % belongs to a test client', p_property_id using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('leads'));

  if p_verdict = 'absent' then
    if p_absent_from is null or p_source_record_id is not null then
      raise exception 'leads.decide_client: absent takes a source and no record' using errcode = '22023';
    end if;
    insert into leads.match_decisions (property_id, absent_from, verdict, reason, decided_by)
    values (p_property_id, p_absent_from, 'absent', btrim(p_reason), p_by) returning id into v_id;
    return jsonb_build_object('decision_id', v_id, 'verdict', 'absent');
  end if;

  if p_source_record_id is null or p_absent_from is not null then
    raise exception 'leads.decide_client: same / different take a record and no source' using errcode = '22023';
  end if;
  select r.establishment_id into v_rec_est from leads.source_records r where r.id = p_source_record_id;
  if v_rec_est is null then
    raise exception 'leads.decide_client: record % not found', p_source_record_id using errcode = '22023';
  end if;
  select max(v.fetched_at) into v_seen from leads.source_versions v where v.source_record_id = p_source_record_id;
  insert into leads.match_decisions (property_id, source_record_id, verdict, seen_version_at, reason, decided_by)
  values (p_property_id, p_source_record_id, p_verdict, v_seen, btrim(p_reason), p_by) returning id into v_id;

  select e.property_id into v_rec_prop from leads.establishments e where e.id = v_rec_est;
  select e.id into v_holder from leads.establishments e where e.property_id = p_property_id and e.status = 'ACTIVE';

  if p_verdict = 'same' then
    if v_holder is not null and v_holder <> v_rec_est then
      -- the property already holds a restaurant: the record joins it (a merge)
      update leads.source_records set establishment_id = v_holder where id = p_source_record_id;
      if not exists (select 1 from leads.source_records r where r.establishment_id = v_rec_est) then
        update leads.establishments set status = 'INACTIVE' where id = v_rec_est;
      end if;
    elsif v_holder is null then
      if v_rec_prop is not null
         and exists (select 1 from leads.source_records r where r.establishment_id = v_rec_est and r.id <> p_source_record_id) then
        -- its restaurant is linked elsewhere and holds other records: this record moves to a new restaurant here
        insert into leads.establishments (property_id) values (p_property_id) returning id into v_new_est;
        update leads.source_records set establishment_id = v_new_est where id = p_source_record_id;
      else
        update leads.establishments set property_id = p_property_id where id = v_rec_est;
      end if;
    end if;   -- v_holder = v_rec_est: already linked
  else        -- different
    if v_rec_prop = p_property_id then
      if exists (select 1 from leads.source_records r where r.establishment_id = v_rec_est and r.id <> p_source_record_id) then
        insert into leads.establishments default values returning id into v_new_est;   -- a split
        update leads.source_records set establishment_id = v_new_est where id = p_source_record_id;
      else
        update leads.establishments set property_id = null where id = v_rec_est;        -- an unlink
      end if;
    end if;
  end if;

  return jsonb_build_object('decision_id', v_id, 'verdict', p_verdict,
    'establishment_id', (select r.establishment_id from leads.source_records r where r.id = p_source_record_id));
end $fn$;
comment on function leads.decide_client(bigint, text, text, text, bigint, text) is
  'The only writer of leads.match_decisions and of establishments.property_id. same / different on a record, or '
  'absent (with p_absent_from) for a property that has no record in that source. p_by must be a staff email.';

-- ---------------------------------------------------------------- private views
create view leads.v_src_bsi as
select sr.id as source_record_id,
       sr.establishment_id,
       l.source_id,
       v.payload -> 'search_item' ->> 'label' as name,
       v.payload -> 'search_item' -> 'physical_address' ->> 'address' as street,
       nullif(btrim(v.payload -> 'search_item' -> 'physical_address' ->> 'address2'), '') as unit,
       v.payload -> 'search_item' -> 'physical_address' ->> 'city' as city,
       left(v.payload -> 'search_item' -> 'physical_address' ->> 'zip_code', 5) as zip,
       case when upper(btrim(coalesce(v.payload -> 'search_item' -> 'mailing_address' ->> 'name', '')))
                 in ('', 'VACANT', 'CURRENT OCCUPANT') then null
            else btrim(v.payload -> 'search_item' -> 'mailing_address' ->> 'name') end as owner_company,
       v.payload -> 'search_item' ->> 'status' as source_status,
       coalesce(v.payload -> 'detail' -> 'interceptors', '[]'::jsonb) as interceptors,
       v.payload -> 'search_item' ->> 'ccn' as ccn,                 -- private: never in a granted view
       v.payload -> 'search_item' -> 'contact' as contact,          -- private: never in a granted view
       v.fetched_at as as_of,
       v.last_seen_at as confirmed_at,
       (select min(v2.fetched_at) from leads.source_versions v2 where v2.source_record_id = sr.id) as first_seen_at,
       v.last_seen_at = max(v.last_seen_at) over () as in_latest_run
  from leads.source_records sr
  join public.entity_source_links l
    on l.entity_type = 'source_record' and l.entity_id = sr.id and l.source_system = 'bsi'
  join lateral (select x.fetched_at, x.last_seen_at, x.payload from leads.source_versions x
                 where x.source_record_id = sr.id order by x.fetched_at desc limit 1) v on true;

create view leads.v_client_candidates as
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

create view leads.v_establishment_state as
select e.id as establishment_id, e.property_id, p.client_id, c.client_code, c.name as client_name,
       case
         when e.property_id is not null then
           case when c.status = 'INACTIVE' or p.deleted_at is not null then 'former_client'
                when c.client_code is null and c.status = 'ACTIVE' then 'warm'
                else 'client' end
         when coalesce(o.open_pairs, 0) > 0 then 'needs_review'
         else 'frozen'
       end as lead_state
  from leads.establishments e
  left join public.properties p on p.id = e.property_id
  left join public.clients c on c.id = p.client_id
  left join (select cc.establishment_id, count(*) as open_pairs from leads.v_client_candidates cc
              where not cc.decided group by cc.establishment_id) o on o.establishment_id = e.id
 where e.status = 'ACTIVE';

-- ---------------------------------------------------------------- public views for Viktor
create view public.v_frozen_leads as
select s.establishment_id, s.name, s.street, s.unit, s.city, s.zip, s.owner_company,
       i.interceptors, i.external_interceptors, i.overdue_interceptors, i.next_pump_due,
       case when i.next_pump_due < (now() at time zone 'America/New_York')::date
            then (now() at time zone 'America/New_York')::date - i.next_pump_due end as days_overdue,
       i.last_pumped, i.never_pumped,
       'bsi'::text as source_system, s.source_id, s.source_status, s.as_of, s.confirmed_at, s.first_seen_at, s.in_latest_run
  from leads.v_src_bsi s
  join leads.v_establishment_state st on st.establishment_id = s.establishment_id and st.lead_state = 'frozen'
  cross join lateral (
    select count(*) filter (where x ->> 'active' = 'y') as interceptors,
           count(*) filter (where x ->> 'active' = 'y' and x -> 'type' ->> 'identifier' = 'external') as external_interceptors,
           count(*) filter (where x ->> 'active' = 'y'
                              and leads.fn_bsi_date(x ->> 'next_pump_date') < (now() at time zone 'America/New_York')::date) as overdue_interceptors,
           min(leads.fn_bsi_date(x ->> 'next_pump_date')) filter (where x ->> 'active' = 'y') as next_pump_due,
           max(leads.fn_bsi_date(x ->> 'last_pump_date')) filter (where x ->> 'active' = 'y') as last_pumped,
           bool_and(leads.fn_bsi_date(x ->> 'last_pump_date') is null) filter (where x ->> 'active' = 'y') as never_pumped
      from jsonb_array_elements(s.interceptors) x) i;
comment on view public.v_frozen_leads is
  'Frozen leads: restaurants we only know from an outside source (BSI Online, City of Boca Raton FOG program), never '
  'contacted, not our client, not a Jobber lead, not waiting for review. One row per restaurant. Overdue = BSI''s next '
  'pump date before today (ET). Read-only, for Viktor (service role). Never shows a CCN or a contact. Trello #166.';
comment on column public.v_frozen_leads.owner_company is 'The mailing company BSI lists for the property (often the operator''s LLC; can be the landlord).';
comment on column public.v_frozen_leads.external_interceptors is 'Active outside grease interceptors (our pumping work); the rest are small kitchen traps.';
comment on column public.v_frozen_leads.next_pump_due is 'The earliest next pump date BSI shows across the active interceptors.';
comment on column public.v_frozen_leads.days_overdue is 'Days past next_pump_due as of today in Eastern time; NULL when not overdue.';
comment on column public.v_frozen_leads.never_pumped is 'True when no active interceptor has a pump on record in BSI.';
comment on column public.v_frozen_leads.as_of is 'When BSI first showed this exact content (start of that scrape run).';
comment on column public.v_frozen_leads.confirmed_at is 'Start of the latest scrape run that showed it unchanged.';

create view public.v_lead_interceptors as
select s.establishment_id, st.lead_state, st.property_id, st.client_id, st.client_code, st.client_name,
       'bsi'::text as source_system, s.source_id, x ->> 'id' as source_interceptor_id, s.name,
       x -> 'type' ->> 'value' as kind, x -> 'size' ->> 'value' as size, nullif(btrim(x ->> 'location'), '') as location,
       (x ->> 'active' = 'y') as active,
       case when x ->> 'needs_repair' in ('true', 'false') then (x ->> 'needs_repair')::boolean end as needs_repair,
       case when x ->> 'pump_frequency' ~ '^[0-9]+$' then (x ->> 'pump_frequency')::int end as pump_frequency_days,
       leads.fn_bsi_date(x ->> 'last_pump_date') as last_pump_date,
       leads.fn_bsi_date(x ->> 'next_pump_date') as next_pump_date,
       case when leads.fn_bsi_date(x ->> 'next_pump_date') < (now() at time zone 'America/New_York')::date
            then (now() at time zone 'America/New_York')::date - leads.fn_bsi_date(x ->> 'next_pump_date') end as days_overdue,
       x ->> 'last_maintenance_report_id' as last_maintenance_report_id,
       s.as_of, s.confirmed_at
  from leads.v_src_bsi s
  join leads.v_establishment_state st on st.establishment_id = s.establishment_id
  cross join lateral jsonb_array_elements(s.interceptors) x;
comment on view public.v_lead_interceptors is
  'One row per BSI interceptor, every state (frozen, needs_review, client, warm, former_client). For a client, '
  'property_id / client_code are ours and source_id / source_interceptor_id are BSI''s property and interceptor ids '
  '(the filing bot, Trello #169). Read-only, service role only. Never shows a CCN or a contact.';

create view public.v_lead_review as
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
comment on view public.v_lead_review is
  'What a person must decide before leads are trusted: client_candidate (an outside record that may be one of our '
  'properties), client_without_source_record (one of our properties in a covered city with no record), '
  'client_record_changed (a linked record whose name or owner changed). Decisions go through leads.decide_client. '
  'Read-only, service role only. Trello #166.';

-- ---------------------------------------------------------------- grants
revoke all on all functions in schema leads from public, anon, authenticated, service_role;
grant usage on schema leads to service_role;
grant execute on function leads.fn_street_key(text), leads.fn_name_key(text), leads.fn_bsi_date(text) to service_role;
revoke all on leads.v_src_bsi, leads.v_client_candidates, leads.v_establishment_state from public, anon, authenticated, service_role;
revoke all on public.v_frozen_leads, public.v_lead_interceptors, public.v_lead_review from public, anon, authenticated, service_role;
grant select on public.v_frozen_leads, public.v_lead_interceptors, public.v_lead_review to service_role;

-- ---------------------------------------------------------------- VERIFY
do $verify$
declare v_bad text; v_r jsonb; v_t timestamptz := now() - interval '1 day'; v_state text; v_srid bigint; v_ok boolean;
begin
  -- helpers
  if leads.fn_street_key('22191 POWERLINE RD A6-A9') is distinct from '22191|POWERLINE'
     or leads.fn_street_key('22191 Powerline Road Palms Plaza') is distinct from '22191|POWERLINE'
     or leads.fn_street_key('10 East Palmetto Park Road') is distinct from leads.fn_street_key('10 E Palmetto Park Rd')
     or leads.fn_street_key('5570 North Military Trail') is distinct from leads.fn_street_key('5570 N MILITARY TRAIL 402')
     or leads.fn_street_key('20642 Florida 7') is distinct from '20642|SR'
     or leads.fn_street_key('no number here') is not null then
    raise exception 'leads M2 VERIFY: fn_street_key cases failed';
  end if;
  if leads.fn_name_key('The Carrot Express, LLC') is distinct from 'CARROT EXPRESS'
     or leads.fn_bsi_date('2024-06-12T00:00:00-05:00') is distinct from date '2024-06-12'
     or leads.fn_bsi_date('1899-12-30T00:00:00-05:00') is not null
     or leads.fn_bsi_date('garbage') is not null then
    raise exception 'leads M2 VERIFY: fn_name_key / fn_bsi_date cases failed';
  end if;

  -- grants: the three public views exactly postgres + service_role SELECT + db_backup_reader SELECT
  select string_agg(distinct c.relname || ':' || coalesce(pg_get_userbyid(a.grantee), 'PUBLIC') || ':' || a.privilege_type, ', ')
    into v_bad
    from pg_class c cross join lateral aclexplode(c.relacl) a
   where c.oid in ('public.v_frozen_leads'::regclass, 'public.v_lead_interceptors'::regclass, 'public.v_lead_review'::regclass)
     and not (pg_get_userbyid(a.grantee) = 'postgres'
              or (pg_get_userbyid(a.grantee) in ('service_role', 'db_backup_reader') and a.privilege_type = 'SELECT'));
  if v_bad is not null then raise exception 'leads M2 VERIFY: unexpected view grants: %', v_bad; end if;
  if has_table_privilege('authenticated', 'public.v_frozen_leads', 'SELECT') or has_table_privilege('anon', 'public.v_lead_review', 'SELECT')
     or not has_table_privilege('service_role', 'public.v_lead_interceptors', 'SELECT')
     or has_table_privilege('service_role', 'leads.v_src_bsi', 'SELECT') then
    raise exception 'leads M2 VERIFY: view privileges are not as intended';
  end if;
  if has_function_privilege('service_role', 'leads.ingest(text,timestamptz,jsonb,text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'leads.decide_client(bigint,text,text,text,bigint,text)', 'EXECUTE')
     or has_function_privilege('anon', 'leads.decide_client(bigint,text,text,text,bigint,text)', 'EXECUTE')
     or not has_function_privilege('service_role', 'leads.fn_street_key(text)', 'EXECUTE')
     or not has_function_privilege('service_role', 'leads.fn_bsi_date(text)', 'EXECUTE') then
    raise exception 'leads M2 VERIFY: function privileges are not as intended';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public'
              and table_name in ('v_frozen_leads', 'v_lead_interceptors', 'v_lead_review')
              and (column_name ilike '%ccn%' or column_name ilike '%contact%' or column_name ilike '%phone%'
                   or column_name ilike '%email%' or column_name ilike '%mailing%')) then
    raise exception 'leads M2 VERIFY: a public view exposes a CCN or contact column';
  end if;

  -- a fake run: two records in a city nobody serves, then the same run again, a change, an older run
  begin
    v_r := leads.ingest('bsi', v_t, '[{"source_id":"verify-1","source_name":"VERIFY ONE","payload":{"search_item":{"label":"VERIFY ONE","physical_address":{"address":"1 Verify Rd","city":"Verifyville","zip_code":"00001"}},"detail":{"interceptors":[]}}},
                                     {"source_id":"verify-2","source_name":"VERIFY TWO","payload":{"search_item":{"label":"VERIFY TWO","physical_address":{"address":"2 Verify Rd","city":"Verifyville","zip_code":"00001"}},"detail":{"interceptors":[]}}}]'::jsonb, 'verify');
    if (v_r ->> 'new_records')::int <> 2 then raise exception 'leads M2 VERIFY: first run %', v_r; end if;
    v_r := leads.ingest('bsi', v_t, '[{"source_id":"verify-1","source_name":"VERIFY ONE","payload":{"search_item":{"label":"VERIFY ONE","physical_address":{"address":"1 Verify Rd","city":"Verifyville","zip_code":"00001"}},"detail":{"interceptors":[]}}}]'::jsonb, 'verify');
    if (v_r ->> 'unchanged')::int <> 1 or (v_r ->> 'new_versions')::int <> 0 then raise exception 'leads M2 VERIFY: same run again %', v_r; end if;
    v_r := leads.ingest('bsi', v_t + interval '1 hour', '[{"source_id":"verify-1","source_name":"VERIFY ONE","payload":{"search_item":{"label":"VERIFY ONE RENAMED","physical_address":{"address":"1 Verify Rd","city":"Verifyville","zip_code":"00001"}},"detail":{"interceptors":[]}}}]'::jsonb, 'verify');
    if (v_r ->> 'new_versions')::int <> 1 then raise exception 'leads M2 VERIFY: a change made no version %', v_r; end if;
    begin
      perform leads.ingest('bsi', v_t - interval '1 day', '[{"source_id":"verify-3","payload":{}}]'::jsonb, 'verify');
      raise exception 'leads M2 VERIFY: an older run was accepted';
    exception when sqlstate '22023' then null;
    end;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- a fake Boca record at Grove Kosher's street: candidate, then same (client), then different (frozen); refusals
  begin
    perform leads.ingest('bsi', v_t, '[{"source_id":"verify-g","source_name":"VERIFY GROVE","payload":{"search_item":{"label":"VERIFY NEIGHBOUR","physical_address":{"address":"22191 POWERLINE RD 99Z","city":"Boca Raton","zip_code":"33433"}},"detail":{"interceptors":[]}}}]'::jsonb, 'verify');
    select l.entity_id into v_srid from public.entity_source_links l where l.entity_type = 'source_record' and l.source_system = 'bsi' and l.source_id = 'verify-g';
    select exists (select 1 from leads.v_client_candidates where source_record_id = v_srid and property_id = 4 and not decided) into v_ok;
    if not v_ok then raise exception 'leads M2 VERIFY: the Grove-street record is not a candidate for property 4'; end if;
    select lead_state into v_state from leads.v_establishment_state where establishment_id = (select establishment_id from leads.source_records where id = v_srid);
    if v_state <> 'needs_review' then raise exception 'leads M2 VERIFY: expected needs_review, got %', v_state; end if;
    perform leads.decide_client(4, 'same', 'verify', 'fred@ayache.com', v_srid);
    select lead_state into v_state from leads.v_establishment_state where establishment_id = (select establishment_id from leads.source_records where id = v_srid);
    if v_state <> 'client' then raise exception 'leads M2 VERIFY: after same expected client, got %', v_state; end if;
    perform leads.decide_client(4, 'different', 'verify', 'fred@ayache.com', v_srid);
    select lead_state into v_state from leads.v_establishment_state where establishment_id = (select establishment_id from leads.source_records where id = v_srid);
    if v_state <> 'frozen' then raise exception 'leads M2 VERIFY: after different expected frozen, got %', v_state; end if;
    begin
      perform leads.decide_client(4, 'same', 'verify', 'someone@gmail.com', v_srid);
      raise exception 'leads M2 VERIFY: a non-staff email was accepted';
    exception when sqlstate '42501' then null;
    end;
    begin
      perform leads.decide_client(162, 'same', 'verify', 'fred@ayache.com', v_srid);
      raise exception 'leads M2 VERIFY: a test client property was accepted';
    exception when sqlstate '22023' then null;
    end;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;
end $verify$;

notify pgrst, 'reload schema';
commit;
