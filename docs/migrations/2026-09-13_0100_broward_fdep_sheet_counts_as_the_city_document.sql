-- 2026-09-13_0100  A Broward per-visit FDEP sheet counts as the city document, no blackout
--
-- Fred, 2026-09-13, listing the rules the whole flow must follow: "it needs to have a Blackout, and
-- remember what i said about that since last week the Broward doesn't needs blackout so they can be
-- send anyways" and, for the DERM app, "only send it if it has the Manifest (with blackout if it's
-- MIAMI-DADE)".
--
-- The Admin Review report already carried it: customer.work_orders.derm_manifest_url is
-- derm.fn_fog_documents(), which returns the redacted pages of the shared Miami-Dade sheet or, when
-- there are none, the Broward FDEP 62-705.300(3) per-visit sheet (2026-09-09_0100). Proven before
-- this change on visit 5973 / manifest 1911 / 028-HUM: fp.unclogme.app/028-hum/visit/qEe9jhkgIj/report
-- renders the sheet as "A - FOG eManifest 312840" (772x1024, loaded) beside the WWTP receipt, and the
-- pdf-service prints exactly that page. That was the condition the 09-09 migration set for touching
-- the city guards, so the two DERM-app paths now follow:
--
--   public.v_derm_manifest_email_readiness   send_blocker was 'not_blacked_out' whenever no redacted
--                                            doc existed; it is now 'no_fog_document', set only when
--                                            there is neither a redacted doc nor a per-visit sheet.
--                                            has_fog_document (boolean) is APPENDED. is_blacked_out
--                                            keeps its exact meaning. The DERM app gates on
--                                            send_blocker IS NOT NULL, never on the string.
--   derm.v_city_email_candidates             docs = redacted pages per (manifest, client) OR, when
--                                            the pair has none, its per-visit sheets, with
--                                            blacked_at = the sheet's uploaded_at. Same precedence as
--                                            fn_fog_documents. The column keeps its name; read it as
--                                            "the FOG document was ready at".
--
-- Companion (same hour): supabase/functions/send-derm-email replaces the redacted_manifest_docs
-- lookups in both loops with derm.fn_fog_documents() for this client's visits on the manifest,
-- reason no_fog_document (was no_redacted_sheet), and drops the derm_address_url requirement from
-- the city loop (the city gets the report, and the FDEP-only manifests have no shared address sheet
-- by construction). DERM Tracker labels: "Not blacked out yet" and its notice become county-neutral.
--
-- Measured before: 12 per-visit sheets, all on manifests with no redacted doc, uploaded 2026-09-08
-- and 2026-09-10, client_id equal to the visit's; none of their visits has an Admin Review send.
-- Expected deltas (asserted by the dry run):
--   candidates:  exactly 12 new (manifest, client) rows, every pre-existing row byte-identical;
--                queue stays 0 (their uploaded_at precedes city_email_start_from); statuses among
--                awaiting_manual_send / no_city_email / no_property only.
--   readiness:   exactly the manifests that have a per-visit sheet and no redacted doc flip
--                send_blocker 'not_blacked_out' -> NULL; every other row keeps NULL or 'no_fog_document'
--                in place of 'not_blacked_out'; is_blacked_out and the photo columns unchanged.
-- Column lists: readiness gains one column at the end; candidates unchanged. Grants kept.

begin;

create or replace view derm.v_city_email_candidates as
WITH cfg AS (
         SELECT COALESCE(( SELECT (NULLIF(btrim(app_config.value), ''::text))::timestamp with time zone AS "nullif"
                   FROM app_config
                  WHERE (app_config.key = 'city_email_start_from'::text)), 'infinity'::timestamp with time zone) AS start_from,
            fn_city_email_delay() AS delay,
            fn_city_email_retry_after() AS retry_after,
            COALESCE(( SELECT (lower(btrim(app_config.value)) = 'true'::text)
                   FROM app_config
                  WHERE (app_config.key = 'city_email_live_sends'::text)), false) AS live_sends
        ), docs AS (
         SELECT r_1.manifest_id,
            r_1.client_id,
            max(r_1.generated_at) AS blacked_at,
            count(*) AS pages
           FROM (derm.redacted_manifest_docs r_1
             JOIN derm_manifests dm ON (((dm.id = r_1.manifest_id) AND (dm.deleted_at IS NULL))))
          GROUP BY r_1.manifest_id, r_1.client_id
        UNION ALL
         SELECT s.manifest_id,
            s.client_id,
            max(COALESCE(s.uploaded_at, s.generated_at, s.created_at)) AS blacked_at,
            count(*) AS pages
           FROM (derm.manifest_visit_sheets s
             JOIN derm_manifests dm ON (((dm.id = s.manifest_id) AND (dm.deleted_at IS NULL))))
          WHERE ((s.deleted_at IS NULL) AND (COALESCE(s.photo_bucket, ''::text) <> ''::text) AND (COALESCE(s.photo_path, ''::text) <> ''::text) AND (NOT (EXISTS ( SELECT 1
                   FROM derm.redacted_manifest_docs d2
                  WHERE ((d2.manifest_id = s.manifest_id) AND (d2.client_id = s.client_id))))))
          GROUP BY s.manifest_id, s.client_id
        ), resolved AS (
         SELECT d.manifest_id,
            d.client_id,
            d.blacked_at,
            d.pages,
            count(DISTINCT v.property_id) AS properties,
            count(DISTINCT p.id) AS city_properties,
            min(p.id) AS property_id
           FROM (((docs d
             LEFT JOIN manifest_visits mv ON ((mv.manifest_id = d.manifest_id)))
             LEFT JOIN visits v ON (((v.id = mv.visit_id) AND (v.deleted_at IS NULL) AND (v.client_id = d.client_id))))
             LEFT JOIN properties p ON (((p.id = v.property_id) AND (p.deleted_at IS NULL) AND (p.city_emails IS NOT NULL) AND (cardinality(p.city_emails) > 0))))
          GROUP BY d.manifest_id, d.client_id, d.blacked_at, d.pages
        ), sent AS (
         SELECT derm_email_sends.manifest_id,
            derm_email_sends.client_id,
            min(derm_email_sends.sent_at) AS first_sent_at
           FROM derm_email_sends
          WHERE ((derm_email_sends.recipient_type = 'city'::text) AND (derm_email_sends.status = 'sent'::text) AND ((COALESCE(derm_email_sends.is_test, false) = false) OR (NOT ( SELECT cfg.live_sends
                   FROM cfg))))
          GROUP BY derm_email_sends.manifest_id, derm_email_sends.client_id
        ), attempted AS (
         SELECT derm_email_sends.manifest_id,
            derm_email_sends.client_id,
            max(derm_email_sends.sent_at) AS last_attempt_at
           FROM derm_email_sends
          WHERE (derm_email_sends.recipient_type = 'city'::text)
          GROUP BY derm_email_sends.manifest_id, derm_email_sends.client_id
        ), errored AS (
         SELECT derm_email_sends.manifest_id,
            derm_email_sends.client_id,
            count(*) AS error_count
           FROM derm_email_sends
          WHERE ((derm_email_sends.recipient_type = 'city'::text) AND (derm_email_sends.status = 'error'::text))
          GROUP BY derm_email_sends.manifest_id, derm_email_sends.client_id
        ), suppressed AS (
         SELECT mv.manifest_id,
            v.client_id,
            min(s_1.sent_at) AS suppressed_at
           FROM (((visit_photo_email_sends s_1
             JOIN visits v ON (((v.id = s_1.visit_id) AND (v.deleted_at IS NULL))))
             JOIN manifest_visits mv ON ((mv.visit_id = v.id)))
             JOIN docs d_1 ON (((d_1.manifest_id = mv.manifest_id) AND (d_1.client_id = v.client_id))))
          WHERE ((s_1.status = 'sent'::text) AND ((COALESCE(s_1.is_test, false) = false) OR (NOT ( SELECT cfg.live_sends
                   FROM cfg))) AND ((s_1.include_manifest IS TRUE) OR ((s_1.include_manifest IS NULL) AND (s_1.sent_at >= d_1.blacked_at))))
          GROUP BY mv.manifest_id, v.client_id
        ), manual AS (
         SELECT DISTINCT ON (mv.manifest_id, v.client_id) mv.manifest_id,
            v.client_id,
            s_2.sent_at AS manual_sent_at,
            s_2.include_photos AS manual_include_photos,
            s_2.visit_id AS manual_visit_id,
            (s_2.include_manifest IS NULL) AS manual_inferred
           FROM (((visit_photo_email_sends s_2
             JOIN visits v ON (((v.id = s_2.visit_id) AND (v.deleted_at IS NULL))))
             JOIN manifest_visits mv ON ((mv.visit_id = v.id)))
             JOIN docs d_2 ON (((d_2.manifest_id = mv.manifest_id) AND (d_2.client_id = v.client_id))))
          WHERE ((s_2.status = 'sent'::text) AND ((COALESCE(s_2.is_test, false) = false) OR (NOT ( SELECT cfg.live_sends
                   FROM cfg))) AND ((s_2.include_manifest IS FALSE) OR ((s_2.include_manifest IS NULL) AND (s_2.sent_at < d_2.blacked_at))))
          ORDER BY mv.manifest_id, v.client_id, s_2.sent_at DESC
        )
 SELECT r.manifest_id,
    r.client_id,
    r.property_id,
    r.blacked_at,
    (GREATEST(r.blacked_at, m.manual_sent_at) + ( SELECT cfg.delay
           FROM cfg)) AS due_at,
    r.pages,
    r.properties,
    r.city_properties,
    s.first_sent_at,
    sup.suppressed_at,
    ( SELECT cfg.start_from
           FROM cfg) AS start_from,
        CASE
            WHEN (s.manifest_id IS NOT NULL) THEN 'already_sent'::text
            WHEN (sup.manifest_id IS NOT NULL) THEN 'suppressed_manual'::text
            WHEN ((a.last_attempt_at IS NOT NULL) AND (a.last_attempt_at > (now() - ( SELECT cfg.retry_after
               FROM cfg)))) THEN 'recently_attempted'::text
            WHEN (COALESCE(e.error_count, (0)::bigint) >= 3) THEN 'too_many_errors'::text
            WHEN (r.properties = 0) THEN 'no_property'::text
            WHEN (r.city_properties > 1) THEN 'ambiguous_property'::text
            WHEN (r.city_properties = 0) THEN 'no_city_email'::text
            WHEN (m.manifest_id IS NULL) THEN 'awaiting_manual_send'::text
            WHEN ((GREATEST(r.blacked_at, m.manual_sent_at) + ( SELECT cfg.delay
               FROM cfg)) > now()) THEN 'waiting'::text
            WHEN (GREATEST(r.blacked_at, m.manual_sent_at) <= ( SELECT cfg.start_from
               FROM cfg)) THEN 'before_go_live'::text
            ELSE 'ready'::text
        END AS status,
    COALESCE(e.error_count, (0)::bigint) AS error_count,
    ( SELECT cfg.delay
           FROM cfg) AS delay,
    a.last_attempt_at,
    m.manual_sent_at,
    m.manual_include_photos,
    m.manual_visit_id,
    ( SELECT cfg.live_sends
           FROM cfg) AS live_sends,
    m.manual_inferred
   FROM (((((resolved r
     LEFT JOIN sent s ON (((s.manifest_id = r.manifest_id) AND (s.client_id = r.client_id))))
     LEFT JOIN attempted a ON (((a.manifest_id = r.manifest_id) AND (a.client_id = r.client_id))))
     LEFT JOIN errored e ON (((e.manifest_id = r.manifest_id) AND (e.client_id = r.client_id))))
     LEFT JOIN suppressed sup ON (((sup.manifest_id = r.manifest_id) AND (sup.client_id = r.client_id))))
     LEFT JOIN manual m ON (((m.manifest_id = r.manifest_id) AND (m.client_id = r.client_id))));

create or replace view public.v_derm_manifest_email_readiness as
SELECT m.id AS manifest_id,
    m.client_id,
    m.white_manifest_number,
    (EXISTS ( SELECT 1
           FROM derm.redacted_manifest_docs d
          WHERE (d.manifest_id = m.id))) AS is_blacked_out,
    COALESCE(pc.classified_images, 0) AS classified_images,
    (COALESCE(pc.classified_images, 0) > 0) AS has_classified_photos,
        CASE
            WHEN ((NOT (EXISTS ( SELECT 1
               FROM derm.redacted_manifest_docs d
              WHERE (d.manifest_id = m.id)))) AND (NOT (EXISTS ( SELECT 1
               FROM derm.manifest_visit_sheets s
              WHERE ((s.manifest_id = m.id) AND (s.deleted_at IS NULL) AND (COALESCE(s.photo_bucket, ''::text) <> ''::text) AND (COALESCE(s.photo_path, ''::text) <> ''::text)))))) THEN 'no_fog_document'::text
            ELSE NULL::text
        END AS send_blocker,
    ((EXISTS ( SELECT 1
           FROM derm.redacted_manifest_docs d
          WHERE (d.manifest_id = m.id))) OR (EXISTS ( SELECT 1
           FROM derm.manifest_visit_sheets s
          WHERE ((s.manifest_id = m.id) AND (s.deleted_at IS NULL) AND (COALESCE(s.photo_bucket, ''::text) <> ''::text) AND (COALESCE(s.photo_path, ''::text) <> ''::text))))) AS has_fog_document
   FROM (derm_manifests m
     LEFT JOIN LATERAL ( SELECT (sum(vp.classified_images))::integer AS classified_images
           FROM (manifest_visits mv
             JOIN v_visit_photo_counts vp ON ((vp.visit_id = mv.visit_id)))
          WHERE (mv.manifest_id = m.id)) pc ON (true))
  WHERE (m.deleted_at IS NULL);

comment on view public.v_derm_manifest_email_readiness is
  'Per live manifest: may it be emailed (send_blocker: no_fog_document when there is neither a redacted Miami-Dade sheet nor a Broward per-visit FDEP sheet; has_fog_document says which side is true) and can the photos checkbox do anything (has_classified_photos). is_blacked_out is still "a redacted document exists". Owner-rights on purpose: authenticated holds no grant on derm.redacted_manifest_docs or derm.manifest_visit_sheets. send_blocker covers ONLY reasons to refuse a send.';

commit;
