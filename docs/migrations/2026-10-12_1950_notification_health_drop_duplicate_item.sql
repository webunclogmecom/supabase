-- ============================================================================
-- 2026-10-12_1950  notification-health: drop item G (city_email_duplicate)
--                  (HHMM is stamped at apply, in the file name, so the file sorts after every migration already in
--                  docs/migrations: sorted order = apply order.)
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-12: "we can send multiple emails that doesn't matter". Item G of 2026-10-12_1400
--   (city_email_duplicate:visit-<id>, "the city received its manifest 2 or more times") flagged 6138 and 6247 in his
--   health email on its first run, for something he has now said is fine. Who sent what, and how often, is shown
--   instead by the history view public.v_visit_city_email_sends (its own migration, visit_city_email_sends).
--
-- WHAT CHANGES
--   public.fn_notification_health_items(jsonb, timestamptz): item G is deleted, and only item G. Copied from the LIVE
--   pg_get_functiondef (md5 f7ae132cfc117c08078ef5da96bd3fe1, pinned below), then 23 lines removed and nothing else
--   (health-g/tests/items.diff, deletions only):
--     - the msend and g0 CTEs (with their comment line), which only item G read;
--     - "UNION SELECT visit_id FROM g0" in base. It only added visits for G: every other item filters label rows on
--       conditions those rows already meet through base's other branches (A on listed, B / C / F on a live completed
--       visit since Sep 15), and D and E do not read label. VERIFY H4 and H5 prove it on 8 inputs;
--     - the G arm of items.
--   The new body's md5 (8a9961d5db8d288b830ccbd0f3a52085, line endings ignored) is asserted after the replace, so what
--   applies is exactly what was diffed.
--   public.log_notification_health(jsonb) does NOT name the item (prosrc search 2026-10-12: only
--   fn_notification_health_items holds 'city_email_duplicate'; no view does), so it is not replaced; its md5
--   (ccbae800bbd62d3cf85c1c1d51e54225) is pinned before and asserted unchanged after.
--   GRANTS, re-asserted for both (health-chain rule, Supabase CLAUDE.md): REVOKE ALL BY NAME FROM PUBLIC, anon,
--   authenticated; EXECUTE to service_role only; checked with has_function_privilege and the exact proacl.
--
-- WHAT STAYS: items A to F and notification_check_failed, word for word; the cron (notification-health, 15 13 * * *);
--   ops.v_health_items and ops.v_health_status (they explode details->'items', so G simply stops appearing; neither
--   is touched); the 2026-10-12_1400 file (its header and VERIFY V8 / V8b are the record of what G was).
--
-- THE TWO OPEN ITEMS (city_email_duplicate:visit-6138, :visit-6247)
--   ops.v_health_items reads only the LATEST notification-health run, and the latest run at writing (sync_log 77837,
--   2026-10-12 15:04 ET) still holds them. This file ends with one real run that it keeps (as 2026-10-12_1400 did),
--   so they leave v_health_items at apply. Without that run they would leave at the next cron run (13:15 UTC).
--   public.health_alert_state needs NOTHING, and must not be hand-edited:
--   - today it holds no notification-health row at all: the 2026-10-12 13:30 UTC scan ran before the check existed.
--     Applied before the 2026-10-13 13:30 UTC scan, the two items never reach it and are never emailed;
--   - applied after that scan, the scan will have recorded them (and emailed them as new). The next scan's step (b)
--     sets resolved_at because v_health_items no longer lists them, and they ride along as "resolved" in the next
--     mail that goes out anyway; a resolution never sends a mail by itself. No fn_health_ack either: that is a
--     time-boxed mute for a problem that still exists, and this one no longer does.
--
-- VERIFY (all inside this transaction; data fixtures in sub-blocks that always roll back)
--   H1 grants of both functions, exactly.
--   H2 the bodies: new md5 as diffed, log_notification_health unchanged, no function left naming city_email_duplicate.
--   H3 the instrument can see G: the OLD body (kept as pg_temp.nhg_old_items, built from the live text pinned above)
--      reports 6138 and 6247 judged at 2026-10-12 17:00 UTC (send-log history, cannot change); the new body does
--      not; and the comparator must fire: it refuses the old output (G included) as equal to itself minus G.
--   H4 new = old minus its G items, item for item, on 6 inputs that write nothing: the live list, an empty list, the
--      Oct 8 / Oct 10 historical list (A must fire), Oct 12 and Sep 28 (B must fire) as of, and 20 days ahead (F
--      fires while visits wait for a manifest).
--   H5 fixtures that must fire, rolled back: property P loses its city inbox and moves, with exactly 3 inbox
--      neighbours, to a new city (D, which pins its threshold at 3), a failed Admin Review reminder run
--      30 hours ago (E, both kinds), Admin Review row 187 without the manifest (C, 6275), and two Admin Review sends
--      WITH the manifest on unsent visit Q (the old body reports a G item for Q, the new one must not). Then a
--      rolled-back run of log_notification_health: its row holds D, E and C, no G, its by_issue has no G key, its
--      items equal old minus G, and ops.v_health_items shows exactly those keys.
--   H6 rolled-back runs of log_notification_health on the live data (no G; items = old minus G; v_health_items) and
--      on a list holding 6247 (A, city_list_false_positive:visit-6247, must fire through the cron entry point).
--   H7 every fixture rolled back (row 187, P and its 3 neighbours, no Verify Town, no fixture send left, sync_log
--      counts unchanged).
--
-- LOCKS: CREATE OR REPLACE FUNCTION blocks no reader (the cron is the only caller, at 13:15 UTC). The fixtures hold
--   row locks on visit_photo_email_sends 187, four properties rows (P and its 3 neighbours), two inserted send rows
--   and one inserted sync_log row for about a second. Refuses to run 13:00 to 13:35 UTC (the health crons write
--   then, and the 13:15 run would race the kept run). SET LOCAL lock_timeout = '3s'. REPEATABLE READ: one snapshot
--   for every comparison; a concurrent change to a fixture row aborts the file, which is safe.
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table is created or altered. The function writes only public.sync_log, the
--   sync journal, which is not audited by design; the kept run writes one row there. The fixture writes to
--   visit_photo_email_sends and properties (audited) are inside sub-blocks that always roll back, their audit rows
--   with them. Not applicable.
-- APPLY: with the file's LF line endings as written (a CRLF copy still applies: H2 ignores carriage returns, but the
--   stored body then carries them, so the next md5 pin of it will differ). At apply, update the Supabase CLAUDE.md
--   line "The daily check" in '"HAS THIS VISIT'S CITY EMAIL GONE?" HAS ONE ANSWER': drop city_email_duplicate from
--   the list and "6138 and 6247 (duplicates, clear Oct 16)" from its first run.
-- ROLLBACK: re-create public.fn_notification_health_items from the 2026-10-12_1400 body (live md5 f7ae132c... at
--   writing) with the same REVOKE / GRANT; the next run brings G back.
-- ============================================================================

BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL lock_timeout = '3s';

DO $pre$
BEGIN
  IF (now() AT TIME ZONE 'UTC')::time BETWEEN time '13:00' AND time '13:35' THEN
    RAISE EXCEPTION 'the health crons run now (13:00 to 13:35 UTC): apply after 13:35 UTC';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'fn_notification_health_items' AND pronamespace = 'public'::regnamespace) <> 1
     OR (SELECT count(*) FROM pg_proc WHERE proname = 'log_notification_health' AND pronamespace = 'public'::regnamespace) <> 1 THEN
    RAISE EXCEPTION 'expected exactly one fn_notification_health_items and one log_notification_health';
  END IF;
  -- the live bodies this file was written against (read 2026-10-12 18:59 ET); re-read and re-diff if this fails
  IF md5(pg_get_functiondef('public.fn_notification_health_items(jsonb,timestamptz)'::regprocedure)) <> 'f7ae132cfc117c08078ef5da96bd3fe1' THEN
    RAISE EXCEPTION 'fn_notification_health_items changed since this file was written: copy the live body again and re-diff';
  END IF;
  IF md5(pg_get_functiondef('public.log_notification_health(jsonb)'::regprocedure)) <> 'ccbae800bbd62d3cf85c1c1d51e54225' THEN
    RAISE EXCEPTION 'log_notification_health changed since this file was written: check whether it now names city_email_duplicate';
  END IF;
END $pre$;

-- the OLD body, kept for the before/after comparison, built from the live text the pin above just checked
DO $old$
DECLARE
  def text := pg_get_functiondef('public.fn_notification_health_items(jsonb,timestamptz)'::regprocedure);
  anchor text := 'CREATE OR REPLACE FUNCTION public.fn_notification_health_items(';
BEGIN
  IF (length(def) - length(replace(def, anchor, ''))) / length(anchor) <> 1 THEN
    RAISE EXCEPTION 'the old body header was not found exactly once';
  END IF;
  EXECUTE replace(def, anchor, 'CREATE FUNCTION pg_temp.nhg_old_items(');
END $old$;

-- old items minus its G items, order kept (the old body sorts by kind; removing elements keeps that order)
CREATE FUNCTION pg_temp.nhg_minus_g(items jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $f$
  SELECT coalesce(jsonb_agg(i ORDER BY o), '[]'::jsonb)
  FROM jsonb_array_elements(items) WITH ORDINALITY t(i, o)
  WHERE i->>'issue' IS DISTINCT FROM 'city_email_duplicate'
$f$;
-- the comparator: the new output equals the old output minus G, item for item
CREATE FUNCTION pg_temp.nhg_same(old_items jsonb, new_items jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $f$
  SELECT jsonb_typeof(old_items) = 'array' AND jsonb_typeof(new_items) = 'array' AND pg_temp.nhg_minus_g(old_items) = new_items
$f$;
CREATE FUNCTION pg_temp.nhg_has(items jsonb, k text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $f$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(items) i WHERE i->>'kind' = k)
$f$;
CREATE FUNCTION pg_temp.nhg_has_g(items jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $f$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(items) i
                  WHERE i->>'issue' = 'city_email_duplicate' OR i->>'kind' LIKE 'city_email_duplicate%')
$f$;
CREATE FUNCTION pg_temp.nhg_issues(items jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $f$
  SELECT coalesce(jsonb_object_agg(k, n), '{}'::jsonb) FROM (SELECT i->>'issue' k, count(*) n FROM jsonb_array_elements(items) i GROUP BY 1) z
$f$;
-- what the receipt reports after COMMIT (a session temp table, gone when the connection closes)
CREATE TEMP TABLE _nhg_report (k text PRIMARY KEY, v jsonb);

-- The new body: the live body with item G removed (health-g/tests/items.diff). Nothing else moved.
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
  )
  -- one item per key: the health scan upserts on (check, key), and a repeated key in one run would abort it
  SELECT coalesce(jsonb_agg(u.item ORDER BY u.item->>'kind'), '[]'::jsonb)
  FROM (SELECT DISTINCT ON (i.item->>'kind') i.item FROM items i ORDER BY i.item->>'kind') u
$function$;

REVOKE ALL ON FUNCTION public.fn_notification_health_items(jsonb, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.log_notification_health(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_notification_health_items(jsonb, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.log_notification_health(jsonb) TO service_role;

DO $verify$
DECLARE
  fn text;
  v_list jsonb; v_old jsonb; v_new jsonb; o1 jsonb; n1 jsonb; o2 jsonb; n2 jsonb; v_row jsonb;
  v_hist jsonb := '[{"visit_id":8575},{"visit_id":8744},{"visit_id":6138},{"visit_id":6247},{"visit_id":6218},{"visit_id":6270},{"visit_id":6284}]';
  lbl text; v_at timestamptz;
  p_id bigint; q_id bigint; n_items int;
  h187 text; hp text; n_nh bigint; n_rem bigint; nb bigint[];
  ok_eq boolean; ok_old_g boolean; ok_fire boolean; ok_no_g boolean; ok_log boolean; ok_vhi boolean;
  rep5 jsonb; rep6 jsonb;
BEGIN
  -- H1. grants: service_role (and cron as postgres) only, revoked BY NAME, no PUBLIC grant, exact proacl
  FOREACH fn IN ARRAY ARRAY['public.fn_notification_health_items(jsonb,timestamptz)', 'public.log_notification_health(jsonb)'] LOOP
    IF has_function_privilege('anon', fn, 'EXECUTE') OR has_function_privilege('authenticated', fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'VERIFY H1: % is callable by anon or authenticated', fn; END IF;
    IF NOT has_function_privilege('service_role', fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'VERIFY H1: service_role cannot execute %', fn; END IF;
    IF (SELECT proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(proacl) a WHERE a.grantee = 0)
               OR proacl::text <> '{postgres=X/postgres,service_role=X/postgres}'
          FROM pg_proc WHERE oid = fn::regprocedure) THEN
      RAISE EXCEPTION 'VERIFY H1: % has proacl %', fn, (SELECT proacl::text FROM pg_proc WHERE oid = fn::regprocedure); END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'fn_notification_health_items' AND pronamespace = 'public'::regnamespace) <> 1 THEN
    RAISE EXCEPTION 'VERIFY H1: an overload of fn_notification_health_items appeared'; END IF;

  -- H2. the bodies
  IF md5(replace(pg_get_functiondef('public.fn_notification_health_items(jsonb,timestamptz)'::regprocedure), chr(13), ''))
       <> '8a9961d5db8d288b830ccbd0f3a52085' THEN
    RAISE EXCEPTION 'VERIFY H2: the new body is not the one that was diffed'; END IF;
  IF md5(pg_get_functiondef('public.log_notification_health(jsonb)'::regprocedure)) <> 'ccbae800bbd62d3cf85c1c1d51e54225' THEN
    RAISE EXCEPTION 'VERIFY H2: log_notification_health changed'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.prosrc LIKE '%city_email_duplicate%' AND p.pronamespace <> pg_my_temp_schema()) THEN
    RAISE EXCEPTION 'VERIFY H2: a function still names city_email_duplicate: %',
      (SELECT string_agg(p.oid::regprocedure::text, ', ') FROM pg_proc p WHERE p.prosrc LIKE '%city_email_duplicate%' AND p.pronamespace <> pg_my_temp_schema()); END IF;

  -- H3. the instrument can see G. Judged at 2026-10-12 17:00 UTC (the send logs are read as of then, history)
  v_old := pg_temp.nhg_old_items('[]', timestamptz '2026-10-12 17:00+00');
  v_new := public.fn_notification_health_items('[]', timestamptz '2026-10-12 17:00+00');
  IF NOT (pg_temp.nhg_has(v_old, 'city_email_duplicate:visit-6138') AND pg_temp.nhg_has(v_old, 'city_email_duplicate:visit-6247')) THEN
    RAISE EXCEPTION 'VERIFY H3: the old body no longer reports 6138 and 6247 on Oct 12, so this check cannot see G: %', pg_temp.nhg_issues(v_old); END IF;
  IF pg_temp.nhg_has_g(v_new) THEN RAISE EXCEPTION 'VERIFY H3: the new body still reports G: %', pg_temp.nhg_issues(v_new); END IF;
  IF pg_temp.nhg_same(v_old, v_old) THEN
    RAISE EXCEPTION 'VERIFY H3: the comparator cannot fire (it accepts the old output, G included, as equal to itself minus G)'; END IF;

  -- H4. new = old minus G on inputs that write nothing; A and B must fire
  FOR lbl, v_list, v_at IN
    SELECT * FROM (VALUES
      ('live_now', public.fn_admin_review_pending() -> 'city', now()),
      ('empty_now', '[]'::jsonb, now()),
      ('hist_now', v_hist, now()),
      ('empty_oct12', '[]'::jsonb, timestamptz '2026-10-12 17:00+00'),
      ('empty_sep28', '[]'::jsonb, timestamptz '2026-09-28 17:00+00'),
      ('empty_plus20d', '[]'::jsonb, now() + interval '20 days')) x(l, li, a)
  LOOP
    v_old := pg_temp.nhg_old_items(v_list, v_at);
    v_new := public.fn_notification_health_items(v_list, v_at);
    IF NOT pg_temp.nhg_same(v_old, v_new) THEN
      RAISE EXCEPTION 'VERIFY H4 %: the new body is not the old one minus G: old % new %', lbl, pg_temp.nhg_issues(v_old), pg_temp.nhg_issues(v_new); END IF;
    IF lbl = 'hist_now' AND NOT pg_temp.nhg_has(v_new, 'city_list_false_positive:visit-6247') THEN
      RAISE EXCEPTION 'VERIFY H4: A did not fire for 6247 on the historical list: %', pg_temp.nhg_issues(v_new); END IF;
    IF lbl = 'empty_sep28' AND NOT coalesce((pg_temp.nhg_issues(v_new)->>'city_list_missed')::int > 0, false) THEN
      RAISE EXCEPTION 'VERIFY H4: B did not fire as of Sep 28: %', pg_temp.nhg_issues(v_new); END IF;
    INSERT INTO _nhg_report VALUES ('H4 ' || lbl, jsonb_build_object('old', pg_temp.nhg_issues(v_old), 'new', pg_temp.nhg_issues(v_new)));
  END LOOP;

  -- H5. fixtures that must fire, then a rolled-back run of log_notification_health under them
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
  SELECT min(v.id) INTO q_id FROM public.visits v
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date >= '2026-09-15'
     AND NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture'])
     AND NOT EXISTS (SELECT 1 FROM public.visit_photo_email_sends s WHERE s.visit_id = v.id AND s.status = 'sent' AND NOT coalesce(s.is_test, false))
     AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_email_sends d ON d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
                      WHERE mv.visit_id = v.id AND d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false));
  -- three other live, non-billing properties with a city inbox: moved with P to a new city, they pin D's threshold at exactly 3
  SELECT (array_agg(q.id ORDER BY q.id))[1:3] INTO nb FROM public.properties q
   WHERE q.deleted_at IS NULL AND NOT coalesce(q.is_billing, false) AND q.id <> p_id
     AND EXISTS (SELECT 1 FROM unnest(coalesce(q.city_emails, '{}'::text[])) e WHERE position('@' IN e) > 0);
  IF p_id IS NULL OR q_id IS NULL OR cardinality(nb) IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION 'VERIFY H5: no property or visit to build the fixtures from (% % %)', p_id, q_id, nb; END IF;
  SELECT md5(to_jsonb(s)::text) INTO h187 FROM public.visit_photo_email_sends s WHERE s.id = 187;
  SELECT md5(string_agg(to_jsonb(p)::text, '|' ORDER BY p.id)) INTO hp FROM public.properties p WHERE p.id = p_id OR p.id = ANY (nb);
  n_nh := (SELECT count(*) FROM public.sync_log WHERE sync_source = 'notification-health');
  n_rem := (SELECT count(*) FROM public.sync_log WHERE sync_source = 'admin_review_reminder');
  INSERT INTO _nhg_report VALUES ('H5 fixtures', jsonb_build_object('D_property', p_id, 'D_neighbours', to_jsonb(nb), 'G_visit', q_id));
  BEGIN
    UPDATE public.properties SET city_emails = '{}'::text[] WHERE id = p_id;                                        -- D
    UPDATE public.properties SET city = 'Verify Town' WHERE id = p_id OR id = ANY (nb);                                 -- D, exactly 3
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, status, details)                                -- E
    VALUES ('admin_review_reminder', now() - interval '30 hours', now() - interval '30 hours', 'error',
            '{"reason":"VERIFY fixture of notification_health_drop_duplicate_item, rolled back"}');
    UPDATE public.visit_photo_email_sends SET include_manifest = false WHERE id = 187;                                -- C (6275)
    INSERT INTO public.visit_photo_email_sends (visit_id, recipient_email, status, is_test, include_manifest, sent_at, reason)  -- G
    SELECT q_id, 'verify-fixture@example.invalid', 'sent', false, true, now() - f.ago,
           'VERIFY fixture of notification_health_drop_duplicate_item, rolled back'
      FROM unnest(ARRAY[interval '1 day', interval '2 days']) f(ago);
    o1 := pg_temp.nhg_old_items('[]');                 n1 := public.fn_notification_health_items('[]');
    o2 := pg_temp.nhg_old_items('[]', now() + interval '20 days');  n2 := public.fn_notification_health_items('[]', now() + interval '20 days');
    ok_eq := pg_temp.nhg_same(o1, n1) AND pg_temp.nhg_same(o2, n2);
    ok_old_g := pg_temp.nhg_has(o1, 'city_email_duplicate:visit-' || q_id);
    ok_fire := EXISTS (SELECT 1 FROM jsonb_array_elements(n1) i WHERE i->>'kind' = 'city_inbox_missing:property-' || p_id
                                                                  AND i->>'reason' LIKE '%while 3 other Verify Town properties%')
           AND pg_temp.nhg_has(n1, 'reminder_not_run:admin_review_reminder')
           AND pg_temp.nhg_has(n1, 'reminder_failed:admin_review_reminder')
           AND pg_temp.nhg_has(n1, 'manifest_follow_stalled:visit-6275');
    ok_no_g := NOT pg_temp.nhg_has_g(n1) AND NOT pg_temp.nhg_has_g(n2);
    n_items := public.log_notification_health();
    SELECT jsonb_build_object('status', l.status, 'rows_errored', l.rows_errored, 'details', l.details) INTO v_row
      FROM public.sync_log l WHERE l.sync_source = 'notification-health' ORDER BY l.started_at DESC LIMIT 1;
    v_list := public.fn_admin_review_pending() -> 'city';
    ok_log := v_row->>'status' = 'attention' AND (v_row->>'rows_errored')::int = n_items
          AND v_row#>'{details,items}' = public.fn_notification_health_items(v_list)
          AND pg_temp.nhg_same(pg_temp.nhg_old_items(v_list), v_row#>'{details,items}')
          AND NOT pg_temp.nhg_has_g(v_row#>'{details,items}') AND NOT (v_row#>'{details,by_issue}') ? 'city_email_duplicate'
          AND pg_temp.nhg_has(v_row#>'{details,items}', 'city_inbox_missing:property-' || p_id)
          AND pg_temp.nhg_has(v_row#>'{details,items}', 'reminder_failed:admin_review_reminder')
          AND pg_temp.nhg_has(v_row#>'{details,items}', 'manifest_follow_stalled:visit-6275');
    ok_vhi := NOT EXISTS ((SELECT item_key FROM ops.v_health_items WHERE check_name = 'notification-health')
                          EXCEPT ALL SELECT i->>'kind' FROM jsonb_array_elements(v_row#>'{details,items}') i)
          AND NOT EXISTS ((SELECT i->>'kind' FROM jsonb_array_elements(v_row#>'{details,items}') i)
                          EXCEPT ALL SELECT item_key FROM ops.v_health_items WHERE check_name = 'notification-health')
          AND NOT EXISTS (SELECT 1 FROM ops.v_health_items WHERE check_name = 'notification-health' AND item_key LIKE 'city_email_duplicate%');
    -- captured in a variable: a row written here would roll back with the fixtures
    rep5 := jsonb_build_object('old_now', pg_temp.nhg_issues(o1), 'new_now', pg_temp.nhg_issues(n1),
                                    'old_plus20d', pg_temp.nhg_issues(o2), 'new_plus20d', pg_temp.nhg_issues(n2),
                                    'log_run', jsonb_build_object('status', v_row->>'status', 'by_issue', v_row#>'{details,by_issue}'));
    RAISE EXCEPTION USING ERRCODE = 'NHG05', MESSAGE = 'roll back the H5 fixtures';
  EXCEPTION WHEN SQLSTATE 'NHG05' THEN NULL;
  END;
  INSERT INTO _nhg_report VALUES ('H5 under fixtures', rep5);
  IF NOT ok_old_g THEN RAISE EXCEPTION 'VERIFY H5: the G fixture (two sends with the manifest on visit %) did not make the OLD body report it', q_id; END IF;
  IF NOT ok_fire THEN RAISE EXCEPTION 'VERIFY H5: a fixture did not fire in the new body (D property %, E, C 6275)', p_id; END IF;
  IF NOT ok_no_g THEN RAISE EXCEPTION 'VERIFY H5: the new body reported G under the fixtures'; END IF;
  IF NOT ok_eq THEN RAISE EXCEPTION 'VERIFY H5: under the fixtures the new body is not the old one minus G'; END IF;
  IF NOT ok_log THEN RAISE EXCEPTION 'VERIFY H5: the rolled-back log_notification_health run under the fixtures wrote the wrong row'; END IF;
  IF NOT ok_vhi THEN RAISE EXCEPTION 'VERIFY H5: ops.v_health_items does not show exactly that run''s items'; END IF;

  -- H6. rolled-back cron-entry runs: the live data, then a list holding 6247 (A must fire through log_notification_health)
  BEGIN
    n_items := public.log_notification_health();
    SELECT l.details INTO v_row FROM public.sync_log l WHERE l.sync_source = 'notification-health' ORDER BY l.started_at DESC LIMIT 1;
    v_list := public.fn_admin_review_pending() -> 'city';
    ok_log := jsonb_array_length(v_row->'items') = n_items AND NOT pg_temp.nhg_has_g(v_row->'items')
          AND NOT (v_row->'by_issue') ? 'city_email_duplicate'
          AND NOT v_row->'items' @> '[{"issue":"notification_check_failed"}]'
          AND pg_temp.nhg_same(pg_temp.nhg_old_items(v_list), v_row->'items');
    ok_vhi := (SELECT count(*) FROM ops.v_health_items WHERE check_name = 'notification-health') = n_items
          AND NOT EXISTS (SELECT 1 FROM ops.v_health_items WHERE check_name = 'notification-health' AND item_key LIKE 'city_email_duplicate%');
    rep6 := jsonb_build_object('items', n_items, 'by_issue', v_row->'by_issue',
                               'old_would_have', pg_temp.nhg_issues(pg_temp.nhg_old_items(v_list)));
    n_items := public.log_notification_health('{"city":[{"visit_id":6247}]}');
    SELECT l.details INTO v_row FROM public.sync_log l WHERE l.sync_source = 'notification-health' ORDER BY l.started_at DESC LIMIT 1;
    ok_fire := pg_temp.nhg_has(v_row->'items', 'city_list_false_positive:visit-6247') AND NOT pg_temp.nhg_has_g(v_row->'items')
           AND EXISTS (SELECT 1 FROM ops.v_health_items WHERE check_name = 'notification-health' AND item_key = 'city_list_false_positive:visit-6247');
    RAISE EXCEPTION USING ERRCODE = 'NHG06', MESSAGE = 'roll back the H6 runs';
  EXCEPTION WHEN SQLSTATE 'NHG06' THEN NULL;
  END;
  INSERT INTO _nhg_report VALUES ('H6 live run', rep6);
  IF NOT ok_log THEN RAISE EXCEPTION 'VERIFY H6: the live rolled-back run wrote G, failed, or is not the old items minus G'; END IF;
  IF NOT ok_vhi THEN RAISE EXCEPTION 'VERIFY H6: ops.v_health_items does not show the live run without G'; END IF;
  IF NOT ok_fire THEN RAISE EXCEPTION 'VERIFY H6: A did not fire for 6247 through log_notification_health'; END IF;

  -- H7. every fixture rolled back
  IF (SELECT md5(to_jsonb(s)::text) FROM public.visit_photo_email_sends s WHERE s.id = 187) IS DISTINCT FROM h187
     OR (SELECT md5(string_agg(to_jsonb(p)::text, '|' ORDER BY p.id)) FROM public.properties p WHERE p.id = p_id OR p.id = ANY (nb)) IS DISTINCT FROM hp
     OR EXISTS (SELECT 1 FROM public.properties WHERE lower(btrim(city)) = 'verify town')
     OR EXISTS (SELECT 1 FROM public.visit_photo_email_sends WHERE recipient_email = 'verify-fixture@example.invalid')
     OR (SELECT count(*) FROM public.sync_log WHERE sync_source = 'notification-health') <> n_nh
     OR (SELECT count(*) FROM public.sync_log WHERE sync_source = 'admin_review_reminder') <> n_rem THEN
    RAISE EXCEPTION 'VERIFY H7: a fixture or a rolled-back run leaked'; END IF;

  RAISE NOTICE 'VERIFY ok: %', (SELECT jsonb_object_agg(r.k, r.v) FROM _nhg_report r);
END $verify$;

DROP FUNCTION pg_temp.nhg_issues(jsonb);
DROP FUNCTION pg_temp.nhg_has_g(jsonb);
DROP FUNCTION pg_temp.nhg_has(jsonb, text);
DROP FUNCTION pg_temp.nhg_same(jsonb, jsonb);
DROP FUNCTION pg_temp.nhg_minus_g(jsonb);
DROP FUNCTION pg_temp.nhg_old_items(jsonb, timestamptz);

-- The real run this migration keeps: ops.v_health_items reads only the latest run, so the two G items leave it now
-- instead of at the next 13:15 UTC run. The check must not have failed, and must hold no G.
DO $kept$
DECLARE n_items int; d jsonb; st text;
BEGIN
  n_items := public.log_notification_health();
  SELECT l.details, l.status INTO d, st FROM public.sync_log l WHERE l.sync_source = 'notification-health' ORDER BY l.started_at DESC LIMIT 1;
  IF st NOT IN ('ok', 'attention') OR jsonb_array_length(d->'items') <> n_items
     OR d->'items' @> '[{"issue":"notification_check_failed"}]' OR (d->'by_issue') ? 'city_email_duplicate'
     OR EXISTS (SELECT 1 FROM ops.v_health_items WHERE check_name = 'notification-health' AND item_key LIKE 'city_email_duplicate%') THEN
    RAISE EXCEPTION 'VERIFY kept run: status %, items %', st, d->'by_issue'; END IF;
  INSERT INTO _nhg_report VALUES ('kept run', jsonb_build_object('status', st, 'items', n_items, 'by_issue', d->'by_issue'));
END $kept$;

COMMIT;

-- read-only receipt (the Management API returns the last result)
SELECT jsonb_build_object(
  'items_md5_lf', md5(replace(pg_get_functiondef('public.fn_notification_health_items(jsonb,timestamptz)'::regprocedure), chr(13), '')),
  'log_md5', md5(pg_get_functiondef('public.log_notification_health(jsonb)'::regprocedure)),
  'acl', (SELECT jsonb_object_agg(proname, proacl::text) FROM pg_proc
           WHERE pronamespace = 'public'::regnamespace AND proname IN ('fn_notification_health_items', 'log_notification_health')),
  'latest_run', (SELECT jsonb_build_object('id', id, 'at_et', (started_at AT TIME ZONE 'America/New_York')::text, 'status', status,
                                           'kinds', (SELECT jsonb_agg(i->>'kind') FROM jsonb_array_elements(details->'items') i))
                   FROM public.sync_log WHERE sync_source = 'notification-health' ORDER BY started_at DESC LIMIT 1),
  'v_health_items', (SELECT jsonb_agg(item_key ORDER BY item_key) FROM ops.v_health_items WHERE check_name = 'notification-health'),
  'health_alert_state', (SELECT jsonb_agg(jsonb_build_object('key', item_key, 'resolved_at', resolved_at, 'alerts', alert_count))
                           FROM public.health_alert_state WHERE check_name = 'notification-health'),
  'verify', (SELECT jsonb_object_agg(k, v) FROM _nhg_report)) AS receipt;
