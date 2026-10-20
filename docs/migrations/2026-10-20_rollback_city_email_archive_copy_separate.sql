-- 2026-10-20_rollback_city_email_archive_copy_separate.sql
-- Puts back public.v_email_delivery and public.fn_notification_health_items exactly as they were before
-- 2026-10-20_1900 (bodies saved from pg_get_viewdef / pg_get_functiondef on 2026-10-20 18:54 ET, md5 14136ca1... / f7d8f94e...).
-- The three columns on derm_email_sends and visit_photo_email_sends stay (nothing reads them after this; dropping them
-- would lose the archive ids of D5 sends). Roll send-derm-email and send-visit-photos-email back to their previous
-- versions FIRST (git history), or new sends keep leaving the archive out of the city email while the view calls
-- their opens archive_copy again (honest, only less informative).
BEGIN;
SET LOCAL lock_timeout = '3s';
CREATE OR REPLACE VIEW public.v_email_delivery AS
 WITH cfg AS (
         SELECT COALESCE(( SELECT
                        CASE
                            WHEN btrim(c.value) ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}(:[0-9]{2}([.][0-9]+)?)?)?([+-][0-9]{2}(:?[0-9]{2})?)?$'::text THEN btrim(c.value)::timestamp with time zone
                            ELSE NULL::timestamp with time zone
                        END AS "case"
                   FROM app_config c
                  WHERE c.key = 'email_open_tracking_since'::text), 'infinity'::timestamp with time zone) AS track_since,
            COALESCE(( SELECT
                        CASE
                            WHEN btrim(c.value) ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}(:[0-9]{2}([.][0-9]+)?)?)?([+-][0-9]{2}(:?[0-9]{2})?)?$'::text THEN btrim(c.value)::timestamp with time zone
                            ELSE NULL::timestamp with time zone
                        END AS "case"
                   FROM app_config c
                  WHERE c.key = 'email_open_tracking_until'::text), 'infinity'::timestamp with time zone) AS track_until,
            COALESCE(( SELECT
                        CASE
                            WHEN btrim(c.value) ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}(:[0-9]{2}([.][0-9]+)?)?)?([+-][0-9]{2}(:?[0-9]{2})?)?$'::text THEN btrim(c.value)::timestamp with time zone
                            ELSE NULL::timestamp with time zone
                        END AS "case"
                   FROM app_config c
                  WHERE c.key = 'email_events_live_since'::text), 'infinity'::timestamp with time zone) AS live_since
        ), rows AS (
         SELECT 'derm_email_sends'::text AS source_table,
            d.id AS send_id,
            d.resend_email_id,
            d.recipient_type AS target,
            d.sent_at,
            d.client_id,
            NULL::bigint AS visit_id,
            d.manifest_id,
            COALESCE(d.is_test, false) AS is_test,
            d.recipient_email,
            d.cc_emails,
            d.bcc_emails
           FROM derm_email_sends d
          WHERE d.status = 'sent'::text AND NULLIF(btrim(d.resend_email_id), ''::text) IS NOT NULL
        UNION ALL
         SELECT 'visit_photo_email_sends'::text AS text,
            s.id,
            s.resend_email_id,
            'city'::text AS text,
            s.sent_at,
            v.client_id,
            s.visit_id,
            NULL::bigint AS int8,
            COALESCE(s.is_test, false) AS "coalesce",
            s.recipient_email,
            s.cc_emails,
            s.bcc_emails
           FROM visit_photo_email_sends s
             LEFT JOIN visits v ON v.id = s.visit_id
          WHERE s.status = 'sent'::text AND NULLIF(btrim(s.resend_email_id), ''::text) IS NOT NULL
        ), sends AS (
         SELECT r.resend_email_id,
            min(r.source_table) AS source_table,
            min(r.send_id) AS send_id,
            array_agg(r.send_id ORDER BY r.send_id) AS send_ids,
            min(r.target) AS target,
            min(r.sent_at) AS sent_at,
            min(r.client_id) AS client_id,
            min(r.visit_id) AS visit_id,
            min(r.manifest_id) AS manifest_id,
            bool_or(r.is_test) AS is_test,
            bool_and(COALESCE(cardinality(r.cc_emails), 0) = 0 AND COALESCE(cardinality(r.bcc_emails), 0) = 0) AS no_copies
           FROM rows r
          GROUP BY r.resend_email_id
        ), to_list AS (
         SELECT DISTINCT r.resend_email_id,
            lower(btrim(a.addr)) AS addr
           FROM rows r
             CROSS JOIN LATERAL unnest(string_to_array(COALESCE(r.recipient_email, ''::text), ','::text)) a(addr)
          WHERE POSITION(('@'::text) IN (a.addr)) > 0
        ), addr AS (
         SELECT t.resend_email_id,
            t.addr,
            COALESCE(bool_or(e.event_type = ANY (ARRAY['bounced'::text, 'failed'::text, 'suppressed'::text])), false) AS refused,
            COALESCE(bool_or(e.event_type = ANY (ARRAY['delivered'::text, 'complained'::text])), false) AS delivered,
            COALESCE(bool_or(e.event_type = 'complained'::text), false) AS complained,
            COALESCE(bool_or(e.event_type = 'delivery_delayed'::text), false) AS delayed,
            max(e.occurred_at) FILTER (WHERE e.event_type = ANY (ARRAY['delivered'::text, 'complained'::text])) AS delivered_at,
            min(e.occurred_at) FILTER (WHERE e.event_type = ANY (ARRAY['bounced'::text, 'failed'::text, 'suppressed'::text])) AS refused_at,
            (array_agg(e.detail ORDER BY e.occurred_at) FILTER (WHERE (e.event_type = ANY (ARRAY['bounced'::text, 'failed'::text, 'suppressed'::text])) AND e.detail IS NOT NULL))[1] AS refused_detail
           FROM to_list t
             LEFT JOIN email_events e ON e.resend_email_id = t.resend_email_id AND e.recipient = t.addr
          GROUP BY t.resend_email_id, t.addr
        ), agg AS (
         SELECT a.resend_email_id,
            count(*) AS to_count,
            count(*) FILTER (WHERE a.delivered AND NOT a.refused) AS delivered_count,
            count(*) FILTER (WHERE a.refused) AS refused_count,
            bool_or(a.complained) AS complained,
            bool_or(a.delayed AND NOT a.delivered AND NOT a.refused) AS delayed,
            max(a.delivered_at) AS delivered_at,
            min(a.delivered_at) AS first_delivered_at,
            min(a.refused_at) AS refused_at,
            (array_agg(a.refused_detail ORDER BY a.refused_at) FILTER (WHERE a.refused_detail IS NOT NULL))[1] AS refused_detail
           FROM addr a
          GROUP BY a.resend_email_id
        ), ev AS (
         SELECT e.resend_email_id,
            count(*) FILTER (WHERE e.event_type <> 'backfill_summary'::text) AS event_count,
            min(e.occurred_at) FILTER (WHERE e.event_type = 'opened'::text) AS opened_at,
            COALESCE(bool_or(e.event_type <> 'backfill_summary'::text AND e.recipient <> ''::text AND t.addr IS NULL), false) AS other_recipient,
            (array_agg(e.detail ORDER BY e.received_at DESC) FILTER (WHERE e.event_type = 'backfill_summary'::text))[1] AS summary
           FROM email_events e
             LEFT JOIN to_list t ON t.resend_email_id = e.resend_email_id AND t.addr = e.recipient
          GROUP BY e.resend_email_id
        ), base AS (
         SELECT s.resend_email_id,
            s.source_table,
            s.send_id,
            s.send_ids,
            s.target,
            s.sent_at,
            s.client_id,
            s.visit_id,
            s.manifest_id,
            s.is_test,
            s.no_copies,
            cfg.track_since,
            cfg.track_until,
            cfg.live_since,
            COALESCE(g.to_count, 0::bigint) AS to_count,
            COALESCE(g.delivered_count, 0::bigint) AS delivered_count,
            COALESCE(g.refused_count, 0::bigint) AS refused_count,
            COALESCE(g.complained, false) AS complained,
            COALESCE(g.delayed, false) AS delayed,
            g.delivered_at,
            g.first_delivered_at,
            g.refused_at,
            g.refused_detail,
            COALESCE(ev.event_count, 0::bigint) AS event_count,
            ev.opened_at,
            COALESCE(ev.other_recipient, false) AS other_recipient,
            ev.summary,
            ev.summary IS NOT NULL AND COALESCE(ev.event_count, 0::bigint) = 0 AS summary_only
           FROM sends s
             CROSS JOIN cfg
             LEFT JOIN agg g ON g.resend_email_id = s.resend_email_id
             LEFT JOIN ev ON ev.resend_email_id = s.resend_email_id
        ), reasoned AS (
         SELECT b.resend_email_id,
            b.source_table,
            b.send_id,
            b.send_ids,
            b.target,
            b.sent_at,
            b.client_id,
            b.visit_id,
            b.manifest_id,
            b.is_test,
            b.no_copies,
            b.track_since,
            b.track_until,
            b.live_since,
            b.to_count,
            b.delivered_count,
            b.refused_count,
            b.complained,
            b.delayed,
            b.delivered_at,
            b.first_delivered_at,
            b.refused_at,
            b.refused_detail,
            b.event_count,
            b.opened_at,
            b.other_recipient,
            b.summary,
            b.summary_only,
                CASE
                    WHEN b.sent_at < b.track_since THEN 'before_tracking'::text
                    WHEN b.sent_at >= b.track_until THEN 'tracking_off'::text
                    WHEN b.summary_only THEN 'summary_only'::text
                    WHEN b.target = 'city'::text THEN 'archive_copy'::text
                    WHEN NOT b.no_copies OR b.other_recipient THEN 'other_recipients'::text
                    ELSE NULL::text
                END AS open_unknown_reason
           FROM base b
        ), st AS (
         SELECT r.resend_email_id,
            r.source_table,
            r.send_id,
            r.send_ids,
            r.target,
            r.sent_at,
            r.client_id,
            r.visit_id,
            r.manifest_id,
            r.is_test,
            r.no_copies,
            r.track_since,
            r.track_until,
            r.live_since,
            r.to_count,
            r.delivered_count,
            r.refused_count,
            r.complained,
            r.delayed,
            r.delivered_at,
            r.first_delivered_at,
            r.refused_at,
            r.refused_detail,
            r.event_count,
            r.opened_at,
            r.other_recipient,
            r.summary,
            r.summary_only,
            r.open_unknown_reason,
                CASE
                    WHEN r.summary_only THEN
                    CASE
                        WHEN (r.summary ->> 'last_event'::text) = ANY (ARRAY['bounced'::text, 'failed'::text, 'suppressed'::text]) THEN 'not_delivered'::text
                        ELSE 'delivered_open_unknown'::text
                    END
                    WHEN r.refused_count > 0 AND r.delivered_count = 0 AND r.refused_count = r.to_count THEN 'not_delivered'::text
                    WHEN r.refused_count > 0 THEN 'partly_bounced'::text
                    WHEN r.complained THEN 'spam'::text
                    WHEN r.to_count > 0 AND r.delivered_count = r.to_count THEN
                    CASE
                        WHEN r.open_unknown_reason IS NOT NULL THEN 'delivered_open_unknown'::text
                        WHEN r.opened_at IS NOT NULL THEN 'opened'::text
                        ELSE 'delivered'::text
                    END
                    WHEN r.delivered_count > 0 THEN 'partly_delivered'::text
                    WHEN r.delayed THEN 'delayed'::text
                    WHEN r.sent_at > (now() - '02:00:00'::interval) THEN 'sending'::text
                    WHEN r.sent_at >= r.live_since THEN 'no_status'::text
                    ELSE 'no_record'::text
                END AS delivery_status,
                CASE
                    WHEN r.opened_at >= r.first_delivered_at THEN floor(EXTRACT(epoch FROM r.opened_at - r.first_delivered_at))::integer
                    ELSE NULL::integer
                END AS open_gap_seconds,
            regexp_replace(COALESCE((r.refused_detail -> 'bounce'::text) ->> 'message'::text, (r.refused_detail -> 'failed'::text) ->> 'reason'::text, (r.refused_detail -> 'suppressed'::text) ->> 'message'::text, r.refused_detail ->> 'message'::text, r.refused_detail ->> 'reason'::text), '[^[:space:]<>@]+@[^[:space:]<>]+'::text, 'an inbox'::text, 'g'::text) AS bounce_reason
           FROM reasoned r
        ), fin AS (
         SELECT st.resend_email_id,
            st.source_table,
            st.send_id,
            st.send_ids,
            st.target,
            st.sent_at,
            st.client_id,
            st.visit_id,
            st.manifest_id,
            st.is_test,
            st.no_copies,
            st.track_since,
            st.track_until,
            st.live_since,
            st.to_count,
            st.delivered_count,
            st.refused_count,
            st.complained,
            st.delayed,
            st.delivered_at,
            st.first_delivered_at,
            st.refused_at,
            st.refused_detail,
            st.event_count,
            st.opened_at,
            st.other_recipient,
            st.summary,
            st.summary_only,
            st.open_unknown_reason,
            st.delivery_status,
            st.open_gap_seconds,
            st.bounce_reason,
                CASE st.delivery_status
                    WHEN 'opened'::text THEN st.opened_at
                    WHEN 'not_delivered'::text THEN COALESCE(st.refused_at,
                    CASE
                        WHEN st.summary_only THEN st.sent_at
                        ELSE NULL::timestamp with time zone
                    END)
                    WHEN 'partly_bounced'::text THEN st.refused_at
                    WHEN 'delivered_open_unknown'::text THEN COALESCE(st.delivered_at, st.sent_at)
                    WHEN 'delivered'::text THEN st.delivered_at
                    WHEN 'spam'::text THEN st.delivered_at
                    WHEN 'partly_delivered'::text THEN st.delivered_at
                    ELSE NULL::timestamp with time zone
                END AS delivery_at
           FROM st
        )
 SELECT resend_email_id,
    source_table,
    send_id,
    send_ids,
    target,
    sent_at,
    client_id,
    visit_id,
    manifest_id,
    is_test,
    delivery_status,
    delivery_at,
    to_count,
    delivered_count,
    refused_count,
    delivered_at,
    opened_at,
    open_gap_seconds,
    open_unknown_reason IS NULL AS open_creditable,
    open_unknown_reason,
    bounce_reason,
    summary_only,
    summary ->> 'basis'::text AS summary_basis,
    summary ->> 'last_event'::text AS summary_last_event,
    event_count,
    jsonb_strip_nulls(jsonb_build_object('target', target, 'to_count', to_count, 'delivered_count', delivered_count, 'refused_count', refused_count, 'delivered_at', delivered_at, 'opened_at',
        CASE
            WHEN open_unknown_reason IS NULL THEN opened_at
            ELSE NULL::timestamp with time zone
        END, 'open_gap_seconds',
        CASE
            WHEN open_unknown_reason IS NULL THEN open_gap_seconds
            ELSE NULL::integer
        END, 'open_unknown_reason', open_unknown_reason, 'bounce_reason', bounce_reason, 'summary_only', summary_only, 'summary_basis', summary ->> 'basis'::text)) AS delivery_detail
   FROM fin;

CREATE OR REPLACE FUNCTION public.fn_notification_health_items(p_city jsonb, p_as_of timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH cfg AS (
    SELECT public.fn_city_email_delay() AS delay,
           coalesce((SELECT nullif(btrim(value), '')::timestamptz FROM public.app_config WHERE key = 'city_email_start_from'),
                    'infinity'::timestamptz) AS go_live,
           -- the first visit date the city email covers: the same constant as public.fn_admin_review_pending
           DATE '2026-09-15' AS scope_from,
           (p_as_of AT TIME ZONE 'America/New_York')::date AS today
  ),
  listed AS (
    SELECT DISTINCT (e->>'visit_id')::bigint AS visit_id
    FROM jsonb_array_elements(coalesce(p_city, '[]'::jsonb)) e
  ),
  -- real Admin Review sends (send-visit-photos-email)
  ar_rows AS (
    SELECT s.visit_id, s.sent_at, s.include_manifest IS TRUE AS with_manifest
    FROM public.visit_photo_email_sends s
    WHERE s.status = 'sent' AND NOT coalesce(s.is_test, false) AND s.sent_at <= p_as_of
  ),
  -- real city sends from the DERM Tracker or the automatic email, for a LIVE manifest linked to the visit and the
  -- visit's own client (derm_email_sends has no visit_id; that pair is the finest grain it has). A row whose reason
  -- starts 'attachment:manifest_images' is a letter that went with NOTHING attached (send-derm-email could build no
  -- report), so it does not count as the city having the manifest. A client copy (recipient_type 'client') never counts.
  dt_rows AS (
    SELECT mv.visit_id, d.sent_at, (d.sent_by_email IS NULL AND d.sent_at >= cfg.go_live) AS automatic
    FROM public.manifest_visits mv
    JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL
    JOIN public.visits v ON v.id = mv.visit_id
    JOIN public.derm_email_sends d ON d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
    CROSS JOIN cfg
    WHERE d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false)
      AND coalesce(d.reason, '') NOT LIKE 'attachment:manifest_images%'
      AND d.sent_at <= p_as_of
  ),
  ar AS (
    SELECT visit_id, min(sent_at) AS first_at, bool_or(with_manifest) AS any_with_manifest,
           max(sent_at) FILTER (WHERE NOT with_manifest) AS last_without_at
    FROM ar_rows GROUP BY visit_id
  ),
  dt AS (
    SELECT visit_id, min(sent_at) AS first_at, (array_agg(automatic ORDER BY sent_at))[1] AS first_automatic
    FROM dt_rows GROUP BY visit_id
  ),
  base AS (
    SELECT v.id AS visit_id FROM public.visits v, cfg
     WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date >= cfg.scope_from
    UNION SELECT visit_id FROM listed
    UNION SELECT ar.visit_id FROM ar, cfg WHERE ar.last_without_at >= cfg.go_live
  ),
  f AS (
    SELECT b.visit_id, v.client_id, c.client_code, v.property_id, coalesce(p.city, 'no city') AS city,
           v.visit_date, v.visit_status, v.deleted_at, v.derm_required,
           EXISTS (SELECT 1 FROM listed l WHERE l.visit_id = b.visit_id) AS listed,
           EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e
                    WHERE e IS NOT NULL AND position('@' IN e) > 0) AS has_inbox,
           EXISTS (SELECT 1 FROM public.v_visit_not_for_city n WHERE n.visit_id = b.visit_id) AS grey_water,
           EXISTS (SELECT 1 FROM public.manifest_visits mv
                     JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL
                    WHERE mv.visit_id = b.visit_id) AS has_manifest,
           coalesce(public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture']), false) AS test_client,
           ar.first_at AS ar_first_at, coalesce(ar.any_with_manifest, false) AS ar_with_manifest, ar.last_without_at,
           dt.first_at AS dt_first_at, dt.first_automatic,
           coalesce(pc.total_images, 0) AS photos_total, coalesce(pc.classified_images, 0) AS photos_sorted
    FROM base b
    LEFT JOIN public.visits v ON v.id = b.visit_id
    LEFT JOIN public.clients c ON c.id = v.client_id
    LEFT JOIN public.properties p ON p.id = v.property_id
    LEFT JOIN ar ON ar.visit_id = b.visit_id
    LEFT JOIN dt ON dt.visit_id = b.visit_id
    LEFT JOIN public.v_visit_photo_counts pc ON pc.visit_id = b.visit_id
  ),
  label AS (
    SELECT f.*, format('Visit %s (%s, %s, %s)', f.visit_id, coalesce(f.client_code, 'no client'), f.city,
                       coalesce(to_char(f.visit_date, 'Mon FMDD'), 'no date')) AS who
    FROM f
  ),
  -- A. listed, although the raw tables say no city email is due or one already went
  a AS (
    SELECT l.*, array_remove(ARRAY[
             CASE WHEN l.visit_status IS DISTINCT FROM 'completed' OR l.deleted_at IS NOT NULL
                  THEN 'the visit is not a live completed visit' END,
             CASE WHEN l.visit_date < cfg.scope_from
                  THEN 'it is dated before the city email started (Sep 15)' END,
             CASE WHEN l.test_client THEN 'it belongs to a test client' END,
             CASE WHEN l.derm_required IS FALSE
                  THEN 'it is not a DERM job (DERM required is off), so no city email is due' END,
             CASE WHEN l.ar_first_at IS NOT NULL
                  THEN 'Admin Review already sent its city email on ' || to_char(l.ar_first_at AT TIME ZONE 'America/New_York', 'Mon FMDD') END,
             CASE WHEN l.dt_first_at IS NOT NULL
                  THEN 'its manifest already went to the city on ' || to_char(l.dt_first_at AT TIME ZONE 'America/New_York', 'Mon FMDD')
                       || CASE WHEN l.first_automatic THEN ' (the automatic email)' ELSE ' (DERM Tracker, Send to city)' END END,
             CASE WHEN l.grey_water THEN 'it is grey water, which never goes to the city' END,
             CASE WHEN NOT l.has_inbox THEN 'its property has no city inbox on file' END
           ], NULL) AS why
    FROM label l CROSS JOIN cfg WHERE l.listed
  ),
  -- C. the city has the report but not the manifest, the manifest IS linked, and it has not followed well past the
  --    automatic email's delay. (No manifest linked at all is F, not C.) Dated since go-live only.
  c0 AS (
    SELECT l.* FROM label l, cfg
    WHERE l.last_without_at IS NOT NULL AND NOT l.ar_with_manifest AND l.dt_first_at IS NULL AND l.has_manifest
      AND l.deleted_at IS NULL AND l.visit_status = 'completed' AND l.visit_date >= cfg.scope_from AND NOT l.test_client
      AND l.derm_required IS NOT FALSE AND NOT l.grey_water
      AND l.last_without_at >= cfg.go_live
      AND l.last_without_at < p_as_of - (cfg.delay + interval '2 days')
  ),
  c AS (
    SELECT c0.*,
           (SELECT string_agg(DISTINCT k.status, ', ')
              FROM public.manifest_visits mv
              JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL
              JOIN derm.v_city_email_candidates k ON k.manifest_id = mv.manifest_id AND k.client_id = c0.client_id
             WHERE mv.visit_id = c0.visit_id) AS sweep_status
    FROM c0
  ),
  -- D. a property with a DERM visit since go-live and no city inbox, in a city where 3+ other properties have one
  props AS (
    SELECT p.id, p.client_id, p.city, lower(btrim(p.city)) AS ck,
           EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e
                    WHERE e IS NOT NULL AND position('@' IN e) > 0) AS has_inbox
    FROM public.properties p
    WHERE p.deleted_at IS NULL AND NOT coalesce(p.is_billing, false) AND nullif(btrim(p.city), '') IS NOT NULL
  ),
  d0 AS (
    SELECT x.id, x.city, x.ck, cl.client_code,
           (SELECT string_agg(v.id || ' (' || to_char(v.visit_date, 'Mon FMDD') || ')', ', ' ORDER BY v.visit_date, v.id)
              FROM public.visits v, cfg
             WHERE v.property_id = x.id AND v.deleted_at IS NULL AND v.visit_status = 'completed'
               AND v.derm_required IS TRUE AND v.visit_date >= cfg.scope_from) AS derm_visits
    FROM props x
    JOIN public.clients cl ON cl.id = x.client_id
    WHERE NOT x.has_inbox
      AND NOT coalesce(public.fn_is_non_customer(x.client_id, ARRAY['test', 'fixture']), false)
  ),
  d AS (
    SELECT d0.*, (SELECT count(*) FROM props y WHERE y.ck = d0.ck AND y.id <> d0.id AND y.has_inbox) AS city_inboxes
    FROM d0 WHERE d0.derm_visits IS NOT NULL
  ),
  -- E. the two 11 AM reminders' own run records (one public.sync_log row per real run, written by the edge functions
  --    and, when the vault key is missing, by the cron wrappers). A [TEST] run logs under '<source>_test' and carries
  --    details.test = true, and never counts. Clean word 'success'; failure word 'error'.
  e AS (
    SELECT s.src, s.label, s.job, r.last_at, r.last_status, r.last_error
    FROM (VALUES ('admin_review_reminder', 'Admin Review', 'admin-review-reminder'),
                 ('stamp_sheets_reminder', 'Stamp Studio', 'stamp-sheets-reminder'),
                 ('time_on_site_reminder', 'time on site', 'time-on-site-reminder')) s(src, label, job)
    LEFT JOIN LATERAL (
      SELECT l.started_at AS last_at, l.status AS last_status,
             coalesce(l.error_details->>'message', l.details->>'reason', 'no reason recorded') AS last_error
      FROM public.sync_log l
      WHERE l.sync_source = s.src AND coalesce(l.details->>'test', 'false') <> 'true' AND l.started_at <= p_as_of
      ORDER BY l.started_at DESC LIMIT 1) r ON true
  ),
  items AS (
    SELECT jsonb_build_object(
             'kind', 'city_list_false_positive:visit-' || a.visit_id, 'issue', 'city_list_false_positive',
             'visit', a.visit_id, 'client_code', a.client_code, 'property', a.property_id,
             'reason', a.who || ' is on the Admin Review "city email not sent" list, but ' || array_to_string(a.why, '; ') || '.',
             'what_to_do', 'Do not send it to the city before checking. The 11 AM list (public.fn_admin_review_pending) and '
                           'this check disagree about this visit: find which of the two is wrong and fix that one.') AS item
      FROM a WHERE cardinality(a.why) > 0
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'city_list_missed:visit-' || l.visit_id, 'issue', 'city_list_missed',
             'visit', l.visit_id, 'client_code', l.client_code, 'property', l.property_id,
             'reason', l.who || ' is a completed DERM job with a city inbox, a manifest and all ' || l.photos_total
                       || ' photos sorted, and nothing has gone to the city, but the Admin Review list leaves it out, so nobody is reminded.',
             'what_to_do', 'Send it to the city from Admin Review, then find out why public.fn_admin_review_pending skipped it.')
      FROM label l CROSS JOIN cfg
     WHERE NOT l.listed AND l.deleted_at IS NULL AND l.visit_status = 'completed' AND l.visit_date >= cfg.scope_from
       AND l.derm_required IS TRUE AND NOT l.test_client AND l.has_inbox AND NOT l.grey_water AND l.has_manifest
       AND l.ar_first_at IS NULL AND l.dt_first_at IS NULL
       AND l.photos_total > 0 AND l.photos_sorted >= l.photos_total
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'manifest_follow_stalled:visit-' || c.visit_id, 'issue', 'manifest_follow_stalled',
             'visit', c.visit_id, 'client_code', c.client_code, 'property', c.property_id, 'sweep_status', c.sweep_status,
             'reason', c.who || ': Admin Review sent the city report without the manifest on '
                       || to_char(c.last_without_at AT TIME ZONE 'America/New_York', 'Mon FMDD') || ', and the manifest has still not gone to the city '
                       || floor(extract(epoch FROM p_as_of - c.last_without_at) / 86400)::int || ' days later. '
                       || CASE WHEN c.sweep_status IS NULL THEN 'Its manifest has no blacked-out copy yet, so the automatic email cannot send it.'
                               ELSE 'The automatic email for its manifest reads "' || c.sweep_status || '".' END,
             'what_to_do', 'Open the manifest in the DERM Tracker and press Send to city, or fix what holds the automatic email.')
      FROM c
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'city_inbox_missing:property-' || d.id, 'issue', 'city_inbox_missing',
             'property', d.id, 'client_code', d.client_code,
             'reason', 'Property ' || d.id || ' (' || d.client_code || ', ' || d.city || ') has DERM visits but no city inbox, while '
                       || d.city_inboxes || ' other ' || d.city || ' properties have one, so its city emails cannot go and the 11 AM list never shows them. '
                       || 'Completed DERM visits since Sep 15: ' || d.derm_visits || '.',
             'what_to_do', 'Add the city inbox to property ' || d.id || ' (the address the other ' || d.city
                           || ' properties use), then send its DERM visits to the city from Admin Review.')
      FROM d WHERE d.city_inboxes >= 3
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'reminder_not_run:' || e.src, 'issue', 'reminder_not_run', 'source', e.src,
             'reason', 'The ' || e.label || ' 11 AM Slack reminder has written no run record since '
                       || to_char(e.last_at AT TIME ZONE 'America/New_York', 'Mon FMDD FMHH12:MI AM') || ' ET. It writes one every day, '
                       'also when there is nothing to post, so the cron job did not run or the call never reached the reminder.',
             'what_to_do', 'Check cron job ' || e.job || ' in cron.job_run_details, the pg_net responses, and the logs of the edge function ' || e.job || '.')
      FROM e WHERE e.last_at IS NOT NULL AND e.last_at < p_as_of - interval '26 hours'
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'reminder_failed:' || e.src, 'issue', 'reminder_failed', 'source', e.src,
             'reason', 'The ' || e.label || ' 11 AM Slack reminder failed on its last run ('
                       || to_char(e.last_at AT TIME ZONE 'America/New_York', 'Mon FMDD FMHH12:MI AM') || ' ET): ' || left(e.last_error, 300) || '.',
             'what_to_do', 'Read that run''s row in public.sync_log (sync_source ' || e.src || ') and the logs of the edge function '
                           || e.job || ', fix the cause, and check Slack got the next post.')
      FROM e WHERE e.last_status = 'error'
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'no_manifest_after_14_days:visit-' || l.visit_id, 'issue', 'no_manifest_after_14_days',
             'visit', l.visit_id, 'client_code', l.client_code, 'property', l.property_id,
             'reason', l.who || ' is a completed DERM job with a city inbox, and ' || (cfg.today - l.visit_date)
                       || ' days later no manifest is linked to it, so its city email cannot go and the 11 AM list holds it.'
                       || coalesce(' Admin Review sent the city report without the manifest on '
                                   || to_char(l.last_without_at AT TIME ZONE 'America/New_York', 'Mon FMDD') || '.', ''),
             'what_to_do', 'Link this pumping''s manifest to the visit (DERM Tracker, or log the dump in the DUMP app) so the city '
                           'email can go. If there is no manifest for it, ask Fred whether the visit still needs a city email.')
      FROM label l CROSS JOIN cfg
     WHERE l.deleted_at IS NULL AND l.visit_status = 'completed' AND l.visit_date >= cfg.scope_from
       AND l.derm_required IS TRUE AND NOT l.test_client AND l.has_inbox AND NOT l.grey_water
       AND NOT l.has_manifest AND NOT l.ar_with_manifest
       AND l.visit_date < cfg.today - 14
    UNION ALL
    -- 2026-10-14_1505: what Resend reported back (public.v_email_delivery). Real sends to real customers only, last 7
    -- days, so a stale item ages out. Never an address in the text: bounce_reason is masked in the view.
    SELECT jsonb_build_object(
             'kind', 'email_not_delivered:' || ed.source_table || '-' || ed.send_id, 'issue', 'email_not_delivered',
             'client_code', cl.client_code, 'visit', ed.visit_id, 'manifest', ed.manifest_id, 'target', ed.target,
             'reason', CASE ed.target WHEN 'city' THEN 'The city email' ELSE 'The client email' END || ' for '
                       || coalesce(cl.client_code, 'no client') || ' sent '
                       || to_char(ed.sent_at AT TIME ZONE 'America/New_York', 'Mon FMDD FMHH12:MI AM') || ' ET '
                       || CASE ed.delivery_status
                            WHEN 'spam' THEN 'was reported as spam by the receiving email system.'
                            WHEN 'partly_bounced' THEN 'was refused by ' || ed.refused_count || ' of ' || ed.to_count || ' inboxes'
                                                       || coalesce(': ' || ed.bounce_reason, '') || '.'
                            ELSE 'was not delivered' || coalesce(': ' || ed.bounce_reason, '') || '.' END,
             'what_to_do', CASE ed.target
                             WHEN 'city' THEN 'Check the city emails on the property in the Client App, then send it to the city again.'
                             ELSE 'Check the client''s report email in the Client App, then send it again.' END)
      FROM public.v_email_delivery ed
      LEFT JOIN public.clients cl ON cl.id = ed.client_id
     WHERE NOT ed.is_test AND NOT coalesce(public.fn_is_non_customer(ed.client_id, ARRAY['test', 'fixture']), false)
       AND ed.delivery_status IN ('not_delivered', 'partly_bounced', 'spam')
       AND ed.sent_at > p_as_of - interval '7 days' AND ed.sent_at <= p_as_of
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'email_status_missing:' || ed.source_table || '-' || ed.send_id, 'issue', 'email_status_missing',
             'client_code', cl.client_code, 'visit', ed.visit_id, 'manifest', ed.manifest_id, 'target', ed.target,
             'reason', 'The ' || ed.target || ' email for ' || coalesce(cl.client_code, 'no client') || ' sent '
                       || to_char(ed.sent_at AT TIME ZONE 'America/New_York', 'Mon FMDD FMHH12:MI AM')
                       || ' ET has no delivery report from Resend after 2 hours, so the Resend webhook may have stopped.',
             'what_to_do', 'Check the webhook in the Resend dashboard (Webhooks, its recent attempts) and the logs of the edge '
                           'function webhook-resend. Once it works, run its backfill ({"backfill": true} with the service key) to fill the gap.')
      FROM public.v_email_delivery ed
      LEFT JOIN public.clients cl ON cl.id = ed.client_id
     WHERE NOT ed.is_test AND NOT coalesce(public.fn_is_non_customer(ed.client_id, ARRAY['test', 'fixture']), false)
       AND ed.delivery_status = 'no_status'
       AND ed.sent_at > p_as_of - interval '7 days' AND ed.sent_at < p_as_of - interval '2 hours'
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'email_delivery_incomplete:' || ed.source_table || '-' || ed.send_id, 'issue', 'email_delivery_incomplete',
             'client_code', cl.client_code, 'visit', ed.visit_id, 'manifest', ed.manifest_id, 'target', ed.target,
             'reason', 'The ' || ed.target || ' email for ' || coalesce(cl.client_code, 'no client') || ' sent '
                       || to_char(ed.sent_at AT TIME ZONE 'America/New_York', 'Mon FMDD FMHH12:MI AM') || ' ET reached '
                       || ed.delivered_count || ' of ' || ed.to_count || ' inboxes and is still '
                       || CASE ed.delivery_status WHEN 'delayed' THEN 'being held by the receiving email system' ELSE 'waiting for the rest' END
                       || ' a day later.',
             'what_to_do', 'Look the email up in the Resend dashboard (Emails). If an inbox keeps refusing it, check that address on the '
                           'property or client, then send again.')
      FROM public.v_email_delivery ed
      LEFT JOIN public.clients cl ON cl.id = ed.client_id
     WHERE NOT ed.is_test AND NOT coalesce(public.fn_is_non_customer(ed.client_id, ARRAY['test', 'fixture']), false)
       AND ed.delivery_status IN ('partly_delivered', 'delayed')
       AND ed.sent_at > p_as_of - interval '7 days' AND ed.sent_at < p_as_of - interval '24 hours'
  )
  -- one item per key: the health scan upserts on (check, key), and a repeated key in one run would abort it
  SELECT coalesce(jsonb_agg(u.item ORDER BY u.item->>'kind'), '[]'::jsonb)
  FROM (SELECT DISTINCT ON (i.item->>'kind') i.item FROM items i ORDER BY i.item->>'kind') u
$function$;
COMMIT;
