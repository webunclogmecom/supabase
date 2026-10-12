-- ============================================================================
-- 2026-10-12_1400  notification-health: a daily check that the 11 AM reminders say what the apps and send logs say
-- ============================================================================
-- THE ASK
--   The 11 AM Slack post "Admin Review: photos and city emails" of 2026-10-12 listed 5 visits as "city email not sent"
--   and all 5 were wrong. Diego (Slack, 2026-10-12): "plug in is a unclog", "a la carte, I already sent it o october 9".
--   Two were unclog jobs (8575, 8744, derm_required false) and three had gone from the DERM Tracker on Oct 9
--   (6218, 6270, 6284). 2026-10-12_1120 fixed the list, but nothing would have caught it, or the next one: the only
--   checks fed the edge function made-up rows, and no health item covered a notification. On Oct 8 the same list held
--   6138 and 6247, already sent from the DERM Tracker on Sep 25, and both were re-sent from Admin Review at 11:18 ET,
--   so Hallandale Beach got 6247 three times and 6138 twice.
--   The 2026-10-12 notification audit (P2): "A daily live check in pg_cron, before 11 AM, feeding the health email."
--   GO-AHEAD: Fred, 2026-10-12: "let's better our logic for the notifications, and check our data is correct, and try to fix it so it doesn't happens again"
--
-- WHAT CHANGES
--   1. NEW public.fn_notification_health_items(p_city jsonb, p_as_of timestamptz DEFAULT now()) -> jsonb items.
--      STABLE, read-only. Judges a city list (the "city" array of public.fn_admin_review_pending()) against the RAW
--      tables (visits, properties, visit_photo_email_sends, derm_email_sends, manifest_visits + live derm_manifests,
--      v_visit_not_for_city, v_visit_photo_counts, sync_log). It is a deliberate second implementation (an oracle) of
--      "has this visit's city email gone": it never reads v_visit_city_email_state or v_visit_city_email_status, so a
--      wrong view is caught instead of copied. A rule change there must change this function in the same migration.
--      "Sent" = a real Admin Review send (status sent, not is_test), or a real city row in derm_email_sends for a live
--      manifest linked to the visit and the visit's own client, whose reason does not start 'attachment:manifest_images'
--      (that letter went with nothing attached). A client copy never counts. p_as_of judges the send logs and
--      sync_log as of that moment (later rows ignored); the cron never passes it, the VERIFY does.
--      PRE-GO-LIVE VISITS DO NOT COUNT (Fred, 2026-10-12: "we don't care about the old for this"): B, C, D, F and G
--      leave out every visit dated before 2026-09-15 (one constant, cfg.scope_from), which is the state
--      'before_go_live' of v_visit_city_email_state (city-state bundle, 2026-10-12_1305). A still flags such a visit
--      when the list shows it. Replayed at 09:15 ET on each of the 27 days Sep 16 to Oct 12, this rule changed no item.
--      Items (key = "kind", stable across days so health_alert_state dedups; the text names the visit or property):
--        A city_list_false_positive:visit-<id>   listed although derm_required is false, a real city send exists in
--          either log, it is grey water, its property has no city inbox, it is not a live completed visit, it is
--          dated before Sep 15, or it is a test client.
--        B city_list_missed:visit-<id>           a live completed DERM job since 2026-09-15 with a city inbox, not a
--          test client, not grey water, a live manifest, all photos sorted (v_visit_photo_counts, the count the post
--          uses), no real send in either log, that the list leaves out.
--        C manifest_follow_stalled:visit-<id>    a visit dated since 2026-09-15 with a real Admin Review send WITHOUT
--          the manifest since go-live (app_config city_email_start_from), older than fn_city_email_delay() + 2 days,
--          the manifest IS linked, and it has not gone to the city. The text says what holds it (no blacked-out copy, or the status
--          derm.v_city_email_candidates gives). No manifest linked at all is F, not C.
--        D city_inbox_missing:property-<id>      a live, non-billing property with a completed DERM visit since
--          2026-09-15 and no city inbox, while 3 or more other live properties of its city (trimmed, any case) have
--          one; test clients left out. Today: 1113 only (324-BIB, Surfside, visit 8112).
--        E reminder_not_run:<source>             the newest REAL run record of 'admin_review_reminder' or
--          'stamp_sheets_reminder' is older than 26 hours (two 11 AM runs are 23 to 25 hours apart over DST; the VERIFY
--          pins it between 25 and 27). Silent until the first real row exists. A [TEST] run
--          (sync_source '<source>_test', or details.test = true) never counts.
--          reminder_failed:<source>              that newest real row has status 'error' (the reminder could not post,
--          or the cron wrapper found no vault key). Clean word 'success', failure word 'error'.
--        F no_manifest_after_14_days:visit-<id>  a live completed DERM job since 2026-09-15 with a city inbox, not grey
--          water, not a test client, no live manifest linked, no Admin Review send that carried the manifest, and its
--          visit date more than 14 days ago. This includes the Admin-Review-first case (report sent, manifest never
--          linked). It replaces a "held too long" line in the Slack post, which stays as it is.
--        G city_email_duplicate:visit-<id>       a visit dated since 2026-09-15, not a test client, whose manifest the
--          city received 2 or more times across both logs (Admin Review sends with the manifest + real DERM Tracker /
--          automatic city sends), the last one within 7 days. Today: 6138 (2 times) and 6247 (3 times), through the
--          Oct 15 run.
--   2. NEW public.log_notification_health(p_pending jsonb DEFAULT NULL) -> integer. Writes ONE sync_log row,
--      sync_source 'notification-health': status 'ok' (nothing found) / 'attention' (items) / 'error' (the check could
--      not run). details = {count, items, city_list_count, by_issue}, the shape the other log_*_health functions use
--      (kind, issue, reason, what_to_do: what health-escalate prints). Any failure, including a change to the shape
--      of fn_admin_review_pending()->'city', becomes the single item notification_check_failed, and no input can make
--      the INSERT fail (the list is counted inside the protected block). p_pending is for the VERIFY only.
--      Both functions: revoked BY NAME from PUBLIC, anon, authenticated; EXECUTE to service_role only.
--   3. cron 'notification-health' at '15 13 * * *' (09:15 EDT / 08:15 EST): after jobber-sync-health (13:13), before
--      start-flags-health (13:20), db-backup-health (13:25), health-escalation (13:30) and the 11 AM ET reminders, so a
--      wrong list reaches Fred's inbox before Diego sees the post.
--   4. ops.v_health_items and ops.v_health_status: rebuilt from their LIVE text (md5 pinned below), adding only
--      'notification-health' to the source list(s) and one CASE arm reading details->'items'. Nothing else moves.
--
-- WHAT IT REPORTS AT WRITING (2026-10-12 13:15 ET, measured on a rolled-back copy):
--   D city_inbox_missing:property-1113; G city_email_duplicate:visit-6138 and visit-6247. A, B, C, E, F: none.
--   The pre-fix function (2026-10-07_1305), rebuilt as a temporary function and judged today, lists 7 visits; A flags
--   exactly the 5 false alarms of the 2026-10-12 post (6218, 6270, 6284 already sent; 8575, 8744 not DERM).
--
-- LOCKS: the heavy VERIFY (function behaviour, rolled-back mutations of single rows of the send logs, sync_log,
--   manifest_visits and properties) runs BEFORE the two health views are replaced; after the DDL only cheap reads
--   run (the views evaluate in about 5 ms and 11 ms). The md5 pin runs twice: at the top, and again right after the
--   snapshot, whose reads hold ACCESS SHARE on both views until COMMIT, so a change committed by another session
--   during the 12 s VERIFY stops the migration instead of being overwritten. SET LOCAL lock_timeout = '3s'.
--   Apply outside 13:00-13:35 UTC (the health crons write then, and the before/after comparison would see their new
--   rows) and retry on a lock_timeout (the 2-hourly backup dump at HH:17 UTC on even hours holds ACCESS SHARE on the
--   views).
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table is created or altered. The function writes only public.sync_log,
--   the sync journal, which is not audited by design. The VERIFY's mutations of visit_photo_email_sends,
--   derm_email_sends (UPDATEs and fixture INSERTs), manifest_visits (DELETEs only), properties, non_customer_clients,
--   photo_classifications and sync_log are inside sub-blocks that always roll back, audit rows and row locks included.
--   Not applicable.
--
-- ROLLBACK: SELECT cron.unschedule('notification-health');
--           re-create ops.v_health_items and ops.v_health_status from the previous text (md5 4baa8428... and
--           4c0ef505..., i.e. this file's bodies without the 'notification-health' entries and arm), with
--           SET LOCAL lock_timeout = '3s';
--           DROP FUNCTION public.log_notification_health(jsonb); DROP FUNCTION public.fn_notification_health_items(jsonb, timestamptz);
--           the rows stay in sync_log (journal) and health_alert_state (they resolve on the next scan).
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

-- Pin: refuse if either health view changed since this file was written (read 2026-10-12 13:02 ET)
DO $pin$
BEGIN
  IF md5(pg_get_viewdef('ops.v_health_items'::regclass, true)) <> '4baa8428a4cd9f06d9ec0b3e12dce4b3' THEN
    RAISE EXCEPTION 'ops.v_health_items changed since this migration was written; rebuild it from the live text';
  END IF;
  IF md5(pg_get_viewdef('ops.v_health_status'::regclass, true)) <> '4c0ef505d2f74de163963272cd88f4e4' THEN
    RAISE EXCEPTION 'ops.v_health_status changed since this migration was written; rebuild it from the live text';
  END IF;
END
$pin$;

-- 1 + 2. The check ------------------------------------------------------------
-- The two functions of the notification health check. Pasted verbatim into the migration and the tests (build.js).

-- Judges a city list (the "city" array of public.fn_admin_review_pending()) against the RAW tables, and adds the
-- checks that need no list. Returns the items array. Read-only.
-- THIS IS A DELIBERATE SECOND IMPLEMENTATION (an oracle) of "has this visit's city email gone". It reads visits,
-- properties, the two send logs and the manifest links itself, and never public.v_visit_city_email_state or
-- public.v_visit_city_email_status, so a wrong view is caught instead of copied. Any rule change to
-- v_visit_city_email_state (what counts as sent, DERM, grey water, inbox, test client) must change this function in
-- the SAME migration, or the two disagree and this check reports it.
-- p_as_of: the moment to judge at (default now). The send logs are read as of that moment (later sends ignored);
-- visits, manifests, photos and inboxes are always today's values. The cron never passes it; the VERIFY does.
-- PRE-GO-LIVE VISITS DO NOT COUNT (Fred, 2026-10-12: "we don't care about the old for this"): no item B, C, D, F or
-- G counts a visit dated before cfg.scope_from (2026-09-15), which is what v_visit_city_email_state's state
-- 'before_go_live' says. A still flags one the list shows ("dated before the city email started"): the list must
-- never hold one.
CREATE OR REPLACE FUNCTION public.fn_notification_health_items(p_city jsonb, p_as_of timestamptz DEFAULT now())
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
  -- every city email that carried the manifest, from either app
  msend AS (
    SELECT visit_id, sent_at, 'Admin Review' AS via FROM ar_rows WHERE with_manifest
    UNION ALL
    SELECT visit_id, sent_at, CASE WHEN automatic THEN 'the automatic email' ELSE 'DERM Tracker' END FROM dt_rows
  ),
  g0 AS (
    SELECT visit_id, count(*) AS n, max(sent_at) AS last_at,
           string_agg(to_char(sent_at AT TIME ZONE 'America/New_York', 'Mon FMDD FMHH12:MI AM') || ' (' || via || ')', ', '
                      ORDER BY sent_at) AS sends
    FROM msend GROUP BY visit_id HAVING count(*) >= 2
  ),
  base AS (
    SELECT v.id AS visit_id FROM public.visits v, cfg
     WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date >= cfg.scope_from
    UNION SELECT visit_id FROM listed
    UNION SELECT ar.visit_id FROM ar, cfg WHERE ar.last_without_at >= cfg.go_live
    UNION SELECT visit_id FROM g0
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
                 ('stamp_sheets_reminder', 'Stamp Studio', 'stamp-sheets-reminder')) s(src, label, job)
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
    SELECT jsonb_build_object(
             'kind', 'city_email_duplicate:visit-' || g0.visit_id, 'issue', 'city_email_duplicate',
             'visit', g0.visit_id, 'client_code', l.client_code, 'property', l.property_id,
             'reason', l.who || ': the city received its manifest ' || g0.n || ' times: ' || g0.sends || '.',
             'what_to_do', 'Nothing to undo, the city already has it. Tell whoever sent it last that it had already gone, and '
                           'check both the DERM Tracker and Admin Review before sending a city email again.')
      FROM g0 JOIN label l ON l.visit_id = g0.visit_id CROSS JOIN cfg
     WHERE NOT l.test_client AND l.visit_date >= cfg.scope_from
       AND g0.last_at > p_as_of - interval '7 days'
  )
  -- one item per key: the health scan upserts on (check, key), and a repeated key in one run would abort it
  SELECT coalesce(jsonb_agg(u.item ORDER BY u.item->>'kind'), '[]'::jsonb)
  FROM (SELECT DISTINCT ON (i.item->>'kind') i.item FROM items i ORDER BY i.item->>'kind') u
$function$;

-- The cron entry point: judge today's list, write ONE verdict row. p_pending is for the VERIFY only (it feeds a
-- broken list on purpose); the cron passes nothing and the function reads public.fn_admin_review_pending().
-- Status words of this source: 'ok' (nothing found), 'attention' (items found), 'error' (the check could not run;
-- it still carries the item notification_check_failed, so a broken check escalates instead of reading as healthy).
CREATE OR REPLACE FUNCTION public.log_notification_health(p_pending jsonb DEFAULT NULL)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_started    timestamptz := clock_timestamp();
  v_city       jsonb;
  v_items      jsonb;
  v_err        text;
  v_failed     boolean := false;
  v_list_count integer;
  n            integer;
begin
  begin
    v_city := coalesce(p_pending, public.fn_admin_review_pending()) -> 'city';
    -- the list's shape is part of the contract: a renamed key must fail loudly, not judge an empty list
    if jsonb_typeof(v_city) is distinct from 'array' then
      raise exception 'fn_admin_review_pending() no longer returns a "city" array (got %)', coalesce(jsonb_typeof(v_city), 'nothing');
    end if;
    if exists (select 1 from jsonb_array_elements(v_city) e where jsonb_typeof(e -> 'visit_id') is distinct from 'number') then
      raise exception 'fn_admin_review_pending() returned a city entry without a numeric visit_id';
    end if;
    v_items := public.fn_notification_health_items(v_city);
    if jsonb_typeof(v_items) is distinct from 'array' then
      raise exception 'fn_notification_health_items() returned no array';
    end if;
    -- counted here, inside the protected block, so no shape can make the INSERT below fail
    v_list_count := jsonb_array_length(v_city);
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_failed := true;
    v_list_count := null;
    v_items := jsonb_build_array(jsonb_build_object(
      'kind', 'notification_check_failed', 'issue', 'notification_check_failed',
      'reason', 'The daily notification check could not run, so nothing it watches was checked today: ' || left(v_err, 300),
      'what_to_do', 'Run select public.log_notification_health(); by hand and fix the error it raises.'));
  end;
  n := jsonb_array_length(v_items);
  -- clock_timestamp(), not now(): two runs in one transaction must not tie in ops.v_health_items' DISTINCT ON
  insert into public.sync_log (sync_source, started_at, finished_at, duration_seconds, rows_errored, status, error_details, details)
  values ('notification-health', v_started, clock_timestamp(),
          round(extract(epoch from clock_timestamp() - v_started)::numeric, 3), n,
          case when v_failed then 'error' when n > 0 then 'attention' else 'ok' end,
          case when v_failed then jsonb_build_object('message', left(v_err, 300)) end,
          jsonb_build_object('count', n, 'items', v_items, 'city_list_count', v_list_count,
                             'by_issue', (select coalesce(jsonb_object_agg(k, c), '{}'::jsonb)
                                            from (select i->>'issue' as k, count(*) as c
                                                    from jsonb_array_elements(v_items) i group by 1) x)));
  return n;
end
$function$;

REVOKE ALL ON FUNCTION public.fn_notification_health_items(jsonb, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.log_notification_health(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_notification_health_items(jsonb, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.log_notification_health(jsonb) TO service_role;

-- VERIFY 1: the functions. Runs BEFORE the health views are replaced, so no app read waits on it.
-- Every control is a fact read from the raw tables (visits, properties, the two send logs, manifest links, sync_log).
-- Data mutations happen inside sub-blocks that always end by raising NH0xx, which rolls the sub-block back (rows,
-- audit rows and row locks); only the measured booleans survive it.
DO $verify$
DECLARE
  fn       text;
  v_today  jsonb;   -- today's real items (the live list)
  v_empty  jsonb;   -- the items for an empty list: every check that needs no list, and B for everything waiting
  v_hist   jsonb;   -- the pre-fix lists of Oct 8 and Oct 10, judged today
  v_ex     jsonb;   -- dynamically chosen examples of each A reason
  v_all    jsonb := '[]'::jsonb;
  v_list   jsonb;
  v_t      timestamptz;
  v_d      date;
  v_ids    jsonb := '{}'::jsonb;  -- the control rows picked at run time, for the closing notice
  x bigint; y bigint; z bigint; t bigint; u bigint; w bigint;
  p_id bigint; q_id bigint; r_id bigint; s_id bigint;
  n int;
  b_bad    text;   -- the B condition whose removal B did not notice
  g bigint;
  pre bigint; zz bigint; m_del bigint; m_live bigint; c_id bigint; pg bigint; po bigint; d2 bigint; dp bigint;
  v_go timestamptz := (SELECT value::timestamptz FROM public.app_config WHERE key = 'city_email_start_from');
  ok1 boolean; ok2 boolean; ok3 boolean; ok4 boolean; ok5 boolean; ok6 boolean; ok7 boolean; ok8 boolean;
BEGIN
  -- V1. Grants: callable by service_role (and cron as postgres) only, revoked BY NAME (default privileges grant by name).
  --     One function of each name, so no older overload is left callable.
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'fn_notification_health_items' AND pronamespace = 'public'::regnamespace) <> 1
     OR (SELECT count(*) FROM pg_proc WHERE proname = 'log_notification_health' AND pronamespace = 'public'::regnamespace) <> 1 THEN
    RAISE EXCEPTION 'VERIFY V1: expected exactly one fn_notification_health_items and one log_notification_health'; END IF;
  FOREACH fn IN ARRAY ARRAY['public.fn_notification_health_items(jsonb,timestamptz)', 'public.log_notification_health(jsonb)'] LOOP
    IF has_function_privilege('anon', fn, 'EXECUTE') OR has_function_privilege('authenticated', fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'VERIFY V1: % is callable by anon or authenticated', fn; END IF;
    IF NOT has_function_privilege('service_role', fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'VERIFY V1: service_role cannot execute %', fn; END IF;
    IF (SELECT proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(proacl) a WHERE a.grantee = 0)
          FROM pg_proc WHERE oid = fn::regprocedure) THEN
      RAISE EXCEPTION 'VERIFY V1: % still carries a PUBLIC grant', fn; END IF;
  END LOOP;

  v_today := public.fn_notification_health_items(public.fn_admin_review_pending() -> 'city');
  v_empty := public.fn_notification_health_items('[]');
  v_all := v_all || v_today || v_empty;

  -- V2. A, historical positive control: what the pre-fix function listed on Oct 8 and Oct 10 and was wrong about.
  --     8575 and 8744 are unclog jobs (derm_required false); 6138 and 6247 went to Hallandale Beach from the DERM
  --     Tracker on Sep 25 (derm_email_sends 184-186); 6218, 6270, 6284 on Oct 9 (190, 191, 194). These are send-log
  --     history; if one of them changes before apply, the migration stops, which is a surprise worth stopping on.
  v_hist := public.fn_notification_health_items(
    '[{"visit_id":8575},{"visit_id":8744},{"visit_id":6138},{"visit_id":6247},{"visit_id":6218},{"visit_id":6270},{"visit_id":6284}]');
  v_all := v_all || v_hist;
  FOREACH x IN ARRAY ARRAY[8575, 8744]::bigint[] LOOP
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_hist) i
                   WHERE i->>'kind' = 'city_list_false_positive:visit-' || x AND i->>'reason' LIKE '%not a DERM job%') THEN
      RAISE EXCEPTION 'VERIFY V2: unclog visit % on the list was not flagged as not DERM', x; END IF;
  END LOOP;
  FOREACH x IN ARRAY ARRAY[6138, 6247, 6218, 6270, 6284]::bigint[] LOOP
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_hist) i
                   WHERE i->>'kind' = 'city_list_false_positive:visit-' || x AND i->>'reason' LIKE '%already went to the city%DERM Tracker%') THEN
      RAISE EXCEPTION 'VERIFY V2: visit % already sent from the DERM Tracker was not flagged', x; END IF;
  END LOOP;

  -- V2b. A, every other reason, on visits chosen from the raw tables at run time: an Admin Review send, grey water,
  --      no city inbox, a test client, a visit that is not completed, a visit dated before Sep 15 (pre-go-live).
  SELECT min(s.visit_id) INTO x FROM public.visit_photo_email_sends s
   WHERE s.status = 'sent' AND NOT coalesce(s.is_test, false) AND s.sent_at >= '2026-09-15';
  SELECT min(n2.visit_id) INTO y FROM public.v_visit_not_for_city n2 JOIN public.visits v ON v.id = n2.visit_id
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed';
  SELECT min(v.id) INTO z FROM public.visits v JOIN public.properties p ON p.id = v.property_id
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date >= '2026-09-15'
     AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0);
  SELECT min(v.id) INTO t FROM public.visits v
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture']);
  SELECT min(v.id) INTO u FROM public.visits v WHERE v.deleted_at IS NULL AND v.visit_status <> 'completed';
  SELECT min(v.id) INTO pre FROM public.visits v
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date < '2026-09-15'
     AND NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture']);
  IF x IS NULL OR y IS NULL OR z IS NULL OR t IS NULL OR u IS NULL OR pre IS NULL THEN
    RAISE EXCEPTION 'VERIFY V2b: no example visit found (% % % % % %)', x, y, z, t, u, pre; END IF;
  v_ex := public.fn_notification_health_items(jsonb_build_array(
            jsonb_build_object('visit_id', x), jsonb_build_object('visit_id', y), jsonb_build_object('visit_id', z),
            jsonb_build_object('visit_id', t), jsonb_build_object('visit_id', u), jsonb_build_object('visit_id', pre)));
  v_all := v_all || v_ex;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_ex) i WHERE i->>'kind' = 'city_list_false_positive:visit-' || x AND i->>'reason' LIKE '%Admin Review already sent%')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_ex) i WHERE i->>'kind' = 'city_list_false_positive:visit-' || y AND i->>'reason' LIKE '%grey water%')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_ex) i WHERE i->>'kind' = 'city_list_false_positive:visit-' || z AND i->>'reason' LIKE '%no city inbox%')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_ex) i WHERE i->>'kind' = 'city_list_false_positive:visit-' || t AND i->>'reason' LIKE '%test client%')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_ex) i WHERE i->>'kind' = 'city_list_false_positive:visit-' || u AND i->>'reason' LIKE '%not a live completed visit%')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_ex) i WHERE i->>'kind' = 'city_list_false_positive:visit-' || pre AND i->>'reason' LIKE '%dated before the city email started%') THEN
    RAISE EXCEPTION 'VERIFY V2b: a false-positive reason did not fire (visits % % % % % %): %', x, y, z, t, u, pre, v_ex; END IF;

  -- V3. B and the A negative, by mutation. Visit X: completed DERM job since go-live, city inbox, not grey water, live
  --     manifest, photos sorted, not a test client, whose ONLY real city send is from Admin Review. Hiding that send
  --     makes X a visit that is really waiting. Then: the live list must hold it, A and B must stay quiet while it is
  --     listed, and B must fire when the list leaves it out.
  SELECT min(v.id) INTO x
    FROM public.visits v
    JOIN public.properties p ON p.id = v.property_id
    JOIN public.v_visit_photo_counts pc ON pc.visit_id = v.id AND pc.total_images > 0 AND pc.classified_images >= pc.total_images
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date >= '2026-09-15' AND v.derm_required IS TRUE
     AND NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture'])
     AND EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0)
     AND NOT EXISTS (SELECT 1 FROM public.v_visit_not_for_city g WHERE g.visit_id = v.id)
     AND EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL WHERE mv.visit_id = v.id)
     AND EXISTS (SELECT 1 FROM public.visit_photo_email_sends s WHERE s.visit_id = v.id AND s.status = 'sent' AND NOT coalesce(s.is_test, false))
     AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_email_sends d ON d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
                      WHERE mv.visit_id = v.id AND d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false));
  IF x IS NULL THEN RAISE EXCEPTION 'VERIFY V3: no Admin-Review-only sent visit to build the B control from'; END IF;
  v_ids := v_ids || jsonb_build_object('B', x);
  BEGIN
    UPDATE public.visit_photo_email_sends SET is_test = true
     WHERE visit_id = x AND status = 'sent' AND NOT coalesce(is_test, false);
    v_list := public.fn_admin_review_pending() -> 'city';
    ok1 := EXISTS (SELECT 1 FROM jsonb_array_elements(v_list) e WHERE (e->>'visit_id')::bigint = x);
    ok2 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items(v_list)) i
                        WHERE i->>'kind' IN ('city_list_missed:visit-' || x, 'city_list_false_positive:visit-' || x));
    ok3 := EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items(
                     (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(v_list) e WHERE (e->>'visit_id')::bigint <> x))) i
                    WHERE i->>'kind' = 'city_list_missed:visit-' || x);
    ok4 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items(jsonb_build_array(jsonb_build_object('visit_id', x)))) i
                        WHERE i->>'kind' = 'city_list_false_positive:visit-' || x);
    -- each B condition broken on X, one at a time (each rolled back): B must go quiet on an empty list
    FOREACH fn IN ARRAY ARRAY['no manifest', 'a photo not sorted', 'a test client', 'no city inbox'] LOOP
      BEGIN
        CASE fn
          WHEN 'no manifest' THEN DELETE FROM public.manifest_visits WHERE visit_id = x;
          WHEN 'a photo not sorted' THEN
            DELETE FROM public.photo_classifications c
             WHERE c.id = (SELECT min(c2.id) FROM public.photo_classifications c2
                             JOIN public.photo_links l2 ON l2.id = c2.photo_link_id AND l2.deleted_at IS NULL
                             JOIN public.photos ph ON ph.id = l2.photo_id AND ph.content_type LIKE 'image/%'
                            WHERE l2.entity_type = 'visit' AND l2.entity_id = x);
          WHEN 'a test client' THEN
            INSERT INTO public.non_customer_clients (client_id, kind, reason)
            SELECT v.client_id, 'test', 'VERIFY fixture of 2026-10-12_1400, rolled back' FROM public.visits v WHERE v.id = x;
          WHEN 'no city inbox' THEN
            UPDATE public.properties p SET city_emails = '{}'::text[] FROM public.visits v WHERE v.id = x AND p.id = v.property_id;
        END CASE;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i WHERE i->>'kind' = 'city_list_missed:visit-' || x) THEN
          b_bad := coalesce(b_bad || ', ', '') || fn; END IF;
        RAISE EXCEPTION USING ERRCODE = 'NH010', MESSAGE = 'roll back one broken B condition';
      EXCEPTION WHEN SQLSTATE 'NH010' THEN NULL;
      END;
    END LOOP;
    RAISE EXCEPTION USING ERRCODE = 'NH001', MESSAGE = 'roll back the B control';
  EXCEPTION WHEN SQLSTATE 'NH001' THEN NULL;
  END;
  IF NOT ok1 THEN RAISE EXCEPTION 'VERIFY V3: fn_admin_review_pending does not list waiting visit % (the list and the raw tables disagree)', x; END IF;
  IF NOT ok2 THEN RAISE EXCEPTION 'VERIFY V3: an item fired for waiting visit % although it is listed', x; END IF;
  IF NOT ok3 THEN RAISE EXCEPTION 'VERIFY V3: city_list_missed did not fire for waiting visit % left off the list', x; END IF;
  IF NOT ok4 THEN RAISE EXCEPTION 'VERIFY V3: city_list_false_positive fired for waiting visit %', x; END IF;
  IF b_bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY V3: city_list_missed still fired for visit % with %', x, b_bad; END IF;
  -- grey water: a grey-water visit meeting every other B condition (its property given an inbox if it has none) must
  -- not be reported. Data-dependent: picked at run time, vacuous (a NOTICE) when no such visit exists.
  SELECT min(v.id) INTO g
    FROM public.visits v
    JOIN public.v_visit_not_for_city gw ON gw.visit_id = v.id
    JOIN public.v_visit_photo_counts pc ON pc.visit_id = v.id AND pc.total_images > 0 AND pc.classified_images >= pc.total_images
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date >= '2026-09-15' AND v.derm_required IS TRUE
     AND v.property_id IS NOT NULL AND NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture'])
     AND EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL WHERE mv.visit_id = v.id)
     AND NOT EXISTS (SELECT 1 FROM public.visit_photo_email_sends s WHERE s.visit_id = v.id AND s.status = 'sent' AND NOT coalesce(s.is_test, false))
     AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_email_sends d ON d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
                      WHERE mv.visit_id = v.id AND d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false));
  IF g IS NULL THEN
    RAISE NOTICE 'VERIFY V3: no grey-water visit to build the grey-water B control from, it is vacuous today';
  ELSE
    v_ids := v_ids || jsonb_build_object('B_grey_water', g);
    BEGIN
      UPDATE public.properties p SET city_emails = ARRAY['verify-fixture@example.invalid']
        FROM public.visits v WHERE v.id = g AND p.id = v.property_id
         AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0);
      ok5 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i WHERE i->>'kind' = 'city_list_missed:visit-' || g);
      RAISE EXCEPTION USING ERRCODE = 'NH011', MESSAGE = 'roll back the grey-water control';
    EXCEPTION WHEN SQLSTATE 'NH011' THEN NULL;
    END;
    IF NOT ok5 THEN RAISE EXCEPTION 'VERIFY V3: grey-water visit % was reported as missed', g; END IF;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.visit_photo_email_sends WHERE visit_id = x AND status = 'sent' AND NOT coalesce(is_test, false)) THEN
    RAISE EXCEPTION 'VERIFY V3: the B control did not roll back for visit %', x; END IF;

  -- V3p. B population control: every city_list_missed item, for the live list and for an empty list, re-derived from
  --      the raw tables (live completed DERM job since Sep 15, city inbox, not a test client, not grey water, live
  --      manifest, photos sorted, no real send in either log, not on the list).
  IF EXISTS (
       SELECT 1 FROM (SELECT i, false AS on_empty FROM jsonb_array_elements(v_today) i
                      UNION ALL SELECT i, true FROM jsonb_array_elements(v_empty) i) q
       LEFT JOIN public.visits v ON v.id = (q.i->>'visit')::bigint
       LEFT JOIN public.properties p ON p.id = v.property_id
       LEFT JOIN public.v_visit_photo_counts pc ON pc.visit_id = v.id
       WHERE q.i->>'issue' = 'city_list_missed'
         AND NOT coalesce(
               v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date >= '2026-09-15' AND v.derm_required IS TRUE
               AND NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture'])
               AND EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0)
               AND NOT EXISTS (SELECT 1 FROM public.v_visit_not_for_city g WHERE g.visit_id = v.id)
               AND EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL WHERE mv.visit_id = v.id)
               AND pc.total_images > 0 AND pc.classified_images >= pc.total_images
               AND NOT EXISTS (SELECT 1 FROM public.visit_photo_email_sends s WHERE s.visit_id = v.id AND s.status = 'sent' AND NOT coalesce(s.is_test, false))
               AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv
                                 JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL
                                 JOIN public.derm_email_sends d ON d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
                                WHERE mv.visit_id = v.id AND d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false)
                                  AND coalesce(d.reason, '') NOT LIKE 'attachment:manifest_images%')
               AND (q.on_empty OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_admin_review_pending() -> 'city') e
                                               WHERE (e->>'visit_id')::bigint = v.id)), false)) THEN
    RAISE EXCEPTION 'VERIFY V3p: a city_list_missed item fails the raw rule'; END IF;

  -- V3b. A DERM Tracker letter that went with NOTHING attached (reason 'attachment:manifest_images:...') is not the
  --      city having the manifest, and neither is a CLIENT copy. Visit W: its only real city send is a DERM Tracker one.
  --      Relabelled either way, W must not read as sent (A quiet on a list holding it, B fires on an empty list).
  SELECT min(v.id) INTO w
    FROM public.visits v
    JOIN public.properties p ON p.id = v.property_id
    JOIN public.v_visit_photo_counts pc ON pc.visit_id = v.id AND pc.total_images > 0 AND pc.classified_images >= pc.total_images
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date >= '2026-09-15' AND v.derm_required IS TRUE
     AND NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture'])
     AND EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0)
     AND NOT EXISTS (SELECT 1 FROM public.v_visit_not_for_city g WHERE g.visit_id = v.id)
     AND NOT EXISTS (SELECT 1 FROM public.visit_photo_email_sends s WHERE s.visit_id = v.id AND s.status = 'sent' AND NOT coalesce(s.is_test, false))
     AND EXISTS (SELECT 1 FROM public.manifest_visits mv
                   JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL
                   JOIN public.derm_email_sends d ON d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
                  WHERE mv.visit_id = v.id AND d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false));
  IF w IS NULL THEN RAISE EXCEPTION 'VERIFY V3b: no DERM-Tracker-only sent visit to build the empty-letter control from'; END IF;
  v_ids := v_ids || jsonb_build_object('empty_letter_and_client_copy', w);
  ok1 := EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items(jsonb_build_array(jsonb_build_object('visit_id', w)))) i
                  WHERE i->>'kind' = 'city_list_false_positive:visit-' || w AND i->>'reason' LIKE '%already went to the city%');
  BEGIN
    UPDATE public.derm_email_sends d SET reason = 'attachment:manifest_images:verify_fixture'
      FROM public.manifest_visits mv JOIN public.visits v ON v.id = mv.visit_id
     WHERE mv.visit_id = w AND d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
       AND d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false);
    ok2 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items(jsonb_build_array(jsonb_build_object('visit_id', w)))) i
                        WHERE i->>'kind' = 'city_list_false_positive:visit-' || w);
    ok3 := EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i
                    WHERE i->>'kind' = 'city_list_missed:visit-' || w);
    RAISE EXCEPTION USING ERRCODE = 'NH005', MESSAGE = 'roll back the empty-letter control';
  EXCEPTION WHEN SQLSTATE 'NH005' THEN NULL;
  END;
  BEGIN
    UPDATE public.derm_email_sends d SET recipient_type = 'client'
      FROM public.manifest_visits mv JOIN public.visits v ON v.id = mv.visit_id
     WHERE mv.visit_id = w AND d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
       AND d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false);
    ok4 := EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i
                    WHERE i->>'kind' = 'city_list_missed:visit-' || w);
    RAISE EXCEPTION USING ERRCODE = 'NH006', MESSAGE = 'roll back the client-copy control';
  EXCEPTION WHEN SQLSTATE 'NH006' THEN NULL;
  END;
  IF NOT ok1 THEN RAISE EXCEPTION 'VERIFY V3b: visit % sent from the DERM Tracker was not flagged when listed', w; END IF;
  IF NOT ok2 THEN RAISE EXCEPTION 'VERIFY V3b: visit % read as sent although its only city letter carried nothing', w; END IF;
  IF NOT ok3 THEN RAISE EXCEPTION 'VERIFY V3b: visit % whose only city letter carried nothing was not reported as missed', w; END IF;
  IF NOT ok4 THEN RAISE EXCEPTION 'VERIFY V3b: visit % read as sent by a client copy of the letter', w; END IF;

  -- V3c. A DERM Tracker city send on a SOFT-DELETED manifest is not the city having this visit's manifest (the
  --      city-state rule; counting it would make item A call a waiting visit sent). Visit D: linked to a deleted
  --      manifest and to a live one, no real city send of its own. A fixture city send on the deleted manifest
  --      (rolled back) must not read as sent; the same fixture on its live manifest must (the twin proves the fixture).
  SELECT v.id, v.client_id,
         (SELECT min(mv.manifest_id) FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id
           WHERE mv.visit_id = v.id AND dm.deleted_at IS NOT NULL AND dm.client_id = v.client_id),
         (SELECT min(mv.manifest_id) FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id
           WHERE mv.visit_id = v.id AND dm.deleted_at IS NULL AND dm.client_id = v.client_id)
    INTO d2, c_id, m_del, m_live
    FROM public.visits v
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date >= '2026-09-15'
     AND NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture'])
     AND EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id
                  WHERE mv.visit_id = v.id AND dm.deleted_at IS NOT NULL AND dm.client_id = v.client_id)
     AND EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id
                  WHERE mv.visit_id = v.id AND dm.deleted_at IS NULL AND dm.client_id = v.client_id)
     AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_email_sends d ON d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
                      WHERE mv.visit_id = v.id AND d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false))
   ORDER BY v.id LIMIT 1;
  IF d2 IS NULL THEN RAISE EXCEPTION 'VERIFY V3c: no visit linked to a soft-deleted manifest to build the deleted-manifest control from'; END IF;
  v_ids := v_ids || jsonb_build_object('deleted_manifest', d2);
  BEGIN
    INSERT INTO public.derm_email_sends (manifest_id, client_id, recipient_email, recipient_type, status, is_test, sent_at, reason)
    VALUES (m_del, c_id, 'verify-fixture@example.invalid', 'city', 'sent', false, now() - interval '1 day', 'VERIFY fixture of 2026-10-12_1400, rolled back');
    ok1 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items(jsonb_build_array(jsonb_build_object('visit_id', d2)))) i
                        WHERE i->>'kind' = 'city_list_false_positive:visit-' || d2 AND i->>'reason' LIKE '%already went to the city%');
    INSERT INTO public.derm_email_sends (manifest_id, client_id, recipient_email, recipient_type, status, is_test, sent_at, reason)
    VALUES (m_live, c_id, 'verify-fixture@example.invalid', 'city', 'sent', false, now() - interval '1 day', 'VERIFY fixture of 2026-10-12_1400, rolled back');
    ok2 := EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items(jsonb_build_array(jsonb_build_object('visit_id', d2)))) i
                    WHERE i->>'kind' = 'city_list_false_positive:visit-' || d2 AND i->>'reason' LIKE '%already went to the city%');
    RAISE EXCEPTION USING ERRCODE = 'NH014', MESSAGE = 'roll back the deleted-manifest control';
  EXCEPTION WHEN SQLSTATE 'NH014' THEN NULL;
  END;
  IF NOT ok1 THEN RAISE EXCEPTION 'VERIFY V3c: visit % read as sent by a city send on its soft-deleted manifest %', d2, m_del; END IF;
  IF NOT ok2 THEN RAISE EXCEPTION 'VERIFY V3c: the fixture city send on live manifest % of visit % did not read as sent', m_live, d2; END IF;

  -- V4. C by mutation. Visit Y: a real Admin Review send WITHOUT the manifest since go-live, older than the delay plus
  --     2 days, whose manifest then went from the DERM Tracker. Quiet as it is; with that DERM Tracker send hidden it
  --     must fire, but only once the delay plus 2 days has passed (judged at two moments with p_as_of), and not when
  --     its report went before go-live (app_config city_email_start_from): its sends moved to an hour before it.
  SELECT s.visit_id, max(s.sent_at) INTO y, v_t
    FROM public.visit_photo_email_sends s
    JOIN public.visits v ON v.id = s.visit_id AND v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.derm_required IS NOT FALSE
                         AND v.visit_date >= '2026-09-15'
   WHERE s.status = 'sent' AND NOT coalesce(s.is_test, false) AND s.include_manifest IS FALSE
     AND s.sent_at >= (SELECT value::timestamptz FROM public.app_config WHERE key = 'city_email_start_from')
     AND s.sent_at < now() - (public.fn_city_email_delay() + interval '2 days')
     AND NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture'])
     AND NOT EXISTS (SELECT 1 FROM public.v_visit_not_for_city g WHERE g.visit_id = v.id)
     AND NOT EXISTS (SELECT 1 FROM public.visit_photo_email_sends s2 WHERE s2.visit_id = v.id AND s2.status = 'sent'
                       AND NOT coalesce(s2.is_test, false) AND s2.include_manifest IS TRUE)
     AND EXISTS (SELECT 1 FROM public.manifest_visits mv
                   JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL
                   JOIN public.derm_email_sends d ON d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
                  WHERE mv.visit_id = v.id AND d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false))
   GROUP BY s.visit_id ORDER BY s.visit_id LIMIT 1;
  IF y IS NULL THEN RAISE EXCEPTION 'VERIFY V4: no report-first send to build the C control from'; END IF;
  v_ids := v_ids || jsonb_build_object('C', y);
  BEGIN
    ok1 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_empty) i WHERE i->>'kind' = 'manifest_follow_stalled:visit-' || y);
    UPDATE public.derm_email_sends d SET is_test = true
      FROM public.manifest_visits mv JOIN public.visits v ON v.id = mv.visit_id
     WHERE mv.visit_id = y AND d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
       AND d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false);
    ok2 := EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i
                    WHERE i->>'kind' = 'manifest_follow_stalled:visit-' || y AND i->>'reason' LIKE '%without the manifest%');
    ok3 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]', v_t + public.fn_city_email_delay() + interval '1 day')) i
                        WHERE i->>'kind' = 'manifest_follow_stalled:visit-' || y);
    ok4 := EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]', v_t + public.fn_city_email_delay() + interval '3 days')) i
                    WHERE i->>'kind' = 'manifest_follow_stalled:visit-' || y);
    UPDATE public.visit_photo_email_sends SET sent_at = v_go - interval '1 hour'
     WHERE visit_id = y AND status = 'sent' AND NOT coalesce(is_test, false);
    ok5 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i
                        WHERE i->>'kind' = 'manifest_follow_stalled:visit-' || y);
    RAISE EXCEPTION USING ERRCODE = 'NH002', MESSAGE = 'roll back the C control';
  EXCEPTION WHEN SQLSTATE 'NH002' THEN NULL;
  END;
  IF NOT ok1 THEN RAISE EXCEPTION 'VERIFY V4: manifest_follow_stalled fired for visit % whose manifest did go', y; END IF;
  IF NOT ok2 THEN RAISE EXCEPTION 'VERIFY V4: manifest_follow_stalled did not fire for visit % once its manifest send was hidden', y; END IF;
  IF NOT ok3 THEN RAISE EXCEPTION 'VERIFY V4: manifest_follow_stalled fired for visit % inside the delay plus 2 days', y; END IF;
  IF NOT ok4 THEN RAISE EXCEPTION 'VERIFY V4: manifest_follow_stalled did not fire for visit % after the delay plus 2 days', y; END IF;
  IF NOT ok5 THEN RAISE EXCEPTION 'VERIFY V4: manifest_follow_stalled fired for visit % whose report went before go-live', y; END IF;

  -- V4b. Pre-go-live visits do not count (Fred, 2026-10-12: "we don't care about the old for this"). Visit Z: dated
  --      before Sep 15, a completed DERM job with a city inbox and a live manifest, nothing sent. A fixture Admin
  --      Review send WITHOUT the manifest a day after go-live (rolled back) would make a visit dated since Sep 15 a C
  --      item; Z must stay quiet. With its manifest links removed too (what would be F) it must stay quiet as well.
  SELECT min(v.id) INTO zz
    FROM public.visits v JOIN public.properties p ON p.id = v.property_id
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date < '2026-09-15' AND v.derm_required IS TRUE
     AND NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture'])
     AND EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0)
     AND NOT EXISTS (SELECT 1 FROM public.v_visit_not_for_city g WHERE g.visit_id = v.id)
     AND EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL WHERE mv.visit_id = v.id)
     AND NOT EXISTS (SELECT 1 FROM public.visit_photo_email_sends s WHERE s.visit_id = v.id AND s.status = 'sent' AND NOT coalesce(s.is_test, false))
     AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_email_sends d ON d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
                      WHERE mv.visit_id = v.id AND d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false));
  IF zz IS NULL THEN RAISE EXCEPTION 'VERIFY V4b: no pre-go-live waiting visit to build the pre-go-live control from'; END IF;
  v_ids := v_ids || jsonb_build_object('pre_go_live_C_F', zz);
  BEGIN
    INSERT INTO public.visit_photo_email_sends (visit_id, recipient_email, status, is_test, include_manifest, sent_at, reason)
    VALUES (zz, 'verify-fixture@example.invalid', 'sent', false, false, v_go + interval '1 day', 'VERIFY fixture of 2026-10-12_1400, rolled back');
    ok1 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i WHERE i->>'visit' = zz::text);
    DELETE FROM public.manifest_visits WHERE visit_id = zz;
    ok2 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i WHERE i->>'visit' = zz::text);
    RAISE EXCEPTION USING ERRCODE = 'NH015', MESSAGE = 'roll back the pre-go-live control';
  EXCEPTION WHEN SQLSTATE 'NH015' THEN NULL;
  END;
  IF NOT ok1 THEN RAISE EXCEPTION 'VERIFY V4b: pre-go-live visit % raised an item after a report sent without its manifest', zz; END IF;
  IF NOT ok2 THEN RAISE EXCEPTION 'VERIFY V4b: pre-go-live visit % raised an item with no manifest linked', zz; END IF;

  -- V5. D. Population: every flagged property lacks an inbox, has a completed DERM visit since Sep 15, is not a test
  --     client, and has 3+ inbox neighbours in its city (raw count). Data positive: 1113 (324-BIB, Surfside; visit 8112
  --     never reached the town) while it still has no inbox. Mutation (rolled back): property P that has an inbox and a
  --     DERM visit loses its inbox -> flagged; moved with 1, then 2 inbox neighbours to a new city -> NOT flagged; with a
  --     3rd neighbour -> flagged. That pins the threshold at exactly 3, whatever the live data looks like.
  IF EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_empty) i LEFT JOIN public.properties p ON p.id = (i->>'property')::bigint
        WHERE i->>'issue' = 'city_inbox_missing'
          AND NOT coalesce(
                p.deleted_at IS NULL AND NOT coalesce(p.is_billing, false)
                AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0)
                AND NOT public.fn_is_non_customer(p.client_id, ARRAY['test', 'fixture'])
                AND EXISTS (SELECT 1 FROM public.visits v WHERE v.property_id = p.id AND v.deleted_at IS NULL AND v.visit_status = 'completed'
                              AND v.derm_required IS TRUE AND v.visit_date >= '2026-09-15')
                AND (SELECT count(*) FROM public.properties q
                      WHERE q.deleted_at IS NULL AND NOT coalesce(q.is_billing, false) AND q.id <> p.id
                        AND lower(btrim(q.city)) = lower(btrim(p.city))
                        AND EXISTS (SELECT 1 FROM unnest(coalesce(q.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0)) >= 3, false)) THEN
    RAISE EXCEPTION 'VERIFY V5: a city_inbox_missing item fails the raw rule'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.properties p, unnest(coalesce(p.city_emails, '{}'::text[])) e WHERE p.id = 1113 AND position('@' IN e) > 0)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_today) i WHERE i->>'kind' = 'city_inbox_missing:property-1113') THEN
    RAISE EXCEPTION 'VERIFY V5: property 1113 has no city inbox and was not flagged'; END IF;
  SELECT min(p.id) INTO p_id
    FROM public.properties p
   WHERE p.deleted_at IS NULL AND NOT coalesce(p.is_billing, false)
     AND NOT public.fn_is_non_customer(p.client_id, ARRAY['test', 'fixture'])
     AND EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0)
     AND EXISTS (SELECT 1 FROM public.visits v WHERE v.property_id = p.id AND v.deleted_at IS NULL AND v.visit_status = 'completed'
                   AND v.derm_required IS TRUE AND v.visit_date >= '2026-09-15')
     AND (SELECT count(*) FROM public.properties q
           WHERE q.deleted_at IS NULL AND NOT coalesce(q.is_billing, false) AND q.id <> p.id
             AND lower(btrim(q.city)) = lower(btrim(p.city))
             AND EXISTS (SELECT 1 FROM unnest(coalesce(q.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0)) >= 3;
  SELECT (array_agg(q.id ORDER BY q.id))[1], (array_agg(q.id ORDER BY q.id))[2], (array_agg(q.id ORDER BY q.id))[3]
    INTO q_id, r_id, s_id
    FROM public.properties q
   WHERE q.deleted_at IS NULL AND NOT coalesce(q.is_billing, false) AND q.id <> p_id
     AND EXISTS (SELECT 1 FROM unnest(coalesce(q.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0);
  IF p_id IS NULL OR s_id IS NULL THEN RAISE EXCEPTION 'VERIFY V5: no property to build the D mutation from (% %)', p_id, s_id; END IF;
  v_ids := v_ids || jsonb_build_object('D_property', p_id, 'D_neighbours', jsonb_build_array(q_id, r_id, s_id));
  BEGIN
    UPDATE public.properties SET city_emails = '{}'::text[] WHERE id = p_id;
    ok1 := EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i WHERE i->>'kind' = 'city_inbox_missing:property-' || p_id);
    BEGIN
      INSERT INTO public.non_customer_clients (client_id, kind, reason)
      SELECT p.client_id, 'test', 'VERIFY fixture of 2026-10-12_1400, rolled back' FROM public.properties p WHERE p.id = p_id;
      ok5 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i WHERE i->>'kind' = 'city_inbox_missing:property-' || p_id);
      RAISE EXCEPTION USING ERRCODE = 'NH012', MESSAGE = 'roll back the D test-client control';
    EXCEPTION WHEN SQLSTATE 'NH012' THEN NULL;
    END;
    UPDATE public.properties SET city = 'Verify Town' WHERE id IN (p_id, q_id);
    ok2 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i WHERE i->>'kind' = 'city_inbox_missing:property-' || p_id);
    UPDATE public.properties SET city = 'Verify Town' WHERE id = r_id;
    ok3 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i WHERE i->>'kind' = 'city_inbox_missing:property-' || p_id);
    UPDATE public.properties SET city = ' verify town ' WHERE id = s_id;
    ok4 := EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i
                    WHERE i->>'kind' = 'city_inbox_missing:property-' || p_id AND i->>'reason' LIKE '%while 3 other Verify Town properties%');
    RAISE EXCEPTION USING ERRCODE = 'NH007', MESSAGE = 'roll back the D control';
  EXCEPTION WHEN SQLSTATE 'NH007' THEN NULL;
  END;
  IF NOT ok1 THEN RAISE EXCEPTION 'VERIFY V5: property % with a DERM visit lost its inbox and was not flagged', p_id; END IF;
  IF NOT ok5 THEN RAISE EXCEPTION 'VERIFY V5: property % of a test client was flagged', p_id; END IF;
  IF NOT ok2 THEN RAISE EXCEPTION 'VERIFY V5: property % was flagged with only 1 inbox neighbour', p_id; END IF;
  IF NOT ok3 THEN RAISE EXCEPTION 'VERIFY V5: property % was flagged with only 2 inbox neighbours', p_id; END IF;
  IF NOT ok4 THEN RAISE EXCEPTION 'VERIFY V5: property % was not flagged with 3 inbox neighbours (city names compared trimmed, any case)', p_id; END IF;
  IF EXISTS (SELECT 1 FROM public.properties WHERE lower(btrim(city)) = 'verify town') THEN
    RAISE EXCEPTION 'VERIFY V5: the D control did not roll back'; END IF;
  -- D counts only DERM visits since Sep 15 (pre-go-live visits do not count): property Q, whose completed DERM visits
  -- are ALL dated before Sep 15, in a city with 3+ other inbox properties, loses its inbox (rolled back) -> NOT flagged.
  SELECT min(p.id) INTO dp
    FROM public.properties p
   WHERE p.deleted_at IS NULL AND NOT coalesce(p.is_billing, false)
     AND NOT public.fn_is_non_customer(p.client_id, ARRAY['test', 'fixture'])
     AND EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0)
     AND EXISTS (SELECT 1 FROM public.visits v WHERE v.property_id = p.id AND v.deleted_at IS NULL AND v.visit_status = 'completed'
                   AND v.derm_required IS TRUE AND v.visit_date < '2026-09-15')
     AND NOT EXISTS (SELECT 1 FROM public.visits v WHERE v.property_id = p.id AND v.deleted_at IS NULL AND v.visit_status = 'completed'
                       AND v.derm_required IS TRUE AND v.visit_date >= '2026-09-15')
     AND (SELECT count(*) FROM public.properties q
           WHERE q.deleted_at IS NULL AND NOT coalesce(q.is_billing, false) AND q.id <> p.id
             AND lower(btrim(q.city)) = lower(btrim(p.city))
             AND EXISTS (SELECT 1 FROM unnest(coalesce(q.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0)) >= 3;
  IF dp IS NULL THEN RAISE EXCEPTION 'VERIFY V5: no property with only pre-go-live DERM visits to build the D pre-go-live control from'; END IF;
  v_ids := v_ids || jsonb_build_object('D_pre_go_live', dp);
  BEGIN
    UPDATE public.properties SET city_emails = '{}'::text[] WHERE id = dp;
    ok1 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i WHERE i->>'kind' = 'city_inbox_missing:property-' || dp);
    RAISE EXCEPTION USING ERRCODE = 'NH016', MESSAGE = 'roll back the D pre-go-live control';
  EXCEPTION WHEN SQLSTATE 'NH016' THEN NULL;
  END;
  IF NOT ok1 THEN RAISE EXCEPTION 'VERIFY V5: property % was flagged although its DERM visits are all from before Sep 15', dp; END IF;

  -- V6. E by mutation: every reminder row (real and [TEST]) is moved aside, then fixtures decide. Silent with no row;
  --     a 27-hour-old real run fires reminder_not_run; a fresh [TEST] row (details.test, or the '_test' source even
  --     without that flag) does not clear it; a 25-hour-old real run does (the gap between two 11 AM runs is 23 to 25
  --     hours over DST, and 11:00 to the next 09:15 check is 22 h, so the 26-hour threshold sits between 25 and 27);
  --     a latest real 'error' fires reminder_failed with its message; a later 'success' clears it.
  BEGIN
    UPDATE public.sync_log SET sync_source = sync_source || ':verify-hidden'
     WHERE sync_source IN ('admin_review_reminder', 'stamp_sheets_reminder', 'admin_review_reminder_test', 'stamp_sheets_reminder_test');
    ok1 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i WHERE i->>'issue' IN ('reminder_not_run', 'reminder_failed'));
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, status, details)
    VALUES ('admin_review_reminder', now() - interval '27 hours', now() - interval '27 hours', 'success', '{"verify_fixture": true, "test": false}'),
           ('stamp_sheets_reminder', now() - interval '27 hours', now() - interval '27 hours', 'success', '{"verify_fixture": true, "test": false}');
    ok2 := (SELECT count(*) = 2 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i
             WHERE i->>'kind' IN ('reminder_not_run:admin_review_reminder', 'reminder_not_run:stamp_sheets_reminder'));
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, status, details)
    VALUES ('admin_review_reminder', now() - interval '1 hour', now() - interval '1 hour', 'success', '{"verify_fixture": true, "test": true}'),
           ('admin_review_reminder_test', now() - interval '1 hour', now() - interval '1 hour', 'success', '{"verify_fixture": true}');
    ok3 := EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i WHERE i->>'kind' = 'reminder_not_run:admin_review_reminder');
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, status, details)
    VALUES ('admin_review_reminder', now() - interval '25 hours', now() - interval '25 hours', 'success', '{"verify_fixture": true, "test": false}');
    ok4 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i WHERE i->>'kind' IN ('reminder_not_run:admin_review_reminder', 'reminder_failed:admin_review_reminder'));
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, status, error_details, details)
    VALUES ('admin_review_reminder', now() - interval '2 hours', now() - interval '2 hours', 'error',
            '{"message": "verify fixture: Slack refused the post"}', '{"verify_fixture": true, "test": false}');
    ok5 := EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i
                    WHERE i->>'kind' = 'reminder_failed:admin_review_reminder' AND i->>'reason' LIKE '%Slack refused the post%')
           AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i WHERE i->>'kind' = 'reminder_not_run:admin_review_reminder');
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, status, details)
    VALUES ('admin_review_reminder', now() - interval '1 hour', now() - interval '1 hour', 'success', '{"verify_fixture": true, "test": false}');
    ok6 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i WHERE i->>'kind' = 'reminder_failed:admin_review_reminder');
    RAISE EXCEPTION USING ERRCODE = 'NH003', MESSAGE = 'roll back the E control';
  EXCEPTION WHEN SQLSTATE 'NH003' THEN NULL;
  END;
  IF NOT ok1 THEN RAISE EXCEPTION 'VERIFY V6: a reminder item fired before any reminder row exists'; END IF;
  IF NOT ok2 THEN RAISE EXCEPTION 'VERIFY V6: reminder_not_run did not fire for both reminders on a 27-hour-old last run'; END IF;
  IF NOT ok3 THEN RAISE EXCEPTION 'VERIFY V6: a [TEST] run row counted as a real run'; END IF;
  IF NOT ok4 THEN RAISE EXCEPTION 'VERIFY V6: reminder_not_run did not clear on a 25-hour-old real run'; END IF;
  IF NOT ok5 THEN RAISE EXCEPTION 'VERIFY V6: reminder_failed did not fire on a latest real error run (or not_run fired on it)'; END IF;
  IF NOT ok6 THEN RAISE EXCEPTION 'VERIFY V6: reminder_failed did not clear after a later success'; END IF;
  IF EXISTS (SELECT 1 FROM public.sync_log WHERE details ? 'verify_fixture' OR sync_source LIKE '%:verify-hidden') THEN
    RAISE EXCEPTION 'VERIFY V6: the E control did not roll back'; END IF;

  -- V7. F. Population: every no_manifest_after_14_days item re-derived from the raw tables. Mutation (rolled back):
  --     visit X (an old DERM job with an inbox and a live manifest, preferring the Admin-Review-first case) loses its
  --     manifest links -> F fires, C does not; judged 14 days after the visit F is quiet, 15 days after it fires. Visit Y, whose city got the
  --     manifest from Admin Review, loses its links -> F stays quiet (the city has it).
  IF EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_empty) i
       LEFT JOIN public.visits v ON v.id = (i->>'visit')::bigint
       LEFT JOIN public.properties p ON p.id = v.property_id
       WHERE i->>'issue' = 'no_manifest_after_14_days'
         AND NOT coalesce(
               v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date >= '2026-09-15' AND v.derm_required IS TRUE
               AND v.visit_date < (now() AT TIME ZONE 'America/New_York')::date - 14
               AND NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture'])
               AND EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0)
               AND NOT EXISTS (SELECT 1 FROM public.v_visit_not_for_city g WHERE g.visit_id = v.id)
               AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL WHERE mv.visit_id = v.id)
               AND NOT EXISTS (SELECT 1 FROM public.visit_photo_email_sends s WHERE s.visit_id = v.id AND s.status = 'sent'
                                 AND NOT coalesce(s.is_test, false) AND s.include_manifest IS TRUE), false)) THEN
    RAISE EXCEPTION 'VERIFY V7: a no_manifest_after_14_days item fails the raw rule'; END IF;
  SELECT v.id, v.visit_date INTO x, v_d
    FROM public.visits v JOIN public.properties p ON p.id = v.property_id
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date >= '2026-09-15' AND v.derm_required IS TRUE
     AND v.visit_date < (now() AT TIME ZONE 'America/New_York')::date - 14
     AND NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture'])
     AND EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0)
     AND NOT EXISTS (SELECT 1 FROM public.v_visit_not_for_city g WHERE g.visit_id = v.id)
     AND EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL WHERE mv.visit_id = v.id)
     AND NOT EXISTS (SELECT 1 FROM public.visit_photo_email_sends s WHERE s.visit_id = v.id AND s.status = 'sent'
                       AND NOT coalesce(s.is_test, false) AND s.include_manifest IS TRUE)
   ORDER BY EXISTS (SELECT 1 FROM public.visit_photo_email_sends s WHERE s.visit_id = v.id AND s.status = 'sent'
                      AND NOT coalesce(s.is_test, false) AND s.include_manifest IS NOT TRUE) DESC, v.id
   LIMIT 1;
  SELECT min(v.id) INTO y
    FROM public.visits v JOIN public.properties p ON p.id = v.property_id
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date >= '2026-09-15' AND v.derm_required IS TRUE
     AND v.visit_date < (now() AT TIME ZONE 'America/New_York')::date - 14
     AND NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture'])
     AND EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0)
     AND NOT EXISTS (SELECT 1 FROM public.v_visit_not_for_city g WHERE g.visit_id = v.id)
     AND EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.visit_id = v.id)
     AND EXISTS (SELECT 1 FROM public.visit_photo_email_sends s WHERE s.visit_id = v.id AND s.status = 'sent'
                   AND NOT coalesce(s.is_test, false) AND s.include_manifest IS TRUE);
  IF x IS NULL OR y IS NULL THEN RAISE EXCEPTION 'VERIFY V7: no visit to build the F control from (% %)', x, y; END IF;
  v_ids := v_ids || jsonb_build_object('F', x, 'F_negative', y);
  ok4 := EXISTS (SELECT 1 FROM public.visit_photo_email_sends s WHERE s.visit_id = x AND s.status = 'sent'
                   AND NOT coalesce(s.is_test, false) AND s.include_manifest IS NOT TRUE);
  BEGIN
    DELETE FROM public.manifest_visits WHERE visit_id IN (x, y);
    v_list := public.fn_notification_health_items('[]');
    ok1 := EXISTS (SELECT 1 FROM jsonb_array_elements(v_list) i WHERE i->>'kind' = 'no_manifest_after_14_days:visit-' || x
                     AND (NOT ok4 OR i->>'reason' LIKE '%Admin Review sent the city report without the manifest%'))
           AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_list) i WHERE i->>'kind' = 'manifest_follow_stalled:visit-' || x);
    ok2 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]', ((v_d + 14)::timestamp + interval '9 hours') AT TIME ZONE 'America/New_York')) i
                        WHERE i->>'kind' = 'no_manifest_after_14_days:visit-' || x);
    ok6 := EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]', ((v_d + 15)::timestamp + interval '9 hours') AT TIME ZONE 'America/New_York')) i
                    WHERE i->>'kind' = 'no_manifest_after_14_days:visit-' || x);
    ok3 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_list) i WHERE i->>'kind' = 'no_manifest_after_14_days:visit-' || y);
    BEGIN
      INSERT INTO public.non_customer_clients (client_id, kind, reason)
      SELECT v.client_id, 'test', 'VERIFY fixture of 2026-10-12_1400, rolled back' FROM public.visits v WHERE v.id = x;
      ok5 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]')) i WHERE i->>'kind' = 'no_manifest_after_14_days:visit-' || x);
      RAISE EXCEPTION USING ERRCODE = 'NH013', MESSAGE = 'roll back the F test-client control';
    EXCEPTION WHEN SQLSTATE 'NH013' THEN NULL;
    END;
    RAISE EXCEPTION USING ERRCODE = 'NH008', MESSAGE = 'roll back the F control';
  EXCEPTION WHEN SQLSTATE 'NH008' THEN NULL;
  END;
  IF NOT ok1 THEN RAISE EXCEPTION 'VERIFY V7: visit % without a manifest after 14 days was not reported as F only', x; END IF;
  IF NOT ok2 THEN RAISE EXCEPTION 'VERIFY V7: visit % was reported as F only 14 days after the visit', x; END IF;
  IF NOT ok6 THEN RAISE EXCEPTION 'VERIFY V7: visit % was not reported as F 15 days after the visit', x; END IF;
  IF NOT ok3 THEN RAISE EXCEPTION 'VERIFY V7: visit % whose city got the manifest from Admin Review was reported as F', y; END IF;
  IF NOT ok5 THEN RAISE EXCEPTION 'VERIFY V7: visit % of a test client was reported as F', x; END IF;
  IF (SELECT count(*) FROM public.manifest_visits WHERE visit_id IN (x, y)) = 0 THEN
    RAISE EXCEPTION 'VERIFY V7: the F control did not roll back'; END IF;

  -- V8. G. History control: 6138 got its manifest twice (DERM Tracker Sep 25, Admin Review Oct 8) and 6247 three times
  --     (DERM Tracker twice on Sep 25, Admin Review Oct 8). Judged on Oct 12 both fire; on Oct 16 (8 days after the
  --     last send) neither; on Sep 28 only 6247 (its two Sep 25 sends; 6138 had one). Population: every G item has 2+
  --     real manifest-carrying city sends, the last within 7 days, and is not a test client.
  v_list := public.fn_notification_health_items('[]', timestamptz '2026-10-12 17:00+00');
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_list) i WHERE i->>'kind' = 'city_email_duplicate:visit-6138' AND i->>'reason' LIKE '%2 times%Admin Review%')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_list) i WHERE i->>'kind' = 'city_email_duplicate:visit-6247' AND i->>'reason' LIKE '%3 times%DERM Tracker%DERM Tracker%Admin Review%') THEN
    RAISE EXCEPTION 'VERIFY V8: the repeat city emails of 6138 and 6247 were not reported on Oct 12'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]', timestamptz '2026-10-16 17:00+00')) i
              WHERE i->>'kind' IN ('city_email_duplicate:visit-6138', 'city_email_duplicate:visit-6247')) THEN
    RAISE EXCEPTION 'VERIFY V8: a repeat city email was still reported more than 7 days after the last send'; END IF;
  v_list := public.fn_notification_health_items('[]', timestamptz '2026-09-28 17:00+00');
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_list) i WHERE i->>'kind' = 'city_email_duplicate:visit-6247' AND i->>'reason' LIKE '%2 times%')
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_list) i WHERE i->>'kind' = 'city_email_duplicate:visit-6138') THEN
    RAISE EXCEPTION 'VERIFY V8: judged on Sep 28, the repeat sends were not read as of that day'; END IF;
  IF EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_empty) i LEFT JOIN public.visits v ON v.id = (i->>'visit')::bigint
        WHERE i->>'issue' = 'city_email_duplicate'
          AND NOT coalesce(NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture'])
                AND (SELECT count(*) >= 2 AND max(m.at) > now() - interval '7 days' FROM (
                       SELECT s.sent_at AS at FROM public.visit_photo_email_sends s
                        WHERE s.visit_id = v.id AND s.status = 'sent' AND NOT coalesce(s.is_test, false) AND s.include_manifest IS TRUE
                       UNION ALL
                       SELECT d.sent_at FROM public.manifest_visits mv
                         JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL
                         JOIN public.derm_email_sends d ON d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
                        WHERE mv.visit_id = v.id AND d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false)
                          AND coalesce(d.reason, '') NOT LIKE 'attachment:manifest_images%') m), false)) THEN
    RAISE EXCEPTION 'VERIFY V8: a city_email_duplicate item fails the raw rule'; END IF;
  -- V8b. G leaves out test clients and pre-go-live visits (rolled back). 6138's client made a test client -> no item on
  --      Oct 12. Two fixture Admin Review sends WITH the manifest (1 and 2 days ago) on a visit dated before Sep 15 ->
  --      no item; the same two on a visit dated since Sep 15 -> an item (the twin proves the fixture).
  SELECT min(v.id) INTO pg FROM public.visits v
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date < '2026-09-15'
     AND NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture'])
     AND NOT EXISTS (SELECT 1 FROM public.visit_photo_email_sends s WHERE s.visit_id = v.id AND s.status = 'sent' AND NOT coalesce(s.is_test, false))
     AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_email_sends d ON d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
                      WHERE mv.visit_id = v.id AND d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false));
  SELECT min(v.id) INTO po FROM public.visits v
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date >= '2026-09-15'
     AND NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture'])
     AND NOT EXISTS (SELECT 1 FROM public.visit_photo_email_sends s WHERE s.visit_id = v.id AND s.status = 'sent' AND NOT coalesce(s.is_test, false))
     AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_email_sends d ON d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
                      WHERE mv.visit_id = v.id AND d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false));
  IF pg IS NULL OR po IS NULL THEN RAISE EXCEPTION 'VERIFY V8b: no unsent visit to build the G fixture from (% %)', pg, po; END IF;
  v_ids := v_ids || jsonb_build_object('G_pre_go_live', pg, 'G_twin', po);
  BEGIN
    INSERT INTO public.non_customer_clients (client_id, kind, reason)
    SELECT v.client_id, 'test', 'VERIFY fixture of 2026-10-12_1400, rolled back' FROM public.visits v WHERE v.id = 6138;
    ok1 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_notification_health_items('[]', timestamptz '2026-10-12 17:00+00')) i
                        WHERE i->>'kind' = 'city_email_duplicate:visit-6138');
    RAISE EXCEPTION USING ERRCODE = 'NH017', MESSAGE = 'roll back the G test-client control';
  EXCEPTION WHEN SQLSTATE 'NH017' THEN NULL;
  END;
  BEGIN
    INSERT INTO public.visit_photo_email_sends (visit_id, recipient_email, status, is_test, include_manifest, sent_at, reason)
    SELECT f.id, 'verify-fixture@example.invalid', 'sent', false, true, now() - f2.ago, 'VERIFY fixture of 2026-10-12_1400, rolled back'
      FROM unnest(ARRAY[pg, po]) f(id) CROSS JOIN unnest(ARRAY[interval '1 day', interval '2 days']) f2(ago);
    v_list := public.fn_notification_health_items('[]');
    ok2 := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_list) i WHERE i->>'kind' = 'city_email_duplicate:visit-' || pg);
    ok3 := EXISTS (SELECT 1 FROM jsonb_array_elements(v_list) i WHERE i->>'kind' = 'city_email_duplicate:visit-' || po AND i->>'reason' LIKE '%2 times%');
    RAISE EXCEPTION USING ERRCODE = 'NH018', MESSAGE = 'roll back the G pre-go-live control';
  EXCEPTION WHEN SQLSTATE 'NH018' THEN NULL;
  END;
  IF NOT ok1 THEN RAISE EXCEPTION 'VERIFY V8b: the repeat sends of 6138 were reported although its client is a test client'; END IF;
  IF NOT ok2 THEN RAISE EXCEPTION 'VERIFY V8b: repeat sends of pre-go-live visit % were reported', pg; END IF;
  IF NOT ok3 THEN RAISE EXCEPTION 'VERIFY V8b: the fixture repeat sends of visit % (dated since Sep 15) were not reported', po; END IF;

  IF EXISTS (SELECT 1 FROM public.non_customer_clients WHERE reason LIKE 'VERIFY fixture of 2026-10-12_1400%')
     OR EXISTS (SELECT 1 FROM public.properties WHERE 'verify-fixture@example.invalid' = ANY (city_emails))
     OR EXISTS (SELECT 1 FROM public.visit_photo_email_sends WHERE recipient_email = 'verify-fixture@example.invalid')
     OR EXISTS (SELECT 1 FROM public.derm_email_sends WHERE recipient_email = 'verify-fixture@example.invalid') THEN
    RAISE EXCEPTION 'VERIFY: a test-client, inbox or send-log fixture did not roll back'; END IF;

  -- V9. Shape of every item produced above: the fields health-escalate prints, a key the health scan can upsert
  --     (no "visit_id" or "dump_folder" field, which ops.v_health_items would take as the key; no repeated key in one
  --     run), the visit or property named in the text, plain text with no em or en dash.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_all) i
              WHERE coalesce(i->>'kind', '') = '' OR coalesce(i->>'issue', '') = '' OR coalesce(i->>'reason', '') = ''
                 OR coalesce(i->>'what_to_do', '') = '' OR i ? 'visit_id' OR i ? 'dump_folder'
                 OR (i ? 'visit' AND position('Visit ' || (i->>'visit') IN i->>'reason') = 0)
                 OR (NOT i ? 'visit' AND i ? 'property' AND position('Property ' || (i->>'property') IN i->>'reason') = 0)
                 OR position(chr(8212) IN i::text) > 0 OR position(chr(8211) IN i::text) > 0) THEN
    RAISE EXCEPTION 'VERIFY V9: an item is missing a field, carries a key-hijacking field, does not name its visit or property, or has a dash: %', v_all; END IF;
  FOREACH v_list IN ARRAY ARRAY[v_today, v_empty, v_hist, v_ex] LOOP
    IF (SELECT count(*) <> count(DISTINCT i->>'kind') FROM jsonb_array_elements(v_list) i) THEN
      RAISE EXCEPTION 'VERIFY V9: a key repeats within one run: %', v_list; END IF;
  END LOOP;

  -- V10. The cron entry point. First, broken lists (rolled back): a missing "city", an object, a number, a string, an
  --      entry without visit_id, a text visit_id. Each must still write exactly ONE row, status 'error', carrying only
  --      notification_check_failed, so a broken check escalates instead of reading as healthy.
  BEGIN
    FOREACH fn IN ARRAY ARRAY['{"photos":{}}', '{"city":{"a":1}}', '{"city":5}', '{"city":"x"}', '{"city":[{"id":1}]}', '{"city":[{"visit_id":"8575"}]}'] LOOP
      n := (SELECT count(*) FROM public.sync_log WHERE sync_source = 'notification-health');
      BEGIN
        PERFORM public.log_notification_health(fn::jsonb);
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'VERIFY V10: log_notification_health raised on the broken list % instead of logging it: %', fn, SQLERRM;
      END;
      IF (SELECT count(*) FROM public.sync_log WHERE sync_source = 'notification-health') <> n + 1
         OR NOT EXISTS (SELECT 1 FROM public.sync_log l
                         WHERE l.sync_source = 'notification-health'
                           AND l.started_at = (SELECT max(started_at) FROM public.sync_log WHERE sync_source = 'notification-health')
                           AND l.status = 'error' AND l.rows_errored = 1 AND jsonb_array_length(l.details->'items') = 1
                           AND l.details->'items'->0->>'kind' = 'notification_check_failed'
                           AND l.details->'city_list_count' = 'null'::jsonb
                           AND coalesce(l.error_details->>'message', '') <> '') THEN
        RAISE EXCEPTION 'VERIFY V10: a broken list % did not write one notification_check_failed row', fn; END IF;
    END LOOP;
    RAISE EXCEPTION USING ERRCODE = 'NH009', MESSAGE = 'roll back the broken-list runs';
  EXCEPTION WHEN SQLSTATE 'NH009' THEN NULL;
  END;
  -- then the real run, which this migration keeps: one row whose verdict matches its items, the check did not fail
  n := public.log_notification_health();
  IF NOT EXISTS (SELECT 1 FROM public.sync_log l
                  WHERE l.sync_source = 'notification-health'
                    AND l.started_at = (SELECT max(started_at) FROM public.sync_log WHERE sync_source = 'notification-health')
                    AND jsonb_array_length(l.details->'items') = n AND l.rows_errored = n
                    AND l.status = CASE WHEN n > 0 THEN 'attention' ELSE 'ok' END
                    AND (l.details->>'city_list_count')::int = jsonb_array_length(public.fn_admin_review_pending() -> 'city')
                    AND NOT l.details->'items' @> '[{"issue":"notification_check_failed"}]') THEN
    RAISE EXCEPTION 'VERIFY V10: log_notification_health wrote no matching row, or the check failed'; END IF;

  RAISE NOTICE 'VERIFY functions ok: today % item(s) %; control rows picked %',
    jsonb_array_length(v_today), (SELECT jsonb_agg(i->>'kind') FROM jsonb_array_elements(v_today) i), v_ids;
END
$verify$;

-- 3. Schedule -------------------------------------------------------------------
SELECT cron.schedule('notification-health', '15 13 * * *', 'select public.log_notification_health()');
DO $cron$
BEGIN
  IF (SELECT count(*) FROM cron.job WHERE jobname = 'notification-health') <> 1
     OR NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'notification-health' AND schedule = '15 13 * * *'
                      AND command = 'select public.log_notification_health()' AND active) THEN
    RAISE EXCEPTION 'VERIFY: cron job notification-health missing or wrong';
  END IF;
END
$cron$;

-- Snapshot of every other check, compared after the views are replaced
CREATE TEMP TABLE nh_before_items ON COMMIT DROP AS SELECT check_name, item_key FROM ops.v_health_items;
CREATE TEMP TABLE nh_before_status ON COMMIT DROP AS SELECT check_name, status, item_count, new_items FROM ops.v_health_status;

-- Pin again: from the snapshot on, this transaction holds ACCESS SHARE on both views, so nobody can change them
DO $pin2$
BEGIN
  IF md5(pg_get_viewdef('ops.v_health_items'::regclass, true)) <> '4baa8428a4cd9f06d9ec0b3e12dce4b3' THEN
    RAISE EXCEPTION 'ops.v_health_items changed since this migration was written; rebuild it from the live text';
  END IF;
  IF md5(pg_get_viewdef('ops.v_health_status'::regclass, true)) <> '4c0ef505d2f74de163963272cd88f4e4' THEN
    RAISE EXCEPTION 'ops.v_health_status changed since this migration was written; rebuild it from the live text';
  END IF;
END
$pin2$;

-- 4. Register the check in both health views (live text + one list entry each + one CASE arm) ---------
-- From here to COMMIT the two views are locked: cheap reads only.
CREATE OR REPLACE VIEW ops.v_health_items AS
WITH latest AS (
         SELECT DISTINCT ON (l.sync_source) l.sync_source,
            l.status,
            l.started_at,
            l.details
           FROM sync_log l
          WHERE l.sync_source = ANY (ARRAY['calendar-push-health'::text, 'blackout-health'::text, 'rpa-derm-health'::text, 'sa-schedule-gap-check'::text, 'jobber-sync-health'::text, 'note-photo-sync-health'::text, 'jobber-client-state-sweep'::text, 'start-flags-health'::text, 'db-backup-health'::text, 'notification-health'::text])
          ORDER BY l.sync_source, l.started_at DESC
        )
 SELECT la.sync_source AS check_name,
    la.status,
    la.started_at AS last_run_at,
    COALESCE(i.value ->> 'visit_id'::text, i.value ->> 'dump_folder'::text, i.value ->> 'kind'::text, i.value ->> 'client_code'::text, i.value::text) AS item_key,
    i.value AS item
   FROM latest la
     CROSS JOIN LATERAL jsonb_array_elements(
        CASE la.sync_source
            WHEN 'calendar-push-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'blackout-health'::text THEN COALESCE(la.details -> 'sheets'::text, '[]'::jsonb)
            WHEN 'rpa-derm-health'::text THEN COALESCE(la.details -> 'reasons'::text, '[]'::jsonb)
            WHEN 'sa-schedule-gap-check'::text THEN COALESCE(la.details -> 'sample'::text, '[]'::jsonb)
            WHEN 'jobber-sync-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'note-photo-sync-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'jobber-client-state-sweep'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'start-flags-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'db-backup-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'notification-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            ELSE '[]'::jsonb
        END) i(value);

CREATE OR REPLACE VIEW ops.v_health_status AS
WITH runs AS (
         SELECT l.id,
            l.sync_source,
            l.status,
            l.started_at,
            l.rows_errored,
            l.details,
            row_number() OVER (PARTITION BY l.sync_source ORDER BY l.started_at DESC) AS rn,
                CASE l.sync_source
                    WHEN 'calendar-push-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'blackout-health'::text THEN COALESCE(l.details -> 'sheets'::text, '[]'::jsonb)
                    WHEN 'rpa-derm-health'::text THEN COALESCE(l.details -> 'reasons'::text, '[]'::jsonb)
                    WHEN 'sa-schedule-gap-check'::text THEN COALESCE(l.details -> 'sample'::text, '[]'::jsonb)
                    WHEN 'jobber-sync-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'jobber-client-state-sweep'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'start-flags-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'note-photo-sync-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'db-backup-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'notification-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    ELSE '[]'::jsonb
                END AS raw_items
           FROM sync_log l
          WHERE l.sync_source = ANY (ARRAY['calendar-push-health'::text, 'blackout-health'::text, 'rpa-derm-health'::text, 'sa-schedule-gap-check'::text, 'jobber-sync-health'::text, 'jobber-client-state-sweep'::text, 'start-flags-health'::text, 'note-photo-sync-health'::text, 'db-backup-health'::text, 'notification-health'::text])
        ), keyed AS (
         SELECT r.id,
            r.sync_source,
            r.status,
            r.started_at,
            r.rows_errored,
            r.details,
            r.rn,
            r.raw_items,
            COALESCE(( SELECT jsonb_agg(DISTINCT COALESCE(i.value ->> 'visit_id'::text, i.value ->> 'dump_folder'::text, i.value ->> 'kind'::text, i.value ->> 'client_code'::text, i.value::text)) AS jsonb_agg
                   FROM jsonb_array_elements(r.raw_items) i(value)), '[]'::jsonb) AS item_keys
           FROM runs r
          WHERE r.rn <= 2
        ), streak AS (
         SELECT g.sync_source,
            g.status,
            count(*) AS runs_in_streak,
            min(g.started_at) AS streak_started_at
           FROM ( SELECT l.sync_source,
                    l.status,
                    l.started_at,
                    row_number() OVER (PARTITION BY l.sync_source ORDER BY l.started_at DESC) - row_number() OVER (PARTITION BY l.sync_source, l.status ORDER BY l.started_at DESC) AS grp
                   FROM sync_log l
                  WHERE l.sync_source = ANY (ARRAY['calendar-push-health'::text, 'blackout-health'::text, 'rpa-derm-health'::text, 'sa-schedule-gap-check'::text, 'jobber-sync-health'::text, 'jobber-client-state-sweep'::text, 'start-flags-health'::text, 'note-photo-sync-health'::text, 'db-backup-health'::text, 'notification-health'::text])) g
          GROUP BY g.sync_source, g.status, g.grp
         HAVING max(g.started_at) = (( SELECT max(l2.started_at) AS max
                   FROM sync_log l2
                  WHERE l2.sync_source = g.sync_source))
        ), cur AS (
         SELECT keyed.id,
            keyed.sync_source,
            keyed.status,
            keyed.started_at,
            keyed.rows_errored,
            keyed.details,
            keyed.rn,
            keyed.raw_items,
            keyed.item_keys
           FROM keyed
          WHERE keyed.rn = 1
        ), prev AS (
         SELECT keyed.id,
            keyed.sync_source,
            keyed.status,
            keyed.started_at,
            keyed.rows_errored,
            keyed.details,
            keyed.rn,
            keyed.raw_items,
            keyed.item_keys
           FROM keyed
          WHERE keyed.rn = 2
        )
 SELECT c.sync_source AS check_name,
    c.status,
    c.started_at AS last_run_at,
    jsonb_array_length(c.item_keys) AS item_count,
    COALESCE(jsonb_array_length(p.item_keys), 0) AS item_count_previous_run,
    c.rows_errored AS rows_errored_raw,
    ( SELECT COALESCE(jsonb_agg(k.value), '[]'::jsonb) AS "coalesce"
           FROM jsonb_array_elements(c.item_keys) k(value)
          WHERE NOT COALESCE(p.item_keys, '[]'::jsonb) @> jsonb_build_array(k.value)) AS new_items,
    ( SELECT COALESCE(jsonb_agg(k.value), '[]'::jsonb) AS "coalesce"
           FROM jsonb_array_elements(COALESCE(p.item_keys, '[]'::jsonb)) k(value)
          WHERE NOT c.item_keys @> jsonb_build_array(k.value)) AS resolved_items,
    c.item_keys = COALESCE(p.item_keys, '[]'::jsonb) AS unchanged_since_last_run,
    s.runs_in_streak AS consecutive_runs_same_status,
    s.streak_started_at AS status_since,
    c.details
   FROM cur c
     LEFT JOIN prev p ON p.sync_source = c.sync_source
     LEFT JOIN streak s ON s.sync_source = c.sync_source AND s.status = c.status;

-- VERIFY 2: the health views. Cheap reads only: it runs while the replaced views are locked.
DO $verify_views$
DECLARE
  v_n_real int; v_keys_real int; v_fix_item boolean; v_fix_status boolean;
BEGIN
  -- registered in the source list AND the CASE of both views (a list entry with no arm contributes nothing)
  IF (length(pg_get_viewdef('ops.v_health_items'::regclass, true)) - length(replace(pg_get_viewdef('ops.v_health_items'::regclass, true), '''notification-health''::text', ''))) / length('''notification-health''::text') <> 2
     OR pg_get_viewdef('ops.v_health_items'::regclass, true) NOT LIKE '%WHEN ''notification-health''::text THEN COALESCE(la.details -> ''items''::text%' THEN
    RAISE EXCEPTION 'VERIFY views: v_health_items must name notification-health once in its list and once in its CASE'; END IF;
  IF (length(pg_get_viewdef('ops.v_health_status'::regclass, true)) - length(replace(pg_get_viewdef('ops.v_health_status'::regclass, true), '''notification-health''::text', ''))) / length('''notification-health''::text') <> 3
     OR pg_get_viewdef('ops.v_health_status'::regclass, true) NOT LIKE '%WHEN ''notification-health''::text THEN COALESCE(l.details -> ''items''::text%' THEN
    RAISE EXCEPTION 'VERIFY views: v_health_status must name notification-health in both lists and its CASE'; END IF;

  -- the real run written by VERIFY 1 is visible, one row per item, every key distinct
  SELECT jsonb_array_length(l.details->'items') INTO v_n_real
    FROM public.sync_log l WHERE l.sync_source = 'notification-health' ORDER BY l.started_at DESC LIMIT 1;
  SELECT count(DISTINCT item_key) INTO v_keys_real FROM ops.v_health_items WHERE check_name = 'notification-health';
  IF v_keys_real IS DISTINCT FROM v_n_real
     OR (SELECT count(*) FROM ops.v_health_items WHERE check_name = 'notification-health') <> v_n_real THEN
    RAISE EXCEPTION 'VERIFY views: v_health_items shows % distinct keys for a run with % items', v_keys_real, v_n_real; END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.v_health_status WHERE check_name = 'notification-health' AND item_count = v_n_real) THEN
    RAISE EXCEPTION 'VERIFY views: v_health_status does not show the notification-health run'; END IF;

  -- fixture (rolled back): a run with one item must reach both views, keyed on its kind, and read as new.
  -- A check with 0 items reads 0 in both views whether or not its CASE arm exists, so this is the real test.
  BEGIN
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
    VALUES ('notification-health', clock_timestamp(), clock_timestamp(), 1, 'attention',
            '{"count":1,"items":[{"kind":"verify_fixture:item-1","issue":"verify_fixture","reason":"fixture","what_to_do":"none"}]}');
    v_fix_item := EXISTS (SELECT 1 FROM ops.v_health_items WHERE check_name = 'notification-health' AND item_key = 'verify_fixture:item-1');
    v_fix_status := EXISTS (SELECT 1 FROM ops.v_health_status WHERE check_name = 'notification-health' AND item_count = 1
                              AND new_items @> '["verify_fixture:item-1"]');
    RAISE EXCEPTION USING ERRCODE = 'NH004', MESSAGE = 'roll back the view fixture';
  EXCEPTION WHEN SQLSTATE 'NH004' THEN NULL;
  END;
  IF NOT v_fix_item THEN RAISE EXCEPTION 'VERIFY views: the fixture item did not reach v_health_items under its kind'; END IF;
  IF NOT v_fix_status THEN RAISE EXCEPTION 'VERIFY views: the fixture item did not show as new in v_health_status'; END IF;

  -- the other nine checks read exactly as before the change (snapshot nh_before_* taken just before the DDL)
  IF EXISTS ((SELECT check_name, item_key FROM ops.v_health_items WHERE check_name <> 'notification-health'
              EXCEPT ALL SELECT check_name, item_key FROM nh_before_items WHERE check_name <> 'notification-health')
             UNION ALL
             (SELECT check_name, item_key FROM nh_before_items WHERE check_name <> 'notification-health'
              EXCEPT ALL SELECT check_name, item_key FROM ops.v_health_items WHERE check_name <> 'notification-health'))
     OR EXISTS ((SELECT check_name, status, item_count, new_items FROM ops.v_health_status WHERE check_name <> 'notification-health'
                 EXCEPT SELECT check_name, status, item_count, new_items FROM nh_before_status)
                UNION ALL
                (SELECT check_name, status, item_count, new_items FROM nh_before_status
                 EXCEPT SELECT check_name, status, item_count, new_items FROM ops.v_health_status WHERE check_name <> 'notification-health')) THEN
    RAISE EXCEPTION 'VERIFY views: another check reads differently after the change'; END IF;

  RAISE NOTICE 'VERIFY views ok: notification-health shows % item(s)', v_n_real;
END
$verify_views$;

DO $acl$
BEGIN
  -- CREATE OR REPLACE VIEW keeps the grants; prove it (authenticated may READ the state, never change it)
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'ops.v_health_items'::regclass)
       <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,yannick_readonly=r/postgres,db_backup_reader=r/postgres}'
     OR (SELECT relacl::text FROM pg_class WHERE oid = 'ops.v_health_status'::regclass)
       <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,yannick_readonly=r/postgres,db_backup_reader=r/postgres}' THEN
    RAISE EXCEPTION 'VERIFY: a health view''s grants changed';
  END IF;
  IF has_table_privilege('anon', 'ops.v_health_items', 'SELECT') OR has_table_privilege('anon', 'ops.v_health_status', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY: anon can read a health view';
  END IF;
END
$acl$;

COMMIT;
