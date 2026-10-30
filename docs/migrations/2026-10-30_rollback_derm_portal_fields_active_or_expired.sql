-- ROLLBACK for 2026-10-30_1148_derm_portal_fields_active_or_expired.sql: puts back the 1135 body (ACTIVE, or EXPIRED only when the client has no ACTIVE permit),
-- md5 20e6069b96d2f55b79e15d4fa8e80b8f. Refuses unless the view is exactly the 1148 body (md5 e6b1167b167d0fc07cb40262f512dc94).

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(pg_get_viewdef('public.v_derm_portal_fields'::regclass, false)) <> 'e6b1167b167d0fc07cb40262f512dc94' then
    raise exception 'public.v_derm_portal_fields is not the 2026-10-30_1148 body; read the live view before rolling back';
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
COMMIT;
