-- 2026-09-11 23:10 ET · City email: a DERM-app send also stops the automatic one, pre-column history
--                         is reconstructed, and the timer runs from the later of blackout and manual send
--
-- Fred, 2026-09-11 (second message), verbatim: "if you send the email from the DERM App it can be send
-- from the DERM App if it have the blackout ready, and it will skip the automatic email if it hasn't been
-- sent yet, because the derm app already will send the derm manifest yes or yes so having an automatic
-- email that will send it makes no senses." And: "have the automatic email to be send 15 min after the
-- admin review app email button".
--
-- Three changes to derm.v_city_email_candidates (body copied from pg_get_viewdef on 2026-09-11 22:55 ET,
-- patched by scratchpad t3_build.js with reverse-patch assertions):
--
-- 1. already_sent (the derm_email_sends city CTE) now counts TEST rows while city_email_live_sends is
--    not 'true', exactly like suppressed and manual already do since 2026-09-11_2230. A manual "Send DERM
--    to city" from the DERM Tracker writes such a row, so it marks the pair already_sent and the sweep
--    skips it: the DERM app sends the manifest whatever happens, so an automatic copy makes no sense.
--    Once the gate is live, only is_test=false rows count, as before, so a test can never suppress a
--    real regulator submission. Side effect that is also a fix: in test mode the sweep's own test
--    sends now satisfy already_sent, so they no longer come back as ready after the 20h retry window
--    (the loop the 2026-08-28 notes describe under "recently_attempted"). Measured effect in test mode:
--    40 pairs that received a TEST city email in August (DERM app tests, earlier sweep runs) read
--    already_sent instead of awaiting_manual_send / no_city_email; at go-live they revert, because only
--    the 17 real rows count then.
--
-- 2. Rows written before visit_photo_email_sends.include_manifest existed (NULL, 2026-08-15 .. 08-2x)
--    are reconstructed from timing. customer.work_orders.derm_manifest_url is written ONLY by the
--    blackout pipeline, at blacked_at; so an Admin Review send BEFORE blacked_at cannot have carried
--    the manifest (counts as include_manifest=false: unlocks), and one AT OR AFTER it did (counts as
--    true: suppresses). manual_inferred (appended column) says when the unlocking row was such a
--    reconstruction. Measured before applying: 38 NULL rows on 16 pairs; the reconstruction unlocks
--    1683/34, 1715/366, 1740/499, 1741/294, 1742/292, 1744/283 and suppresses 1726/143, 1728/525.
--
-- 3. due_at = GREATEST(blacked_at, manual_sent_at) + city_email_delay, in the column and in the
--    waiting arm. "N after the Admin Review send" when the blackout is older (Fred's 15-minute test),
--    "N after the blackout" when the send came first (the steady state). It was blacked_at + delay
--    only, which gave the office no window after a manual send on an already blacked manifest.
--
-- Columns: manual_inferred appended at the END (never reordered). Grants untouched (CREATE OR REPLACE).
--
-- Verified in a rolled-back dry run (scratchpad t3_dry.sql): every pre-existing column except status,
-- due_at and suppressed_at identical on all 710 rows (EXCEPT ALL both directions); due_at, first_sent_at,
-- suppressed_at and the manual columns equal to direct reads; only the expected status transitions;
-- four mutants (already_sent not test-aware, old due_at, inference without the blackout comparison,
-- suppression inference dropped) each refused.

begin;

create or replace view derm.v_city_email_candidates as
 WITH cfg AS (
         SELECT COALESCE(( SELECT NULLIF(btrim(app_config.value), ''::text)::timestamp with time zone AS "nullif"
                   FROM app_config
                  WHERE app_config.key = 'city_email_start_from'::text), 'infinity'::timestamp with time zone) AS start_from,
            fn_city_email_delay() AS delay,
            fn_city_email_retry_after() AS retry_after,
            COALESCE(( SELECT btrim(app_config.value) = 'true'::text
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
            WHEN r.blacked_at <= (( SELECT cfg.start_from
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

comment on view derm.v_city_email_candidates is
  'Every blacked-out DERM manifest with an explicit status for the automatic city email. status=ready means due now. '
  'The automatic email needs a MANUAL Admin Review send first (2026-09-11): awaiting_manual_send = no status=sent '
  'visit_photo_email_sends row without the manifest on a live visit of that client on that manifest; suppressed_manual = a '
  'manual send already carried the manifest; already_sent = a city row in derm_email_sends (the DERM Tracker button or a '
  'previous sweep). include_manifest NULL rows are reconstructed from timing: before blacked_at = without, at/after = with. '
  'Test rows count for all three while city_email_live_sends<>true. due_at = greatest(blacked_at, manual_sent_at) + delay. '
  'manual_include_photos is the photo choice the automatic email copies; manual_inferred marks a reconstructed unlock. '
  'Never filters a row away: no_city_email, ambiguous_property, recently_attempted, too_many_errors, awaiting_manual_send and '
  'before_go_live are visible states, not silent absences. The wait and the retry window both come from app_config.';

commit;
