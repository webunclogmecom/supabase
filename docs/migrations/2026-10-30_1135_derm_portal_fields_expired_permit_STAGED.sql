-- 2026-10-30_1135  public.v_derm_portal_fields: file with an EXPIRED permit when it is the one we have   ⛔ STAGED
--
-- ⛔ NOT APPLIED. Fred (2026-10-30, "Wait for Jonathan"): apply it when Jonathan is ready to press Auto file on
-- 315-CAP visit 7849 for his video. Applying puts 7849 and 7992 in the bot's hourly queue at once.
-- On apply: rename this file without _STAGED and record the time in the header.
--
-- WHY. Slack #apps-notifications 2026-10-30 (the GDO digest thread): 315-CAP Capas Burger Aventura sat in the
-- digest as "No GDO permit on the visit" (manifest 834433, visit 7849, 2026-08-28). Diego then entered GDO-14098
-- in the Client App, but its PDF is the 2024 permit ("valid from 01-JAN-2024 through 31-DEC-2024"), so
-- client.upsert_gdo_permit stored it EXPIRED and this view (ACTIVE only) still gave the visit no permit; Auto file
-- answered "No GDO permit on file for this visit." Fred: *"even if it's expired or not that's the one we have so
-- we file it with that expired one, if we get an error from the Bot it'd be different because we just need to
-- deliver the data, the bot will deliver the response (error or success)"*.
--
-- WHAT. Built from the LIVE pg_get_viewdef (md5 3ff7de253bfff2da1e2278df9740a041); ONE anchored edit, the permit lateral:
--   before: g.status = 'ACTIVE'
--   after:  g.status = 'ACTIVE', or g.status = 'EXPIRED' when the client has no ACTIVE permit.
-- Never INACTIVE (53 rows: a permit demoted because it names another business, or replaced). An EXPIRED permit is
-- not used beside an ACTIVE one, so a renewal under a new number cannot double-file. EXPIRED is written only when a
-- permit is entered with a past expiration (client.upsert_gdo_permit, fn_check_gdo_on_visit); nothing expires
-- permits by date (22 ACTIVE permits are past their date today and are filed as before).
-- Every filing path reads this view, so all of them follow: the hourly queue (v_derm_portal_queue/_held), the Auto
-- file button and Record a manual filing (derm.visit_gdo_our_record, visit_gdo_manual_eligibility, visit_gdo_report),
-- fn_record_manual_gdo_report, fn_resolve_rpa_permit, fn_requeue_derm_portal, the health check (gdo_no_permit reads
-- the held view). rpa-derm-result already accepts a permit of the visit's client in any status. Display surfaces
-- (Calendar, derm.visits list, Field Portal) keep ACTIVE only, by Fred's 2026-09-28 decision.
-- REACH, measured 2026-10-30 11:30 ET in a rolled-back run of this exact body: 104 rows before and after; only
-- visits 7849 and 7992 (both 315-CAP) change, from no permit to GDO-14098 (gdo 261); every other column of every
-- other row unchanged; both enter v_derm_portal_queue (neither is held); 7849's Auto file becomes available.
-- Rule 8: a view, nothing to audit. ROLLBACK: 2026-10-30_rollback_derm_portal_fields_expired_permit.sql

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(pg_get_viewdef('public.v_derm_portal_fields'::regclass, false)) <> '3ff7de253bfff2da1e2278df9740a041' then
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

do $verify$
declare v_n int; v_cap text;
begin
  -- an INACTIVE permit (another business's, or replaced) is never filed
  select count(*) into v_n from public.v_derm_portal_fields f join public.gdos g on g.id = f.gdo_id where g.status = 'INACTIVE';
  if v_n <> 0 then raise exception 'VERIFY 1: % rows carry an INACTIVE permit', v_n; end if;
  -- an EXPIRED permit is used only when the client has no ACTIVE one
  select count(*) into v_n from public.v_derm_portal_fields f join public.gdos g on g.id = f.gdo_id
   where g.status = 'EXPIRED' and exists (select 1 from public.gdos a where a.client_id = g.client_id and a.status = 'ACTIVE'
                                           and a.gdo_number ~ '^GDO-[0-9]+$');
  if v_n <> 0 then raise exception 'VERIFY 2: % rows use an EXPIRED permit beside an ACTIVE one', v_n; end if;
  -- the case that asked for it (315-CAP, visit 7849): GDO-14098
  select string_agg(coalesce(gdo_number, 'none'), ',') into v_cap from public.v_derm_portal_fields where visit_id = 7849;
  if v_cap is distinct from 'GDO-14098' then raise exception 'VERIFY 3: visit 7849 reads %', v_cap; end if;
end
$verify$;

COMMIT;
