-- 2026-10-30_1135  GDO filing: an EXPIRED permit is filed when it is the one we have; 315-CAP visit 7849 kept out of
--                   the hourly queue so Jonathan can press Auto file on it himself
--
-- WHY. Slack #apps-notifications 2026-10-30 (the GDO digest thread): 315-CAP Capas Burger Aventura sat in the
-- digest as "No GDO permit on the visit" (manifest 834433, visit 7849, 2026-08-28). Diego entered GDO-14098 in the
-- Client App, but its PDF is the 2024 permit ("valid from 01-JAN-2024 through 31-DEC-2024"), so
-- client.upsert_gdo_permit stored it EXPIRED; public.v_derm_portal_fields (ACTIVE only) still gave the visit no
-- permit and Auto file answered "No GDO permit on file for this visit." Fred: *"even if it's expired or not that's
-- the one we have so we file it with that expired one, if we get an error from the Bot it'd be different because we
-- just need to deliver the data, the bot will deliver the response (error or success)"*. Jonathan asked to keep the
-- Capas case for his video ("don't run it"); Fred: *"apply the fix, but can't you just skip this one visit from the
-- queue so they auto file it?"*
--
-- WHAT. All three bodies copied from the LIVE pg_get_viewdef (md5 fields 3ff7de253bfff2da1e2278df9740a041, queue 82bb5d0022e2f19e660d4f8e3dbb4a42,
-- held b8bbe1fc394a1362108abba7f8de23c4); one anchored, literal edit each:
--   1. public.v_derm_portal_fields, the permit lateral: ACTIVE, or EXPIRED when the client has no ACTIVE permit;
--      never INACTIVE (53 rows: a permit naming another business, or replaced). Every filing path reads this view:
--      the hourly queue, the Auto file button and Record a manual filing (derm.visit_gdo_our_record and siblings),
--      fn_record_manual_gdo_report, fn_resolve_rpa_permit, fn_requeue_derm_portal, the health check. rpa-derm-result
--      already accepts any permit of the visit's client. EXPIRED is written only when a permit is entered with a past
--      expiration; nothing expires permits by date (22 ACTIVE permits are past their date and are filed as before).
--   2. public.v_derm_portal_queue: a visit whose id is listed in public.app_config 'gdo_queue_skip_visit_ids'
--      (comma-separated, audited table) is not served to the hourly bot. Set here to '7849'. The Auto file button
--      never reads the queue, so it still works. To end the skip: update app_config set value = '' (no DDL).
--      ⚠ The queue keeps one visit per (manifest, permit); skipping a visit can let a sibling on the same manifest be
--      served instead. 7849 has none (manifest 1773 has no other reporting visit).
--   3. public.v_derm_portal_queue_held: such a visit reads held_by = 'skipped_by_hand' (before the sibling arm), so
--      the bot's held summary shows the skip instead of hiding it.
-- REACH, measured 2026-10-30 ~11:50 ET in a rolled-back run of these exact bodies: only 315-CAP changes. Visits 7849 and
-- 7992 get GDO-14098 (gdo 261); the queue goes from empty to 7992 alone (7849 skipped_by_hand); every other held row
-- unchanged; 7849's button row: GDO-14098, ticket 834433, can_record_manual, no lease in 20 h. Control: with the skip
-- list empty, 7849 enters the queue too.
-- Rule 8: views and one app_config row (app_config is audited). ROLLBACK: 2026-10-30_rollback_gdo_filing_expired_permit.sql

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(pg_get_viewdef('public.v_derm_portal_fields'::regclass, false)) <> '3ff7de253bfff2da1e2278df9740a041' then
    raise exception 'public.v_derm_portal_fields changed since this migration was generated; rebuild it from the live definition';
  end if;
end
$pin$;
do $pin$
begin
  if md5(pg_get_viewdef('public.v_derm_portal_queue'::regclass, false)) <> '82bb5d0022e2f19e660d4f8e3dbb4a42' then
    raise exception 'public.v_derm_portal_queue changed since this migration was generated; rebuild it from the live definition';
  end if;
end
$pin$;
do $pin$
begin
  if md5(pg_get_viewdef('public.v_derm_portal_queue_held'::regclass, false)) <> 'b8bbe1fc394a1362108abba7f8de23c4' then
    raise exception 'public.v_derm_portal_queue_held changed since this migration was generated; rebuild it from the live definition';
  end if;
end
$pin$;

insert into public.app_config (key, value) values ('gdo_queue_skip_visit_ids', '7849')
  on conflict (key) do update set value = excluded.value;

create or replace view public.v_derm_portal_fields as
 SELECT v.id AS visit_id,
    v.visit_date,
    v.client_id,
    c.client_code,
    c.name AS client_name,
    client.fn_derm_recipient(c.id) ->> 'email'::text AS client_email,
    pp.address,
    pp.city,
    pp.zip,
    pp.county,
    gd.gdo_number,
    m.id AS manifest_id,
    m.white_manifest_number,
    m.dump_ticket_date,
    df.name AS disposal_facility,
    m.derm_address_url,
    m.derm_address_extra_urls,
    m.derm_manifest_url,
    m.derm_manifest_extra_urls,
    GREATEST(v.updated_at, mv_link.linked_at) AS updated_at,
    mv_link.linked_at,
        CASE
            WHEN m.yellow_ticket_number IS NOT NULL THEN m.yellow_ticket_number
            WHEN m.white_manifest_number IS NOT NULL AND length(m.white_manifest_number) >= 5 THEN m.white_manifest_number
            ELSE NULL::text
        END AS ticket_number,
        CASE
            WHEN m.yellow_ticket_number IS NOT NULL THEN 'broward'::text
            WHEN m.white_manifest_number IS NOT NULL AND length(m.white_manifest_number) >= 5 THEN 'dade'::text
            ELSE 'unknown'::text
        END AS jurisdiction,
    gd.gdo_id,
    vs.urls AS visit_sheet_urls,
    m.derm_address_url IS NOT NULL OR COALESCE(cardinality(m.derm_address_extra_urls), 0) > 0 OR cardinality(vs.urls) > 0 AS has_sheet
   FROM visits v
     JOIN clients c ON c.id = v.client_id
     JOIN LATERAL ( SELECT mv.manifest_id,
            GREATEST(m2.updated_at, m2.created_at) AS linked_at
           FROM manifest_visits mv
             JOIN derm_manifests m2 ON m2.id = mv.manifest_id AND m2.deleted_at IS NULL
          WHERE mv.visit_id = v.id
          ORDER BY m2.created_at DESC
         LIMIT 1) mv_link ON true
     JOIN derm_manifests m ON m.id = mv_link.manifest_id
     LEFT JOIN LATERAL ( SELECT p.address,
            p.city,
            p.zip,
            p.county
           FROM properties p
          WHERE p.client_id = c.id AND p.is_primary
          ORDER BY p.id
         LIMIT 1) pp ON true
     LEFT JOIN LATERAL ( SELECT g.gdo_number,
            g.id AS gdo_id
           FROM gdos g
          WHERE g.client_id = c.id AND g.gdo_number ~ '^GDO-[0-9]+$'::text AND (g.status = 'ACTIVE'::text OR g.status = 'EXPIRED'::text AND NOT (EXISTS ( SELECT 1
                   FROM gdos a
                  WHERE a.client_id = c.id AND a.status = 'ACTIVE'::text AND a.gdo_number ~ '^GDO-[0-9]+$'::text)))) gd ON true
     LEFT JOIN disposal_facilities df ON df.id = m.disposal_facility_id
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN m.derm_address_url IS NULL AND COALESCE(cardinality(m.derm_address_extra_urls), 0) = 0 THEN ARRAY( SELECT d.url
                       FROM derm.fn_fog_documents(m.id, v.client_id, v.id) d(effective_page, url)
                      ORDER BY d.effective_page)
                    ELSE '{}'::text[]
                END AS urls) vs
  WHERE v.deleted_at IS NULL AND fn_visit_is_gdo_reporting(v.id);

create or replace view public.v_derm_portal_queue as
 SELECT DISTINCT ON (manifest_id, gdo_id) visit_id,
    visit_date,
    client_id,
    client_code,
    client_name,
    client_email,
    address,
    city,
    zip,
    county,
    gdo_number,
    manifest_id,
    white_manifest_number,
    dump_ticket_date,
    disposal_facility,
    derm_address_url,
    derm_address_extra_urls,
    derm_manifest_url,
    derm_manifest_extra_urls,
    updated_at,
    linked_at,
    ticket_number,
    jurisdiction,
    gdo_id,
    NULL::text[] AS visit_sheet_urls
   FROM v_derm_portal_fields f
  WHERE visit_date >= rpa_launch_cutoff() AND gdo_id IS NOT NULL AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND (s.status = 'SUCCESS'::text OR s.portal_confirmation IS NOT NULL))) AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND s.created_at > (now() - '20:00:00'::interval))) AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND NOT s.gdo_id IS DISTINCT FROM f.gdo_id AND NOT s.retryable AND s.status <> 'SUCCESS'::text AND s.created_at > GREATEST(f.updated_at, COALESCE(( SELECT max(rq.requeued_at) AS max
                   FROM derm_portal_requeue rq
                  WHERE rq.manifest_id = f.manifest_id AND (rq.gdo_id IS NULL OR NOT rq.gdo_id IS DISTINCT FROM f.gdo_id)), '-infinity'::timestamp with time zone)))) AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_leases l
             JOIN manifest_visits lmv ON lmv.visit_id = l.visit_id
          WHERE lmv.manifest_id = f.manifest_id AND (l.gdo_id IS NULL OR NOT l.gdo_id IS DISTINCT FROM f.gdo_id) AND l.leased_at > (now() - '20:00:00'::interval))) AND NOT (f.visit_id::text = ANY (string_to_array(replace(COALESCE(( SELECT c.value
           FROM app_config c
          WHERE c.key = 'gdo_queue_skip_visit_ids'::text), ''::text), ' '::text, ''::text), ','::text)))
  ORDER BY manifest_id, gdo_id, (abs(visit_date - dump_ticket_date)), visit_id;

create or replace view public.v_derm_portal_queue_held as
 SELECT visit_id,
    gdo_id,
    gdo_number,
    manifest_id,
    client_code,
    visit_date,
        CASE
            WHEN NOT visit_date >= rpa_launch_cutoff() THEN 'before_launch_cutoff'::text
            WHEN (EXISTS ( SELECT 1
               FROM derm_portal_submissions s
                 JOIN manifest_visits smv ON smv.visit_id = s.visit_id
              WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND (s.status = 'SUCCESS'::text OR s.portal_confirmation IS NOT NULL))) THEN 'already_filed'::text
            WHEN gdo_id IS NULL THEN 'no_permit'::text
            WHEN (EXISTS ( SELECT 1
               FROM derm_portal_submissions s
                 JOIN manifest_visits smv ON smv.visit_id = s.visit_id
              WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND s.created_at > (now() - '20:00:00'::interval))) THEN 'cooldown_20h'::text
            WHEN (EXISTS ( SELECT 1
               FROM derm_portal_submissions s
                 JOIN manifest_visits smv ON smv.visit_id = s.visit_id
              WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND NOT s.gdo_id IS DISTINCT FROM f.gdo_id AND NOT s.retryable AND s.status <> 'SUCCESS'::text AND s.created_at > GREATEST(f.updated_at, COALESCE(( SELECT max(rq.requeued_at) AS max
                       FROM derm_portal_requeue rq
                      WHERE rq.manifest_id = f.manifest_id AND (rq.gdo_id IS NULL OR NOT rq.gdo_id IS DISTINCT FROM f.gdo_id)), '-infinity'::timestamp with time zone)))) THEN 'data_error'::text
            WHEN (EXISTS ( SELECT 1
               FROM derm_portal_leases l
                 JOIN manifest_visits lmv ON lmv.visit_id = l.visit_id
              WHERE lmv.manifest_id = f.manifest_id AND (l.gdo_id IS NULL OR NOT l.gdo_id IS DISTINCT FROM f.gdo_id) AND l.leased_at > (now() - '20:00:00'::interval))) THEN 'leased'::text
            WHEN (f.visit_id::text = ANY (string_to_array(replace(COALESCE(( SELECT c.value
           FROM app_config c
          WHERE c.key = 'gdo_queue_skip_visit_ids'::text), ''::text), ' '::text, ''::text), ','::text))) THEN 'skipped_by_hand'::text
            WHEN NOT (EXISTS ( SELECT 1
               FROM v_derm_portal_queue qq
              WHERE qq.visit_id = f.visit_id AND NOT qq.gdo_id IS DISTINCT FROM f.gdo_id)) THEN 'sibling_won_this_pass'::text
            ELSE NULL::text
        END AS held_by
   FROM v_derm_portal_fields f;

do $verify$
declare v_n int; v_t text;
begin
  select count(*) into v_n from public.v_derm_portal_fields f join public.gdos g on g.id = f.gdo_id where g.status = 'INACTIVE';
  if v_n <> 0 then raise exception 'VERIFY 1: % rows carry an INACTIVE permit', v_n; end if;
  select count(*) into v_n from public.v_derm_portal_fields f join public.gdos g on g.id = f.gdo_id
   where g.status = 'EXPIRED' and exists (select 1 from public.gdos a where a.client_id = g.client_id and a.status = 'ACTIVE'
                                           and a.gdo_number ~ '^GDO-[0-9]+$');
  if v_n <> 0 then raise exception 'VERIFY 2: % rows use an EXPIRED permit beside an ACTIVE one', v_n; end if;
  select string_agg(coalesce(gdo_number, 'none'), ',') into v_t from public.v_derm_portal_fields where visit_id = 7849;
  if v_t is distinct from 'GDO-14098' then raise exception 'VERIFY 3: visit 7849 reads %', v_t; end if;
  if exists (select 1 from public.v_derm_portal_queue where visit_id = 7849) then raise exception 'VERIFY 4: 7849 is served'; end if;
  select held_by into v_t from public.v_derm_portal_queue_held where visit_id = 7849;
  if v_t is distinct from 'skipped_by_hand' then raise exception 'VERIFY 5: 7849 held_by %', v_t; end if;
  if not exists (select 1 from public.v_derm_portal_queue where visit_id = 7992) then raise exception 'VERIFY 6: 7992 not served'; end if;
end
$verify$;

COMMIT;
