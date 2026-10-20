-- 2026-10-20_1930_unopened_email_reminder.sql
--
-- THE SLACK ALERT FOR EMAILS DELIVERED BUT NOT OPENED (Trello xMtqH9Xw), Monday, Wednesday and Friday at 11 AM ET.
--
-- WHY. Yan (Slack #new-app-issues, 2026-10-20): "I want a notification 3 times a week if emails have been delivered
--   and not opened (if they have been opened I dont want a notification)". The card: the office (Diego) catches
--   unopened government emails early and follows up by phone before deadlines slip. Fred, from the mockup (2026-10-20):
--   build D5 first (2026-10-20_1900 + the senders, so a city open can be counted), keep an email on the list up to
--   7 days, Layout 1 (grouped by city), tag Diego, post in #apps-notifications like the other app notifications.
--
-- WHAT
--   public.fn_unopened_emails(p_as_of timestamptz DEFAULT now()) -> jsonb {as_of, emails[]}. The ONE rule of what the
--     alert lists; the edge function only formats it. It reads the apps' own answers, never re-derives them:
--     public.v_email_delivery (status, open timing), public.v_visit_city_email_sends (the city email's visit and who
--     sent it) and public.v_client_email_sends (client emails). An email is listed when ALL hold:
--       real (not is_test), not a test or fixture client (fn_is_non_customer), sent after open tracking started
--       (app_config email_open_tracking_since: before that an open can never be known), sent at least 24 hours and less
--       than 7 days before p_as_of (Fred: "up to 7 days"; the 24 hours gives the reader a day first), and it is
--       section 'not_delivered': delivery_status not_delivered / partly_bounced / spam / partly_delivered / delayed, or
--       section 'not_opened': delivery_status delivered / delivered_open_unknown, or opened LESS than 60 seconds after it
--         arrived (the apps call that "most likely automatically by their email app"; a machine open must not take an
--         email off the call list).
--     Not listed: opened 60 s or more after arrival (Yan: opened, no notification), still sending, no status (the
--     health email covers a webhook that stopped), no record.
--   public.fn_request_unopened_email_reminder(): the 11 AM caller, the same shape as the other reminders
--     (2026-10-12_1310): only the run that is 11 AM in New York goes on, it calls the edge function every day, and the
--     edge function decides whether today is a posting day (Mon/Wed/Fri ET) and writes one public.sync_log row per run
--     (source unopened_email_reminder; '_test' for a [TEST] run), so a quiet day and a day it never ran differ. A
--     missing vault key writes the 'error' row here.
--   cron unopened-email-reminder '0 15,16 * * *'.
--   public.fn_notification_health_items (body copied from pg_get_functiondef, md5 pinned): the E list gains
--     ('unopened_email_reminder', 'unopened email', 'unopened-email-reminder'), so reminder_not_run / reminder_failed
--     reach Fred's health email (26-hour window: the edge function writes a row every day, posting or not).
--
-- VERIFY (inside, cheap): grants on both new functions (service_role only); the list runs now and returns an array;
--   POSITIVE CONTROL on live data: as of 2026-10-22 11:00 ET it lists the real Admin Review city email of 2026-10-20
--   (visit_photo_email_sends 403) as not_opened; the wrapper keeps the 11 AM gate and its own URL; the cron job exists;
--   the health items are unchanged on install. Every list rule runs on fixtures in
--   scripts/probes/unopened_emails_fixtures.sql (rolled back).
-- Rule 8: no table or column change. sync_log is the append-only run log (existing opt-out).
-- ROLLBACK: docs/migrations/2026-10-20_rollback_unopened_email_reminder.sql (unschedules the job, drops the two new
--   functions, puts back the health function body).

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$
BEGIN
  IF md5(pg_get_functiondef('public.fn_notification_health_items(jsonb,timestamp with time zone)'::regprocedure)) <> 'b502c20f40cd29eaec8a9399ce6b6b9b' THEN
    RAISE EXCEPTION 'public.fn_notification_health_items changed since this migration was written: copy the new live body';
  END IF;
END $pin$;

CREATE TEMP TABLE ue_health_before ON COMMIT DROP AS
  SELECT public.fn_notification_health_items('[]'::jsonb, now()) AS h;

CREATE OR REPLACE FUNCTION public.fn_unopened_emails(p_as_of timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH cfg AS (
    SELECT coalesce((SELECT CASE WHEN btrim(c.value) ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN btrim(c.value)::timestamptz END
                       FROM public.app_config c WHERE c.key = 'email_open_tracking_since'), 'infinity'::timestamptz) AS track_since
  ),
  -- one row per city email: a DERM Tracker send is credited to every visit of that client on the manifest, keep one
  city AS (
    SELECT DISTINCT ON (s.source_table, s.send_id) s.source_table, s.send_id, s.visit_id, s.via, s.sent_by_name
    FROM public.v_visit_city_email_sends s
    ORDER BY s.source_table, s.send_id, s.visit_id
  ),
  sends AS (
    SELECT d.resend_email_id, d.source_table, d.send_id, d.target, d.sent_at, d.client_id, d.manifest_id, d.is_test,
           d.delivery_status, d.to_count, d.delivered_count, d.refused_count, d.open_gap_seconds, d.open_unknown_reason,
           d.bounce_reason, c.visit_id, c.via, c.sent_by_name
    FROM public.v_email_delivery d
    JOIN city c ON c.source_table = d.source_table AND c.send_id = d.send_id
    WHERE d.target = 'city'
    UNION ALL
    SELECT d.resend_email_id, d.source_table, d.send_id, d.target, d.sent_at, d.client_id, d.manifest_id, d.is_test,
           d.delivery_status, d.to_count, d.delivered_count, d.refused_count, d.open_gap_seconds, d.open_unknown_reason,
           d.bounce_reason,
           (SELECT min(mv.visit_id) FROM public.manifest_visits mv JOIN public.visits v2 ON v2.id = mv.visit_id
             WHERE mv.manifest_id = d.manifest_id AND v2.client_id = d.client_id AND v2.deleted_at IS NULL),
           'derm_tracker', ce.sent_by_name
    FROM public.v_email_delivery d
    JOIN public.v_client_email_sends ce ON ce.send_id = d.send_id
    WHERE d.target = 'client' AND d.source_table = 'derm_email_sends'
  ),
  listed AS (
    SELECT s.*,
           CASE
             WHEN s.delivery_status IN ('not_delivered', 'partly_bounced', 'spam', 'partly_delivered', 'delayed') THEN 'not_delivered'
             WHEN s.delivery_status IN ('delivered', 'delivered_open_unknown') THEN 'not_opened'
             -- an open under 60 s is most likely the reader's email system, not a person (the apps say so too)
             WHEN s.delivery_status = 'opened' AND s.open_gap_seconds < 60 THEN 'not_opened'
           END AS section
    FROM sends s CROSS JOIN cfg
    WHERE NOT s.is_test
      AND s.sent_at >= cfg.track_since
      AND s.sent_at <= p_as_of - interval '24 hours'
      AND s.sent_at > p_as_of - interval '7 days'
      AND NOT coalesce(public.fn_is_non_customer(s.client_id, ARRAY['test', 'fixture']), false)
  )
  SELECT jsonb_build_object(
    'as_of', p_as_of,
    'emails', coalesce(jsonb_agg(jsonb_build_object(
       'section', l.section, 'target', l.target, 'source_table', l.source_table, 'send_id', l.send_id,
       'resend_email_id', l.resend_email_id,
       'client_code', cl.client_code, 'client_name', cl.name, 'city', nullif(btrim(p.city), ''),
       'visit_id', l.visit_id, 'visit_date', v.visit_date, 'manifest_id', l.manifest_id,
       'app', CASE WHEN l.source_table = 'visit_photo_email_sends' THEN 'admin_review' ELSE 'derm_tracker' END,
       'kind', CASE WHEN l.source_table = 'visit_photo_email_sends' THEN 'job report'
                    WHEN l.target = 'city' THEN 'manifest' ELSE 'report to the client' END,
       'via', l.via, 'sent_by_name', l.sent_by_name, 'sent_at', l.sent_at,
       'delivery_status', l.delivery_status, 'open_gap_seconds', l.open_gap_seconds,
       'open_unknown_reason', l.open_unknown_reason, 'to_count', l.to_count, 'delivered_count', l.delivered_count,
       'refused_count', l.refused_count, 'bounce_reason', l.bounce_reason
     ) ORDER BY l.sent_at, l.send_id) FILTER (WHERE l.section IS NOT NULL), '[]'::jsonb))
  FROM listed l
  LEFT JOIN public.clients cl ON cl.id = l.client_id
  LEFT JOIN public.visits v ON v.id = l.visit_id
  LEFT JOIN public.properties p ON p.id = v.property_id
$function$;

COMMENT ON FUNCTION public.fn_unopened_emails(timestamp with time zone) IS
  'The ONE list behind the unopened email Slack alert (2026-10-20_1930, Trello xMtqH9Xw): real emails (city and DERM Tracker client) sent after open tracking started, 1 to 7 days before p_as_of, not delivered or not opened (an open under 60 s counts as not opened). Reads v_email_delivery, v_visit_city_email_sends, v_client_email_sends. service_role only.';
REVOKE ALL ON FUNCTION public.fn_unopened_emails(timestamp with time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_unopened_emails(timestamp with time zone) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_unopened_emails(timestamp with time zone) TO service_role;

CREATE OR REPLACE FUNCTION public.fn_request_unopened_email_reminder()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text;
begin
  -- 11 AM Eastern whatever the season (Fred, 2026-10-07: every scheduled notification at 11): the job runs at 15:00
  -- and 16:00 UTC, and only one is 11 AM in New York. The edge function decides whether today is a posting day
  -- (Monday, Wednesday, Friday ET) and writes its run record in public.sync_log on every call.
  if extract(hour from now() at time zone 'America/New_York') <> 11 then
    return;
  end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping the unopened email reminder';
    insert into public.sync_log (sync_source, started_at, finished_at, duration_seconds, status, rows_errored,
                                 error_details, details)
    values ('unopened_email_reminder', now(), clock_timestamp(), 0, 'error', 1,
            jsonb_build_object('message', 'The unopened email Slack reminder did not run today: the database is missing the key '
                               || 'it uses to call the reminder. Put the key back, then the reminder runs again tomorrow.'),
            jsonb_build_object('posted', false, 'reason', 'no vault key', 'missing_secret', 'edge_invoke_service_key',
                               'test', false));
    return;
  end if;
  perform net.http_post(
    url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/unopened-email-reminder',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000);
end
$function$;
REVOKE ALL ON FUNCTION public.fn_request_unopened_email_reminder() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_request_unopened_email_reminder() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_request_unopened_email_reminder() TO service_role;

SELECT cron.schedule('unopened-email-reminder', '0 15,16 * * *', 'select public.fn_request_unopened_email_reminder()');

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
                 ('time_on_site_reminder', 'time on site', 'time-on-site-reminder'),
                 ('unopened_email_reminder', 'unopened email', 'unopened-email-reminder')) s(src, label, job)
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
    UNION ALL
    -- 2026-10-20_1900 (D5): since D5 the archive copy of a city email is its OWN email to derm@ayache.com, sent right
    -- after the city email. A real city send whose archive copy did not go (archive_resend_email_id NULL) is listed here,
    -- 15 minutes after the send, for 7 days. The city has its email; only our archive copy is missing.
    SELECT jsonb_build_object(
             'kind', 'city_email_archive_missing:' || x.src || '-' || x.id, 'issue', 'city_email_archive_missing',
             'client_code', cl.client_code, 'visit', x.visit_id, 'manifest', x.manifest_id,
             'reason', 'The city email for ' || coalesce(cl.client_code, 'no client') || ' sent '
                       || to_char(x.sent_at AT TIME ZONE 'America/New_York', 'Mon FMDD FMHH12:MI AM') || ' ET reached the city, but our archive copy '
                       || 'to derm@ayache.com did not go out' || coalesce(': ' || left(x.archive_error, 200), '') || '.',
             'what_to_do', 'Nothing is owed to the city. Keep a copy for the archive: the email is in the Resend dashboard (Emails) for 30 days. '
                           || 'Then read the logs of the edge function ' || x.fn || ' to see why the archive copy failed.')
      FROM (SELECT 'derm_email_sends'::text AS src, d.id, NULL::bigint AS visit_id, d.manifest_id, d.client_id, d.sent_at,
                   d.archive_error, 'send-derm-email'::text AS fn
              FROM public.derm_email_sends d
             WHERE d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false)
               AND d.hidden_copies_separate IS TRUE AND d.archive_resend_email_id IS NULL
            UNION ALL
            SELECT 'visit_photo_email_sends', s.id, s.visit_id, NULL::bigint, v.client_id, s.sent_at,
                   s.archive_error, 'send-visit-photos-email'
              FROM public.visit_photo_email_sends s
              LEFT JOIN public.visits v ON v.id = s.visit_id
             WHERE s.status = 'sent' AND NOT coalesce(s.is_test, false)
               AND s.hidden_copies_separate IS TRUE AND s.archive_resend_email_id IS NULL) x
      LEFT JOIN public.clients cl ON cl.id = x.client_id
     WHERE NOT coalesce(public.fn_is_non_customer(x.client_id, ARRAY['test', 'fixture']), false)
       AND x.sent_at > p_as_of - interval '7 days' AND x.sent_at < p_as_of - interval '15 minutes'
  )
  -- one item per key: the health scan upserts on (check, key), and a repeated key in one run would abort it
  SELECT coalesce(jsonb_agg(u.item ORDER BY u.item->>'kind'), '[]'::jsonb)
  FROM (SELECT DISTINCT ON (i.item->>'kind') i.item FROM items i ORDER BY i.item->>'kind') u
$function$;

-- VERIFY ------------------------------------------------------------------------------------------------------------
DO $verify$
DECLARE r jsonb; n int;
BEGIN
  -- V1 grants: service_role only
  IF has_function_privilege('anon', 'public.fn_unopened_emails(timestamp with time zone)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_unopened_emails(timestamp with time zone)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.fn_request_unopened_email_reminder()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_request_unopened_email_reminder()', 'EXECUTE') THEN
    RAISE EXCEPTION 'V1 a new function is executable by anon or authenticated'; END IF;
  IF NOT has_function_privilege('service_role', 'public.fn_unopened_emails(timestamp with time zone)', 'EXECUTE') THEN
    RAISE EXCEPTION 'V1 service_role cannot execute fn_unopened_emails'; END IF;
  -- V2 it runs now and returns an array
  r := public.fn_unopened_emails(now());
  IF jsonb_typeof(r->'emails') <> 'array' THEN RAISE EXCEPTION 'V2 emails is not an array: %', r; END IF;
  -- V3 POSITIVE CONTROL: as of 2026-10-22 11:00 ET the real Admin Review city email of 2026-10-20 is listed
  r := public.fn_unopened_emails(timestamptz '2026-10-22 15:00+00');
  SELECT count(*) INTO n FROM jsonb_array_elements(r->'emails') e
   WHERE e->>'source_table' = 'visit_photo_email_sends' AND (e->>'send_id')::bigint = 403
     AND e->>'section' = 'not_opened' AND e->>'kind' = 'job report' AND e->>'city' IS NOT NULL;
  IF n <> 1 THEN RAISE EXCEPTION 'V3 visit_photo_email_sends 403 not listed as of 2026-10-22: %', r; END IF;
  -- and nothing sent less than a day before, or 7 days or more before, is listed
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'emails') e
              WHERE (e->>'sent_at')::timestamptz > timestamptz '2026-10-21 15:00+00'
                 OR (e->>'sent_at')::timestamptz <= timestamptz '2026-10-15 15:00+00') THEN
    RAISE EXCEPTION 'V3 an email outside the 1 to 7 day window is listed'; END IF;
  -- V4 the wrapper keeps the 11 AM gate and calls its own function; the cron job is there
  IF position('<> 11' IN pg_get_functiondef('public.fn_request_unopened_email_reminder()'::regprocedure)) = 0
     OR position('https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/unopened-email-reminder'
                 IN pg_get_functiondef('public.fn_request_unopened_email_reminder()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'V4 the wrapper lost its hour gate or its URL'; END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'unopened-email-reminder' AND schedule = '0 15,16 * * *' AND active) THEN
    RAISE EXCEPTION 'V4 the cron job is missing'; END IF;
  -- V5 the health function knows the new source and its output did not change on install
  IF position('unopened_email_reminder' IN pg_get_functiondef('public.fn_notification_health_items(jsonb,timestamp with time zone)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'V5 the health function does not know unopened_email_reminder'; END IF;
  IF (SELECT h FROM ue_health_before) IS DISTINCT FROM public.fn_notification_health_items('[]'::jsonb, now()) THEN
    RAISE EXCEPTION 'V5 fn_notification_health_items output changed on install'; END IF;
  RAISE NOTICE 'unopened email reminder migration verify: all pass';
END $verify$;

COMMIT;
