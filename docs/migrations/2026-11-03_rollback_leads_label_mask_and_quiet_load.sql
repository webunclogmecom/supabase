-- ROLLBACK of 2026-11-03_2039_leads_label_mask_and_quiet_load. The four view bodies, leads.ingest, the previous
-- leads.ingest_quiet and the comments as they were just before it, captured from pg_get_viewdef / pg_get_functiondef /
-- obj_description on 2026-11-03 (not retyped, md5-checked); the 431 link labels are copied back from the payload.
-- ORDER: run this BEFORE 2026-11-03_rollback_leads_privacy_fixes.sql, which drops the previous ingest_quiet signature
-- that only this file puts back.
-- THE LOADER: put scripts/leads/load_bsi.mjs back to its 8bb8a1e5 version with this file (the current one refuses to
-- send without the text signature, on purpose). Never run an older loader's --dry-run: before 8bb8a1e5 it was the DO
-- block that wrote every CCN and contact to the server log (16:41 ET 2026-11-03).
-- Undoing this shows the 3 contact-name labels to service_role again, copies the labels back into
-- public.entity_source_links, and lets a cast, a lock wait or a cancel fail the loader's statement (and log it).
begin;
set local lock_timeout = '3s';
set local search_path = public, extensions;
create or replace view leads.v_bsi_contact_names as
SELECT DISTINCT upper(regexp_replace(btrim((((payload -> 'search_item'::text) -> 'contact'::text) ->> 'name'::text)), '[[:space:]]+'::text, ' '::text, 'g'::text)) AS name_key
   FROM leads.source_versions v
  WHERE (COALESCE(btrim((((payload -> 'search_item'::text) -> 'contact'::text) ->> 'name'::text)), ''::text) <> ''::text);
create or replace view public.v_frozen_leads as
SELECT s.establishment_id,
    s.name,
    s.street,
    s.unit,
    s.city,
    s.zip,
        CASE
            WHEN (upper(regexp_replace(btrim(s.owner_company), '[[:space:]]+'::text, ' '::text, 'g'::text)) IN ( SELECT n.name_key
               FROM leads.v_bsi_contact_names n)) THEN NULL::text
            ELSE s.owner_company
        END AS owner_company,
    i.interceptors,
    i.external_interceptors,
    i.overdue_interceptors,
    i.next_pump_due,
        CASE
            WHEN (i.next_pump_due < ((now() AT TIME ZONE 'America/New_York'::text))::date) THEN (((now() AT TIME ZONE 'America/New_York'::text))::date - i.next_pump_due)
            ELSE NULL::integer
        END AS days_overdue,
    i.last_pumped,
    i.never_pumped,
    'bsi'::text AS source_system,
    s.source_id,
    s.source_status,
    s.as_of,
    s.confirmed_at,
    s.first_seen_at,
    s.in_latest_run
   FROM ((leads.v_src_bsi s
     JOIN leads.v_establishment_state st ON (((st.establishment_id = s.establishment_id) AND (st.lead_state = 'frozen'::text))))
     CROSS JOIN LATERAL ( SELECT count(*) FILTER (WHERE ((x.value ->> 'active'::text) = 'y'::text)) AS interceptors,
            count(*) FILTER (WHERE (((x.value ->> 'active'::text) = 'y'::text) AND (((x.value -> 'type'::text) ->> 'identifier'::text) = 'external'::text))) AS external_interceptors,
            count(*) FILTER (WHERE (((x.value ->> 'active'::text) = 'y'::text) AND (leads.fn_bsi_date((x.value ->> 'next_pump_date'::text)) < ((now() AT TIME ZONE 'America/New_York'::text))::date))) AS overdue_interceptors,
            min(leads.fn_bsi_date((x.value ->> 'next_pump_date'::text))) FILTER (WHERE ((x.value ->> 'active'::text) = 'y'::text)) AS next_pump_due,
            max(leads.fn_bsi_date((x.value ->> 'last_pump_date'::text))) FILTER (WHERE ((x.value ->> 'active'::text) = 'y'::text)) AS last_pumped,
            bool_and((leads.fn_bsi_date((x.value ->> 'last_pump_date'::text)) IS NULL)) FILTER (WHERE ((x.value ->> 'active'::text) = 'y'::text)) AS never_pumped
           FROM jsonb_array_elements(s.interceptors) x(value)) i);
create or replace view public.v_lead_interceptors as
SELECT s.establishment_id,
    st.lead_state,
    st.property_id,
    st.client_id,
    st.client_code,
    st.client_name,
    'bsi'::text AS source_system,
    s.source_id,
    (x.value ->> 'id'::text) AS source_interceptor_id,
    s.name,
    ((x.value -> 'type'::text) ->> 'value'::text) AS kind,
    ((x.value -> 'size'::text) ->> 'value'::text) AS size,
    NULLIF(btrim((x.value ->> 'location'::text)), ''::text) AS location,
    ((x.value ->> 'active'::text) = 'y'::text) AS active,
        CASE
            WHEN ((x.value ->> 'needs_repair'::text) = ANY (ARRAY['true'::text, 'false'::text])) THEN ((x.value ->> 'needs_repair'::text))::boolean
            ELSE NULL::boolean
        END AS needs_repair,
        CASE
            WHEN ((x.value ->> 'pump_frequency'::text) ~ '^[0-9]+$'::text) THEN ((x.value ->> 'pump_frequency'::text))::integer
            ELSE NULL::integer
        END AS pump_frequency_days,
    leads.fn_bsi_date((x.value ->> 'last_pump_date'::text)) AS last_pump_date,
    leads.fn_bsi_date((x.value ->> 'next_pump_date'::text)) AS next_pump_date,
        CASE
            WHEN (leads.fn_bsi_date((x.value ->> 'next_pump_date'::text)) < ((now() AT TIME ZONE 'America/New_York'::text))::date) THEN (((now() AT TIME ZONE 'America/New_York'::text))::date - leads.fn_bsi_date((x.value ->> 'next_pump_date'::text)))
            ELSE NULL::integer
        END AS days_overdue,
    (x.value ->> 'last_maintenance_report_id'::text) AS last_maintenance_report_id,
    s.as_of,
    s.confirmed_at
   FROM ((leads.v_src_bsi s
     JOIN leads.v_establishment_state st ON ((st.establishment_id = s.establishment_id)))
     CROSS JOIN LATERAL jsonb_array_elements(s.interceptors) x(value));
create or replace view public.v_lead_review as
WITH cand AS MATERIALIZED (
         SELECT v_client_candidates.source_record_id,
            v_client_candidates.establishment_id,
            v_client_candidates.source_id,
            v_client_candidates.name,
            v_client_candidates.street,
            v_client_candidates.owner_company,
            v_client_candidates.property_id,
            v_client_candidates.client_id,
            v_client_candidates.client_code,
            v_client_candidates.client_name,
            v_client_candidates.client_status,
            v_client_candidates.client_street,
            v_client_candidates.matched_on,
            v_client_candidates.name_score,
            v_client_candidates.last_verdict,
            v_client_candidates.last_decided_by,
            v_client_candidates.last_decided_at,
            v_client_candidates.decided
           FROM leads.v_client_candidates
        ), covered AS MATERIALIZED (
         SELECT DISTINCT upper(btrim(s.city)) AS city_key
           FROM leads.v_src_bsi s
        )
 SELECT 'client_candidate'::text AS kind,
    c.source_record_id,
    c.establishment_id,
    'bsi'::text AS source_system,
    c.source_id,
    c.name AS source_name,
    c.street AS source_street,
        CASE
            WHEN (upper(regexp_replace(btrim(c.owner_company), '[[:space:]]+'::text, ' '::text, 'g'::text)) IN ( SELECT n.name_key
               FROM leads.v_bsi_contact_names n)) THEN NULL::text
            ELSE c.owner_company
        END AS owner_company,
    c.property_id,
    c.client_code,
    c.client_name,
    c.client_street,
    c.matched_on,
    c.name_score,
    c.last_verdict,
    c.last_decided_by,
    c.last_decided_at
   FROM cand c
  WHERE (NOT c.decided)
UNION ALL
 SELECT 'client_without_source_record'::text AS kind,
    NULL::bigint AS source_record_id,
    NULL::bigint AS establishment_id,
    'bsi'::text AS source_system,
    NULL::text AS source_id,
    NULL::text AS source_name,
    NULL::text AS source_street,
    NULL::text AS owner_company,
    p.id AS property_id,
    c.client_code,
    c.name AS client_name,
    p.address AS client_street,
    NULL::text AS matched_on,
    NULL::numeric AS name_score,
    NULL::text AS last_verdict,
    NULL::text AS last_decided_by,
    NULL::timestamp with time zone AS last_decided_at
   FROM (properties p
     JOIN clients c ON ((c.id = p.client_id)))
  WHERE ((p.deleted_at IS NULL) AND (c.status <> 'INACTIVE'::text) AND (upper(btrim(p.city)) IN ( SELECT k.city_key
           FROM covered k)) AND (NOT COALESCE(fn_is_non_customer(c.id), false)) AND (NOT (EXISTS ( SELECT 1
           FROM leads.establishments e
          WHERE ((e.property_id = p.id) AND (e.status = 'ACTIVE'::text))))) AND (NOT (EXISTS ( SELECT 1
           FROM cand cc
          WHERE ((cc.property_id = p.id) AND (NOT cc.decided))))) AND (NOT (EXISTS ( SELECT 1
           FROM leads.match_decisions md
          WHERE ((md.property_id = p.id) AND (md.verdict = 'absent'::text) AND (md.absent_from = 'bsi'::text))))))
UNION ALL
 SELECT 'client_record_changed'::text AS kind,
    sr.id AS source_record_id,
    e.id AS establishment_id,
    'bsi'::text AS source_system,
    s.source_id,
    s.name AS source_name,
    s.street AS source_street,
        CASE
            WHEN (upper(regexp_replace(btrim(s.owner_company), '[[:space:]]+'::text, ' '::text, 'g'::text)) IN ( SELECT n.name_key
               FROM leads.v_bsi_contact_names n)) THEN NULL::text
            ELSE s.owner_company
        END AS owner_company,
    e.property_id,
    c.client_code,
    c.name AS client_name,
    p.address AS client_street,
    NULL::text AS matched_on,
    NULL::numeric AS name_score,
    d.verdict AS last_verdict,
    d.decided_by AS last_decided_by,
    d.decided_at AS last_decided_at
   FROM ((((((leads.establishments e
     JOIN leads.source_records sr ON ((sr.establishment_id = e.id)))
     JOIN leads.v_src_bsi s ON ((s.source_record_id = sr.id)))
     JOIN properties p ON ((p.id = e.property_id)))
     JOIN clients c ON ((c.id = p.client_id)))
     JOIN LATERAL ( SELECT md.verdict,
            md.decided_by,
            md.decided_at,
            md.source_record_id,
            md.seen_version_at
           FROM leads.match_decisions md
          WHERE ((md.source_record_id = sr.id) AND (md.property_id = e.property_id))
          ORDER BY md.id DESC
         LIMIT 1) d ON (true))
     JOIN leads.source_versions dv ON (((dv.source_record_id = d.source_record_id) AND (dv.fetched_at = d.seen_version_at))))
  WHERE ((e.status = 'ACTIVE'::text) AND (d.verdict = 'same'::text) AND ((((dv.payload -> 'search_item'::text) ->> 'label'::text) IS DISTINCT FROM s.name) OR ((((dv.payload -> 'search_item'::text) -> 'mailing_address'::text) ->> 'name'::text) IS DISTINCT FROM ( SELECT (((x.payload -> 'search_item'::text) -> 'mailing_address'::text) ->> 'name'::text)
           FROM leads.source_versions x
          WHERE (x.source_record_id = sr.id)
          ORDER BY x.fetched_at DESC
         LIMIT 1))));
CREATE OR REPLACE FUNCTION leads.ingest(p_source text, p_run_started_at timestamp with time zone, p_records jsonb, p_file text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;
drop function leads.ingest_quiet(text, text, text, text, boolean);
CREATE OR REPLACE FUNCTION leads.ingest_quiet(p_source text, p_run_started_at timestamp with time zone, p_records jsonb, p_file text, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- A failing statement is written to the server log with its full text. The loader sends the payload (CCNs, BSI
-- contacts) as a literal, so that statement must never fail: every error is caught here and returned as data, and a
-- dry run undoes itself inside this function (2026-11-03_1848).
declare v_ingest jsonb; v_report jsonb;
begin
  begin
    v_ingest := leads.ingest(p_source, p_run_started_at, p_records, p_file);
    if p_dry_run is false then
      return jsonb_build_object('ok', true, 'dry_run', false, 'ingest', v_ingest);
    end if;
    v_report := jsonb_build_object('ok', true, 'dry_run', true, 'ingest', v_ingest,
      'states', (select jsonb_object_agg(s.lead_state, s.n)
                   from (select e.lead_state, count(*) as n from leads.v_establishment_state e group by 1) s),
      'frozen_rows', (select count(*) from public.v_frozen_leads),
      'interceptor_rows', (select count(*) from public.v_lead_interceptors),
      'review', (select jsonb_agg(jsonb_build_object('kind', r.kind, 'bsi', r.source_id, 'name', r.source_name,
                   'client', r.client_code, 'property', r.property_id, 'on', r.matched_on, 'score', r.name_score)
                   order by r.kind, r.client_code, r.source_id)
                   from public.v_lead_review r));
    raise exception using errcode = 'P0001', message = 'leads_ingest_quiet_undo';
  exception when others then
    if sqlerrm = 'leads_ingest_quiet_undo' then return v_report; end if;
    return jsonb_build_object('ok', false, 'dry_run', coalesce(p_dry_run, true), 'sqlstate', sqlstate, 'message', sqlerrm);
  end;
end $function$;
comment on function leads.ingest_quiet(text, timestamptz, jsonb, text, boolean) is 'The loader''s only entry (scripts/leads/load_bsi.mjs). Calls leads.ingest; never raises: an error comes back as {ok:false, sqlstate, message}, so the statement carrying the payload is never written to the server log. p_dry_run (default true) returns what the load would produce and keeps nothing.';
revoke all on function leads.ingest_quiet(text, timestamptz, jsonb, text, boolean) from public, anon, authenticated, service_role;
update public.entity_source_links l set source_name = s.name
  from leads.v_src_bsi s
 where l.entity_type = 'source_record' and l.source_system = 'bsi' and l.entity_id = s.source_record_id;
comment on view leads.v_bsi_contact_names is 'Every contact-person name BSI has given us (any version), upper case, spaces collapsed. Private. The public lead views blank a mailing name (owner_company) equal to one of these (2026-11-03_1848).';
comment on view public.v_frozen_leads is 'Frozen leads: restaurants we only know from an outside source (BSI Online, City of Boca Raton FOG program), never contacted, not our client, not a Jobber lead, not waiting for review. One row per restaurant. Overdue = BSI''s next pump date before today (ET). Read-only, for Viktor (service role; his first read is not tested yet). Never shows a CCN or a BSI contact (owner_company is blank when it is a contact''s name). Trello #166.';
comment on column public.v_frozen_leads.name is null;
comment on column public.v_frozen_leads.owner_company is 'The mailing name BSI lists for the property (often the operator''s LLC; can be the landlord). Blank when it is the name of a person BSI lists as a contact (private, Fred 2026-11-03).';
comment on view public.v_lead_interceptors is 'One row per BSI interceptor, every state (frozen, needs_review, client, warm, former_client). For a client, property_id / client_code are ours and source_id / source_interceptor_id are BSI''s property and interceptor ids (the filing bot, Trello #169). Read-only, service role only. Never shows a CCN or a contact.';
comment on view public.v_lead_review is 'What a person must decide before leads are trusted: client_candidate (an outside record that may be one of our properties), client_without_source_record (one of our properties in a covered city with no record), client_record_changed (a linked record whose name or owner changed). Decisions go through leads.decide_client. Read-only, service role only; owner_company is blank when it is a BSI contact''s name. Trello #166.';
comment on table leads.source_versions is 'What the source said: a new row only when the content changed; otherwise only last_seen_at moves. fetched_at = start of the first run that returned this content; last_seen_at = start of the latest run that returned it unchanged. Private: payloads hold CCNs and BSI contacts (Fred 2026-11-03: keep privately). No API role reads them. The only view that outputs them is leads.v_src_bsi, readable by postgres, db_backup_reader (the backup) and Supabase''s platform roles, like every table. scripts/checks/leads_integrity.sql tests the public views'' values.';
comment on function leads.ingest(text, timestamptz, jsonb, text) is 'The only writer of leads.source_records / source_versions. p_records = [{source_id, source_name, payload}], one call per run (scripts/leads/load_bsi.mjs). A new version only when the payload changed; otherwise last_seen_at moves. Never touches a link, a decision or a status.';
notify pgrst, 'reload schema';
commit;
