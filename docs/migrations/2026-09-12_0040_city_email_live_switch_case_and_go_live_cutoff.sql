-- 2026-09-12 00:40 ET · City email: the live switch is read case-insensitively, and the go-live
--                         cutoff keys on the event that makes a pair due
--
-- Two findings from the adversarial review of the 2026-09-11 rework (workflow wf_d4d2b4c6-389), both
-- confirmed by two independent verifiers; body copied from pg_get_viewdef on 2026-09-12 00:20 ET and
-- patched by scratchpad t4_build.js with reverse-patch assertions.
--
-- 1. cfg.live_sends read app_config.city_email_live_sends as btrim(value) = 'true' while
--    send-derm-email reads it as trim().toLowerCase() === 'true', and app_config has no CHECK on the
--    value. A hand-typed 'True' would have made the mailer live (real municipal recipients) while the
--    view still counted test rows as already_sent / suppressed / unlocking. Now lower(btrim(value)).
--
-- 2. before_go_live tested r.blacked_at <= start_from. Since 2026-09-11_2310 the event that makes a pair
--    due is greatest(blacked_at, manual_sent_at) (Fred: "15 min after the admin review app email
--    button"), so a manifest blacked out before go-live and unlocked by an Admin Review send AFTER
--    go-live could never fire: it went awaiting -> waiting -> before_go_live forever. The cutoff now
--    tests the same greatest(): a pair whose unlocking send lands after go-live is admitted 24 hours
--    after that send; pairs unlocked by August sends (the reconstructed history) stay before_go_live
--    exactly as the 2026-08-28 backlog decision intended. Measured: with start_from = infinity today
--    no row changes status; the difference only appears after go-live, and the rolled-back probe
--    below demonstrates it.
--
-- Columns unchanged (no reorder, nothing appended). Grants untouched (CREATE OR REPLACE).

begin;

create or replace view derm.v_city_email_candidates as
 WITH cfg AS (
         SELECT COALESCE(( SELECT NULLIF(btrim(app_config.value), ''::text)::timestamp with time zone AS "nullif"
                   FROM app_config
                  WHERE app_config.key = 'city_email_start_from'::text), 'infinity'::timestamp with time zone) AS start_from,
            fn_city_email_delay() AS delay,
            fn_city_email_retry_after() AS retry_after,
            COALESCE(( SELECT lower(btrim(app_config.value)) = 'true'::text
                   FROM app_config
                  WHERE app_config.key = 'city_email_live_sends'::text), false) AS live_sends
        ), docs AS (
         SELECT r_1.manifest_id,
            r_1.client_id,
            max(r_1.generated_at) AS blacked_at,
            count(*) AS pages
           FROM derm.redacted_manifest_docs r_1
             JOIN derm_manifests dm ON dm.id = r_1.manifest_id AND dm.deleted_at IS NULL
          GROUP BY r_1.manifest_id, r_1.client_id
        ), resolved AS (
         SELECT d.manifest_id,
            d.client_id,
            d.blacked_at,
            d.pages,
            count(DISTINCT v.property_id) AS properties,
            count(DISTINCT p.id) AS city_properties,
            min(p.id) AS property_id
           FROM docs d
             LEFT JOIN manifest_visits mv ON mv.manifest_id = d.manifest_id
             LEFT JOIN visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL AND v.client_id = d.client_id
             LEFT JOIN properties p ON p.id = v.property_id AND p.deleted_at IS NULL AND p.city_emails IS NOT NULL AND cardinality(p.city_emails) > 0
          GROUP BY d.manifest_id, d.client_id, d.blacked_at, d.pages
        ), sent AS (
         SELECT derm_email_sends.manifest_id,
            derm_email_sends.client_id,
            min(derm_email_sends.sent_at) AS first_sent_at
           FROM derm_email_sends
          WHERE derm_email_sends.recipient_type = 'city'::text AND derm_email_sends.status = 'sent'::text AND (COALESCE(derm_email_sends.is_test, false) = false OR NOT ( SELECT cfg.live_sends
                   FROM cfg))
          GROUP BY derm_email_sends.manifest_id, derm_email_sends.client_id
        ), attempted AS (
         SELECT derm_email_sends.manifest_id,
            derm_email_sends.client_id,
            max(derm_email_sends.sent_at) AS last_attempt_at
           FROM derm_email_sends
          WHERE derm_email_sends.recipient_type = 'city'::text
          GROUP BY derm_email_sends.manifest_id, derm_email_sends.client_id
        ), errored AS (
         SELECT derm_email_sends.manifest_id,
            derm_email_sends.client_id,
            count(*) AS error_count
           FROM derm_email_sends
          WHERE derm_email_sends.recipient_type = 'city'::text AND derm_email_sends.status = 'error'::text
          GROUP BY derm_email_sends.manifest_id, derm_email_sends.client_id
        ), suppressed AS (
         SELECT mv.manifest_id,
            v.client_id,
            min(s_1.sent_at) AS suppressed_at
           FROM visit_photo_email_sends s_1
             JOIN visits v ON v.id = s_1.visit_id AND v.deleted_at IS NULL
             JOIN manifest_visits mv ON mv.visit_id = v.id
             JOIN docs d_1 ON d_1.manifest_id = mv.manifest_id AND d_1.client_id = v.client_id
          WHERE s_1.status = 'sent'::text AND (COALESCE(s_1.is_test, false) = false OR NOT ( SELECT cfg.live_sends
                   FROM cfg)) AND (s_1.include_manifest IS TRUE OR s_1.include_manifest IS NULL AND s_1.sent_at >= d_1.blacked_at)
          GROUP BY mv.manifest_id, v.client_id
        ), manual AS (
         SELECT DISTINCT ON (mv.manifest_id, v.client_id) mv.manifest_id,
            v.client_id,
            s_2.sent_at AS manual_sent_at,
            s_2.include_photos AS manual_include_photos,
            s_2.visit_id AS manual_visit_id,
            s_2.include_manifest IS NULL AS manual_inferred
           FROM visit_photo_email_sends s_2
             JOIN visits v ON v.id = s_2.visit_id AND v.deleted_at IS NULL
             JOIN manifest_visits mv ON mv.visit_id = v.id
             JOIN docs d_2 ON d_2.manifest_id = mv.manifest_id AND d_2.client_id = v.client_id
          WHERE s_2.status = 'sent'::text AND (COALESCE(s_2.is_test, false) = false OR NOT ( SELECT cfg.live_sends
                   FROM cfg)) AND (s_2.include_manifest IS FALSE OR s_2.include_manifest IS NULL AND s_2.sent_at < d_2.blacked_at)
          ORDER BY mv.manifest_id, v.client_id, s_2.sent_at DESC
        )
 SELECT r.manifest_id,
    r.client_id,
    r.property_id,
    r.blacked_at,
    GREATEST(r.blacked_at, m.manual_sent_at) + (( SELECT cfg.delay
           FROM cfg)) AS due_at,
    r.pages,
    r.properties,
    r.city_properties,
    s.first_sent_at,
    sup.suppressed_at,
    ( SELECT cfg.start_from
           FROM cfg) AS start_from,
        CASE
            WHEN s.manifest_id IS NOT NULL THEN 'already_sent'::text
            WHEN sup.manifest_id IS NOT NULL THEN 'suppressed_manual'::text
            WHEN a.last_attempt_at IS NOT NULL AND a.last_attempt_at > (now() - (( SELECT cfg.retry_after
               FROM cfg))) THEN 'recently_attempted'::text
            WHEN COALESCE(e.error_count, 0::bigint) >= 3 THEN 'too_many_errors'::text
            WHEN r.properties = 0 THEN 'no_property'::text
            WHEN r.city_properties > 1 THEN 'ambiguous_property'::text
            WHEN r.city_properties = 0 THEN 'no_city_email'::text
            WHEN m.manifest_id IS NULL THEN 'awaiting_manual_send'::text
            WHEN (GREATEST(r.blacked_at, m.manual_sent_at) + (( SELECT cfg.delay
               FROM cfg))) > now() THEN 'waiting'::text
            WHEN GREATEST(r.blacked_at, m.manual_sent_at) <= (( SELECT cfg.start_from
               FROM cfg)) THEN 'before_go_live'::text
            ELSE 'ready'::text
        END AS status,
    COALESCE(e.error_count, 0::bigint) AS error_count,
    ( SELECT cfg.delay
           FROM cfg) AS delay,
    a.last_attempt_at,
    m.manual_sent_at,
    m.manual_include_photos,
    m.manual_visit_id,
    ( SELECT cfg.live_sends
           FROM cfg) AS live_sends,
    m.manual_inferred
   FROM resolved r
     LEFT JOIN sent s ON s.manifest_id = r.manifest_id AND s.client_id = r.client_id
     LEFT JOIN attempted a ON a.manifest_id = r.manifest_id AND a.client_id = r.client_id
     LEFT JOIN errored e ON e.manifest_id = r.manifest_id AND e.client_id = r.client_id
     LEFT JOIN suppressed sup ON sup.manifest_id = r.manifest_id AND sup.client_id = r.client_id
     LEFT JOIN manual m ON m.manifest_id = r.manifest_id AND m.client_id = r.client_id;

commit;
