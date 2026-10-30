-- 2026-10-30_1148  public.v_derm_portal_fields: every ACTIVE or EXPIRED permit of the client, never INACTIVE
--
-- WHY. Follows 2026-10-30_1135 (an EXPIRED permit only when the client has no ACTIVE one). Fred, on a visit with several
-- permits: *"remember to include all the GDO's associated in the options even if they're expired"*. Asked whether the
-- hourly bot should also file an expired permit next to an active one, he picked "Bot files every permit shown"; and
-- for INACTIVE permits (a PDF naming another business, or replaced) "Leave them out".
-- How several permits show: no picker. The DERM Tracker visit page renders one GDO report block per permit
-- (derm.visit_gdo_our_record), each with its own Record a manual filing and Auto file, and the hourly bot files one
-- report per (manifest, permit). Both read this view, so both now list every ACTIVE and EXPIRED permit.
--
-- WHAT. Built from the LIVE pg_get_viewdef (md5 20e6069b96d2f55b79e15d4fa8e80b8f, the 1135 body); one anchored edit, the permit lateral:
--   before: ACTIVE, or EXPIRED when the client has no ACTIVE permit
--   after:  status = ANY ('ACTIVE','EXPIRED')
-- REACH, measured 2026-10-30 in a rolled-back run: no client has an ACTIVE and an EXPIRED permit today, so no row
-- changes now (rows, permits and the queue are identical). Control in the same run: with one of 009-CN's three ACTIVE
-- permits set EXPIRED, visit 6567 keeps 3 rows (the 1135 body gives 2).
-- ⚠ A permit renewed under a NEW number while the old row stays EXPIRED will now be filed under both numbers. Today
-- EXPIRED is written only when a permit is entered with a past expiration (client.upsert_gdo_permit,
-- fn_check_gdo_on_visit); nothing expires permits by date.
-- The skip list (app_config gdo_queue_skip_visit_ids) and the held view's 'skipped_by_hand' are unchanged.
-- Rule 8: a view, nothing to audit. ROLLBACK: 2026-10-30_rollback_derm_portal_fields_active_or_expired.sql

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(pg_get_viewdef('public.v_derm_portal_fields'::regclass, false)) <> '20e6069b96d2f55b79e15d4fa8e80b8f' then
    raise exception 'public.v_derm_portal_fields changed since this migration was generated; rebuild it from the live definition';
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
          WHERE g.client_id = c.id AND (g.status = ANY (ARRAY['ACTIVE'::text, 'EXPIRED'::text])) AND g.gdo_number ~ '^GDO-[0-9]+$'::text) gd ON true
     LEFT JOIN disposal_facilities df ON df.id = m.disposal_facility_id
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN m.derm_address_url IS NULL AND COALESCE(cardinality(m.derm_address_extra_urls), 0) = 0 THEN ARRAY( SELECT d.url
                       FROM derm.fn_fog_documents(m.id, v.client_id, v.id) d(effective_page, url)
                      ORDER BY d.effective_page)
                    ELSE '{}'::text[]
                END AS urls) vs
  WHERE v.deleted_at IS NULL AND fn_visit_is_gdo_reporting(v.id);

do $verify$
declare v_n int; v_t text;
begin
  select count(*) into v_n from public.v_derm_portal_fields f join public.gdos g on g.id = f.gdo_id where g.status not in ('ACTIVE','EXPIRED');
  if v_n <> 0 then raise exception 'VERIFY 1: % rows carry a permit that is neither ACTIVE nor EXPIRED', v_n; end if;
  select string_agg(coalesce(gdo_number, 'none'), ',') into v_t from public.v_derm_portal_fields where visit_id = 7849;
  if v_t is distinct from 'GDO-14098' then raise exception 'VERIFY 2: visit 7849 reads %', v_t; end if;
  select count(*) into v_n from public.v_derm_portal_fields where visit_id = 6567;
  if v_n <> 3 then raise exception 'VERIFY 3: visit 6567 has % permits, expected 3', v_n; end if;
end
$verify$;
COMMIT;
