-- ============================================================================
-- 2026-10-29 13:30 ET  The 11 AM Admin Review post lists Broward clients only
-- ============================================================================
-- Slack #apps-notifications, 2026-10-29 11:00 ET post "Broward: city email not sent yet (4)": Diego, "The only
-- customer in Broward is Sassy, Why does it show me the other ones?" The list held every visit whose city has an inbox
-- (Surfside, in Miami-Dade, and Hallandale Beach, in Broward) under the fixed word "Broward" (Fred, 2026-10-12: put
-- them together "and just call it Broward"). Three of the four were Surfside (083-SHUL, 306-16, 324-BIB).
-- Fred, 2026-10-29: "i don't care about the label, only show Broward clients."
--
-- WHAT CHANGES
--   1. public.fn_admin_review_pending(): a visit is listed only when its property's county is 'Broward' (one JOIN).
--      Everything else in the list rule is unchanged.
--   2. public.fn_notification_health_items(): its own rebuild of the list follows the same rule, or the daily health
--      check would report every Surfside visit as "city_list_missed". It also names a non-Broward visit if one is
--      ever listed (city_list_false_positive). Nothing else in it moves.
-- Not changed: the edge function admin-review-reminder (its heading "Broward" is now true), the Admin Review app,
-- the city email itself (Surfside visits still get their city email when someone sends it; they are only no longer
-- in this post).
-- Both bodies copied from pg_get_functiondef with anchored edits (each anchor matched once), md5-pinned below.
-- Rollback: 2026-10-29_rollback_admin_review_list_broward_only.sql
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path = public, pg_catalog;

DO $pin$
BEGIN
  IF md5(pg_get_functiondef('public.fn_admin_review_pending'::regproc)) <> '0c87852b0765f00ed76ff970c2a0b5ba'
     OR md5(pg_get_functiondef('public.fn_notification_health_items'::regproc)) <> '8acedc59f5879ad060d7957f3c18dff7' THEN
    RAISE EXCEPTION 'a function changed since this migration was written; rebuild it from the live bodies';
  END IF;
END $pin$;

-- the list before the change, for the checks below
CREATE TEMP TABLE _old_list ON COMMIT DROP AS
  SELECT (e->>'visit_id')::bigint AS visit_id FROM jsonb_array_elements(public.fn_admin_review_pending() -> 'city') e;

CREATE OR REPLACE FUNCTION public.fn_admin_review_pending()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH today AS (SELECT (now() AT TIME ZONE 'America/New_York')::date AS d),
  pend AS (
    -- completed since the city email went live (2026-09-15 09:07 ET), read from public.v_visit_city_email_state, the
    -- one per-visit answer (2026-10-12_1305). needs_city_email = DERM-required (NULL counts as required), not grey
    -- water, the city has an email on file, dated 2026-09-15 or later (older visits read before_go_live), a live
    -- manifest is linked, and nothing carrying the manifest has gone yet (Admin Review with the manifest, the DERM
    -- Tracker "Send to city", or the automatic sweep). The date line below repeats before_go_live on purpose, so no
    -- later change to the view can put a pre-go-live visit on the post. Not listed:
    -- waiting_manifest (no manifest linked yet, held: Diego, 2026-10-12, "kc is waiting manifest so off course I can
    -- not sent it") and report_sent_manifest_follows (Admin Review sent the report without the manifest; the sweep
    -- sends the manifest). A visit held too long is a health-check item (log_notification_health), not a post line.
    SELECT st.visit_id, c.client_code, c.name AS client_name, st.regulator_municipality AS city,
           st.visit_date, e.full_name AS driver,
           coalesce(pc.total_images, 0) AS photos_total, coalesce(pc.classified_images, 0) AS photos_sorted
    FROM public.v_visit_city_email_state st
    JOIN public.visits v ON v.id = st.visit_id
    JOIN public.clients c ON c.id = st.client_id
    LEFT JOIN public.v_visit_photo_counts pc ON pc.visit_id = st.visit_id
    LEFT JOIN public.employees e ON e.id = v.assigned_driver_id
    -- 2026-10-29 (Fred, on Diego's "The only customer in Broward is Sassy ... Why does it show me the other ones?"):
    -- "only show Broward clients". The visit's property must be in Broward County; Surfside (Miami-Dade) is left out.
    -- public.fn_notification_health_items applies the same rule, so its check does not report them as missed.
    JOIN public.properties pr ON pr.id = v.property_id AND pr.county = 'Broward'
    WHERE st.state = 'needs_city_email'
      AND st.visit_date >= DATE '2026-09-15'
      AND NOT public.fn_is_non_customer(st.client_id, ARRAY['test', 'fixture'])
  ),
  unsorted AS (
    -- the Admin Review queue's "Photos Not Sorted": in the queue, and some photo not classified yet
    SELECT w.id, w.visit_date
    FROM public.visits_with_review w
    JOIN public.v_visit_photo_counts pc ON pc.visit_id = w.id
    WHERE w.visit_status = 'completed' AND w.in_review_scope
      AND w.visit_date <= (SELECT d FROM today)
      AND pc.total_images > pc.classified_images
      AND NOT public.fn_is_non_customer(w.client_id, ARRAY['test', 'fixture'])
  )
  SELECT jsonb_build_object(
    'city', coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.city, p.visit_date, p.client_code) FROM pend p), '[]'::jsonb),
    'photos', jsonb_build_object(
      'count', (SELECT count(*) FROM unsorted),
      'last_7_days', (SELECT count(*) FROM unsorted WHERE visit_date > (SELECT d FROM today) - 7),
      'oldest', (SELECT min(visit_date) FROM unsorted)))
$function$;

CREATE TEMP TABLE _new_list ON COMMIT DROP AS
  SELECT public.fn_admin_review_pending() -> 'city' AS city;

-- control: the OLD health rule, fed the new (shorter) list, reports every dropped visit as missed. Rows kept for V4.
CREATE TEMP TABLE _old_health ON COMMIT DROP AS
  SELECT public.fn_notification_health_items((SELECT city FROM _new_list)) AS items;

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
    SELECT b.visit_id, v.client_id, c.client_code, v.property_id, coalesce(p.city, 'no city') AS city, p.county,
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
             CASE WHEN NOT l.has_inbox THEN 'its property has no city inbox on file' END,
             CASE WHEN l.county IS DISTINCT FROM 'Broward'
                  THEN 'its property is not in Broward County, and the list shows Broward clients only (Fred, 2026-10-29)' END
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
       AND l.county = 'Broward'  -- the list shows Broward clients only (2026-10-29)
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

DO $verify$
DECLARE
  v_old int; v_new int; v_dropped int; v_extra int; v_wrong int; v_ctl int; v_missed int; v_fp int;
BEGIN
  SELECT count(*) INTO v_old FROM _old_list;
  SELECT jsonb_array_length(city) INTO v_new FROM _new_list;

  -- V1 the new list is exactly the old list's Broward visits
  SELECT count(*) INTO v_extra FROM jsonb_array_elements((SELECT city FROM _new_list)) e
   WHERE (e->>'visit_id')::bigint NOT IN (SELECT visit_id FROM _old_list);
  SELECT count(*) INTO v_wrong FROM _old_list o JOIN public.visits v ON v.id = o.visit_id
    LEFT JOIN public.properties p ON p.id = v.property_id
   WHERE (p.county = 'Broward') <> EXISTS (SELECT 1 FROM jsonb_array_elements((SELECT city FROM _new_list)) e
                                            WHERE (e->>'visit_id')::bigint = o.visit_id);
  IF v_extra > 0 OR v_wrong > 0 THEN
    RAISE EXCEPTION 'V1: the new list is not the old list''s Broward visits (extra %, wrong %)', v_extra, v_wrong;
  END IF;
  v_dropped := v_old - v_new;

  -- V2 control: with the old health rule, each dropped visit is reported as missed (the reason this migration also
  -- changes the health check). Only measurable when something was dropped.
  SELECT count(*) INTO v_ctl FROM jsonb_array_elements((SELECT items FROM _old_health)) i
   WHERE i->>'issue' = 'city_list_missed'
     AND (i->>'visit')::bigint IN (SELECT visit_id FROM _old_list)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements((SELECT city FROM _new_list)) e WHERE e->>'visit_id' = i->>'visit');
  IF v_ctl <> v_dropped THEN
    RAISE EXCEPTION 'V2: the old health rule should report the % dropped visits as missed, it reports %', v_dropped, v_ctl;
  END IF;

  -- V3 the new health rule reports none of them, and no false positive on the new list
  SELECT count(*) FILTER (WHERE i->>'issue' = 'city_list_missed' AND (i->>'visit')::bigint IN (SELECT visit_id FROM _old_list)),
         count(*) FILTER (WHERE i->>'issue' = 'city_list_false_positive')
    INTO v_missed, v_fp
    FROM jsonb_array_elements(public.fn_notification_health_items((SELECT city FROM _new_list))) i;
  IF v_missed > 0 OR v_fp > 0 THEN
    RAISE EXCEPTION 'V3: the new health rule still reports % missed / % false positive', v_missed, v_fp;
  END IF;

  -- V4 a non-Broward visit put on the list is named as a false positive (the new reason fires)
  IF v_dropped > 0 THEN
    SELECT count(*) INTO v_fp FROM jsonb_array_elements(public.fn_notification_health_items(
      (SELECT jsonb_agg(jsonb_build_object('visit_id', visit_id)) FROM _old_list))) i
     WHERE i->>'issue' = 'city_list_false_positive' AND i->>'reason' LIKE '%not in Broward County%';
    IF v_fp <> v_dropped THEN
      RAISE EXCEPTION 'V4: % non-Broward visits on the list should be named, % were', v_dropped, v_fp;
    END IF;
  END IF;

  RAISE NOTICE 'list before %, after %, dropped % (not Broward)', v_old, v_new, v_dropped;
END $verify$;

COMMIT;
