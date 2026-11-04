-- ROLLBACK of 2026-11-03_1848_leads_privacy_fixes. The three view bodies and the comments as they were just before it,
-- captured from pg_get_viewdef / obj_description on 2026-11-03 (not retyped); then drops leads.ingest_quiet and
-- leads.v_bsi_contact_names. Revert scripts/leads/load_bsi.mjs with it (git), or the loader calls a missing function.
-- Undoing this shows the 431 BSI links to signed-in staff again and the BSI contact names in owner_company.
-- ORDER (added 2026-11-03 ~20:50 ET): run 2026-11-03_rollback_leads_label_mask_and_quiet_load.sql FIRST; it puts back the
-- ingest_quiet signature this file drops. Rehearsed as one chain, undone (scratchpad chain_rollbacks.mjs).
-- 🛑 THE LOADER: the version this file goes with (fd2eab18) has a --dry-run that is the DO block which wrote every CCN and
-- contact to the server log at 16:41 ET. After a revert, run live loads only, or keep the current loader and accept
-- that it refuses to run.
begin;
set local lock_timeout = '3s';
set local search_path = public, extensions;
create or replace view client.entity_source_links as
SELECT id,
    entity_type,
    entity_id,
    source_system,
    source_id,
    source_name,
    match_method,
    match_confidence,
    synced_at,
    created_at
   FROM entity_source_links;
create or replace view public.v_frozen_leads as
SELECT s.establishment_id,
    s.name,
    s.street,
    s.unit,
    s.city,
    s.zip,
    s.owner_company,
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
    c.owner_company,
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
    s.owner_company,
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
comment on view client.entity_source_links is null;
comment on view public.v_frozen_leads is 'Frozen leads: restaurants we only know from an outside source (BSI Online, City of Boca Raton FOG program), never contacted, not our client, not a Jobber lead, not waiting for review. One row per restaurant. Overdue = BSI''s next pump date before today (ET). Read-only, for Viktor (service role). Never shows a CCN or a contact. Trello #166.';
comment on column public.v_frozen_leads.owner_company is 'The mailing company BSI lists for the property (often the operator''s LLC; can be the landlord).';
comment on view public.v_lead_review is 'What a person must decide before leads are trusted: client_candidate (an outside record that may be one of our properties), client_without_source_record (one of our properties in a covered city with no record), client_record_changed (a linked record whose name or owner changed). Decisions go through leads.decide_client. Read-only, service role only. Trello #166.';
comment on table leads.source_versions is 'What the source said: a new row only when the content changed; otherwise only last_seen_at moves. fetched_at = start of the first run that returned this content; last_seen_at = start of the latest run that returned it unchanged. Private: payloads hold CCNs and BSI contacts (Fred 2026-11-03: keep privately); no view anyone can read outputs them (scripts/checks/leads_integrity.sql).';
comment on schema leads is 'Frozen leads (Trello #165/#166, 2026-11-03): outside records about restaurants we do not serve yet (BSI Online Boca Raton first), kept as received with their source and dates. Private: not exposed to the API; Viktor reads the public.v_frozen_leads / v_lead_interceptors / v_lead_review views. Plan docs/specs/2026-11-03-boca-bsi-leads-and-filing-plan.md.';
drop function leads.ingest_quiet(text, timestamptz, jsonb, text, boolean);
drop view leads.v_bsi_contact_names;
notify pgrst, 'reload schema';
commit;
