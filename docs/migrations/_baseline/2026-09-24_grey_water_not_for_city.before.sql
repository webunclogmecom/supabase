-- Baseline (pre-change) definitions of the objects changed by 2026-09-24_2110_grey_water_not_for_city.sql.
-- 🛑 ROLLBACK ORDER: FIRST redeploy send-visit-photos-email and send-derm-email from the commit before that
-- change (git checkout <previous commit> -- supabase/functions/send-visit-photos-email supabase/functions/send-derm-email,
-- then supabase functions deploy each). Both read public.v_visit_not_for_city and refuse every city send
-- without it. THEN run this whole file: it restores derm.v_city_email_candidates and
-- public.fn_request_city_email_sweep from their pre-change text (CREATE OR REPLACE keeps their ACLs), then
-- drops public.v_visit_not_for_city.
-- ⚠ public.v_visit_grey_water_pumping keeps the `tier` column that change added: CREATE OR REPLACE VIEW cannot
-- drop a column, and the rows are the same, so it is left as is.
-- ⚠ The restored sweep forwards city_email_test_recipient even while live, so if that key is non-empty every
-- automatic city email goes to it as a test again. Empty the key first, or do not roll the sweep back.
-- Unqualified names resolve on the default search_path, as when these were captured.

-- derm.v_city_email_candidates (md5 67f6be35a8124f6844b5035bdf1ca5c8)
CREATE OR REPLACE VIEW derm.v_city_email_candidates AS
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
         SELECT s_1.manifest_id,
            s_1.client_id,
            max(COALESCE(s_1.uploaded_at, s_1.generated_at, s_1.created_at)) AS blacked_at,
            count(*) AS pages
           FROM (derm.manifest_visit_sheets s_1
             JOIN derm_manifests dm ON (((dm.id = s_1.manifest_id) AND (dm.deleted_at IS NULL))))
          WHERE ((s_1.deleted_at IS NULL) AND (COALESCE(s_1.photo_bucket, ''::text) <> ''::text) AND (COALESCE(s_1.photo_path, ''::text) <> ''::text) AND (NOT (EXISTS ( SELECT 1
                   FROM derm.redacted_manifest_docs d2
                  WHERE ((d2.manifest_id = s_1.manifest_id) AND (d2.client_id = s_1.client_id))))))
          GROUP BY s_1.manifest_id, s_1.client_id
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

-- public.fn_request_city_email_sweep (md5 71a71ffdb864367b5c0de0c2390c5471)
CREATE OR REPLACE FUNCTION public.fn_request_city_email_sweep()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_key   text;
  v_limit int;
  v_test  text;
  v_recipients jsonb;
  v_body  jsonb;
begin
  select coalesce(nullif(btrim(value), '')::int, 5) into v_limit
    from public.app_config where key = 'city_email_batch_limit';
  v_limit := coalesce(v_limit, 5);

  select jsonb_agg(jsonb_build_object(
           'manifest_id', q.manifest_id,
           'client_id',   q.client_id,
           -- 🛑 property_id is what keeps the email to the municipality that actually covers this
           -- visit. Without it send-derm-email unions city_emails across every property the
           -- client owns, which over-sends on 38 of the 107 sendable manifests.
           'property_id', q.property_id,
           -- 2026-09-11: the automatic email copies the photo choice of the manual send that
           -- unlocked it (Fred: "the automatic email should follow the same selection").
           -- NULL only on pre-2026-08-20 rows; send-derm-email then keeps its default (true).
           'include_photos', q.manual_include_photos,
           'manual_visit_id', q.manual_visit_id))
    into v_recipients
    from (select * from derm.v_city_email_queue order by blacked_at limit v_limit) q;

  if v_recipients is null then
    return;  -- nothing due. No HTTP call, no edge invocation, no log noise.
  end if;

  select decrypted_secret into v_key
    from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping city email sweep';
    return;
  end if;

  v_body := jsonb_build_object('target', 'city', 'recipients', v_recipients);

  select nullif(btrim(value), '') into v_test
    from public.app_config where key = 'city_email_test_recipient';
  if v_test is not null then
    v_body := v_body || jsonb_build_object('test_recipient', v_test);
  end if;

  perform net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/send-derm-email',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body    := v_body,
    timeout_milliseconds := 60000);
end $function$
;

DROP VIEW public.v_visit_not_for_city;

NOTIFY pgrst, 'reload schema';
