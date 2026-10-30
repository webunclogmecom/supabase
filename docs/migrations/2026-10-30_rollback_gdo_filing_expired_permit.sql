-- ROLLBACK for 2026-10-30_1135 (GDO filing with an EXPIRED permit + the queue skip list)
-- Puts back the three bodies from before (md5 fields 3ff7de253bfff2da1e2278df9740a041, queue 82bb5d0022e2f19e660d4f8e3dbb4a42, held b8bbe1fc394a1362108abba7f8de23c4) and
-- empties the skip list. Refuses unless all three views are exactly the 1135 bodies.
-- (To end only the skip, do not roll back: update public.app_config set value = '' where key = 'gdo_queue_skip_visit_ids';)

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(pg_get_viewdef('public.v_derm_portal_fields'::regclass, false)) <> '20e6069b96d2f55b79e15d4fa8e80b8f' then
    raise exception 'public.v_derm_portal_fields is not the 2026-10-30_1135 body; read the live view before rolling back';
  end if;
end
$pin$;
do $pin$
begin
  if md5(pg_get_viewdef('public.v_derm_portal_queue'::regclass, false)) <> '43708439a5737fd8b26c56584be31f14' then
    raise exception 'public.v_derm_portal_queue is not the 2026-10-30_1135 body; read the live view before rolling back';
  end if;
end
$pin$;
do $pin$
begin
  if md5(pg_get_viewdef('public.v_derm_portal_queue_held'::regclass, false)) <> 'e7325ae3d556f457632cb2d7538acc99' then
    raise exception 'public.v_derm_portal_queue_held is not the 2026-10-30_1135 body; read the live view before rolling back';
  end if;
end
$pin$;

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
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text AND g.gdo_number ~ '^GDO-[0-9]+$'::text) gd ON true
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
          WHERE lmv.manifest_id = f.manifest_id AND (l.gdo_id IS NULL OR NOT l.gdo_id IS DISTINCT FROM f.gdo_id) AND l.leased_at > (now() - '20:00:00'::interval)))
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
            WHEN NOT (EXISTS ( SELECT 1
               FROM v_derm_portal_queue qq
              WHERE qq.visit_id = f.visit_id AND NOT qq.gdo_id IS DISTINCT FROM f.gdo_id)) THEN 'sibling_won_this_pass'::text
            ELSE NULL::text
        END AS held_by
   FROM v_derm_portal_fields f;

update public.app_config set value = '' where key = 'gdo_queue_skip_visit_ids';

do $verify$
begin
  if exists (select 1 from public.v_derm_portal_fields f join public.gdos g on g.id = f.gdo_id where g.status = 'EXPIRED') then
    raise exception 'VERIFY: an EXPIRED permit is still used';
  end if;
end
$verify$;
COMMIT;
